# iVox 架构

## 概览

macOS 本地语音助手守护进程，全栈 actor 化。输入侧接 AI 工具（Claude Code、PI coding agent）、微信与全局热键，输出侧走本地 MLX TTS/ASR + 系统媒体控制；另有划词翻译（`Opt+S`）与 Finder/终端快捷（QuickActions）。

```
                          用户
                       ┌──┴──┐
                       │ 微信 │
                       └──┬──┘
               ┌──────────┤
          ilink 长轮询     │ hook.sh
               │          │ (Claude Code hook)
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
              │                     │      右⌘/右⌃ 语音 · Opt+S 翻译 · Opt+Z/A/Q/X/C 快捷
              │  MediaHTTPServer   │  →  Web UI (8888)
              │         │          │
              │         ▼          │
              │  PlaybackQueue     │
              │  (actor)           │
              │   ├─ TSPRemote ───┼──→ Unix Socket → 誊清员进程（独立，mlx-audio-swift）
              │   └─ AudioPlayer   │  AVAudioEngine 播放
              │         │          │
              │  MediaController   │  MRMediaRemoteSendCommand
              │  (只给麦克风让路)   │
              └─────────────────────┘

   誊清员进程（`ivox tts --serve`，独立进程）
   ┌─────────────────────┐
   │ TTSEngine + TTSServer│  MLX 推理 + PCM 写回
   │ 崩溃由 TSPRemote 重拉 │  日志 ~/.config/ivox/tts.log
   └─────────────────────┘
```

## 子系统

按**能力域**归类如下（源码目录、`ivox status`、README 功能表三处一致）：

| 能力域 | 目录 | 子系统 |
|---|---|---|
| 自动播报 | `Sources/iVox/Playback/` | PlaybackQueue、PlaybackSession、AudioPlayer、CaptionPanel、**TTSProviding（契约）/ TSPRemote（远程引擎）/ TTSServer（誊清员）/ TTSTrace**、TTSEngine（仅 `IVOX_TTS=local`） |
| 语音输入 | `Sources/iVox/SpeechInput/` | SpeechInput |
| 划词翻译 | `Sources/iVox/Translation/` | Translation |
| 快速操作 | `Sources/iVox/QuickActions/` | QuickActions |
| 微信桥接 | `Sources/iVox/WeChat/` | WeChatPlatform、ClaudeAskService |
| 媒体控制 | `Sources/iVox/MediaControl/` | MediaHTTPServer、MediaController、SodaVolumeDucker |
| 屏幕锁 | `Sources/iVox/Screen/` | ScreenControl |
| （基础设施） | `HotKey/` `Network/` `Daemon/` `Commands/` | GlobalKeyTap、SocketServer、Daemon |

七个能力域**彼此平级**——运行时互相协作（语音输入会打断播报并给麦克风让出背景音乐、划词翻译借播报念译文），但代码上无主从，各占一个目录。基础设施跨域共用，不归任何能力域。

下面按子系统逐个说明。

### Daemon — 生命周期管理

`Sources/iVox/Daemon/Daemon.swift`

所有服务的所有者。按顺序：init（加载配置/状态）→ run（并行启动各服务）→ cleanup（SIGINT/SIGTERM 优雅关闭）。各服务以 `Task` 运行，取消传播到所有子任务。

**收尾后 `fflush` + `_exit(0)`，不走静态析构**：mlx 全局持有一张 `CommandEncoder` 哈希表，进程退出时
`__cxa_finalize_ranges` → 表析构 → `CommandEncoder::~CommandEncoder` → `end_encoding`，撞上未收口的
encoder 即 SIGSEGV。现场是 `ivox restart` 恰好在合成进行中，整进程被这一下带崩（自检里连着几个用例
ECONNREFUSED）。收尾已完成、日志已落盘，直接退场，不给析构函数碰 GPU 的机会。

### CrashTrap — 崩溃捕获

`Sources/iVox/Daemon/CrashTrap.swift`

MLX 后端崩在 C++ 层时，系统日志里只有一行 `mutex lock failed: Invalid argument`、**没有调用栈**，事后
无从判断是哪条路径撞上去的。故自己接 `SIGABRT/SIGSEGV/SIGBUS/SIGILL/SIGFPE`，把带栈的记录写进
`~/.config/ivox/crash.log`，下次启动打进 daemon.log 再清空。

两个必须记住的坑：

- 清空记录**只能用 `ftruncate`**（原地截断），不能用 `String.write(toFile:)`——那是「写临时文件 +
  rename」，换掉了 inode，而 handler 的 fd 在此之前就已打开，指向一个已经没人看见的孤儿文件，
  于是**每次崩溃的完整栈都写进了虚空**（`crash.log` 恒为 0 字节）。同理顺序必须是「先报走记录 →
  截断 → 再开 fd」
- 崩溃计数记 `~/.config/ivox/crash.count`：`crash.log` 每次启动就被清空，光靠它编号永远是 `#1`

信号处理函数里只用异步信号安全的调用（`write`/`fsync`/`backtrace`），不碰 actor 与 Logger。

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
- 协议实测细节见 [`native-bridge.md`](native-bridge.md)。

### SocketServer — Unix Domain Socket IPC

`Sources/iVox/Network/`

- `~/.config/ivox/ivox.sock`，JSON 行协议
- 支持 TTS 播报（`{source:claude,voice:wanwan}` 前缀）和 ASR 识别
- 详见 [`docs/socket-api.md`](socket-api.md)

### 合成引擎 — `TTSProviding` 契约 + 两种实现

**契约**：`Sources/iVox/Playback/TTSProviding.swift`（成员一律声明 `async`——按同步写会报
"conformance crosses into actor-isolated code"）。队列与 `ConnectionHandler` 只认这个协议，
不知道背后是进程内还是跨进程。

| 实现 | 落点 | 谁在用 |
|---|---|---|
| `TSPRemote` | `Playback/TSPRemote.swift` | **默认**。Unix socket + `StreamFrame` 长度帧，兼**监督者**：先问 socket 再问 child，断了重拉 |
| `TTSEngine` | `Playback/TTSEngine.swift` | `IVOX_TTS=local` 时退回进程内，仅供调试对照 |

装点在 `Daemon.init`；`Daemon.cleanup` 显式 `stopChild()`，不留孤儿。子进程入口是
`ivox tts --serve`（`Commands/TTSCommand.swift`），日志落 `~/.config/ivox/tts.log`。

> **为什么默认走远程**：MLX 的 Metal 命令编码器析构时重复释放 GPU 命令队列 → SIGTRAP。
> 上游未修、Swift 侧拿不到 encoder 引用，无从拦截。裁决与判据见
> [`docs/playback/purpose.md`](playback/purpose.md) 2026-10-19 那条。

### TTSEngine — 进程内 MLX 合成（`IVOX_TTS=local`）

`Sources/iVox/Playback/TTSEngine.swift`

- `mlx-audio-swift` 加载本地 Qwen3-TTS 模型
- `generateStream()` 流式合成 float32 PCM → 重采样 48kHz → int16
- 按音色读取 `refAudio` + `refText` 做声音克隆
- 流式间隔由 `streamingInterval` 控制
- **合成串行**：世代闸门保证第 N 代必须等第 N-1 代**完全离开模型**才准进 MLX（模型非并发安全）
- ⚠️ **打断后不丢弃 MLX 生成器**：encoder 里还压着未 commit 的命令，析构即触发 AGX 断言
  （SIGABRT `commit command buffer with uncommitted encoder`）或 `copy_gpu` 越界（SIGSEGV）。
  现在取消后**停止 yield 但继续把流读完**，等 GPU 自然收口再抛 `CancellationError`
- `refAudio` 走**盒子缓存**：`mlx-swift` 的 `refAudio` 参数带 `sending`（转移所有权），而库内部
  又靠 `ObjectIdentifier(refAudio)` 复用输入准备上下文——故必须交同一个实例，造新的每块多花
  1~2 秒（实测 4~5s 涨到 5~7s）。两层盒子看着冗余，实为绕开库的所有权语义

### PlaybackSession + PlaybackQueue — 身份与播放

**为什么分两层**：2026-10-17 重构（`Sources/iVox/Playback/PlaybackSession.swift`）把「当前在播什么」
从队列的旁路变量搬进容器。起因是一次真实缺陷——掀页后页号没清，第二次按压拿旧页号删掉了后到的内容。
根因不是忘了清，而是容器里压根没有「当前」。**身份层只回答「这是什么、谁被作废了」，
播放层只回答「下一个块是谁」。**

`PlaybackSession`（actor）：唯一持有容器与全部身份记账。容器三层——
**段 Segment**（一次回复 = 一摞 / 普通播报）→ **页 Page**（一条消息）→ **块 Block**（1~80 字合成单位），
外加一个独立的**加急段**列表（Opt+S 译文）排在最前。游标指向当前块但**不把它弹出容器**。
墓碑 `deadTurns` 拦用户显式作废的摞的后续增量（**右⌘说话不算作废**——它是「暂停不删」，不清场也不埋）。

`PlaybackQueue`（actor）：只管播放。连续管道 `processNext` 逐块 `synthesizeStream → player.write`，
块间不 drain（设备零停顿）；**所有路径的收尾收敛到唯一的 `pumpOrSettle()`**（有活补起管道 /
没活收字幕 / 仍有未封的段就起空闲宽限）；`pipelineSeq` 代号作废在途管道。打断权只归用户快捷键，
三档全是「掐 + 掀」，Opt+S 译文走插队。

**取舍理由、维护约束与踩过的坑一律见 [`playback/queue.md`](playback/queue.md)**（本节只留地图，
细节在两处重复就会各自漂移——2026-10-17 的架构文档漂移就是这么发生的）。

术语：**摞**（一次输入引发的全部回复）/ **页**（一条消息）/ **块**（合成单位）/ **段**（容器里的排队单位，一摞 = 一段）。
完整术语表见 [`playback/requirements.md`](playback/requirements.md)，取舍见 [`playback/purpose.md`](playback/purpose.md)。

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
- **只给麦克风让路**（外加 Web 控制台的手动控制）：录音要干净、背景音乐会串进麦克风干扰识别，所以录的时候让它停；说完则继续 —— 它不是"控制你的播放器"。**播报不经由它**（播报不改音乐的播放状态；播报期间改汽水音乐音量的是另一条路，见 `SodaVolumeDucker`）。只认抖音 / 汽水音乐两个 App（`AudioAppRegistry`），其它播放器一概不碰；`MediaController` 是 `actor`，记着"这次暂停是我们发的"，恢复只对自己发过的暂停生效
- 语义是**「说完继续」，不是「恢复原状」**：你若本来就把音乐暂停着，录音结束会**把它放起来** —— 这是设计意图（"让路"预设了"对方本来在走"），不是缺陷
- 曾想把判据做得更"精确"（暂停前先查"是否真有媒体在播"）：MediaRemote 那条是**回调式私有 API**，在 Swift 6 下连踩两坑（`@convention(block)` 被判 sending → 区域隔离编译错；绕开后闭包逃逸 → 运行期崩、daemon 崩循环），已撤。也考虑过用"**静音**代替暂停"—— 不成立：系统音量是全局的，会把 iVox 自己的播报一起静掉（macOS 没有按 App 调音量的公开接口）

### SodaVolumeDucker — 播报时给汽水音乐让路

`Sources/iVox/MediaControl/SodaVolumeDucker.swift`

- **播报开始 → 汽水音乐降 5 格，播报结束 → 升 5 格**，每格间隔 500ms（汽水音乐反应慢，再密它跟不上）
- **走 ESP32-S3 的真 HID**（`POST http://192.168.100.3/key`）：汽水音乐**丢弃 CGEvent 合成键**（实测），只有真硬件事件才被它当用户操作。设备接口 token 读 esp32-hid-lab 仓里那一份（就是烧进板子里的同一个值）
- **改数值、不切播放状态**——所以不会重演旧「借还背景音乐」的抖动（借了还、还了借，状态来回切）
- **相对调节，不读当前格数**：汽水音乐那 20 格是**应用内**音量（不是系统输出音量），本机读不到。音量本来就低时会触底，播完升回去不等于原值——已知取舍
- 只在汽水音乐**正在运行**时动手：这些键会同时送到前台 App，它没开时按下去只会误伤当前窗口
- 播报侧只发两个时刻（`PlaybackSignal.started` / `.ended`），按键在后台发，**不占播报主流程**

### ScreenControl — 锁屏 / 解锁

`Sources/iVox/Screen/ScreenControl.swift`

- **`ivox lock` / `ivox unlock`**：锁屏是 `Ctrl+Cmd+Q`；解锁是「按一下 Ctrl 唤醒 → 等 2 秒 → 输密码 → 等 500ms → 回车」
- **走 HID 真键**（`HidInjector` → 常驻 ESP32-S3 注入器）：**macOS 锁屏后不把 CGEvent 合成键交给
  loginwindow** —— 合成键能锁屏，**醒不来**。所以锁屏与解锁都发真硬件事件
- 锁屏**只有这一个实现**：Web 控制台的锁屏按钮也走它（原来那条 CGEvent 路已删）
- **覆盖范围**：只做「锁屏」这一种。**重启后的解锁不在范围内**——重启后要先进系统才有 daemon，
  daemon 没起来就发不出解锁键。解锁还要求系统**没睡眠**（睡眠了进程被冻结）
- 登录密码是 **AES-GCM 密文，写死在代码里**（`ScreenControl.swift`），运行时解开。
  **安全边界**：密文与密钥都在二进制里 → 挡住的是「明文出现在源码/日志/命令行」，**挡不住逆向**。
  另：密码以明文走局域网 HTTP 到板子（固件无 TLS），同一 WiFi 上抓到包的人能还原它
- Web 控制台上是**一个滑块、两个方向**：右滑锁定、左滑解锁（滑块位置即锁屏状态）

### SpeechInput — 语音输入

`Sources/iVox/SpeechInput/`

- 键盘监听由 `HotKey/GlobalKeyTap` **独占**（一个 tap 服务多个消费者，见下节），本服务只订阅**修饰键**：右⌘(0x36) / 右⌃(0x3E) 的状态变化由它回调进来
- **right ⌘/⌃ 按下**：过 150ms 长按阈值 → 查授权 → **先试录**；`record()` 成功了才暂停音乐 +
  取消 TTS + 出浮窗（见下「副作用在录上之后」）
- **right ⌘/⌃ 松开**：结束录音 + 恢复音乐 + 开始 ASR 识别
- 用户快捷键五个：right⌘ 说话、Opt+S 插队念译文、Ctrl+2 掀桌（只静音播报，不录音、不碰音乐）、Ctrl+1 跳整摞、Ctrl+Esc 读下一页。**pi 新轮与停止帧不再打断**，一律排队
- ASR 结果通过 `CGEvent` 模拟键盘输入 + `NSPasteboard` 粘贴
- 需要设备控制与数据访问权限（`AXIsProcessTrustedWithOptions`）
- **副作用发生在「真的在录」之后**：原先一按下就先打断播报、暂停音乐，然后才建 recorder——
  没插麦克风时按一下 = 白打断一次播报、白暂停一次音乐，然后静默失败。现在**先试录、试活了才
  让路**：打断与让路是为录音服务的，没在录就没什么好让的
- **刻意不做设备预检**：耳机类麦克风**按需唤醒**，未唤醒时枚举/默认设备可能为空，预检会误判、
  把本来能用的设备焊死。按下就试这一下、试活了算数，恰好是对按需唤醒最友好的做法
- 失败日志**授权层与设备层分开报**：TCC 的 `authorizationStatus` vs CoreAudio 的默认输入设备名
  （`AVAudioSession` 是 iOS 独有的，macOS 上走 `CoreAudio`）。实测常见形态是「授权已给、
  设备层空」——只写「启动失败」会让人跑去系统设置里白找，那儿本来就勾上了
- 失败路径的 recorder 进**隔离区**延迟 1 秒释放：`record()` 返回 false 的那一瞬 audio queue 的
  回调线程**已经起来**了，立刻析构会让它访问已释放对象 → `objc_loadWeak` 野指针 SIGSEGV
  （2026-10-19 实测）。与 TTS 那侧「排空 MLX 流再放行」是同一条纪律：**底层线程已经在跑，
  就不能把对象扔了**

### GlobalKeyTap — 键盘事件层

`Sources/iVox/HotKey/GlobalKeyTap.swift`

- 独占一个 CGEvent tap 与**专用线程的 run loop**，只按事件类型 / keyCode **路由**，不含任何业务判断
- **键位可配**：配置 `hotkeys` 段（`Config.hotkeys`）按动作名给键位，只写要改的；默认键位的**唯一真源**是
  `HotKeySpec.defaultChord`，解析器与默认值都在 `iVoxKit/HotKeySpec.swift`（纯逻辑、可测）。改完跑
  `ivox restart` 生效。**本节及下文提到的所有键位都是默认值**——实际生效的看 `daemon.log` 里的
  「热键: 动作 = 键位」各行；配错时那里会写明是哪个动作、错在哪、退回了哪个默认
- 消费者按**能力归属**分派（`Daemon.setUpHotKeys()`）：右⌘/右⌃ → `SpeechInputService`；`Opt+S` → `TranslationService`；`Opt+Z/A/Q/X/C` → `QuickActionsService`；`Ctrl+2` / `Ctrl+1` / `Ctrl+Esc` → `PlaybackQueue`（手动打断三档：掀桌 / 跳整摞 / 读下一页）
- 热键精确匹配（四个标准修饰位全等，故 `Cmd+Shift+D` 之类的变体不误触），其余按键一律透传；`keyUp` 也一律透传（若按 keyCode 宽松匹配，会吞掉「单独按 D」的抬起而干扰打字）
- ⚠️ tap 回调**跑在专用线程且监听的是全系统键盘**——回调里任何耗时都会拖慢整机输入，所以只做整数比较，业务一律 offload
- 普通键（`keyDown`）需要「输入监控」权限：只授辅助功能时表现为"修饰键正常、`Opt+S` 毫无反应"，启动时用 `CGPreflightListenEventAccess()` 自检并打印引导
- **防误触也在这一层判，一处判完**（都是纯整数比较，不碰业务）：① **同键冷却，按键分档**——
  `Opt+S` 0.2s（它靠后写胜出连按，冷却只挡连击）、三个打断键 0.3s（翻页掀摞本就该能连按）、
  其余 1s。冷却中**仍然吃掉事件**只是不执行：漏给目标 app 更糟。走 `systemUptime` 单调时钟，
  只在 tap 线程读写，不加锁。② **右⌘/右⌃ 150ms 长按阈值**——按下沿延迟到阈值才发，阈值内松开
  当没发生过。它**不套冷却**：按住说话是「按下起录、松开结束」，套冷却会把「说一句再说一句」
  的第二句吃掉。⚠️ 每 `make update` 都会重签二进制、**输入监控权限可能随之失效**（TCC 跟着
  签名走），症状是 `Opt+S` 全哑而修饰键照常

### Translation — 划词翻译

`Sources/iVox/Translation/`（AppKit/CG 侧）+ `Sources/iVoxKit/Translation/`（纯逻辑，可单测）

- `Opt+S` → 模拟 `Cmd+C` 取选中文本（`ClipboardReader`，用 `changeCount` 校验剪贴板**真的变了**，而不是 iDict 那样盲等 50ms）→ 翻译 → 屏幕下方居中的歌词式浮窗（`TranslationPanel`，NSPanel 非激活浮层）+ 可选朗读
- **贵的动作押后**：先弹「读取选区…」占位 → 读剪贴板校验 → 弹「翻译中…」→ **等 200ms 提交点才发请求**。期间又按一次（世代推进）就到此为止，请求压根不发——误触的代价从「一次请求 + 一次朗读」降到「一个闪一下的空窗」
- **连按是「后写胜出」而非丢弃**：`generation` 世代号，在途的那一代回来发现号变了就作废、不上屏不朗读。原先 `guard !inFlight else { return }` 是直接丢第二次，换了个选区想再译一次白按
- **译文零重复推理**：`TranslationService`（actor）两层——**在途去重**（同一段文字并发时后到的等同一次的结果）与**最近 16 条译文缓存**（FIFO，键带 `provider|model`，切后端不拿旧译文顶账）。命中缓存**照样朗读**：用户想听的是译文，缓存省的是生成，不是他的耳朵
- **三个浮窗各自独立、刻意不抽公共件**（消失策略与生命周期各不同，硬抽要开一堆口子）：语音波形（`OverlayPanel`，跟鼠标收）、翻译结果（`TranslationPanel`，屏幕下方 96pt）、播报字幕（`CaptionPanel`，贴底 24pt，`captions.enabled` 开关，**跟播放不跟合成**）。三者同源的是那套 `NSPanel` 组合：非激活、悬于所有窗口、跨 Space
- **字幕钉在哪块屏**：默认主屏（`NSScreen.screens.first`）——**不跟 `NSScreen.main`**（那是键盘焦点所在屏，焦点一动字幕就跑到人看不见的屏上去）。要钉到别的屏，配置 `captions.screen` 填那块屏的 **UUID**（`ScreenIdentity`，macOS 由 EDID 派生、系统自己拿它记屏幕摆位，拔插/重启/改分辨率都不变）。**为什么不用序号/型号/坐标**：同型号同分辨率的两块屏（两块 Redmi 27 NU）在 vendor/model/serial 上完全相同，只有 UUID 认得出；序号随插拔漂移、坐标随摆放变。钉的屏没接上时落回主屏并告警一次
  - ⚠️ **macOS 给同型号两块屏起的编号不是「第几块」**：`localizedName` 里「Redmi 27 NU (2)」是**上层那块**（主屏、菜单栏那块），「(1)」是下层那块——别照 `system_profiler` 的列出顺序数，那儿是另一回事

- 翻译走 `iVoxKit.TranslationService`（`actor`）：Google 主/备**双通道容灾**，或 OpenAI 兼容；**直连失败自动走兜底代理**（`translation.proxyURL`），直连用短超时探测（`directProbeTimeoutSeconds`），成功后记住「该走代理」
- 朗读走 `PlaybackQueue.speakUserInitiated()`：**插队**——掐掉在播的那一句让译文立刻响，但**不掀桌**（其余段全保留、流式轮不作废）。与 hook 汇报的「只排队」语义相反
- 浮窗**刻意不做**拖拽 / 点击外部关闭 / 文本选择——这三样都要 key window，当前无 `NSApplication` 事件循环的形态给不了
- CLI 侧 `ivox translate <text> [--selection] [--json]`**不依赖 daemon**，是整条链路的可验证接缝

### QuickActions — Finder/终端快捷

`Sources/iVox/QuickActions/QuickActionsService.swift`

- `Opt+Z` 在 Finder 当前目录开终端；`Opt+A`/`Opt+X`/`Opt+Q` 开终端并执行 `claude`/`codex`/`pi`；`Opt+C` 把选中项路径写进剪贴板
- `Opt+Z`（不带命令）在 Ghostty **已经在跑时改为聚焦**而非开新窗口——连按五下开五个终端是最明显的「后面干活的压力」。取舍：复用时不保证落在 Finder 当前目录（取已在跑的窗口目录要向 Ghostty 要 Automation 授权，不值当）。带命令的三个**仍开新实例**（见下条实测坑②，这条不能破）
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
| `DaemonStatus.swift` | `{type:status}` 的返回体：七个能力域的健康度 + 权限 |
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
  ├── PlaybackQueue (actor)    ← await 调度 `any TTSProviding`（默认 TSPRemote，跨进程）
  │                              与 AudioPlayer（音频回调走 AudioPlayer 的 serialQueue）
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
   - voice = sourceVoices["claude"] ?? sourceVoices["default"]
   - 显式 `{voice:xxx}` 可覆盖
   - cleanText() 清洗 Markdown + 行内噪音
4. PlaybackQueue.enqueue(job) → PlaybackSession.appendPlain / appendGrouped
   → 追加到队尾；由收敛点 `pumpOrSettle()` 判断要不要起管道（**不是这里判断**）
5. `engine.synthesizeStream()`（`any TTSProviding`，默认 TSPRemote 走 socket 到誊清员）
   → AsyncThrowingStream<Data>；块号 `seq` 是跨进程归因的主键，两侧日志都打它
6. AudioPlayer.write(chunk) → scheduleBuffer 连续排队（超高水位背压）；跨块不 drain。
   块带「句首」标记（`AudioChunk.sentenceText`）时，被设备读出即回报字幕（`onCaption`，见上节）
7. 每块播完（或失败/取消）都 `session.commit(cursor)` **无条件前移**——不前移就会卡在同一块上死循环
8. 整条管道末端 drain() 一次，等跨块尾音播完
9. 还有没收尾的摞（`session.anyUnsealed`：未封的段 **+ 已声明未到字的流式轮**）但队列已空 → 起空闲宽限；
   否则收字幕（**不还音乐，播报早就不碰它了**）。宽限是**兜底**（60 秒），常态是端说完了就立刻收
   （端说了「说完了」= `session.finishedTurns` 记一笔：**收尾是终判**，后到的正文照念但不再揭回
   「还在说」——收尾与正文是两条独立通路，谁先到没保证）
```

### pi 流式播报（第二层流式）

pi 扩展（`scripts/pi/ivox.ts` → `~/.pi/agent/extensions/ivox.ts`）在模型生成中逐 `text_delta` 转发**原文**（TS 侧不切句），经一条长连接按 `\n` 分帧送入 socket。**这条连接的边界是一个 agent run（= 一次输入）**，不是 turn —— pi 的结构是 `agent_start` 之后 N 个 turn 循环、每个 turn 恰好一条 assistant 消息（`packages/agent/src/agent-loop.ts`），整摞回复都落在同一个 `agent_start … agent_end` 之间，页的边界由每条 assistant `message_start` 的 `{page}` 帧给出：

```
{type:stream,source:pi,turn:<id>}\n   首帧开流（beginTurn，登记轮次；新轮排队不打断）
<增量原文行>…                          仅 text_delta，跳过 thinking/toolcall
{end}\n                                agent_end 收尾      或  {cancel:<id>}\n（Escape）
```

`ConnectionHandler.handleStream` 把增量喂给 `StreamBuffer`（iVoxKit）：累积原文，只在**安全边界**（句末/段落、且吐出前缀代码围栏配平、累计 ≥ `minFlushChars`=24）抽出完整前缀 → 复用同一份 `cleanText() → splitSentences()` 切句入队。切句/清洗真源只在 Swift 一份，TS 绝不切句（否则破坏 Markdown AST 块末补句号与跨行规则）。模型写下一句时上一句已在常驻管道里播。

### 微信消息

```
1. WeChatPlatform 长轮询 getupdates（每 ~35 秒）
2. 收到消息 → 去重 → 白名单过滤 → 提取文本
3. Daemon.handleWeChatMessage()
   → ClaudeAskService.askStreaming()（常驻 `claude`，走 stream-json 双工，非 --print）
   → WeChatPlatform.sendMessage() 发回微信
```

**这条链路不发声**：回复以文字发回微信，不进 `PlaybackQueue`（裁决见
[playback/purpose.md](playback/purpose.md)）——聊天窗口里已经有文字了，再念一遍是打扰。
它也不经过 Claude Code 的 hook 体系（那是 Claude Code 会话才有的）。

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

优先级：`显式 voice > sourceVoices 映射 > sourceVoices["default"]`（默认音色就并在这一段里）

```
ConnectionHandler.extractVoicePrefix():
  if {voice:xxx} in payload  → xxx
  else if {source:s}         → sourceVoices[s] ?? sourceVoices["default"]
  else                       → sourceVoices["default"]
```

## 部署结构

所有运行时文件在 `~` 下，项目目录可删：

```
~/.local/bin/ivox                          # CLI 与守护进程同一个二进制（约 61MB，ad-hoc 签名）
~/.config/ivox/config.toml                 # 配置（TOML，可写注释）
~/.config/ivox/scripts/                   # 接入资产权威源（随发布包解包，分发器读这里）
~/.config/ivox/hook.sh                     # 分发后的 hook（Claude 挂载引用它）
~/.config/ivox/model/                      # TTS/ASR MLX 模型
~/.config/ivox/voices/                     # 参考音频
~/.config/ivox/wechat/                     # 微信轮询状态
~/.config/ivox/daemon.log                  # 主进程日志（5MB 轮转）
~/.config/ivox/tts.log                      # 誊清员日志（拆进程后各写各的）
~/.config/ivox/tts-crash.log               # 誊清员崩溃现场（主进程的 crash.log 是它自己的）
~/.config/ivox/crash.log / crash.count     # 主进程崩溃现场与累计次数
~/.config/ivox/ivox.sock                    # 主进程 socket
~/.config/ivox/ivox-tts.sock                # 誊清员 socket
```

日志为什么分家（2026-10-19 决定）：拆成子进程后若还共用一份文件，从「pi 没出声」
查到「MLX 崩了」翻了三轮日志——因为**所有角色写进同一个文件，谁的错看不出来**。
分家之后判据变成一句话：**哪个文件里有现场，就是哪个角色的错**。三份日志靠
`IVOX_LOG_FILE` 与 `IVOX_ROLE` 落点，块号 `seq` 随 IPC 递过去，跨文件对得起来。

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

**打断权只归 ivox 快捷键**（right⌘ 说话 / Opt+S 插队译文 / 手动三档：Ctrl+Esc 读下一页 · Ctrl+1 跳整摞 · Ctrl+2 掀桌）；`hook.sh` **不再有 interrupt 分支**（手动打断在 `ivox skip` 三档：`--page` 读下一页 / `--stack` 跳整摞 / `--all` 全场闭嘴），`UserPromptSubmit` 亦不挂。

| 工具 | 配置/挂载 | 回复播报 |
|------|----------|----------|
| Claude Code（交互会话） | `~/.claude/settings.json` | **MessageDisplay → `hook.sh msgdisplay claude`**（assistant 行批增量，过程逐句播、final 批含完整结尾）＋ **Stop → `hook.sh end claude`**（只发「这一摞说完了」的暗号，不出声） |
| PI coding agent | `~/.pi/agent/extensions/ivox.ts` | `message_update` 流式（`agent_settled` 兜底） |

由 `install-hooks.sh` 统一安装（Claude 挂 MessageDisplay + Stop 收尾信号）；它**不再挂 UserPromptSubmit interrupt**（`write_prompt_hook` 已被置为 no-op）。它**只写不删**：老配置里遗留的 Claude `Stop` 播报得人工摘除（`settings.json` 的 `hooks.Stop`），否则与 MessageDisplay 同播会把整条回复念两遍。`hook.sh` 有 `msgdisplay` / `end` 两模式（`end` 只送收尾暗号、不出声）：`msgdisplay` 提取 `delta` 增量并攒成整页，经 `ivox speak` 排队入队（不打断）。

**`~/.config/ivox/lastturn/`** 是 hook 链的一小块状态：Claude 的 Stop payload 里**没有 `turn_id`**（官方
hooks reference 的 Stop 专属字段只有 `stop_hook_active` / `last_assistant_message` / …，通用字段是
`prompt_id`），所以 `msgdisplay` 每批把 `session_id → turn_id` 的对照写进这个目录，Stop 到了再反查。
按 session 分文件是为了两个会话并行时互不覆盖。**七天后自动淘汰**：这张表只为 Stop 反查而存，回复
结束就无用，此前只涨不清（实测堆到 30 个文件）；现在每轮 Stop 顺手扫一遍删掉 mtime 超过 7 天的——
一轮一次、代价可忽略，七天内可能还会被反查，更早的会话不可能还在对话里。

**接入资产随发布包自包含**：release tarball 除 `ivox` 外含 `scripts/`（hook.sh + pi/ + install-hooks.sh），安装/升级时解包到权威源 `~/.config/ivox/scripts/`，再由分发器幂等铺到各 agent 位置。同步只发生在三个显式时机：`make update`（runtime.sh deploy-bin）、`ivox update`（UpdateCommand 解包后 Process 调分发器）、`install-binary.sh`（curl|bash 首次安装也补齐接入）；守护进程启动不自动同步。分发器与被分发的资产**同目录**（部署态在 `~/.config/ivox/scripts/`，源码态在仓库 `scripts/`），素材源即自身所在目录，无需探测。
