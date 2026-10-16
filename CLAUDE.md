# CLAUDE.md

为 Claude Code 提供代码协作指导。

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

  ── 六个能力域（目录与 README 功能表、ivox status 一一对应）──
  Playback/            — 自动播报：TTSEngine（mlx-audio-swift 流式合成）+ PlaybackQueue + AudioPlayer
  SpeechInput/         — 语音输入：右⌘/右⌃ 录音 + ASR + 浮窗（事件由 HotKey 层送来）
  Translation/         — 划词翻译（Cmd+D）：复制 → 翻译 → 浮窗 + 朗读
  QuickActions/        — 快速操作：Finder/终端快捷（Opt+Z/A/Q/X/C）
  WeChat/              — 微信桥接：ilink HTTP 客户端 + 长轮询平台
  MediaControl/        — 媒体控制：Web 控制台（MediaHTTPServer + Web UI）+ MediaController

  ── 基础设施（跨能力域）──
  HotKey/              — GlobalKeyTap：键盘事件层（独占 tap，按归属路由给上面几家）
  Network/             — SocketServer（Unix domain socket IPC）
  Daemon/Daemon.swift  — actor-based daemon: init → run → cleanup loop；装配与热键分派
  Commands/            — ServeCommand, SpeakCommand, TranslateCommand 等
  Utilities/           — Version, 日志工具
  Resources/           — assets, 默认音色, Info.plist, 配置模板（编进二进制 bundle）

Sources/iVoxKit/       — 共享库（无 MLX 依赖）
  Config.swift         — JSON 配置模型
  Logger.swift         — Log.{info,debug,warn,error}
  DaemonStatus.swift   — {type:status} 的返回体（六个能力域健康度）
  SocketClient.swift   — AppPaths + socket 客户端
  TextCleaner.swift    — Markdown + 噪音过滤（给 TTS 用）
  TextSplitter.swift   — 流式文本分块
  StreamBuffer.swift   — 流式 turn 的安全边界切分
  StreamFrame.swift    — 长度帧协议
  AudioPipeline.swift  — 重采样
  Translation/         — 翻译服务（Google 双通道容灾 + OpenAI 兼容）、配置模型、选区清洗
  WindowPlacement.swift— 浮窗锚定几何（纯函数，含副屏坐标修正）

Tests/iVoxTests/       — 测试（仅依赖 iVoxKit）

integrations/          — 各外部 agent 的对接适配层（安装时由脚本 cp，不编进二进制）
  hook.sh              — 通用播报 hook（claude/codex 共用）
  pi/ivox.ts           — pi coding agent 流式扩展

docs/                  — architecture.md, socket-api.md, hook-chain.md, playback-queue.md, CHANGELOG.md；archive/ 放历史复盘与调研
scripts/               — runtime.sh, download-models.sh, install-*.sh（构建/安装工具脚本）
```

## 架构

基于守护进程的 actor 架构（LaunchAgent 托管，`ivox autostart on/off` 控制启停）：

```
Claude Code/Codex → hook.sh               ┐
pi 扩展(integrations/pi, text_delta 流式)  ├→ Unix Socket → Daemon ─┬─ PlaybackQueue (actor)
微信 ilink 长轮询                          ┘                       │   ├─ TTSEngine (mlx-audio-swift)
                                                                   │   └─ AudioPlayer (AVAudioEngine)
                                                                   ├─ GlobalKeyTap (键盘事件层，一个 tap)
                                                                   │    ├─ SpeechInputService (右⌘/右⌃ + ASR)
                                                                   │    ├─ TranslationService (Cmd+D 划词翻译)
                                                                   │    └─ QuickActionsService (Opt+Z/A/Q/X/C)
                                                                   └─ MediaHTTPServer (端口 8888, Web UI)
```

关键模式：
- **Swift 6 严格并发**：所有服务都是 `actor` 类型。跨 actor 调用使用 `await`。`@Sendable` 闭包必须捕获值拷贝的 `let` 绑定（不能是 actor 上下文中的 `var`）。
- **Daemon 生命周期**：`init` 加载配置 → `run()` 并行启动所有服务 → `cleanup()` 处理 SIGINT/SIGTERM 退出。
- **微信长轮询**：`GetUpdatesResp.ret` 是 `Int?`（API 在空响应时省略 `ret`）。手动用 `withThrowingTaskGroup` 让 URL 请求和 `Task.sleep` 超时竞速（URLSession idle timeout 在长轮询 TCP keep-alive 下不会触发）。
- **TTS 两层流水线**：
  - *第一层（切句/清洗，真源只在 Swift 一份）*：文本先 `cleanText`（Markdown AST 去噪 + URL/路径/ANSI/emoji 处理）再 `splitSentences`（句末边界 `。！？!?…；;\n`，合并到 ≤80 字；英文 `.` 不切以保小数/缩写）。TS 扩展和 hook **绝不在客户端切句**（会破坏 AST 块末补句号与跨行规则）。
  - *第二层（连续播放管道）*：`PlaybackQueue.processNext` 是跨所有 job 的循环，逐句 `synthesizeStream → player.write`，**句间不 drain**；`AudioPlayer` 用单个常驻 `AVAudioPlayerNode` 连续 `scheduleBuffer`，4s/2s 高低水位背压（`pendingFrames` 随 `dataConsumed` 核减），prime 静音仅在设备播空/取消后补一次，`drain()` 只在整轮末端调一次。改这里务必读 `docs/playback-queue.md`，不要重新引入逐句 drain（会导致逐字卡顿）。
- **流式 turn 协议**：pi 扩展经一条长连接按 `\n` 分帧：首帧 `{type:stream,source,turn}` → 原文增量帧（仅 text_delta）→ `{end}`/`{cancel}`，EOF=end。服务端 `StreamBuffer`（iVoxKit 纯逻辑）累积原文，只在安全边界（句末/段落、代码围栏配平、≥`minFlushChars`=24）抽出整段复用同一套 cleanText→splitSentences。`PlaybackJob.turnID`：**队列按轮分桶排队，播全播完**——同一 `turnID` 分块并入同桶顺序追加，新 turn 在队尾追加新桶、**不打断**在播旧轮（桶播完才前移）；无 turn 的普通播报（`ivox speak`/hook.sh）同上排队。**打断权只归用户快捷键**，手动打断分三档：**轻** = Ctrl+2 跳当前句（`skipCurrentSentence`：只丢正在播的这句，同轮剩下的照念）、**中** = Ctrl+1 跳整轮（`skipCurrentBucket`：丢当前桶，下一桶接着播）、**掀桌** = Ctrl+Esc 清楚（`cancelAll` 全场清）/ 右⌘ 说话。Cmd+D 译文是**插队**——`speakUserInitiated` 只掐在播、译文桶插到队首，其余桶全保留（播完译文接着播）。`{type:stop}` 停止帧与流式新轮**不再打断**（ConnectionHandler 对 stop 帧仅记日志忽略）。某桶 `ended` 才允许空桶前移；流动中空桶保活等下一批。连接内这四类操作经 `ConnectionHandler.StreamOpChain` **按帧序执行**（乱序会让 `{end}` 之后到达的同轮分块把已关轮次重新打开、管道永久挂起）。详见 `docs/socket-api.md`。
- **播报通路（hook / 微信 / MessageDisplay）**：①Claude Code 交互会话的播报**只靠 `MessageDisplay` 钩子**（`hook.sh msgdisplay claude`）——assistant 消息按行批增量播报，过程内容（分步/工具多段）逐句进桶、边写边播，**不再挂 Stop / UserPromptSubmit**（摘 Stop 因 MessageDisplay 的 final 批已含完整结尾，两者同播会重复；摘 UserPromptSubmit 因打断权只归快捷键）。`hook.sh` 已**移除 interrupt 分支**（`ivox quiet` 手动能力保留，只是不经 hook.sh 自动触发）。②微信链路（`ClaudeAskService` spawn claude 读 stream-json）**只用 assistant 帧**——最后一条 assistant 即完整结尾，不单独取 result（内容重复），无去重逻辑。③pi 走流式（见下）。

- **键盘热键分层**：`HotKey/GlobalKeyTap` 独占 CGEvent tap 与专用 run loop，**只按事件类型 / keyCode 路由**，不含业务判断——tap 回调跑在专用线程上且监听**全系统**键盘，回调里任何耗时都会拖慢整机输入，所以一律 offload。消费者：右⌘/右⌃ → `SpeechInputService`，`Cmd+D` → `TranslationService`，`Opt+Z/A/Q/X/C` → `QuickActionsService`，`Ctrl+Esc`/`Ctrl+1`/`Ctrl+2` → `PlaybackQueue`（手动打断三档：掀桌 / 跳整轮 / 跳这句）（由 `Daemon.setUpHotKeys()` 按能力归属分派，不把逻辑揉在一起）。热键只精确匹配（四个标准修饰位全等，Cmd+Shift+D 之类的变体不误触），其余按键一律透传；`keyUp` 也一律透传（按 keyCode 宽松匹配会吞掉「单独按 D」的抬起、干扰打字）。**要加新热键：在 `GlobalKeyTap.bindings` 加一条 + 在 `setUpHotKeys` 加一个消费者。** 注意普通键（keyDown）需要「输入监控」权限，只授辅助功能时表现为"修饰键正常、Cmd+D 毫无反应"。

- **配置**：`~/.config/ivox/config.json`，所有运行时文件在 `~/.config/ivox/` 下。

- **日志**：`~/.config/ivox/daemon.log`（nohup 的 stdout/stderr）。使用 `Log.{info,debug,warn,error}`。

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
此问题已在 `swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-06-15-a` 中修复。详见 `docs/archive/incident-swift-compiler-crash.md`。

### 代码签名变更导致 TCC 权限失效
Ad-hoc 签名每次构建都会变化 → TCC 权限（麦克风、辅助功能）丢失。`deploy-bin`（`make update`）会自动重新签名。部署后如权限丢失，需在系统设置中重新勾选。

### 安装网络层问题（HTTP/2 截断 + Metal Toolchain）
git smart 协议（POST `git-upload-pack`）在国内偶发 HTTP/2 截断，HuggingFace 也常 SSL 握手失败。已实现兜底：模型下载三级 fallback（HF → hf-mirror → ModelScope），mlx 子模块 tarball 预填（`scripts/fetch-mlx-submodules.sh`），SwiftPM `--skip-update`。首次安装还需 `xcodebuild -downloadComponent MetalToolchain`（~838MB）。详见 `docs/archive/guide-install-network.md`。

## 部署

```bash
make update       # 编译 → 签名 → 复制到 ~/.local/bin/ivox → 重启守护进程
```

The binary at `~/.local/bin/ivox` is what hook scripts and `ivox autostart on/off` invoke. Project dir can be deleted after deploy.

`~/.local/bin/ivox` 是 hook 脚本调用的二进制，由 `ivox autostart on/off` 控制启停（LaunchAgent 托管）。部署后项目目录可删除。

## 测试

```bash
make test                          # 自动使用 xcrun --toolchain swift-latest（推荐，别先 make build）
# 跑单个文件 / 单个用例：
xcrun --toolchain swift-latest swift test --filter TextCleanerTests
xcrun --toolchain swift-latest swift test --filter TextCleanerTests/testColonLeadInGetsNoPseudoPeriod
```

测试仅覆盖 `iVoxKit`（无 MLX 依赖，快），位于 `Tests/iVoxTests/`：TextCleaner / TextSplitter / StreamBuffer / StreamFrame / AudioPipeline / Config。主程序 iVox（含 MLX/Audio actor）无单测，靠真实 daemon + `ivox speak` / pi 实测验证。

```bash
make check-tts                      # 播报黑盒自检：压真实 daemon，13 个用例（需先 ivox autostart on，模型就绪）
make check-tts ARGS="-f tail"       # 只跑匹配用例；--strict 让 advisory 计入失败；--managed 自行重启守护进程
```

`scripts/tts-check.mjs`（零依赖 Node，仅用 `node:` 内置模块）经 Unix socket 发流式帧、`GET /health` 探运行态、增量 tail `daemon.log` 断言：协议正确性、合成时长、轮次隔离、取消丢弃迟到帧、EOF 残尾、并行取消不拖垮在跑的轮（pi 复现）、停止哨兵作废在跑的轮、多轮交错时队首轮等块不得空转（`E8`）、密集打断压测、打断后活性、尾音完整（`needsAudio`，无设备自动 skip）。**它是排障工具，不是每次改动都要跑的回归**：日常改动用 `make test` + 单点验证（临时脚本压真实 socket、看 `daemon.log`）；只有正常播报出问题（没声音/卡住/串音/未收尾）时才用它定位。

## 版本号

```bash
make version V=v1.2.0    # 更新 Version.swift, 提交并打 tag
```

版本号定义在 `Sources/iVox/Utilities/Version.swift`。

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
