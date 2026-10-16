# iVox 架构

## 概览

macOS 本地语音助手守护进程，全栈 actor 化。输入侧接 AI 工具（Claude Code、Codex、PI coding agent）、微信与全局热键，输出侧走本地 MLX TTS/ASR + 系统媒体控制；另有划词翻译（`Cmd+D`）与 Finder/终端快捷（QuickActions）。

```
                          用户
                       ┌──┴──┐
                       │ 微信 │
                       └──┬──┘
               ┌──────────┤
          ilink 长轮询     │ hook.sh
               │          │ (Claude Code / Codex Stop Hook)
               ▼          │
         WeChatPlatform   │
         ───────────────  │
         接收 → 注入      │ Unix Socket
                         ▼
              ┌─────────────────────┐
              │   Daemon (actor)    │
              │                     │
              │  WeChatPlatform ←──┤
              │  SocketServer ←────┤
              │  GlobalKeyTap ←────┤  ←  键盘事件层：一个 tap，按归属路由
              │                     │      右⌘/右⌃ 语音 · Cmd+D 翻译 · Opt+Z/A/Q/X/C 快捷
              │  MediaHTTPServer   │  →  Web UI (8888)
              │         │          │
              │         ▼          │
              │  PlaybackQueue     │
              │  (actor)           │
              │   ├─ TTSEngine     │  mlx-audio-swift 流式推理
              │   └─ AudioPlayer   │  AVAudioEngine 播放
              │         │          │
              │  MediaController   │  MRMediaRemoteSendCommand
              │  (暂停/恢复音乐)    │
              └─────────────────────┘
```

## 子系统

按**能力域**归类如下（源码目录、`ivox status`、README 功能表三处一致）：

| 能力域 | 目录 | 子系统 |
|---|---|---|
| 自动播报 | `Sources/iVox/Playback/` | TTSEngine、PlaybackQueue、AudioPlayer |
| 语音输入 | `Sources/iVox/SpeechInput/` | SpeechInput |
| 划词翻译 | `Sources/iVox/Translation/` | Translation |
| 快速操作 | `Sources/iVox/QuickActions/` | QuickActions |
| 微信桥接 | `Sources/iVox/WeChat/` | WeChatPlatform、ClaudeAskService |
| 媒体控制 | `Sources/iVox/MediaControl/` | MediaHTTPServer、MediaController |
| （基础设施） | `HotKey/` `Network/` `Daemon/` `Commands/` `Utilities/` | GlobalKeyTap、SocketServer、Daemon |

六个能力域**彼此平级**——运行时互相协作（播报会暂停音乐、语音输入会打断播报、划词翻译借播报念译文），但代码上无主从，各占一个目录。基础设施跨域共用，不归任何能力域。

下面按子系统逐个说明。

### Daemon — 生命周期管理

`Sources/iVox/Daemon/Daemon.swift`

所有服务的所有者。按顺序：init（加载配置/状态）→ run（并行启动各服务）→ cleanup（SIGINT/SIGTERM 优雅关闭）。各服务以 `Task` 运行，取消传播到所有子任务。

```swift
// run() 内部大致结构
async let ws: Void = wechat?.start(handler: handleWeChatMsg)
async let sock = socketServer.start(handler: handleSocketMsg)
async let mic = speechInput.start()
// ...
await ws; await sock; await mic
```

### WeChatPlatform — 微信 ilink 长轮询

`Sources/iVox/WeChat/WeChatPlatform.swift`

- Actor 封装，通过 `WeChatClient` 调用微信 ilink API
- 长轮询 `getupdates` 获取新消息，`GetUpdatesResp.ret` 为 `Int?`（空响应不返回此字段）
- 手动 `withThrowingTaskGroup` 超时（URLSession 空闲超时在 TCP 保活下不触发）
- 消息去重（5 分钟窗口），单用户白名单：`from` 精确等于扫码注册的那一个
- Typing 指示器（单张 ticket，10 分钟缓存）
- 单用户状态持久化：`get_updates.buf` 和 `context_token.json`（单个 userID + contextToken）到 `~/.config/ivox/wechat/`

收到消息 → Daemon.handleWeChatMessage → ClaudeAskService（常驻桥）→ WeChatPlatform.sendMessage 发回微信。

### ClaudeAskService — 原生常驻 Claude Agent

`Sources/iVox/Network/ClaudeAskService.swift`

Swift 直接 spawn 原生 `claude` 进程、经 stdio NDJSON 通信，**无 node、无 Agent SDK 依赖**（此前的 node sidecar 方案占用 278 MB node_modules，已移除）。底层 claude 进程常驻 → **后台任务跨微信消息存活**。

```
Daemon (actor)
  └─ ClaudeAskService: 常驻 claude 子进程（stdio NDJSON）
        启动  claude --input-format stream-json --output-format stream-json
                    --verbose --dangerously-skip-permissions --model <m>
                    [--resume <sid>]          # cwd 用进程 currentDirectoryURL
        stdin  逐行写 {"type":"user","message":{role:"user",content}}
        stdout 逐行读，忽略 system/assistant，取 type=="result" 的 result / session_id
```

要点：
- stdin 每条 user 消息**必须外包一层** `{type:"user",message:{...}}`；裸 `{role,content}` 会被静默忽略。
- result 按 FIFO 匹配当前最早等待者（单 agent 串行）；`session_id` 落盘 `~/.config/ivox/wechat/bridge_state.json`，进程重启用 `--resume` 恢复历史。
- agent 的工作目录固定为 `~/.config/ivox/wechat/workspace`，读写收敛在隔离目录。
- Daemon `cleanup()` 中 `await claudeAsk.stop()` 关 stdin、等退出（60×50ms）、超时 terminate，避免孤儿与新旧进程并存。
- 权限为最大权限 `--dangerously-skip-permissions`（全自动免确认）；发 `/new` terminate 当前进程、清 session_id 指针，下次裸启新会话。
- 协议实测细节见 [`research-native-bridge.md`](research-native-bridge.md)。

### SocketServer — Unix Domain Socket IPC

`Sources/iVox/Network/`

- `~/.config/ivox/ivox.sock`，JSON 行协议
- 支持 TTS 播报（`{source:claude,voice:wanwan}` 前缀）和 ASR 识别
- 详见 [`docs/socket-api.md`](socket-api.md)

### TTSEngine — 本地语音合成

`Sources/iVox/Playback/TTSEngine.swift`

- `mlx-audio-swift` 加载本地 Qwen3-TTS 模型
- `generateStream()` 流式合成 float32 PCM → 重采样 48kHz → int16
- 按音色读取 `refAudio` + `refText` 做声音克隆
- 流式间隔由 `streamingInterval` 控制

### PlaybackQueue — 播放调度

`Sources/iVox/Playback/PlaybackQueue.swift`

- Actor，管理播报队列
- **连续播放管道**：`processNext` 是跨所有 job 的循环，逐句 `synthesizeStream → player.write`，句间不 drain，设备零停顿（对齐 ai-stack 的常驻 OutputStream）
- `enqueue` **按轮分桶**追加到队列尾部，同 `turnID` 分块并入同桶顺序 append；新 turn 在队尾追加新桶**不打断**在播旧轮；**无 turn 的普通播报（hook.sh / `ivox speak`）同排队**。`processNext` 播完队首桶才前移 = 「按轮排队、播全播完」
- **过期轮次静默丢弃**：`turnID` 已被作废（`deadTurns` 墓碑）的迟到帧/`endTurn` 一律 no-op，不再开口，避免残音反杀
- 还有未结束的流式轮（`anyTurnInFlight`，由各桶 `ended` 推导）时队列瞬时排空就挂起 `waitForJobs()` 等下一批，不退出、不恢复音乐；全部轮 `ended` 且排空才收尾
- **打断权只归用户快捷键**，手动打断三档：**轻** Ctrl+2 跳当前句（`skipCurrentSentence`：只丢正在播这句，同轮剩下的照念）、**中** Ctrl+1 跳整轮（`skipCurrentBucket`：丢当前桶，下一桶接着播）、**掀桌** Ctrl+Esc 清楚（`cancelAll` 全场清）+ right⌘ 说话；Cmd+D 译文走 `speakUserInitiated` **插队**（只掐在播、译文桶插到队首，其余桶全保留）。**`{type:stop}` 停止帧与流式新轮不再打断**。agent 回复到达的普通播报只排队。旧的 ↓ 跳段已删，「跳」统一走 Ctrl+1 / Ctrl+2
- **「掐在播」与「清场」是两层**：`preemptCurrent` 只作废管道代号 + 取消在播合成与已排队音频，**不动 `buckets`**；`bargeIn` 是「先清空队列、再调它」（掀桌）。三档里只有**掀桌**用 `bargeIn`；**跳句 / 跳桶 / 译文插队都只 `preemptCurrent`** —— 所以「不掀桌」不是各自实现的巧合，而是同一条路径上的自然结果
- **播报字幕（可选，`playback.captions`）从播放侧取**：每句首块音频捎上该句文本（`AudioChunk.sentenceText`），`AudioPlayer` 在它被设备读出时回调 → 队列转发给 `onCaption`。从**合成**侧取会让字幕早一两句（合成领先播放，实测踩过）；跳句 / 跳桶 / 掀桌前先撤字幕，队列真空闲时由 `pumpOrResume` 收
- ⚠️ **循环里每个 `continue` 都必须有挂起点**：producer 曾在「队首桶已播空、该轮尚未收尾」时落进一个无 `await` 的 `continue` —— 空转**独占整个 actor**（`enqueue`/`endTurn`/`cancelAll` 全被饿死，连快捷键打断都进不来），播报永久瘫痪外加烧满一核，且 **10 秒读超时的 EOF 兜底也救不回**（`endTurn` 进不了僵死的 actor）。黑盒自检 `E8` 钉住了这个现场
- `cancelAll()` 清空队列 + 取消全部播放（bargeIn + 清 turn 状态）
- 等待 TTS 模型就绪后再开始合成
- 播报前通过 `MediaController` 暂停音乐，播完恢复

### AudioPlayer — 音频播放

`Sources/iVox/Playback/AudioPlayer.swift`

- `AVAudioEngine` + 单个常驻 `AVAudioPlayerNode.scheduleBuffer()`，整条播报复用、句间不重启
- **高低水位背压**：已排队音频 >4s 暂停合成、降到 2s 放行（`pendingFrames` 随 `dataConsumed` 回调核减）
- prime 静音（200ms，唤醒电源管理休眠的 node）只在设备真正播空 / 取消后补一次
- `drain()` 仅在整条管道末端调用一次，等待跨 job 的尾音播完；带超时兜底防回调丢失
- `cancelPendingPlayback()` 递增 `generation` 作废旧缓冲回调，并恢复背压挂起点
- 句首块可捎带该句文本（`write(_:startsSentence:)`）：该块被设备读出（`.dataConsumed`）时回调 `onSentenceStarted`，供播报字幕与声音对齐；**被掐掉的句子因世代校验不会误报**，打断路径无需特殊处理

### MediaController — 系统媒体控制

`Sources/iVox/MediaControl/MediaController.swift`

- `MRMediaRemoteSendCommand` 系统框架直接控制媒体播放
- 播放 / 暂停 / 切歌走 `MRMediaRemoteSendCommand`（免权限）；音量 / 静音 / 方向键 / 锁屏走 `CGEvent`，要「设备控制与数据访问」
- **本质是「让路」**：播报 / 采集要出声，音乐就让开；说完则继续 —— 它不是"控制你的播放器"。所以只认抖音 / 汽水音乐两个 App（`AudioAppRegistry`），其它播放器一概不碰；`MediaController` 是 `actor`，记着"这次暂停是我们发的"，恢复只对自己发过的暂停生效
- 语义是**「说完继续」，不是「恢复原状」**：你若本来就把音乐暂停着，播报结束会**把它放起来** —— 这是设计意图（"让路"预设了"对方本来在走"），不是缺陷
- 曾想把判据做得更"精确"（暂停前先查"是否真有媒体在播"）：MediaRemote 那条是**回调式私有 API**，在 Swift 6 下连踩两坑（`@convention(block)` 被判 sending → 区域隔离编译错；绕开后闭包逃逸 → 运行期崩、daemon 崩循环），已撤。也考虑过用"**静音**代替暂停"—— 不成立：系统音量是全局的，会把 iVox 自己的播报一起静掉（macOS 没有按 App 调音量的公开接口）

### SpeechInput — 语音输入

`Sources/iVox/SpeechInput/`

- 键盘监听由 `HotKey/GlobalKeyTap` **独占**（一个 tap 服务多个消费者，见下节），本服务只订阅**修饰键**：右⌘(0x36) / 右⌃(0x3E) 的状态变化由它回调进来
- **right ⌘/⌃ 按下**：暂停音乐 + 取消 TTS + 开始录音（「你一开口，对方就停」——用户快捷键打断之一）
- **right ⌘/⌃ 松开**：结束录音 + 恢复音乐 + 开始 ASR 识别
- 用户快捷键五个：right⌘ 说话、Cmd+D 插队念译文、Ctrl+Esc 掀桌（只静音播报 + 恢复音乐，不录音）、Ctrl+1 跳整轮、Ctrl+2 跳当前句。**pi 新轮与停止帧不再打断**，一律排队
- ASR 结果通过 `CGEvent` 模拟键盘输入 + `NSPasteboard` 粘贴
- 需要设备控制与数据访问权限（`AXIsProcessTrustedWithOptions`）

### GlobalKeyTap — 键盘事件层

`Sources/iVox/HotKey/GlobalKeyTap.swift`

- 独占一个 CGEvent tap 与**专用线程的 run loop**，只按事件类型 / keyCode **路由**，不含任何业务判断
- 消费者按**能力归属**分派（`Daemon.setUpHotKeys()`）：右⌘/右⌃ → `SpeechInputService`；`Cmd+D` → `TranslationService`；`Opt+Z/A/Q/X/C` → `QuickActionsService`；`Ctrl+Esc` / `Ctrl+1` / `Ctrl+2` → `PlaybackQueue`（手动打断三档：掀桌 / 跳整轮 / 跳这句）
- 热键精确匹配（四个标准修饰位全等，故 `Cmd+Shift+D` 之类的变体不误触），其余按键一律透传；`keyUp` 也一律透传（若按 keyCode 宽松匹配，会吞掉「单独按 D」的抬起而干扰打字）
- ⚠️ tap 回调**跑在专用线程且监听的是全系统键盘**——回调里任何耗时都会拖慢整机输入，所以只做整数比较，业务一律 offload
- 普通键（`keyDown`）需要「输入监控」权限：只授辅助功能时表现为"修饰键正常、`Cmd+D` 毫无反应"，启动时用 `CGPreflightListenEventAccess()` 自检并打印引导

### Translation — 划词翻译

`Sources/iVox/Translation/`（AppKit/CG 侧）+ `Sources/iVoxKit/Translation/`（纯逻辑，可单测）

- `Cmd+D` → 模拟 `Cmd+C` 取选中文本（`ClipboardReader`，用 `changeCount` 校验剪贴板**真的变了**，而不是 iDict 那样盲等 50ms）→ 翻译 → 屏幕下方居中的歌词式浮窗（`TranslationPanel`，NSPanel 非激活浮层）+ 可选朗读
- **三个浮窗各自独立、刻意不抽公共件**（消失策略与生命周期各不同，硬抽要开一堆口子）：语音波形（`OverlayPanel`，跟鼠标收）、翻译结果（`TranslationPanel`，屏幕下方 96pt）、播报字幕（`CaptionPanel`，贴底 24pt，`playback.captions` 开关，**跟播放不跟合成**）。三者同源的是那套 `NSPanel` 组合：非激活、悬于所有窗口、跨 Space
- 翻译走 `iVoxKit.TranslationService`（`actor`）：Google 主/备**双通道容灾**，或 OpenAI 兼容；**直连失败自动走兜底代理**（`translation.proxyURL`），直连用短超时探测（`directProbeTimeoutSeconds`），成功后记住「该走代理」
- 朗读走 `PlaybackQueue.speakUserInitiated()`：**插队**——掐掉在播的那一句让译文立刻响，但**不掀桌**（其余桶全保留、流式轮不作废）。与 hook 汇报的「只排队」语义相反
- 浮窗**刻意不做**拖拽 / 点击外部关闭 / 文本选择——这三样都要 key window，当前无 `NSApplication` 事件循环的形态给不了
- CLI 侧 `ivox translate <text> [--selection] [--json]`**不依赖 daemon**，是整条链路的可验证接缝

### QuickActions — Finder/终端快捷

`Sources/iVox/QuickActions/QuickActionsService.swift`

- `Opt+Z` 在 Finder 当前目录开终端；`Opt+A`/`Opt+X`/`Opt+Q` 开终端并执行 `claude`/`codex`/`pi`；`Opt+C` 把选中项路径写进剪贴板
- 开终端走 **Ghostty**（`--working-directory` + `--initial-command` 是它的原生 CLI 参数）：一条 LaunchServices 调用就够，**不需要**临时 `.command` 文件，也不沾 Terminal 的 Automation 授权
- 三个实测坑：① 参数必须经 `NSWorkspace.OpenConfiguration.arguments`（数组）下发——命令行 `open --args` 会把**含空格的参数拆坏**；② **必须配 `createsNewApplicationInstance`**，复用已运行的 Ghostty 实例时参数会被**静默忽略**（命令根本不跑）；③ **不用 `-e`**——它每次弹 macOS 的「Allow Ghostty to execute」确认框，Ghostty 目前无配置项可关
- 命令写作 `--initial-command=/bin/zsh -lc <cmd>`：该参数默认经 `/bin/bash --noprofile --norc -c` 执行，套一层 login shell 才拿得到用户 PATH（`/opt/homebrew/bin`、`~/.local/bin` 都不在 GUI 进程的最小 PATH 里）；另配 `--wait-after-command=true` 让命令退出后**保留窗口**（Ghostty 默认关窗，与原先 Terminal 的行为不一致，退出 claude 时会看不到最后的输出）
- 取 Finder 路径仍走 AppleScript（唯一需要 Automation 授权的点，面积很小）
- 选中项是**文件**时：开终端取它的**所在目录**，复制路径取**文件本身**

### MediaHTTPServer — Web UI

`Sources/iVox/MediaControl/MediaHTTPServer.swift`

- 嵌入式 HTTP 服务器，端口 8888
- Web UI：播放/暂停/下一曲控制 + 状态展示
- REST API：`/api/config`、`/api/speak` 等

### iVoxKit — 共享库

`Sources/iVoxKit/`（无 MLX 依赖，可独立测试）

| 文件 | 职责 |
|------|------|
| `Config.swift` | JSON 配置模型（TTS/ASR 路径、音色、媒体控制、播报字幕、微信、划词翻译等） |
| `Logger.swift` | 日志工具，输出到 daemon.log（0600），5MB 轮转 |
| `DaemonStatus.swift` | `{type:status}` 的返回体：六个能力域的健康度 + 权限 |
| `SocketClient.swift` | `AppPaths`（socket / 配置目录）+ socket 客户端 |
| `TextCleaner.swift` | Markdown AST 过滤（跳过代码块）+ 行内噪音（URL/路径/哈希/UUID/JSON/ANSI/进度）+ emoji |
| `TextSplitter.swift` | 切句（句末边界，合并到 ≤80 字） |
| `StreamBuffer.swift` | 流式 turn 的安全边界切分（句末 / 代码围栏配平 / `minFlushChars`） |
| `StreamFrame.swift` | 长度帧协议（`L<n>` + 正文 + end 标记） |
| `AudioPipeline.swift` | 音频格式转换工具（重采样） |
| `Translation/` | 翻译服务（Google 双通道容灾 + OpenAI 兼容）、配置模型、选区清洗 |

## 并发模型

所有服务都是 **actor**，跨 actor 通信走 `await`。关键 actor 边界：

```
Daemon (actor)
  ├── WeChatPlatform (actor)   ← await 调用 WeChatClient (actor)
  ├── PlaybackQueue (actor)    ← await 调度 TTSEngine / AudioPlayer（音频回调走 AudioPlayer 的 serialQueue）
  ├── SocketServer (非 actor)  → 回调 Daemon 的 actor 隔离方法
  ├── SpeechInputService       → CGEvent 回调 → actor 方法
  └── CaptionPanel (@MainActor)→ 队列的音频回调 → Task { @MainActor } 更新浮窗
```

Swift 6 严格并发下，`@Sendable` 闭包不能捕获 actor 内的 `var`。用 `let capture = varValue` 创建值拷贝再传入闭包。

**往 UI（AppKit）方向的边界：一律回主线程**。后台 actor（如队列的音频回调）要更新浮窗时走 `Task { @MainActor in panel.update(...) }`。浮窗自身或标 `@MainActor`（`CaptionPanel`——调用点本就在主线程上，标注零成本），或刻意不标、由调用方切线程（`OverlayPanel`——持有者不是 MainActor 类，标注会把整条链拖成 async）。两者都是有意的取舍，不是不一致。

## 数据流

### TTS 播报

```
1. Hook 脚本 → `ivox speak -s claude "文本"`
2. SpeakCommand → Unix Socket `{source:claude}文本`
3. ConnectionHandler.handle():
   - 解析前缀 → source="claude"
   - voice = sourceVoices["claude"] ?? defaultVoice
   - 显式 `{voice:xxx}` 可覆盖
   - cleanText() 清洗 Markdown + 行内噪音
4. PlaybackQueue.enqueue(job)
   → 追加到队尾；如空闲则启动 processNext，其入口调用 MediaController.pause()
5. TTSEngine.synthesizeStream() → AsyncThrowingStream<Data>
6. AudioPlayer.write(chunk) → scheduleBuffer 连续排队（超高水位背压）；跨 job 不 drain。
   块带「句首」标记（`AudioChunk.sentenceText`）时，被设备读出即回报字幕（`onCaption`，见 PlaybackQueue 节）
7. 整条管道末端 drain() 一次，等跨 job 尾音播完
8. 没有流动中的轮（`anyTurnInFlight`）且队列空 → 撤字幕 + MediaController.resume()
```

### pi 流式播报（第二层流式）

pi 扩展（`integrations/pi/ivox.ts` → `~/.pi/agent/extensions/ivox.ts`）在模型生成中逐 `text_delta` 转发**原文**（TS 侧不切句），经一条长连接按 `\n` 分帧送入 socket：

```
{type:stream,source:pi,turn:<id>}\n   首帧开流（beginTurn，登记轮次；新轮排队不打断）
<增量原文行>…                          仅 text_delta，跳过 thinking/toolcall
{end}\n                                turn_end 收尾      或  {cancel:<id>}\n（Escape）
```

`ConnectionHandler.handleStream` 把增量喂给 `StreamBuffer`（iVoxKit）：累积原文，只在**安全边界**（句末/段落、且吐出前缀代码围栏配平、累计 ≥ `minFlushChars`=24）抽出完整前缀 → 复用同一份 `cleanText() → splitSentences()` 切句入队。切句/清洗真源只在 Swift 一份，TS 绝不切句（否则破坏 Markdown AST 块末补句号与跨行规则）。模型写下一句时上一句已在常驻管道里播。

### 微信消息

```
1. WeChatPlatform 长轮询 getupdates（每 ~35 秒）
2. 收到消息 → 去重 → 白名单过滤 → 提取文本
3. Daemon.handleWeChatMessage()
   → ClaudeAskService.ask() 调用 claude --print
   → WeChatPlatform.sendMessage() 发回微信
4. claude --print 结束 → Stop Hook → hook.sh → ivox speak TTS
```

## 文本过滤

`TextCleaner` 只在 daemon 侧执行，分两层（取舍标准：屏幕可以略读，耳朵只能线性听完）：

1. **Markdown AST**（`swift-markdown` 库）
   - 跳过：CodeBlock、HTMLBlock、InlineHTML、ThematicBreak
   - 保留：标题、段落、列表、引用、链接标题、加粗/斜体、行内代码、图片 alt、表格单元格
2. **行内噪音**（顺序不可调换：URL → 噪音 → emoji）
   - 删除 URL、UUID、≥12 位 hex hash、ANSI 转义、JSON 对象、速度/ETA 噪音
   - 路径只保留文件名：`/Users/admin/x/TextCleaner.swift` → `TextCleaner.swift`
   - 箭头 `→` → 「到」；其余 ASCII 符号（`_ = @ &`）→ 空格，避免 `loadRefAudio_12` 粘成 `loadRefAudio12`
   - 删除 emoji；各类空白折叠为一个空格

清洗后由 `TextSplitter` 分成 ≤80 字的块入队，既贴合 TTS 的句级合成，也让流式 turn 能边切边播。

## 音色匹配

优先级：`显式 voice > sourceVoices 映射 > defaultVoice`

```
ConnectionHandler.extractVoicePrefix():
  if {voice:xxx} in payload  → xxx
  else if {source:s}         → sourceVoices[s] ?? defaultVoice
  else                       → defaultVoice
```

## 部署结构

所有运行时文件在 `~` 下，项目目录可删：

```
~/.local/bin/ivox                          # CLI 入口（符号链接）
~/.local/share/ivox/runtime/iVox          # 实际二进制
~/.config/ivox/config.json                 # 配置
~/.config/ivox/integrations/               # 集成资产权威源（随发布包解包，分发器读这里）
~/.config/ivox/hook.sh                     # 分发后的 hook（Claude/Codex 挂载引用它）
~/.config/ivox/model/                      # TTS/ASR MLX 模型
~/.config/ivox/voices/                     # 参考音频
~/.config/ivox/wechat/                     # 微信轮询状态
~/.config/ivox/daemon.log                  # 日志（5MB 轮转）
```

`make update` 停服 → 构建 → 签名 → 拷贝二进制 → 启动守护进程。

## 构建系统

`Makefile` 使用 `xcrun --toolchain swift-latest swift`，符号链接指向 Swift 6.4 开发快照（`swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-06-15-a`）。早期快照编译 MLXAudioTTS 的崩溃已在该版本修复，见 [`archive/incident-swift-compiler-crash.md`](archive/incident-swift-compiler-crash.md)。

关键 target：

| Target | 作用 |
|--------|------|
| `make build` | `swift build -c release -Xswiftc -Osize` |
| `make update` | runtime.sh stop（launchctl bootout）→ build + voices + deploy-bin → runtime.sh start（bootstrap） |
| `make run` | build + 前台运行（调试） |
| `make test` | 运行 iVoxKit 测试 |

## Hook 集成

**打断权只归 ivox 快捷键**（right⌘ 说话 / Cmd+D 插队译文 / 手动三档：Ctrl+2 跳这句 · Ctrl+1 跳整轮 · Ctrl+Esc 掀桌）；`hook.sh` **不再有 interrupt 分支**（`ivox quiet` 手动能力保留在 ivox CLI），`UserPromptSubmit` 亦不挂。

| 工具 | 配置/挂载 | 回复播报 |
|------|----------|----------|
| Claude Code（交互会话） | `~/.claude/settings.json` | **MessageDisplay → `hook.sh msgdisplay claude`**（assistant 行批增量，过程逐句播、final 批含完整结尾；**不再挂 Stop**） |
| Codex | `~/.codex/hooks.json` | Stop → hook.sh codex |
| PI coding agent | `~/.pi/agent/extensions/ivox.ts` | `message_update` 流式（`agent_settled` 兜底） |

由 `install-hooks.sh` 统一安装（Claude 挂 MessageDisplay，Codex 仍挂 Stop）；它**不再挂 UserPromptSubmit interrupt**（`write_prompt_hook` 已被置为 no-op）。它**只写不删**：老配置里遗留的 Claude `Stop` 播报得人工摘除（`settings.json` 的 `hooks.Stop`），否则与 MessageDisplay 同播会把整条回复念两遍。`hook.sh` 有 `speak` / `msgdisplay` 两模式：`speak` 提取 `last_assistant_message`、`msgdisplay` 提取 `delta` 增量，都经 `ivox speak` 排队进桶（不打断）。

**集成资产随发布包自包含**：release tarball 除 `ivox` 外含整个 `integrations/`（含 `install-hooks.sh`），安装/升级时解包到权威源 `~/.config/ivox/integrations/`，再由分发器幂等铺到各 agent 位置。同步只发生在三个显式时机：`make update`（runtime.sh deploy-bin）、`ivox upgrade`（UpgradeCommand 解包后 Process 调分发器）、`install-binary.sh`（curl|bash 首次安装也补齐集成）；守护进程启动不自动同步。分发器按自身位置探测素材源：脚本在 `integrations/` 内（部署态）用同级目录，在 `scripts/`（源码态）用 `../integrations`。
