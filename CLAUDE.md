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
  Playback/            — 自动播报：PlaybackQueue + PlaybackSession + InterruptOrigin（**打断归因**：档位 × 入口，日志里说得清谁按的什么键）+ AudioPlayer + CaptionPanel（**歌词式字幕**：把「这一页的句子 + 念到第几句」交给浮窗，逐字高亮自己算）
    TTS/               — 合成层：TTSProviding（契约）+ TSPRemote（默认，跨进程）+ TTSServer/TTSEngine（誊清员子进程）+ TTSTrace
  SpeechInput/         — 语音输入：右⌘ 录音 + ASR + 浮窗（事件由 HotKey 层送来）+ ClaudeAskService（ASR 出文后送问 Claude）
  Translation/         — 划词翻译（Opt+Z）：复制 → 翻译 → 交给浮窗服务两行（原文 + 译文）+ 朗读
  QuickActions/        — 快速操作：Finder/终端快捷（Opt+Q/A/X/S/C）
  WeChat/              — 微信桥接：ilink HTTP 客户端 + 长轮询平台
  MediaControl/        — 媒体控制：Web 控制台（MediaHTTPServer + Web UI + HTTPResponseHandler）+ MediaController + AudioAppRegistry + HealthSnapshot + SodaVolumeDucker（iVox 占用注意力时给汽水音乐压音量）
  Screen/              — 屏幕锁：ScreenControl（ivox lock / ivox unlock + Web 滑块，走 HID 真键）+ ScreenLock（**锁屏判据**：会话字典里的 `CGSSessionScreenIsLocked`，配轮询监视器）

  ── 基础设施（跨能力域）──
  Overlay/             — 屏幕上那块 iVox 浮窗：**OverlayService 是公共服务**——一块载体（不是上下两个框）、排版、落点、选屏、去重（同一句话只显示一遍）、消失、以及背景音乐让路全归它；使用方只说「显示哪几行字」（行里还能带一段**高亮区间**：卡拉OK式）。`[overlay]` 段管钉屏与间距
                       — **锁屏时浮层停摆**（`Screen/ScreenLock` 是判据唯一真源，轮询 1 秒一次——系统在这件事上**不发任何通知**，实测 2026-11-06）：停摆期间内容照记、只是不摆上屏，解锁后一次重画还原。停摆优先于一切对齐判据（系统在锁屏期间会把窗口改回可见，那时「内容还在」是常态，按常理该摆正——但屏上没人看，摆正就是浮在锁屏界面上）
                       — **屏上其实有两块浮层**：字幕+译文共用 OverlayService 这一块载体；**录音胶囊是另一块**（`SpeechInput/OverlayPanel`，SwiftUI 胶囊，未并入）。两块**共用选屏规则**（`Overlay/OverlayScreen`：钉了 UUID 就钉那块，没钉跟鼠标），且胶囊**贴顶**、字幕**贴底**——同一块屏上两块浮层不打架
  HotKey/              — 键盘事件层：GlobalKeyTap（**收**键：独占 tap，按归属路由给上面几家）+ HidInjector（**发**键：往常驻 ESP32-S3 注入器发真硬件事件，串行队列）
  Network/             — SocketServer（Unix domain socket IPC）+ ConnectionHandler（帧解析与分派）
  Daemon/Daemon.swift  — actor-based daemon: init → run → cleanup loop；装配与热键分派
  Commands/            — ServeCommand, SpeakCommand, TranslateCommand 等
  Version.swift        — 版本号常量（唯一真源，make version 写它）
  Resources/           — assets, 默认音色, Info.plist, 配置模板（编进二进制 bundle）

Sources/iVoxKit/       — 共享库（无 MLX 依赖）
  Config.swift         — 配置模型（外部配置现为 TOML，见 TOML.swift；键名一律驼峰）+ 内置音色 VoiceCatalog（代码内配置）
  ConfigAudit.swift    — 配置键名审计：报出「写了但没人认领」的键（已知键由各类型 CodingKeys 派生）
  ConfigTemplate.swift — 默认配置模板（唯一真源，`ivox init-config` 写的就是它）
  TOML.swift           — 自研 TOML 解析（无外部依赖）
  TOMLDocument.swift   — TOML 就地改（保留用户自己的注释）
  HotKeySpec.swift     — 热键动作与默认键位（默认键位唯一真源）
  InstanceLock.swift   — 实例独占锁（一个 socket 只允许一个 daemon）
  PlaybackStore.swift  — 队列落盘（SQLite，两张表：pages + sentences，存还没播出去的页与句）
  SocketStream.swift   — socket 流式读写与时间纪律（读超时是每趟 read 的上限）
  Logger.swift         — Log.{info,debug,warn,error}
  DaemonStatus.swift   — {type:status} 的返回体（七个能力域健康度）
  SocketClient.swift   — AppPaths + socket 客户端
  TextCleaner.swift    — Markdown + 噪音过滤（给 TTS 用）
  TextSplitter.swift   — 切句（合成单位，≤80 字）
  StreamFrame.swift    — 长度帧协议
  AudioPipeline.swift  — 重采样
  Translation/         — 翻译服务（Google 双通道容灾 + OpenAI 兼容）、配置模型、选区清洗

Tests/iVoxTests/       — 测试（21 个文件：多数只依赖 iVoxKit；PlaybackSessionStoryTests、OverlayServiceTests、TSPRemoteSlowSynthesisTests 等 6 个 @testable import iVox；TestSocketServer 是共用假 socket server）

docs/                  — README.md（索引 + 分类规则）· architecture.md · hook-chain.md · socket-api.md · native-bridge.md（微信链路实测依据）；playback/ 放播报四层：paper.md（比喻，**建立直觉但不裁决**）· purpose.md（取舍，**有分歧听它**）· sources.md（接入方）· requirements.md（需求）· queue.md（实现 + 维护约束）；CHANGELOG.md；archive/ 放历史复盘与调研（未裁决的提案一旦落地就挪进来，如 `proposal-drop-stop.md`）
scripts/               — 装机与部署：runtime.sh（部署）· download-models.sh · fetch-mlx-submodules.sh · install-*.sh · tts-check.mjs（黑盒自检）· hotkey.py（用 ESP32 真键盘按热键，测热键用）
                        接入资产（各外部 agent 的对接层，安装时由 install-hooks.sh cp，不编进二进制）：
                        · hook.sh（Claude Code 的播报 hook：**`hook.sh <source>`，不带动作名**——按 message_id 攒成整页送一次；收尾信号整条删除）
                        · pi/ivox.ts（pi coding agent 扩展：每页调一次 ivox speak）
```

## 架构

> 本节只留**地图**（谁在哪儿、关键模式是什么），细节一律推给 `docs/`——`architecture.md`（整体架构）、`hook-chain.md`（钩子链路）、`playback/`（播报四层）。地图与细节分开维护，否则两份会各自漂移。

基于守护进程的 actor 架构（LaunchAgent 托管，`ivox on/off` 控制启停、`ivox restart` 只重启进程）：

```
Claude Code → hook.sh                   ┐
pi 扩展(scripts/pi, 每页一次 speak)  ├→ Unix Socket → Daemon ─┬─ PlaybackQueue (actor)
微信 ilink 长轮询 → WeChatPlatform（**只发消息**，回复本身不播；⚠️ 但它 spawn 的 claude
  **照样触发上面那套 hook**（hook 配在 user 级 settings.json，谁启动 claude 都吃）——
  微信回复会不会在本机念，由 `[wechat] speak` 决定，默认 false＝不念）
                                           │   ├─ TSPRemote ─→ 誊清员子进程 `ivox tts --serve`（mlx-audio-swift）
                                                                   │   └─ AudioPlayer (AVAudioEngine)
                                                                   │        └─ OverlayService (浮窗公共服务：一块载体)
                                                                   │             ├─ CaptionPanel (字幕行，可选)
                                                                   │             └─ TranslationPanel (译文行)
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
- **队列 = 页的 FIFO**（2026-11-02 改，唯一真源）：**页** = 一条 assistant 消息 = 队列里唯一的单位；
  页里装**句**（1~80 字的合成单位，纯实现细节，用户不感知）。页按**到达顺序**排，先来先进，谁都不插队。
  **整套「摞」的概念没了**：一次输入引发的全部回复不再成组；`turn_id`/`session_id` **不进队列、不落库**，
  只在日志里出现；**没有墓碑**（用户放弃之后不再拦后续内容，迟到的内容照播）；
  **没有收尾信号**（端不再报「说完了」——`Stop` 钩子整条摘掉，`hook.sh` 不再有 `end` 分支）——
  **队列排空即收尾**（等设备静了 → 字幕收起、汽水音量还回）。原「空闲宽限」配置项
  `idleGraceSeconds` 随收尾信号一起删了（配置审计会点名它）。
- **打断只有两档**（2026-11-02，原三档）：**掐** = 断在播的那一句，**掀** = 丢弃某一层的全部内容：
  **Ctrl+1 = 掀页**（`skipCurrentPage`：掐掉在播的那一句 + 丢掉用户此刻正在听的那一页的剩余内容，
  从下一页接着念）、**Ctrl+2 = 全掀**（`cancelAll`：取消在播 + 清空全部排队内容，**不留墓碑**——
  这一下之后再来的内容照播）。原 Ctrl+2 掀摞、Ctrl+3 全掀的位置空出来了，**Ctrl+3 现在没有绑定**。
  右⌘ 说话是**暂停不删**（设备闭嘴让麦克风干净，队列与内容一概不动，说完接着播——「你停一下」，
  不是「你别说了」）。Opt+Z 译文**不进队列**：主节点只是**暂停**（缓冲原样留着，和右⌘说话一个语义），
  译文从**独立播放节点**出声，念完主节点从原处接着播。
  **打断权只归用户快捷键**：机器最多「借道」——队列的长期顺序只由到达顺序决定，谁都不永久插队。
- **播报的词只用这两个**，其它说法一律作废；完整术语表见 `docs/playback/requirements.md`）：
  **页** = 一条 assistant 消息（= 队列里唯一的单位；身份是助理自编的 `PlaybackPage.localID`，
  外部 `message_id` / `turn_id` 只作日志备注）；
  **句** = 目标 1～80 字的合成单位（无标点的长串会硬切，最多 160）（**服务拿去播报用的，不是给用户看的**；
  `PlaybackSentence.seq`，全局单调，两侧日志都打它）。
  读法：捏着队首那一页 → 撕下一个句去合成播放 → 这页撕完翻下一页 → 队列空了就收桌。
  按键对应（两档都是掐 + 掀）：**Ctrl+1 = 掀页**、**Ctrl+2 = 全掀**。
  ~~"assistant"~~（一会儿指回复、一会儿指会话）、~~"一叠 = 一轮、一张 = 一句"~~、~~"跳这句"~~、
  ~~"摞"~~（2026-11-02 作废）、~~"块"~~（现在叫**句**）都已作废。

- **来源与音色是客户端的事，服务端不管（2026-11-02）**：客户端说清「谁在说话」「用哪个音色」，
  **服务端照单念——不猜、不管、不拒**（`voice` 缺了就走默认音色，`source` 缺了就按 `default` 记）。
  猜错的后果是**整页用错音色念出来**，而现场没人发现，所以这个选择权归客户端。
  `ivox speak` 的 `--source` **必填**（缺了在命令行就报错，请求根本发不出去）；
  `--voice` **可省**（省了走默认音色）——这道检查在客户端，正好符合「各端做好各端的事」。
  **音色的真源仍是 `config.toml` 的 `[playback.sourceVoices]`**，只是**读它的人从守护进程换成了客户端**：
  **配置表里放的是 iVox 项目自己的端（`hook.sh`、pi 扩展）的音色；每个端自己去表里拿自己那一份，
  传给 `ivox speak`**（该来源自己的键 → 取不到退回 `default` 键 → 都没有就不带 `--voice`）。
  别的项目自带配置的端（如 Samantha 读自己的 `Configuration.ivox.ttsVoice`）不归这张表管，
  也不必往这儿加。
  守护进程只留用这张表的 `default` 键（译文朗读兜底、`ivox voice list` 的「默认」标记）。
  ⚠️ 这意味着**改这张表要同时看两个客户端**（`scripts/hook.sh` 与 `scripts/pi/ivox.ts`），
  它们各自手写了一份 TOML 取值逻辑（不引第三方库）。
- **播报只有一个入口：`ivox speak`**（2026-11-02）：各端自己拼好命令
  （`ivox speak --source <来源> --voice <音色> -- "<正文>"`）再发出去，一次请求 = 队列里的一页。
  **将来接新的端，照这个模板来**：自己攒页 → 自己读 `config.toml` 的 `[playback.sourceVoices]`
  查音色 → 自己拼好上面这条命令调过去（查不到音色就不带 `--voice`，服务端会走默认音色）。
  **不要新开协议、不要新开 socket 协议分支**
  （曾经有第二条入口——pi 的流式连接——两条入口就是两套语义，各自在漂）。
  **服务端只管照单念**，不猜来源、不猜音色。三个接入方各自做好各自的事：
  ①**Claude Code**：`MessageDisplay` 钩子 → `hook.sh`（**只管 Claude 这一端**：按 `message_id`
  攒成整页 → 自己查音色 → 拼 `ivox speak --source claude --voice <音色>`）。
  **不再挂 Stop / UserPromptSubmit**：Stop 收尾信号整套作废（队列排空即收尾，不需要端报「说完了」）；
  UserPromptSubmit 因打断权只归快捷键。**收尾 = 队列排空**：等设备把尾音播完 → 收字幕、还汽水音量。
  手动打断走命令行 `ivox skip --page|--all` 两档（`ivox quiet` 已删除）。
  ②**微信：永不出声**——微信那个 claude 以 **`--bare`** 启动（跳过所有钩子，实测 hook 不再触发，
  模型与接口配置照旧），所以它的回复**压根不进播报队列**。聊天窗口里已经有文字了，再念一遍是打扰
  （见 `docs/playback/purpose.md` 的裁决）。**没有开关**：微信不播报是结构性的，不是配置出来的。
  ③**pi**：每页（一条 assistant 消息）调一次 `ivox speak --source pi --voice <音色>`。
  ⚠️ 代价：以前 pi 走流式连接能 `{cancel}` 撤掉这一轮的页，现在没有流也就撤不回来
  （已送出的页照念完；要立刻闭嘴用 `ivox skip --all`）。

- **键盘热键分层**：`HotKey/GlobalKeyTap` 独占 CGEvent tap 与专用 run loop，**只按事件类型 / keyCode 路由**，不含业务判断——tap 回调跑在专用线程上且监听**全系统**键盘，回调里任何耗时都会拖慢整机输入，所以一律 offload。消费者：右⌘（默认；配置可改成右⌃ 或两者）→ `SpeechInputService`，`Opt+Z` → `TranslationService`，`Opt+Q/A/X/S/C` → `QuickActionsService`，`Ctrl+2`/`Ctrl+1` → `PlaybackQueue`（手动打断两档：掐+全掀 / 掐+掀页）（由 `Daemon.setUpHotKeys()` 按能力归属分派，不把逻辑揉在一起）。热键只精确匹配（四个标准修饰位全等，Cmd+Shift+D 之类的变体不误触），其余按键一律透传；`keyUp` 也一律透传（按 keyCode 宽松匹配会吞掉「单独按 D」的抬起、干扰打字）。**要加新热键：在 `iVoxKit/HotKeySpec.swift` 的 `HotKeyAction` 加一个动作 + `defaultChord` 给默认键位 + 在 `setUpHotKeys` 加一个消费者**（`GlobalKeyTap` 里不再有键位表，它只消费）。**键位可在配置 `hotkeys` 段按动作名改**（TOML 写法 `translate = "opt+z"`；首次安装会写全量默认键位）；⚠️ 默认键位有**两份副本**：代码兜底 `HotKeySpec.defaultChord` 与模板 `iVoxKit/ConfigTemplate.swift`（安装脚本不再内嵌第三份，改默认要同步这两处）；配错时启动日志会写明（哪个动作、错在哪、退回哪个默认），生效的键位逐行打「热键: 动作 = 键位」。改完跑 `ivox restart`（只重启进程，不动登录自启开关）。 注意普通键（keyDown）需要「输入监控」权限，只授辅助功能时表现为"修饰键正常、Opt+Z 毫无反应"。
- **防误触也在 tap 层判，一处判完**：① **同键冷却，按键分档**——`Opt+Z` 0.2s（它靠后写胜出连按，冷却只挡连击）、两个打断键 0.3s（掀页全掀本就该能连按）、其余 1s；冷却中**仍然吃掉事件**只是不执行（漏给目标 app 更糟），走 `systemUptime`，只在 tap 线程读写。② **语音键（右⌘，默认只有它）有 150ms 长按阈值**——按下不足就松开判为误触，按下沿直接丢弃（很多 App 用右⌘，碰一下就打断播报+暂停音乐+开麦代价太大）。它**不套冷却**：按住说话是「按下起录、松开结束」，套冷却会把「说一句再说一句」的第二句吃掉。
- **右⌘ 语音：副作用发生在「真的在录」之后**——按下经阈值与授权检查后**先试录**，`record()` 成功了才 `pausePlayback`（**暂停播报输出**，不删内容：麦克风要干净，用户说的却是「你停一下」不是「你别说了」）→ `pause`（暂停音乐）→ 浮窗「聆听中…」+ Tink + 波形；松开右⌘再 `resumePlayback` 从原位接着播。**不做设备预检**：耳机类麦克风按需唤醒，预检「设备在不在」会误判、把本来能用的设备焊死；按下就试这一下、试活了算数。失败时播报不动、音乐不停，只在日志写清原因（**授权层与设备层分开报**：TCC 状态 vs CoreAudio 的默认输入设备名，`AVAudioSession` 是 iOS 独有的、macOS 走 CoreAudio）。失败路径的 recorder 进**隔离区**延迟 1 秒释放——`record()` 返回 false 时 audio queue 的回调线程已经起来了，立刻析构会 `objc_loadWeak` 野指针（2026-10-19 实测 SIGSEGV）。**全项目借还背景音乐只此一家**：只有说话时借（按下 pause、松开 resume）。**播报链路不改音乐的播放状态**——它做的是另一码事：汽水音乐压音量**只跟浮层走**（浮窗在屏上就降 5 格，浮窗一消失就恢复；不看「正在出声」——声音归声音、屏幕归屏幕）。改数值不切状态，所以不会抖；判据与时机归浮窗服务 `Overlay/OverlayService.swift`，按下去的动作在 `MediaControl/SodaVolumeDucker.swift`。

- **ASR 模型按需加载 + 空闲卸载**：权重 2.5G，不随 daemon 启动加载——第一次识别时才加载
  （实测约 1 秒），**空闲 10 分钟自动卸载**还内存（`ASREngine` 里的巡检任务）。按下语音键时
  **并行**起加载，录音本身不依赖模型 → **用户照样立刻能说话**（「可以说了」＝按下那声 Tink ＋
  浮窗「可以说了」，与模型无关）；模型没就绪时浮窗显示「加载模型…」，只影响文字出来的早晚
- **TTS 模型：只被「人主动关播报」释放，没有空闲卸载**（与 ASR 那套相反，ASR 是按需加载 +
  空闲 10 分钟自动卸载）：播报是 TTS 唯一的用途，播报关了模型就没有存在理由——几 G 显存
  凭什么白占。`ivox playback off` → `PlaybackQueue.setEnabled(false)` → `engine.releaseModel()`
  （远程引擎收掉誊清员子进程＝显存随它归还；进程内引擎丢引用 + `MLX.Memory.clearCache()`，
  **只置空引用不降 RSS**）；`playback.enabled` 本来就是 false 时**启动就不加载模型**。
  **释放的是内存不是能力**：之后真有合成请求（别的入口直连 `{type:tts}`）会按需加载回来。
  问状态**不会把模型请回来**——那就把刚还回去的显存又占上了（引擎内部一个 `wanted` 标志管这事）。
  `TTSProviding` 上的 `releaseModel()` / `resumeModel()` 是这条规则的唯一接口
- **ESP32 注入器的 token 路径**：仓改名过（esp32-hid-lab → esp32-lab），
  路径写死会让「压音量」全程静默失效。`HidInjector` 按**候选列表**找 token，
  `HID_TOKEN_FILE` 可覆盖，失败时报错**列出找过的路径**（别再只写死一个）
- **合成引擎有两个实现，装点在 `Daemon.init`**：`any TTSProviding` 默认是 `TSPRemote`（跨进程到
  誊清员 `ivox tts --serve`）；设环境变量 `IVOX_TTS=local` 退回进程内 `TTSEngine`，仅供调试期对照。
  **为什么默认远程**：MLX 的 Metal 命令编码器析构重复释放 GPU 命令队列 → SIGTRAP，上游未修、
  Swift 侧拿不到 encoder 引用，无从拦截，所以把它圈出去（裁决见 `docs/playback/purpose.md`）。
  `Daemon.cleanup` 会显式 `stopChild()`，不留孤儿（`kill -9` 主进程时它不会跟着死）。
  **合成流的三个时间纪律**（2026-10-24 修，细节见 `docs/playback/queue.md`）：① **读超时不是断流**——
  `EAGAIN` 继续等，判「断了」只有 EOF（原先沿用控制 socket 的 10 秒读超时，合成一慢就被当成
  断流 → 那一句整句丢弃，实测真对话里连丢 4 块）；② **引擎没就绪先等就绪**（请求撞上「模型正在
  加载」会被直接拒掉，那一句就白丢了）；③ **一帧都没送出时可重发一次**（已送出半截的不重发，
  否则会播成「前半截 + 从头再来一遍」）。时间口径集中在 `iVoxKit/SocketStream.swift`。

- **配置分三层**（2026-10-21 重新规划，飞哥裁决）：① **代码内配置**——都在 `iVoxKit/Config.swift` 里：
  `ModelPaths`（模型路径）、`TTSConfig.default`（合成参数）、`VoiceCatalog`（内置音色）、
  `MediaControlConfig.default`（Web 控制台开关与端口）；
  这些**不进用户配置**，外部再写会被审计点名（写了不生效）；② **外部配置**——
  `~/.config/ivox/config.toml`，**就这一个文件**，装凭据与用户会改的（开关/键位/端口/路径），
  **键名一律驼峰**（`wechat` 段早先是蛇形，2026-10-21 统一）；**`[playback]` 段现在只有两类东西**：
  `enabled`（播报总开关）与音色（`[playback.sourceVoices]` + `[[playback.voices]]`，2026-10-29 从
  顶层挪进来——音色只服务播报；老位置照读不失效，加载时自动搬家）。
  ⚠️ `[playback.sourceVoices]` 这张「来源→音色」表**由客户端读**（hook.sh 与 pi 扩展），
  守护进程不再拿它兜底——它只用 `default` 键（客户端查不到音色时走的就是这个）。⚠️ `idleGraceSeconds`
  已删（收尾信号整套作废，队列排空即收尾）——还写着它会被配置审计点名；③ **用户数据**——录音、微信
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
  `hook.log`（hook.sh 审计行，同样按 5M 阈值轮转成 `hook.log.old`）。靠 `IVOX_LOG_FILE` + `IVOX_ROLE` 分流。
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

### 队列落盘：daemon 挂了，排队的东西还在

**内存只是工作副本，真源在磁盘**：`~/.config/ivox/ivox-queue.db`（SQLite，系统自带
libsqlite3）。里面**只存还没播出去的东西**；daemon 起来时（**接单之前**）把它们重新排队。

**两张表**（2026-11-02 起，队列里只有页）：

| 表 | 列 | 一行是什么 |
|---|---|---|
| `pages` | `page INTEGER PRIMARY KEY`、`source TEXT`、`voice TEXT`、`text TEXT` | 一页：页号、来源（端）、音色、整页原文 |
| `sentences` | `seq INTEGER PRIMARY KEY`、`page INTEGER`、`text TEXT` | 一句：句号、所属页号、文本 |

**没有 turn_id / session_id 列**——它们只进日志。老库（一张 `blocks` 表，装的是旧的三层结构）
启动时改名 `blocks_legacy` 保留，不删也不读。

- 写点：入队（存那一页与它的每一句）、播完（删已交给合成的句，句见底时那一页也删）、
  被掀（掀页/全掀/撤页 → 删）
- 恢复出来的内容要**显式开管道**才有人念（`restorePersisted` 里补一次 `pumpOrSettle`）——
  管道是「入队」时起的，恢复不经过它
- 队列库路径**跟 socket 走**（`ivox-queue.db` / `ivox-debug-queue.db`），隔离实例各写各的
- 写盘失败只记警告，不挡播报

**为什么必须有**：`ivox on` / `make update` 走 `launchctl kickstart -k`，那是 **SIGKILL**
（旧 daemon 瞬间死、抓不到、atexit 也不跑）——**每次部署都会杀一次 daemon**。
队列只在内存里，就等于每次部署都丢一次排队。

### 实例独占锁：一个 socket 只允许一个 daemon

daemon 启动第一件事是抢 `~/.config/ivox/ivox.lock`（`InstanceLock`，flock），
**抢不到就自己退出**并说清「已有一个在跑（pid=…）」。

**为什么 socket 挡不住**：第二份 daemon 会 unlink 掉 socket 再 bind，先跑的那份还活着
（**还占着全局热键、麦克风**），却再也收不到命令——机器上看着「就一个 daemon」，实际是两个
（2026-10-26 实测：前台手起的一份 + launchd 托管的一份并存过）。锁加在**进程级**才拦得住。

调试要跑第二份时，**必须显式隔离**：

```bash
IVOX_SOCKET=/tmp/ivox-debug.sock IVOX_LOG_FILE=/tmp/ivox-debug.log ~/.local/bin/ivox serve
```

socket、锁、誊清员 socket 全部由主 socket 派生（`ivox-debug.sock` / `ivox-debug.lock` /
`ivox-debug-tts.sock`），各走各的。**隔离实例不装热键、不开语音输入、不起 Web 控制台**
——那三样都是全局资源（抢同一个右⌘、抢麦克风、抢 8888 端口），装上就是「两份并存」的老毛病。

⚠️ **macOS 的权限归属算在「谁启动它」名下，不由二进制自己决定**：从 Claude Code 或终端
手起的实例一律挂到启动者（`com.anthropic.claude-code`）名下 → **每起一次就弹一次权限框**
（2026-10-26 实测弹了十几次；launchd 托管那份直接放行，不弹）。隔离实例因为不装热键/
语音输入，**一项权限都不申请**，也就没有框。要测热键就测 launchd 托管那份。

`ivox status` 的「实例」段会报出 socket、锁、daemon pid——「是不是开重了」一条命令就有答案。

## 测试

```bash
make test                          # 自动使用 xcrun --toolchain swift-latest（推荐，别先 make build）
# 跑单个文件 / 单个用例：
xcrun --toolchain swift-latest swift test --filter TextCleanerTests
xcrun --toolchain swift-latest swift test --filter TextCleanerTests/testColonLeadInGetsNoPseudoPeriod
```

测试仅覆盖 `iVoxKit`（无 MLX 依赖，快），位于 `Tests/iVoxTests/`：TextCleaner / TextSplitter / StreamFrame / AudioPipeline / Config / Translation / **PlaybackSessionStory**（测页的分段与丢弃归属）/ **PlaybackStore**（落盘两张表）/ **OverlayService**（测浮窗落点几何与去重判据）/ **InterruptOrigin**（打断归因的措辞契约）。主程序 iVox（含 MLX/Audio actor）无单测，靠真实 daemon + `ivox speak` / pi 实测验证。

**测热键用 `scripts/hotkey.py`**（不是 osascript）：热键走 CGEvent tap，而**合成来源的键盘事件会被 app 丢弃**（汽水音乐就丢），
所以要真按就得出真键盘——ESP32 那块板子通过 USB 把自己枚举成 HID 键盘，按下去的是**真硬件事件**。
键位从 `~/.config/ivox/config.toml` 的 `[hotkeys]` 段读（用户改过的那份，脚本不另抄默认键位）：

```bash
/Users/admin/iCode/services/.venv/bin/python scripts/hotkey.py             # 列出所有热键：动作 → 键位
/Users/admin/iCode/services/.venv/bin/python scripts/hotkey.py skipAll    # 按下「全掀」那个键
```

按完看 `~/.config/ivox/daemon.log` 里的归因（`全掀·键盘 ctrl+2`）。
⚠️ 脚本**会真的按键**，测试时手别放键盘上，被按下的键会打到当前前台的 App。

```bash
make check-tts                      # 播报黑盒自检：压真实 daemon，20 个用例（需先 ivox on，模型就绪）
make check-tts ARGS="-f tail"       # 只跑匹配用例；--strict 让 advisory 计入失败；--managed 自行重启守护进程
```

`scripts/tts-check.mjs`（零依赖 Node，仅用 `node:` 内置模块）经 Unix socket 发**一次请求 = 一页**的
播报请求（与 `ivox speak` 同一个入口）、`GET /health` 探运行态、增量 tail `daemon.log` 断言：
一次请求只成一页（`N1`）、服务端不管来源与音色（`N2`）、合成时长、队列见底不得空转（`E8`）、
密集打断压测、打断后活性、尾音完整（`needsAudio`，无设备自动 skip）。断言要数「队列状态」等 DEBUG 行，而 daemon 默认只留 INFO 及以上（`Logger` 的级别门限），所以脚本自己 `launchctl setenv IVOX_LOG_LEVEL=debug` + `kickstart` 重启 daemon，跑完 unset 环境变量——**这是它跟普通 `ivox on` 唯一的区别，别把它改回附加到已在跑的 daemon**（2026-10-17：日志门限一落地，`E3`/`A-tail` 两条靠 DEBUG 行吃饭的断言直接假红）。**它是排障工具，不是每次改动都要跑的回归**：日常改动用 `make test` + 单点验证（临时脚本压真实 socket、看 `daemon.log`）；只有正常播报出问题（没声音/卡住/串音/未收尾）时才用它定位。**但改播报队列核心（`PlaybackQueue` / `ConnectionHandler` 的收尾·打断·入队）时必须跑一次全量**——2026-10-16 踩过：三个用例悄悄腐烂成假绿（两条正则与日志格式失配、一条断言过严、一条被自检自己的噪声检测抓成 skip），全靠一次全量才暴露；修完全量 13/13。**2026-10-19 拆成三进程后又跑全量：19 pass / 0 fail / 1 advisory**；
2026-10-20 审计补两条用例（`F-pcm-duration`、`S3-skip-stack-plain-stacks-are-separate`），同日补
`R1`（誊清员崩了 → 该块作废 / 队列继续 / 监督者重拉，v6.0.0 的招牌能力，此前只有一次手工验收撑着），
现共 **16 条**（`S3-skip-stack-*` 随「摞」一起删掉了；6 条流式用例随「唯一入口」一起删掉，
补了 `N1`/`N2` 两条盯新契约）。
**2026-11-02 队列改版后重跑全量：20 pass / 0 fail / 0 skip / 0 advisory**（用例按新协议重写，
旧断言一律不算数——它们会假绿）。**同日「唯一入口」改版后用例重写为 16 条，全量 16 pass / 0 fail / 0 skip / 0 advisory**。
**2026-11-03 补 `P4`（队列深时掀页 → 被掀页之后「已合成未出声」的页必须再合成一遍，
否则它们再也听不到），全量 17 条**。
**手动起的 daemon 必须以 `IVOX_LOG_LEVEL=debug` 起**，否则脚本切不动它的日志级别——它认得出
DEBUG 不可见，会把靠 DEBUG 行吃饭的 `E3`/`A-tail` 降级为 skip 并写明原因（2026-10-20 加这道保护：
原先只打一行警告就往下跑，那两条直接假红，报「入队块数(0)」这种看着像产品坏了的数）。
唯一那条 advisory 是 `B-synthesis-leads-playback`（合成领先播放 3.7s ≈ 4s 高水位）——跨进程后
预取余量变薄的已知代价，**不是回归，别去"修"**。

**静音闸由 `scripts/tts-check.sh` 自己落、自己收**（2026-10-25 改）：自检压的是真实 daemon，而**真人对话的播报走同一个队列**——你一边跟我聊，队列就被我的回复占满，用例要么被噪声检测 skip，要么因合成被挤成欠载而假红。2026-10-17 实测：有对话 `pass=14 fail=1 skip=4`，落闸后 `pass=19 fail=0 skip=0`。这个闸在 `scripts/hook.sh` 里，走**哨兵文件而不是环境变量**：hook 由 Claude Code 的 harness 拉起，环境在它启动时定死，改不动；文件每次执行都重新判断。
⚠️ **以前是人手动落、手动撤**（`touch` / `trash`），2026-10-25 漏撤过一次 → 闸一直挂着 → Claude 的播报全被挡在门外，表现为「没声也没字幕」。现在闸的落与收都在脚本里（`trap` 兜住失败与 Ctrl-C），**人不用管**；真要手动查：`ls /tmp/ivox-hook-muted`。

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
