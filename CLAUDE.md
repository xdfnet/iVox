# CLAUDE.md

为 Claude Code 提供代码协作指导。

## 与 Claude 协作

- **少发 Bash**：查一次就够，命令能合并就合并，输出只回关键几行。
  终端里 `⏺ Bash(...)` 块会刷屏，而 Claude Code 没有隐藏工具调用的开关
  （`viewMode` 是它打包的 Storybook 字段，对 CLI 无效，2026-10-21 实测）——
  屏幕干净只能从我这边少刷。

## 编译

```bash
# Release 编译（默认）
make build

# 编译 + 部署 + 重启守护进程
make update

# 运行测试
make test

# 清除构建产物
make clean

# 前台调试运行
make run
```

**需要 Swift 6.4** — 使用开发快照 `swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-06-15-a`。Makefile 使用 `xcrun --toolchain swift-latest swift`（`swift-latest` 符号链接指向该快照）。

## 项目结构

```
Sources/iVox/          — 主程序 target
  EntryPoint.swift     — @main, ArgumentParser 子命令

  ── 七个能力域（目录与 README 功能表、ivox status 一一对应）──
  Playback/            — 自动播报：PlaybackQueue + PlaybackSession + AudioPlayer + CaptionPanel（播报字幕，config 可开关；`captions.screen` 可按屏的 UUID 钉到指定屏）+ PlaybackSignal（播报起落信号，给「给背景让路」用）
    TTS/               — 合成层：TTSProviding（契约）+ TSPRemote（默认，跨进程）+ TTSServer/TTSEngine（誊清员子进程）+ TTSTrace
  SpeechInput/         — 语音输入：右⌘ 录音 + ASR + 浮窗（事件由 HotKey 层送来）+ ClaudeAskService（ASR 出文后送问 Claude）
  Translation/         — 划词翻译（Opt+Z）：复制 → 翻译 → 浮窗 + 朗读
  QuickActions/        — 快速操作：Finder/终端快捷（Opt+Q/A/X/S/C）
  WeChat/              — 微信桥接：ilink HTTP 客户端 + 长轮询平台
  MediaControl/        — 媒体控制：Web 控制台（MediaHTTPServer + Web UI + HTTPResponseHandler）+ MediaController + AudioAppRegistry + HealthSnapshot + SodaVolumeDucker（播报时给汽水音乐压音量）
  Screen/              — 屏幕锁：ScreenControl（ivox lock / ivox unlock + Web 滑块，走 HID 真键）

  ── 基础设施（跨能力域）──
  HotKey/              — 键盘事件层：GlobalKeyTap（**收**键：独占 tap，按归属路由给上面几家）+ HidInjector（**发**键：往常驻 ESP32-S3 注入器发真硬件事件，串行队列）
  Network/             — SocketServer（Unix domain socket IPC）+ ConnectionHandler（帧解析与分派）
  Daemon/Daemon.swift  — actor-based daemon: init → run → cleanup loop；装配与热键分派
  Commands/            — ServeCommand, SpeakCommand, TranslateCommand 等
  Version.swift        — 版本号常量（唯一真源，make version 写它）
  Resources/           — assets, 默认音色, Info.plist, 配置模板（编进二进制 bundle）

Sources/iVoxKit/       — 共享库（无 MLX 依赖）
  Config.swift         — JSON 配置模型（外部配置；键名一律驼峰）+ 内置音色 VoiceCatalog（代码内配置）
  ConfigAudit.swift    — 配置键名审计：报出「写了但没人认领」的键（已知键由各类型 CodingKeys 派生）
  Logger.swift         — Log.{info,debug,warn,error}
  DaemonStatus.swift   — {type:status} 的返回体（七个能力域健康度）
  SocketClient.swift   — AppPaths + socket 客户端
  TextCleaner.swift    — Markdown + 噪音过滤（给 TTS 用）
  TextSplitter.swift   — 流式文本分块
  StreamBuffer.swift   — 流式 turn 的安全边界切分
  StreamFrame.swift    — 长度帧协议
  AudioPipeline.swift  — 重采样
  Translation/         — 翻译服务（Google 双通道容灾 + OpenAI 兼容）、配置模型、选区清洗

Tests/iVoxTests/       — 测试（18 个文件：多数只依赖 iVoxKit；PlaybackSessionStoryTests、CaptionLayoutTests、TSPRemoteSlowSynthesisTests 例外，@testable import iVox；TestSocketServer 是共用假 socket server）

docs/                  — README.md（索引 + 分类规则）· architecture.md · hook-chain.md · socket-api.md · native-bridge.md（微信链路实测依据）；playback/ 放播报五层：paper.md（比喻，**建立直觉但不裁决**）· purpose.md（取舍，**有分歧听它**）· sources.md（接入方）· requirements.md（需求）· queue.md（实现 + 维护约束）；CHANGELOG.md；archive/ 放历史复盘与调研
scripts/               — 装机与部署：runtime.sh（部署）· download-models.sh · fetch-mlx-submodules.sh · install-*.sh · tts-check.mjs（黑盒自检）
                        接入资产（各外部 agent 的对接层，安装时由 install-hooks.sh cp，不编进二进制）：
                        · hook.sh（Claude Code 的播报 hook：msgdisplay 送整页 / end 送收尾暗号）
                        · pi/ivox.ts（pi coding agent 流式扩展）
```

## 架构

> 本节只留**地图**（谁在哪儿、关键模式是什么），细节一律推给 `docs/`——`architecture.md`（整体架构）、`hook-chain.md`（钩子链路）、`playback/`（播报四层）。地图与细节分开维护，否则两份会各自漂移。

基于守护进程的 actor 架构（LaunchAgent 托管，`ivox on/off` 控制启停、`ivox restart` 只重启进程）：

```
Claude Code → hook.sh                   ┐
pi 扩展(scripts/pi, text_delta 流式)  ├→ Unix Socket → Daemon ─┬─ PlaybackQueue (actor)
微信 ilink 长轮询 → WeChatPlatform（**只发消息，不发声**，不进本图这条线）
                                           │   ├─ TSPRemote ─→ 誊清员子进程 `ivox tts --serve`（mlx-audio-swift）
                                                                   │   └─ AudioPlayer (AVAudioEngine)
                                                                   │        └─ CaptionPanel (播报字幕，可选)
                                                                   ├─ GlobalKeyTap (键盘事件层，一个 tap)
                                                                   │    ├─ SpeechInputService (右⌘ + ASR)
                                                                   │    ├─ TranslationService (Opt+Z 划词翻译)
                                                                   │    └─ QuickActionsService (Opt+Q/A/X/S/C)
                                                                   ├─ MediaHTTPServer (端口 8888, Web UI)
                                                                   │    └─ ScreenControl (Web 滑块锁/解锁)
                                                                   └─ ScreenControl (ivox lock / unlock)
                                                                        └─ HidInjector (真 HID → ESP32-S3 注入器)
```

关键模式：
- **Swift 6 严格并发**：所有服务都是 `actor` 类型。跨 actor 调用使用 `await`。`@Sendable` 闭包必须捕获值拷贝的 `let` 绑定（不能是 actor 上下文中的 `var`）。
- **Daemon 生命周期**：`init` 加载配置 → `run()` 并行启动所有服务 → `cleanup()` 处理 SIGINT/SIGTERM 退出。
- **微信长轮询**：`GetUpdatesResp.ret` 是 `Int?`（API 在空响应时省略 `ret`）。手动用 `withThrowingTaskGroup` 让 URL 请求和 `Task.sleep` 超时竞速（URLSession idle timeout 在长轮询 TCP keep-alive 下不会触发）。
- **TTS 两层流水线**：
  - *第一层（切句/清洗，真源只在 Swift 一份）*：文本先 `cleanText`（Markdown AST 去噪 + URL/路径/ANSI/emoji 处理）再 `splitSentences`（句末边界 `。！？!?…；;\n`，合并到 ≤80 字；英文 `.` 不切以保小数/缩写）。TS 扩展和 hook **绝不在客户端切句**（会破坏 AST 块末补句号与跨行规则）。
  - *第二层（连续播放管道）*：`PlaybackQueue.processNext` 是跨所有 job 的循环，逐句 `synthesizeStream → player.write`，**句间不 drain**；`AudioPlayer` 用单个常驻 `AVAudioPlayerNode` 连续 `scheduleBuffer`，4s/2s 高低水位背压（`pendingFrames` 随 `dataConsumed` 核减），prime 静音仅在设备播空/取消后补一次，`drain()` 只在整轮末端调一次。改这里务必读 `docs/playback/requirements.md`（需求）与 `docs/playback/queue.md`（实现），不要重新引入逐句 drain（会导致逐字卡顿）。
- **流式 turn 协议**：pi 扩展经一条长连接按 `\n` 分帧：首帧 `{type:stream,source,turn}` → 原文增量帧（仅 text_delta）→ `{end}`/`{cancel}`，EOF=end。**这条连接的边界是「用户的一次输入」（pi 的一个 agent run），不是它内部的 turn** —— pi 一次输入会拆成 N 个 turn（每个 turn 恰好一条 assistant 消息、工具调用就再来一轮），所以 `agent_start` 开流、`agent_end` 关流，中途每条 assistant `message_start` 发一个 `{page}` 帧分页。早先按 turn 开合等于把一次输入切成 N 摞、Ctrl+1 只掀得掉一页（2026-10-18 修）。`turn` 号本身是接入方自编的接力棒（只管「这批跟刚才那批是一伙的」），**外部有没有像样的 id 不重要，摞/页/块的内部号一律由助理自编**。服务端 `StreamBuffer`（iVoxKit 纯逻辑）累积原文，只在安全边界（句末/段落、代码围栏配平、≥`minFlushChars`=24）抽出整段复用同一套 cleanText→splitSentences。`PlaybackJob.turnID`：**队列按轮排队，播全播完**——同一 `turnID` 分块并入同一段顺序追加，新 turn 在队尾追加新段、**不打断**在播旧轮（这一摞播完才前移）；无 turn 的普通播报（`ivox speak`/hook.sh）同上排队。**打断的准星**：动手的只有用户，机器最多「借道」—— 队列的长期顺序只由到达顺序决定，谁都不永久插队；Opt+Z 译文是唯一的机器开口，也只是临时插队（念完即走，原顺序原样）。**打断权只归用户快捷键**，手动打断三档全是「掐 + 掀」——**掐** = 断在播的那一块，**掀** = 丢弃某一层的全部内容：**Ctrl+Esc** = 掐 + 掀当前页（`skipCurrentPage`：掀掉当前页的剩余块；还没来的页不拦）、**Ctrl+1** = 掐 + 掀当前摞（`skipCurrentBucket`：掀掉这一摞的全部段 + 立墓碑拦它的后续增量，下一摞接着播）、**Ctrl+2** = 掐 + 全掀（`cancelAll`，**挂墓碑**：当前存在的所有摞，不分来源，它们的后续增量也别来）/ 右⌘ 说话（**暂停不删**：设备闭嘴让麦克风干净，队列与内容一概不动，说完接着播——「你停一下」，不是「你别说了」；2026-10-23 修：它原先误用「全掀」，于是被清场顺手埋了碑，Claude 同一摞后续送来的页被静默丢弃，实测丢过 891 字 / 15 块）。Opt+Z 译文是**插队**——`speakUserInitiated` 只掐在播、译文段插到队首（加急位），其余段全保留（播完译文接着播）。`{type:stop}` 停止帧与流式新轮**不再打断**（ConnectionHandler 对 stop 帧仅记日志忽略）。某段 sealed 才允许空段前移；流动中空段保活等下一批。连接内这四类操作经 `ConnectionHandler.StreamOpChain` **按帧序执行**（乱序会让 `{end}` 之后到达的同轮分块把已关轮次重新打开、管道永久挂起）。详见 `docs/socket-api.md`。
- **播报的词只用这三个**，其它说法一律作废；完整术语表见 `docs/playback/requirements.md`）：
  **摞** = **你发一条信息之后 AI 为此产生的全部回复**（夹工具调用时它会回答很多次，全算这一摞；由你按回车划分；身份是助理自编的 `PlaybackSegment.localID`，外部 `turn_id` 只作备注）；
  **页** = 一摞里的**一次回复**（一条 assistant 消息；身份同样是助理自编的 `PlaybackPage.localID`，实测一个 turn 底下最多见过 19 页）；
  **块** = 1～80 字的合成单位（**服务拿去播报用的，不是给用户看的**；`PlaybackBlock`，页上的文字被切开送去合成的那些条）。
  读法：捏着队首那一摞 → 翻到当前页 → 撕下一个块去合成播放 → 这页撕完翻下一页 → 这一摞说完（下一条回复到来把它盖上）→ 换下一摞。
  按键对应（三档都是掐 + 掀）：**Ctrl+Esc = 掀页**、**Ctrl+1 = 掀摞**、**Ctrl+2 = 全掀**。
  ~~"assistant"~~（一会儿指回复、一会儿指会话）、~~"一叠 = 一轮、一张 = 一句"~~、~~"跳这句"~~（实现里没有"句"这个单位）都已作废。

- **播报通路（hook / 微信 / MessageDisplay）**：①Claude Code 交互会话的播报**只靠 `MessageDisplay` 钩子**（`hook.sh msgdisplay claude`）——assistant 消息按行批增量播报，过程内容（分步/工具多段）逐句进段、边写边播，**不再挂 Stop / UserPromptSubmit**（摘 Stop 因 MessageDisplay 的 final 批已含完整结尾，两者同播会重复；摘 UserPromptSubmit 因打断权只归快捷键）。钩子把 payload 的 **`turn_id` 当分组号**（`ivox speak --group`）——**一摞 = 一次输入引发的全部回复**，Ctrl+1 掀的就是整摞（后续增量由墓碑拦住，另见下「弱分组」）。**收尾三个触发点，主力是 `Stop`**：①**主力** `Stop` 钩子（`hook.sh end` → `ivox speak --final` → `closeOpenGroup()`：只送「说完了」这个暗号、**不带正文**，故与 MessageDisplay 不重复；**只标 ended、不立墓碑**——在途的页还要让它播完。⚠️ 2026-10-21 修过：收尾曾顺手立墓碑，于是「Stop 早到 9 毫秒」就把随后到达的最后一段 140 字静默丢弃（用户听到的是「念到一半没了声音」）——**Stop 与正文是两条独立通路，谁先到没保证**。⚠️ 2026-10-24 再修一处同源的问题：实测 27 轮里 **14 轮 Stop 比正文早到 10~20 毫秒**，于是最后一页正文落在 Stop 之后、**自成一摞**（用户按 Ctrl+1 想掀整轮，掀不到最后这页），字幕与音量还会在中途收一次又起一次。修法在**钩子侧**：`hook.sh end` 把收尾信号**延后 300ms 再发**（后台 sleep，钩子照常立刻返回），让正文先落地。⚠️ **延后只是减少竞态、不是消除**——实测正文与收尾只差 1 毫秒的情形照样发生（黑盒 `I1` 踩中）。**服务端因此加了一道终判**（2026-10-24）：收尾过的摞记在 `PlaybackSession.finishedTurns` 里，**后到的正文照念（一个字不丢），但不再把这一摞拽回「还在说」**。早先它会把印揭开（`sealed = false`），于是这一摞永远停在「还在说」→ `anyUnsealed` 恒为真 → **队列永不结算 → 字幕不收、汽水音量不还**（黑盒 `I1` 干等 60 秒超时）。宽限封的印**照旧可揭**（宽限只是猜「说完了」，不是判死）。现在**内容生死只由用户主动放弃决定**（掀/全掀/取消才埋碑；**右⌘说话不是放弃，只是暂停**），收尾只管「什么时候收字幕」）；②「新的 turn 来了就把上一个盖上」——**清场与兜底**（盖上即可，不埋碑）；③**最后兜一层 60 秒空闲宽限**（`idleGraceSeconds`：队列见底又仍有未结束的轮，**先等设备把已排队音频播完**——声音真停下才开始数，否则会在尾音还没念完时就判完、把字幕收掉——再静候 60 秒没新内容即判说完）。**它只是兜底，不是常态**：常态是端说完了就立刻收（Claude 的 Stop / pi 的 `{end}`）。⚠️ 2026-10-24 从 5 秒改成 60 秒：Claude 一轮里的多页之间常隔 20~130 秒（跑工具、想事情），5 秒一到就误判「说完了」→ **一轮被切成好几摞**（用户按 Ctrl+1 想掀整轮，掀不到最后那页）、字幕提前收、汽水音乐音量一升一降；页级的 `final` 只说明"这一页说完"，认不得"整摞说完"（一次回复夹工具调用会有好几页），所以不拿它收尾。`hook.sh` 已**移除 interrupt 分支**（手动打断改由命令行 `ivox skip --page|--stack|--all` 三档承担，`ivox quiet` 已删除）。②**微信链路不发声**：`WeChatPlatform` 只有 `sendMessage` / `sendTyping` / 长轮询，不进播报队列——聊天窗口里已经有文字了，再念一遍是打扰（见 `docs/playback/purpose.md` 的裁决）。③pi 走流式（见下）。

- **键盘热键分层**：`HotKey/GlobalKeyTap` 独占 CGEvent tap 与专用 run loop，**只按事件类型 / keyCode 路由**，不含业务判断——tap 回调跑在专用线程上且监听**全系统**键盘，回调里任何耗时都会拖慢整机输入，所以一律 offload。消费者：右⌘（默认；配置可改成右⌃ 或两者）→ `SpeechInputService`，`Opt+Z` → `TranslationService`，`Opt+Q/A/X/S/C` → `QuickActionsService`，`Ctrl+2`/`Ctrl+1`/`Ctrl+Esc` → `PlaybackQueue`（手动打断三档：掐+全掀 / 掐+掀摞 / 掐+掀页）（由 `Daemon.setUpHotKeys()` 按能力归属分派，不把逻辑揉在一起）。热键只精确匹配（四个标准修饰位全等，Cmd+Shift+D 之类的变体不误触），其余按键一律透传；`keyUp` 也一律透传（按 keyCode 宽松匹配会吞掉「单独按 D」的抬起、干扰打字）。**要加新热键：在 `iVoxKit/HotKeySpec.swift` 的 `HotKeyAction` 加一个动作 + `defaultChord` 给默认键位 + 在 `setUpHotKeys` 加一个消费者**（`GlobalKeyTap` 里不再有键位表，它只消费）。**键位可在配置 `hotkeys` 段按动作名改**（TOML 写法 `translate = "opt+z"`；首次安装会写全量默认键位）；⚠️ 默认键位有**两份副本**：代码兜底 `HotKeySpec.defaultChord` 与模板 `iVoxKit/ConfigTemplate.swift`（安装脚本不再内嵌第三份，改默认要同步这两处）；配错时启动日志会写明（哪个动作、错在哪、退回哪个默认），生效的键位逐行打「热键: 动作 = 键位」。改完跑 `ivox restart`（只重启进程，不动登录自启开关）。 注意普通键（keyDown）需要「输入监控」权限，只授辅助功能时表现为"修饰键正常、Opt+Z 毫无反应"。
- **防误触也在 tap 层判，一处判完**：① **同键冷却，按键分档**——`Opt+Z` 0.2s（它靠后写胜出连按，冷却只挡连击）、三个打断键 0.3s（翻页掀摞本就该能连按）、其余 1s；冷却中**仍然吃掉事件**只是不执行（漏给目标 app 更糟），走 `systemUptime`，只在 tap 线程读写。② **语音键（右⌘，默认只有它）有 150ms 长按阈值**——按下不足就松开判为误触，按下沿直接丢弃（很多 App 用右⌘，碰一下就打断播报+暂停音乐+开麦代价太大）。它**不套冷却**：按住说话是「按下起录、松开结束」，套冷却会把「说一句再说一句」的第二句吃掉。
- **右⌘ 语音：副作用发生在「真的在录」之后**——按下经阈值与授权检查后**先试录**，`record()` 成功了才 `pausePlayback`（**暂停播报输出**，不删内容：麦克风要干净，用户说的却是「你停一下」不是「你别说了」）→ `pause`（暂停音乐）→ 浮窗「聆听中…」+ Tink + 波形；松开右⌘再 `resumePlayback` 从原位接着播。**不做设备预检**：耳机类麦克风按需唤醒，预检「设备在不在」会误判、把本来能用的设备焊死；按下就试这一下、试活了算数。失败时播报不动、音乐不停，只在日志写清原因（**授权层与设备层分开报**：TCC 状态 vs CoreAudio 的默认输入设备名，`AVAudioSession` 是 iOS 独有的、macOS 走 CoreAudio）。失败路径的 recorder 进**隔离区**延迟 1 秒释放——`record()` 返回 false 时 audio queue 的回调线程已经起来了，立刻析构会 `objc_loadWeak` 野指针（2026-10-19 实测 SIGSEGV）。**全项目借还背景音乐只此一家**：只有说话时借（按下 pause、松开 resume）。**播报链路不改音乐的播放状态**——它做的是另一码事：播报开始把汽水音乐音量降 5 格、播完升回（改数值不切状态，所以不会抖，见 `MediaControl/SodaVolumeDucker.swift`）。

- **合成引擎有两个实现，装点在 `Daemon.init`**：`any TTSProviding` 默认是 `TSPRemote`（跨进程到
  誊清员 `ivox tts --serve`）；设环境变量 `IVOX_TTS=local` 退回进程内 `TTSEngine`，仅供调试期对照。
  **为什么默认远程**：MLX 的 Metal 命令编码器析构重复释放 GPU 命令队列 → SIGTRAP，上游未修、
  Swift 侧拿不到 encoder 引用，无从拦截，所以把它圈出去（裁决见 `docs/playback/purpose.md`）。
  `Daemon.cleanup` 会显式 `stopChild()`，不留孤儿（`kill -9` 主进程时它不会跟着死）。
  **合成流的三个时间纪律**（2026-10-24 修，细节见 `docs/playback/queue.md`）：① **读超时不是断流**——
  `EAGAIN` 继续等，判「断了」只有 EOF（原先沿用控制 socket 的 10 秒读超时，合成一慢就被当成
  断流 → 那一块整块丢弃，实测真对话里连丢 4 块）；② **引擎没就绪先等就绪**（请求撞上「模型正在
  加载」会被直接拒掉，那一块就白丢了）；③ **一帧都没送出时可重发一次**（已送出半截的不重发，
  否则会播成「前半截 + 从头再来一遍」）。时间口径集中在 `iVoxKit/SocketStream.swift`。

- **配置分三层**（2026-10-21 重新规划，飞哥裁决）：① **代码内配置**——都在 `iVoxKit/Config.swift` 里：
  `ModelPaths`（模型路径）、`TTSConfig.default`（合成参数）、`VoiceCatalog`（内置音色）、
  `MediaControlConfig.default`（Web 控制台开关与端口）；
  这些**不进用户配置**，外部再写会被审计点名（写了不生效）；② **外部配置**——
  `~/.config/ivox/config.toml`，**就这一个文件**，装凭据与用户会改的（开关/键位/端口/路径），
  **键名一律驼峰**（`wechat` 段早先是蛇形，2026-10-21 统一）；③ **用户数据**——录音、微信
  context_token 等程序写出的东西。**写错的键不会静默**：`ConfigAudit` 在解码后对照各段已知键
  打日志，还能猜「是不是想写 allowFrom？」（已知键从各类型 `CodingKeys` 派生，不另抄清单）。
  **格式是 TOML**（`iVoxKit/TOML.swift` 自研解析/序列化，无外部依赖）：能写注释，配置能当说明书读；
  默认模板在 `iVoxKit/ConfigTemplate.swift`（唯一真源，`ivox init-config` 写的就是它）。
  **配置注释的规范（2026-10-24 统一）**：每一项的注释**写在行尾**，一律三段——
  **是什么 ｜ 默认值 ｜ 可选值**（键名不重复，键就在左边）；需要展开说明的项，在它**上一行**
  另起一行、以 `#   ` 缩进写补充。全文件只有这一种风格。默认值取自代码真源（各类型的 `default`），
  别抄错。改注释风格时模板与用户的 config.toml **两份一起改**。
  程序改配置（`ivox voice add/remove`、`ivox wechat setup`）走 `TOMLDocument` **就地改**，
  保留用户自己写的注释——整体重排会把注释冲掉。
  所有运行时文件在 `~/.config/ivox/` 下（家当说明在 `Sources/iVox/Resources/runtime-files.md`，
  装机时由 `ivox init-config` 拷到 `~/.config/ivox/runtime-files.md`）。

- **日志分三份，各归各的角色**（分家是有意的：出事时「哪个文件里有现场，就是哪个角色的错」）：
  `daemon.log`（主进程：队列/打断/播放收尾，>5M 轮转）· `tts.log`（誊清员：合成侧）·
  `hook.log`（hook.sh 审计行，⚠️ 只增不减、无轮转）。靠 `IVOX_LOG_FILE` + `IVOX_ROLE` 分流。
  使用 `Log.{info,debug,warn,error}`。排查某一块怎么没出声：拿 `seq`（助理自编的块号，
  两侧日志都打）去 `daemon.log` 与 `tts.log` 对时间线。崩溃捕获见 `CrashTrap`：MLX 后端崩在 C++ 层时系统日志只有一行、没调用栈，故自己接信号往 `~/.config/ivox/crash.log` 写带栈的记录，下次启动打进 daemon.log 并原地 `ftruncate` 清空（**不能**用 `String.write(toFile:)`，那是「临时文件+rename」，换掉 inode 会让 handler 已开的 fd 写进无人可见的孤儿文件）；累计次数记 `~/.config/ivox/crash.count`（`crash.log` 每次启动就清空，光靠它编号永远是 #1）。

## 注释约定

与现有代码保持一致，新代码照此写：

- **中文**为主；`// MARK: -` 保留英文（Swift 惯例）。
- **解释「为什么」，不复述代码**。把下一行翻译一遍的注释应当删掉。
- **坑点写清后果与历史**——这是本仓最有价值的注释风格：「曾致 `EXC_BREAKPOINT`」「蓝牙断流实测必现」「顺序不可调换，否则 URL 会被当路径砍成残片」。难缠的时序/边界问题，踩坑结论写进注释，别只留在 commit message 里。
- **对外可见的 API 用 `///`**；iVoxKit 的 public 符号带参数说明（`- Parameter`）。
- **常量与魔法值就地说明来源**（如「3 秒是直连探测超时，理由是…」）。
- **每个文件开头一句文件说明**（`//`，1–2 行，写在 import 之后）：讲「这个文件负责什么」，方便按职责定位。它与类型的 `///` **分工不同**——`///` 讲的是**该类型自己的契约、用法与坑**。
  - 别把文件说明在类型的 `///` 里复述一遍；纯复述的 `///` 应删掉（`VersionCommand` / `TranslationPanel` / `Daemon` 等都清过一轮）。
  - `///` 是**声明文档**：写在声明上、**紧贴**；与声明隔空行会被 Xcode 关联到下面那个声明（`Logger.swift` 踩过：文件说明变成了 `maxLogSize` 的文档）。
  - 文件说明别写成 `// MARK: -` 分区标记——那是代码分区用的，不是文件职责（有 13 个文件踩过）。
- 非 Swift 文件同样要有文件头说明，注释符按各语言惯例（shell `#`、JS/TS `//`）。
- 标点不强制统一，**但同一文件内保持一致**；不为了统一标点去翻改老代码。

## 已知问题

### Swift 6.4 快照版编译器崩溃（已修复）
见上面的「编译」节（用的是 `swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-06-15-a`，崩溃在该版本已修复）；
复盘见 `docs/archive/incident-swift-compiler-crash.md`。

### 代码签名与 TCC 权限（已根治）
macOS 的 TCC（麦克风/辅助功能/输入监控）认的是**签名要求**。ad-hoc 签名（`codesign -s -`）的
要求里含 **cdhash**（= 二进制内容哈希）→ 每次重编译内容就变、要求就变 → 旧授权自动作废，
于是每次部署都得手动重新勾一遍权限。

**现在用自签的长期身份**（`CN=iVox Local Signing`，10 年有效、不会被 Apple 吊销），
它的 designated requirement 只含**证书指纹**（`dabf80f8…`）→ 换多少次版本权限都不掉。
2026-10-21 实测：重编译 + 重新签（同一张证书）后，六项能力与三项权限全绿，一次没掉。

- 签名身份的选择顺序（`scripts/runtime.sh` 的 `sign_bin`）：
  `IVOX_SIGN_IDENTITY` > 自签的 `iVox Local Signing` > 钥匙串里第一个有效证书 > ad-hoc。
- 证书与私钥备份在 `~/.config/ivox/signing/`（钥匙串重置后按那里的 README 恢复；
  恢复后指纹仍是同一张 → **权限不用重勾**）。
- 将来若要把 iVox **分发给别人**（Gatekeeper / 公证），得换 Developer ID 证书——
  那时签名身份变了，权限会掉一次。

### 安装网络层问题（HTTP/2 截断 + Metal Toolchain）
git smart 协议（POST `git-upload-pack`）在国内偶发 HTTP/2 截断，HuggingFace 也常 SSL 握手失败。已实现兜底：模型下载三级 fallback（HF → hf-mirror → ModelScope），mlx 子模块 tarball 预填（`scripts/fetch-mlx-submodules.sh`），SwiftPM `--skip-update`。首次安装还需 `xcodebuild -downloadComponent MetalToolchain`（~838MB）。详见 `docs/archive/guide-install-network.md`。

## 部署

```bash
make update       # 编译 → 签名 → 复制到 ~/.local/bin/ivox → 重启守护进程
                  # 任何一步失败/被中断都会自动回滚到上一版并把服务拉回来
```

The binary at `~/.local/bin/ivox` is what hook scripts and `ivox on/off` invoke. Project dir can be deleted after deploy.

`~/.local/bin/ivox` 是 hook 脚本调用的二进制，由 `ivox on/off` 控制启停（LaunchAgent 托管）。部署后项目目录可删除。

## 测试

```bash
make test                          # 自动使用 xcrun --toolchain swift-latest（推荐，别先 make build）
# 跑单个文件 / 单个用例：
xcrun --toolchain swift-latest swift test --filter TextCleanerTests
xcrun --toolchain swift-latest swift test --filter TextCleanerTests/testColonLeadInGetsNoPseudoPeriod
```

测试仅覆盖 `iVoxKit`（无 MLX 依赖，快），位于 `Tests/iVoxTests/`：TextCleaner / TextSplitter / StreamBuffer / StreamFrame / AudioPipeline / Config / Translation / **PlaybackSessionStory**（第 9 个，测摞的分段与墓碑归属）。主程序 iVox（含 MLX/Audio actor）无单测，靠真实 daemon + `ivox speak` / pi 实测验证。

```bash
make check-tts                      # 播报黑盒自检：压真实 daemon，21 个用例（需先 ivox on，模型就绪）
make check-tts ARGS="-f tail"       # 只跑匹配用例；--strict 让 advisory 计入失败；--managed 自行重启守护进程
touch /tmp/ivox-hook-muted          # ⚠️ 跑之前先落静音闸，见下
trash /tmp/ivox-hook-muted          # 跑完提起
```

`scripts/tts-check.mjs`（零依赖 Node，仅用 `node:` 内置模块）经 Unix socket 发流式帧、`GET /health` 探运行态、增量 tail `daemon.log` 断言：协议正确性、合成时长、轮次隔离、取消丢弃迟到帧、EOF 残尾、并行取消不拖垮在跑的轮（pi 复现）、停止哨兵作废在跑的轮、多轮交错时队首轮等块不得空转（`E8`）、密集打断压测、打断后活性、尾音完整（`needsAudio`，无设备自动 skip）。断言要数「队列状态」等 DEBUG 行，而 daemon 默认只留 INFO 及以上（`Logger` 的级别门限），所以脚本自己 `launchctl setenv IVOX_LOG_LEVEL=debug` + `kickstart` 重启 daemon，跑完 unset 环境变量——**这是它跟普通 `ivox on` 唯一的区别，别把它改回附加到已在跑的 daemon**（2026-10-17：日志门限一落地，`E3`/`A-tail` 两条靠 DEBUG 行吃饭的断言直接假红）。**它是排障工具，不是每次改动都要跑的回归**：日常改动用 `make test` + 单点验证（临时脚本压真实 socket、看 `daemon.log`）；只有正常播报出问题（没声音/卡住/串音/未收尾）时才用它定位。**但改播报队列核心（`PlaybackQueue` / `ConnectionHandler` 的收尾·打断·入队）时必须跑一次全量**——2026-10-16 踩过：三个用例悄悄腐烂成假绿（两条正则与日志格式失配、一条断言过严、一条被自检自己的噪声检测抓成 skip），全靠一次全量才暴露；修完全量 13/13。**2026-10-19 拆成三进程后又跑全量：19 pass / 0 fail / 1 advisory**；
2026-10-20 审计补两条用例（`F-pcm-duration`、`S3-skip-stack-plain-stacks-are-separate`），同日补
`R1`（誊清员崩了 → 该块作废 / 队列继续 / 监督者重拉，v6.0.0 的招牌能力，此前只有一次手工验收撑着），
现共 **21 条**。
**手动起的 daemon 必须以 `IVOX_LOG_LEVEL=debug` 起**，否则脚本切不动它的日志级别——它认得出
DEBUG 不可见，会把靠 DEBUG 行吃饭的 `E3`/`A-tail` 降级为 skip 并写明原因（2026-10-20 加这道保护：
原先只打一行警告就往下跑，那两条直接假红，报「入队块数(0)」这种看着像产品坏了的数）。
唯一那条 advisory 是 `B-synthesis-leads-playback`（合成领先播放 3.7s ≈ 4s 高水位）——跨进程后
预取余量变薄的已知代价，**不是回归，别去"修"**。

**跑之前必须落静音闸**：`touch /tmp/ivox-hook-muted`（跑完 `trash` 提起）。自检压的是真实 daemon，而**真人对话的播报走同一个队列**——你一边跟我聊，队列就被我的回复占满，用例要么被噪声检测 skip，要么因合成被挤成欠载而假红。2026-10-17 实测：有对话 `pass=14 fail=1 skip=4`，落闸后 `pass=19 fail=0 skip=0`。这个闸在 `scripts/hook.sh` 里，走**哨兵文件而不是环境变量**：hook 由 Claude Code 的 harness 拉起，环境在它启动时定死，改不动；文件每次执行都重新判断。闸在手上可见（`ls /tmp/ivox-hook-muted`），不怕忘。

## 版本号

```bash
make version V=v1.2.0    # 更新 Version.swift, 提交并打 tag
```

版本号定义在 `Sources/iVox/Version.swift`。

## 发布流程

每次发版前检查：

```bash
# 1. 确认所有改动已 commit
git status

# 2. 打包二进制 + 自包含集成资产（产物在 .build/release/）
make package

# 3. 打版本 tag（自动 commit + tag）
make version V=vX.X.X

# 4. 更新 docs/CHANGELOG.md（填入本版改动）

# 5. 提交 CHANGELOG + push
git add -A && git commit -m "docs: 更新 CHANGELOG vX.X.X" && git push origin main --tags

# 6. 创建 GitHub Release + 上传二进制
gh release create vX.X.X --title "iVox vX.X.X" --notes "..."
gh release upload vX.X.X .build/release/ivox-vX.X.X-macos-arm64.tar.gz --clobber

# 7. 更新 release notes（如有修正）
gh release edit vX.X.X --notes "..."
```

注意

- `install-binary.sh` 期望 `.tar.gz` 格式，不是 `.zip`
- push 后 CI 不做任何事，二进制需手动上传到 Release
