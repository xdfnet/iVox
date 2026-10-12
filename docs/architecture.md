# iVox 架构

## 概览

macOS 本地语音助手守护进程，全栈 actor 化。输入侧接 AI 工具（Claude Code、Codex、Qwen Code、DeepSeek Harness、PI coding agent）和微信，输出侧走本地 MLX TTS/ASR + 系统媒体控制。

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
              │  SpeechInput ←─────┤  ←  ⌘ 键 CGEvent 监听
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

`Sources/iVox/TTS/TTSEngine.swift`

- `mlx-audio-swift` 加载本地 Qwen3-TTS 模型
- `generateStream()` 流式合成 float32 PCM → 重采样 48kHz → int16
- 按音色读取 `refAudio` + `refText` 做声音克隆
- 可配置重试（`maxRetries`、`retryDelayMs`）、流式间隔（`streamingInterval`）

### PlaybackQueue — 播放调度

`Sources/iVox/Audio/PlaybackQueue.swift`

- Actor，管理播报队列
- **连续播放管道**：`processNext` 是跨所有 job 的循环，逐句 `synthesizeStream → player.write`，句间不 drain，设备零停顿（对齐 ai-stack 的常驻 OutputStream）
- `enqueue` 追加到队列尾部，同 `turnID` 不打断；新 turn（用户发言）触发 `bargeIn` 打断旧轮；**无 turn 的普通播报（hook.sh / `ivox speak`）只排队，不打断**
- **过期轮次静默丢弃**：`currentTurn` 已切到新轮后，旧轮的迟到帧/`endTurn`（含旧连接 EOF 残尾）一律 no-op、不再 `bargeIn`，避免旧轮残音反杀新轮（真人对话：你一开口对方就停）
- 流式轮次（`turnOpen`）队列瞬时排空时挂起 `waitForJobs()` 等下一批，不退出、不恢复音乐；`endTurn` 后排空才收尾
- 打断只有两个途径，且都源于**用户开口**：**说话/提交**（right⌘ 录音与 `hook.sh interrupt` 哨兵都触发 `cancelAll()`）与**新轮次**（用户给 pi/dsh 发言，新 turn 触发 `bargeIn`）；agent 回复到达的普通播报只排队。不再有「跳段」语义
- `cancelAll()` 清空队列 + 取消全部播放（bargeIn + 清 turn 状态）
- 等待 TTS 模型就绪后再开始合成
- 播报前通过 `MediaController` 暂停音乐，播完恢复

### AudioPlayer — 音频播放

`Sources/iVox/Audio/AudioPlayer.swift`

- `AVAudioEngine` + 单个常驻 `AVAudioPlayerNode.scheduleBuffer()`，整条播报复用、句间不重启
- **高低水位背压**：已排队音频 >4s 暂停合成、降到 2s 放行（`pendingFrames` 随 `dataConsumed` 回调核减）
- prime 静音（50ms，唤醒电源管理休眠的 node）只在设备真正播空 / 取消后补一次
- `drain()` 仅在整条管道末端调用一次，等待跨 job 的尾音播完；带超时兜底防回调丢失
- `cancelPendingPlayback()` 递增 `generation` 作废旧缓冲回调，并恢复背压挂起点

### MediaController — 系统媒体控制

`Sources/iVox/Audio/MediaController.swift`

- `MRMediaRemoteSendCommand` 系统框架直接控制媒体播放
- 支持播放/暂停/切换/下一曲，无需设备控制与数据访问权限

### SpeechInput — 语音输入

`Sources/iVox/SpeechInput/`

- `CGEvent.tapCreate()` **只监听 `flagsChanged`**（right ⌘ 或 right ⌃），不再监听任何普通 `keyDown`——打字、Esc、方向键全部原样透传（GUI 客户端里打字不等于要它闭嘴，Esc 还要留给 agent 取消生成）
- **right ⌘/⌃ 按下**：暂停音乐 + 取消 TTS + 开始录音（「你一开口，对方就停」，这是唯一的键盘打断途径）
- **right ⌘/⌃ 松开**：结束录音 + 恢复音乐 + 开始 ASR 识别
- 另一条打断途径是用户给 pi/dsh 发言时新轮次入队自动 bargeIn，无需按键
- ASR 结果通过 `CGEvent` 模拟键盘输入 + `NSPasteboard` 粘贴
- 需要设备控制与数据访问权限（`AXIsProcessTrustedWithOptions`）

### MediaHTTPServer — Web UI

`Sources/iVox/Audio/MediaHTTPServer.swift`

- 嵌入式 HTTP 服务器，端口 8888
- Web UI：播放/暂停/下一曲控制 + 状态展示
- REST API：`/api/config`、`/api/speak` 等

### iVoxKit — 共享库

`Sources/iVoxKit/`（无 MLX 依赖，可独立测试）

| 文件 | 职责 |
|------|------|
| `Config.swift` | JSON 配置模型（TTS/ASR 路径、音色、媒体控制、微信等） |
| `Logger.swift` | 日志工具，输出到 daemon.log，5MB 轮转 |
| `TextCleaner.swift` | Markdown AST 过滤（跳过代码块）+ 行内噪音（URL/路径/哈希/UUID/JSON/ANSI/进度）+ emoji |
| `AudioPipeline.swift` | 音频格式转换工具 |
| `TextSplitter.swift` | 按句切分并合并到 ≤80 字，供播报分块 |

## 并发模型

所有服务都是 **actor**，跨 actor 通信走 `await`。关键 actor 边界：

```
Daemon (actor)
  ├── WeChatPlatform (actor)   ← await 调用 WeChatClient (actor)
  ├── PlaybackQueue (actor)    ← await 调度 TTSEngine / AudioPlayer
  ├── SocketServer (非 actor)  → 回调 Daemon 的 actor 隔离方法
  └── SpeechInputService       → CGEvent 回调 → actor 方法
```

Swift 6 严格并发下，`@Sendable` 闭包不能捕获 actor 内的 `var`。用 `let capture = varValue` 创建值拷贝再传入闭包。

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
6. AudioPlayer.write(pcm) → scheduleBuffer 连续排队（超高水位背压）；跨 job 不 drain
7. 整条管道末端 drain() 一次，等跨 job 尾音播完
8. turnOpen 已结束且队列空 → MediaController.resume()
```

### pi 流式播报（第二层流式）

pi 扩展（`integrations/pi/ivox.ts` → `~/.pi/agent/extensions/ivox.ts`）在模型生成中逐 `text_delta` 转发**原文**（TS 侧不切句），经一条长连接按 `\n` 分帧送入 socket：

```
{type:stream,source:pi,turn:<id>}\n   首帧开流（beginTurn，打断旧轮）
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
~/.config/ivox/hook.sh                     # 分发后的 hook（Claude/Codex/Qwen 挂载引用它）
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
| `make update` | ivox off → build + voices + deploy-bin → ivox on |
| `make run` | build + 前台运行（调试） |
| `make test` | 运行 iVoxKit 测试 |

## Hook 集成

每个 hook 类工具挂两个事件：**UserPromptSubmit → `hook.sh interrupt`**（提交即打断旧播报，调 `ivox quiet`）与 **Stop → `hook.sh <source>`**（回复完成，`ivox speak` 念新回复）。

| 工具 | 配置/挂载 | 提交即打断 | 回复播报 |
|------|----------|-----------|----------|
| Claude Code | `~/.claude/settings.json` | UserPromptSubmit → hook.sh interrupt | Stop → hook.sh claude |
| Codex | `~/.codex/hooks.json` | UserPromptSubmit → hook.sh interrupt | Stop → hook.sh codex |
| Qwen Code | `~/.qwen/settings.json` | UserPromptSubmit → hook.sh interrupt | Stop → hook.sh qwen |
| DeepSeek Harness | `~/.dsh/profiles/desktop` 插件 `ivox-tts.mjs` | 新 turn `start` 帧自动 bargeIn | `agent/assistant-stream` 逐 text-delta 流式；socket 不可用时 turn-stopping 退回 hook.sh（内置桥接 Stop payload 无文本） |
| PI coding agent | `~/.pi/agent/extensions/ivox.ts` | `message_start` 用户消息即 `{cancel}` 旧轮 + 新轮首帧（beginTurn 的 bargeIn 清场） | `message_update` 流式（`agent_settled` 兜底） |

由 `install-hooks.sh` 统一安装（已存在则跳过；`UserPromptSubmit` 的旧参数名 `stop` 会被就地改写为 `interrupt`）。`hook.sh` 两种模式：`interrupt` 只调 `ivox quiet` 打断；`<source>` 提取回复文本调 `ivox speak`（TTS 由各工具这一层统一处理）。

**集成资产随发布包自包含**：release tarball 除 `ivox` 外含整个 `integrations/`（含 `install-hooks.sh`），安装/升级时解包到权威源 `~/.config/ivox/integrations/`，再由分发器幂等铺到各 agent 位置。同步只发生在三个显式时机：`make update`（runtime.sh deploy-bin）、`ivox upgrade`（UpgradeCommand 解包后 Process 调分发器）、`install-binary.sh`（curl|bash 首次安装也补齐集成）；守护进程启动不自动同步。分发器按自身位置探测素材源：脚本在 `integrations/` 内（部署态）用同级目录，在 `scripts/`（源码态）用 `../integrations`。
