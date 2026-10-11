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
  Commands/            — ServeCommand, SpeakCommand, WeChatCommand 等
  Daemon/Daemon.swift  — actor-based daemon: init → run → cleanup loop
  TTS/                 — TTSEngine（mlx-audio-swift 流式合成）
  Audio/               — AudioPlayer, PlaybackQueue, MediaController, MediaHTTPServer
  SpeechInput/         — macOS 语音识别，Cmd 键监听 via CGEvent
  WeChat/              — 微信 ilink HTTP 客户端 + 长轮询平台
  Network/             — SocketServer（Unix domain socket IPC）
  Utilities/           — Version, 日志工具
  Resources/          — assets, 默认音色, Info.plist, 配置模板（编进二进制 bundle）

Sources/iVoxKit/       — 共享库（无 MLX 依赖）
  Config.swift         — JSON 配置模型
  Logger.swift         — Log.{info,debug,warn,error}
  TextCleaner.swift    — Markdown + 噪音过滤（给 TTS 用）
  TextSplitter.swift   — 流式文本分块

Tests/iVoxTests/       — 测试（仅依赖 iVoxKit）

integrations/          — 各外部 agent 的对接适配层（安装时由脚本 cp，不编进二进制）
  hook.sh              — 通用 Stop hook（claude/codex/qwen/dsh 共用）
  pi/ivox.ts           — pi coding agent 流式扩展
  dsh/                 — DeepSeek Harness cordis 插件（ivox-tts.mjs + package.json）

docs/                  — architecture.md, socket-api.md, hook-chain.md, dsh-tts.md, playback-queue.md, CHANGELOG.md；archive/ 放历史复盘与调研
scripts/               — runtime.sh, download-models.sh, install-*.sh（构建/安装工具脚本）
```

## 架构

基于守护进程的 actor 架构（无 launchd，`ivox on/off` 手动管理）：

```
Claude Code/Codex/Qwen/DSH → hook.sh(Stop) ┐
pi 扩展(integrations/pi, text_delta 流式)  ├→ Unix Socket → Daemon ─┬─ PlaybackQueue (actor)
微信 ilink 长轮询                          ┘                       │   ├─ TTSEngine (mlx-audio-swift)
                                                                   │   └─ AudioPlayer (AVAudioEngine)
                                                                   ├─ SpeechInputService (Cmd 键 + ASR)
                                                                   └─ MediaHTTPServer (端口 8888, Web UI)
```

关键模式：
- **Swift 6 严格并发**：所有服务都是 `actor` 类型。跨 actor 调用使用 `await`。`@Sendable` 闭包必须捕获值拷贝的 `let` 绑定（不能是 actor 上下文中的 `var`）。
- **Daemon 生命周期**：`init` 加载配置 → `run()` 并行启动所有服务 → `cleanup()` 处理 SIGINT/SIGTERM 退出。
- **微信长轮询**：`GetUpdatesResp.ret` 是 `Int?`（API 在空响应时省略 `ret`）。手动用 `withThrowingTaskGroup` 让 URL 请求和 `Task.sleep` 超时竞速（URLSession idle timeout 在长轮询 TCP keep-alive 下不会触发）。
- **TTS 两层流水线**：
  - *第一层（切句/清洗，真源只在 Swift 一份）*：文本先 `cleanText`（Markdown AST 去噪 + URL/路径/ANSI/emoji 处理）再 `splitSentences`（句末边界 `。！？!?…；;\n`，合并到 ≤80 字；英文 `.` 不切以保小数/缩写）。TS 扩展和 hook **绝不在客户端切句**（会破坏 AST 块末补句号与跨行规则）。
  - *第二层（连续播放管道）*：`PlaybackQueue.processNext` 是跨所有 job 的循环，逐句 `synthesizeStream → player.write`，**句间不 drain**；`AudioPlayer` 用单个常驻 `AVAudioPlayerNode` 连续 `scheduleBuffer`，4s/2s 高低水位背压（`pendingFrames` 随 `dataConsumed` 核减），prime 静音仅在设备播空/取消后补一次，`drain()` 只在整轮末端调一次。改这里务必读 `docs/playback-queue.md`，不要重新引入逐句 drain（会导致逐字卡顿）。
- **流式 turn 协议**：pi 扩展经一条长连接按 `\n` 分帧：首帧 `{type:stream,source,turn}` → 原文增量帧（仅 text_delta）→ `{end}`/`{cancel}`，EOF=end。服务端 `StreamBuffer`（iVoxKit 纯逻辑）累积原文，只在安全边界（句末/段落、代码围栏配平、≥`minFlushChars`=24）抽出整段复用同一套 cleanText→splitSentences。`PlaybackJob.turnID`：新 turn/无 turn 普通 speak 打断旧轮（bargeIn），同 turn 顺序追加；`turnOpen` 时队列排空挂起 `waitForJobs` 等下一批、不恢复音乐。详见 `docs/socket-api.md`。

- **配置**：`~/.config/ivox/config.json`，所有运行时文件在 `~/.config/ivox/` 下。

- **日志**：`~/.config/ivox/daemon.log`（nohup 的 stdout/stderr）。使用 `Log.{info,debug,warn,error}`。

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

The binary at `~/.local/bin/ivox` is what hook scripts and `ivox on/off` invoke. Project dir can be deleted after deploy.

`~/.local/bin/ivox` 是 hook 脚本调用的二进制，由 `ivox on/off` 手动管理。部署后项目目录可删除。

## 测试

```bash
make test                          # 自动使用 xcrun --toolchain swift-latest（推荐，别先 make build）
# 跑单个文件 / 单个用例：
xcrun --toolchain swift-latest swift test --filter TextCleanerTests
xcrun --toolchain swift-latest swift test --filter TextCleanerTests/testColonLeadInGetsNoPseudoPeriod
```

测试仅覆盖 `iVoxKit`（无 MLX 依赖，快），位于 `Tests/iVoxTests/`：TextCleaner / TextSplitter / StreamBuffer / StreamFrame / AudioPipeline / Config。主程序 iVox（含 MLX/Audio actor）无单测，靠真实 daemon + `ivox speak` / pi 实测验证。

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

# 2. 打包二进制
cd .build/release && tar czf ivox-vX.X.X-macos-arm64.tar.gz ivox

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
