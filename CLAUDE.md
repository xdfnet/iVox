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
  Resources/          — hook.sh, assets, 默认音色

Sources/iVoxKit/       — 共享库（无 MLX 依赖）
  Config.swift         — JSON 配置模型
  Logger.swift         — Log.{info,debug,warn,error}
  TextCleaner.swift    — Markdown + 噪音过滤（给 TTS 用）
  TextSplitter.swift   — 流式文本分块

Sources/iVoxTests/     — 测试（仅依赖 iVoxKit）

docs/                  — architecture.md, api.md, CHANGELOG.md, hook-chain.md, stability.md, compiler-bugs.md
scripts/               — runtime.sh, download-models.sh, install-*.sh
```

## 架构

基于守护进程的 actor 架构（无 launchd，`ivox start/stop` 手动管理）：

```
Claude Code/Codex  →  hook.sh  →  Unix Socket  →  Daemon
                                                          ├─ PlaybackQueue (actor)
                                                          │   ├─ TTSEngine (mlx-audio-swift)
                                                          │   └─ AudioPlayer (AVAudioEngine)
                                                          ├─ WeChatPlatform (actor, 长轮询)
                                                          ├─ SpeechInputService (Cmd 键 + ASR)
                                                          └─ MediaHTTPServer (端口 8888, Web UI)
```

关键模式：
- **Swift 6 严格并发**：所有服务都是 `actor` 类型。跨 actor 调用使用 `await`。`@Sendable` 闭包必须捕获值拷贝的 `let` 绑定（不能是 actor 上下文中的 `var`）。
- **Daemon 生命周期**：`init` 加载配置 → `run()` 并行启动所有服务 → `cleanup()` 处理 SIGINT/SIGTERM 退出。
- **微信长轮询**：`GetUpdatesResp.ret` 是 `Int?`（API 在空响应时省略 `ret`）。手动用 `withThrowingTaskGroup` 让 URL 请求和 `Task.sleep` 超时竞速（URLSession idle timeout 在长轮询 TCP keep-alive 下不会触发）。
- **TTS 流水线**：Qwen3-TTS 通过 `mlx-audio-swift` 流式合成，`AVAudioEngine` 播放。文本先由 `TextCleaner` 预处理（去除 Markdown 噪音、URL、路径、ANSI 码）。

- **配置**：`~/.config/ivox/config.json`，所有运行时文件在 `~/.config/ivox/` 下。

- **日志**：`~/.config/ivox/daemon.log`（nohup 的 stdout/stderr）。使用 `Log.{info,debug,warn,error}`。

## 已知问题

### Swift 6.4 快照版编译器崩溃（已修复）
此问题已在 `swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-06-15-a` 中修复。详见 `docs/compiler-bugs.md`。

### 代码签名变更导致 TCC 权限失效
Ad-hoc 签名每次构建都会变化 → TCC 权限（麦克风、辅助功能）丢失。`deploy-bin`（`make update`）会自动重新签名。部署后如权限丢失，需在系统设置中重新勾选。

## 部署

```bash
make update       # 编译 → 签名 → 复制到 ~/.local/bin/ivox → 重启守护进程
```

The binary at `~/.local/bin/ivox` is what hook scripts and `ivox start/stop` invoke. Project dir can be deleted after deploy.

`~/.local/bin/ivox` 是 hook 脚本调用的二进制，由 `ivox start/stop` 手动管理。部署后项目目录可删除。

## 测试

```bash
make test
# 或直接：
TOOLCHAINS=swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-06-15-a swift test
# 或直接用 make test（自动使用 xcrun --toolchain swift-latest）
```

测试仅覆盖 `iVoxKit`（无 MLX 依赖，快）。测试位于 `Sources/iVoxTests/`。

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
