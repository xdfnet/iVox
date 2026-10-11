# iVox

<p align="center">
  <img src="https://img.shields.io/badge/Swift-6.4-FA7343?logo=swift&logoColor=white" alt="Swift 6.4">
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple_Silicon-M1%2B-A2AAAD?logo=apple&logoColor=white" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/TTS%2FASR-MLX_Local-7B68EE?logo=mlflow&logoColor=white" alt="MLX Local TTS/ASR">
  <img src="https://img.shields.io/badge/license-MIT-green?logo=opensourceinitiative&logoColor=white" alt="MIT">
</p>

<p align="center">
  <b>macOS 本地语音助手</b> — TTS 播报 · ASR 语音输入 · 微信消息桥接<br>
  全本地 MLX 推理，不依赖任何云端 API
</p>

---

## 功能

| 🗣️ AI 自动播报 | 🎙️ 语音输入 | 💬 微信桥接 |
|:---:|:---:|:---:|
| Claude Code / Codex / pi 回复自动朗读<br>pi 边生成边逐句播报，跳过代码和噪音<br>按 ↓ 跳过当前段，任意键取消整条 | 按住右 ⌘ 或右 ⌃ 说话，松开识别粘贴<br>屏幕浮窗实时显示录音波形与状态<br>纯语音输入，不碰键盘 | 微信消息→常驻 Claude Agent<br>后台任务跨消息持续运行<br>AI 回复自动转发回微信 |

播报前暂停音乐，播完自动恢复。一条命令安装，装完即运行（不注册登录自启，用 `ivox on/off` 手动管理）。

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/xdfnet/iVox/main/scripts/install-binary.sh | bash
```

需要编译？克隆后 `make` 即可（需 Swift 6.4 开发快照 + Xcode 26+）。

## 使用

安装完服务已在后台运行。常用命令：

```bash
ivox speak "你好"           # 手动播报
ivox voice list             # 列出音色
ivox status                 # 版本、各功能健康状态、权限、模型/音色文件体检
ivox listen -f 录音.wav     # 语音识别
ivox restart                # 重启服务
ivox upgrade                # 检查 GitHub 最新版并自动升级（备份旧版、重签、重启）
```

**健康检查**（Web UI 端口，默认 8888）：

```bash
curl -s 127.0.0.1:8888/health
# {"status":"ok","version":"3.5.0","model":"Qwen3-TTS-…","engine":"ready","queued":0,"playing":false}
```

**微信**：配置后微信消息自动注入 Claude Code，AI 回复通过 TTS 播报并转发回微信。

```bash
ivox wechat setup              # 扫码登录微信机器人的 ilink bot
ivox wechat status             # 查看配置状态
```

音色匹配：`--voice` 指定 > `sourceVoices` 映射 > `defaultVoice`

| 音色 | 说明 |
|------|------|
| 甜妹桃子 taozi | 活泼甜美，默认 |
| 湾湾小何 wanwan | 温柔知性，Codex/Qwen 默认 |
| 米仔 mizai | 温暖自然 |
| 大易 dayi | 沉稳可靠 |

> 音色基于 `refAudio` + `refText` 做声音克隆。可自定义：`ivox voice add -i my -n "我的" --ref-audio ~/voice.wav --ref-text "内容"`

## 开发

```bash
make build     # release 编译（自动使用 Swift 6.4 开发快照）
make run       # 编译 + 前台调试
make update    # 停服 + 编译 + 部署 + 启动守护进程
make test      # 运行测试
make clean     # 清除 .build
```

> 需要 Swift 6.4 开发快照（`swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-06-15-a`）。早期快照的编译器崩溃已在该版本修复，详见 [`docs/archive/incident-swift-compiler-crash.md`](docs/archive/incident-swift-compiler-crash.md)。

## 配置

`~/.config/ivox/config.json` 主要字段：

| 字段 | 说明 |
|------|------|
| `models.ttsPath` / `models.asrPath` | 本地 MLX 模型路径 |
| `tts.streamingInterval` | 流式输出间隔，默认 0.08s |
| `speechInput.enabled` | 语音输入开关 |
| `mediaControl.httpServerEnabled` | Web UI（端口 8888） |
| `wechat.token` | 微信 ilink bot token |
| `voice.xx.refAudio` | 音色参考音频路径 |

完整字段见 `Sources/iVoxKit/Config.swift`。

## 架构

```
Claude Code / Codex → hook ─┐
pi 扩展（逐句流式）──────────┴→ Unix Socket → Daemon
                                            ├── TTSEngine (本地 MLX)
                                            ├── WeChatPlatform (ilink 长轮询)
                                            │       └─ 常驻 Claude Agent (Swift 直连 claude)
                                            ├── SpeechInput (右 ⌘ / 右 ⌃ + ASR)
                                            └── MediaHTTPServer (Web UI)
```

微信消息经守护进程发给一个常驻 `claude` Agent（Swift 经 stdio NDJSON 直连，无 node 依赖），后台任务可跨消息持续运行；Agent 工作目录隔离在 `~/.config/ivox/wechat/workspace`，发 `/new` 可开新会话。

详见 [架构文档](docs/architecture.md)。

## 权限

| 权限 | 用途 | 是否必需 |
|------|------|:--------:|
| **麦克风** | 语音输入（按住右 ⌘ / 右 ⌃ 说话 → ASR） | 不用语音输入可不给 |
| **设备控制与数据访问** | ① 监听 ⌘ 键 ② 剪贴板粘贴注入 ③ 媒体控制 | **是** |
| **代码签名** | ad-hoc 自签，每次重建哈希变化 → TCC 权限失效 | 部署后重新勾选 |

设备控制与数据访问路径：系统设置 → 隐私与安全性 → 设备控制与数据访问 → 勾选 `ivox`。

> 重建二进制后 ad-hoc 签名变化，TCC 记录的权限会失效。`make update`（`deploy-bin`）会自动重新签名，但如果权限丢了，需要去系统设置重新勾选。

## 依赖

- macOS 14+ / Apple Silicon
- Swift 6.4 开发快照 / Xcode 26+
- [Claude Code](https://claude.com/claude-code) CLI — 微信常驻 Agent（Swift 经 stdio 直连）
- [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) — 本地 MLX 推理
- [Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS) — TTS 模型（[官方博客](https://qwen.ai/blog?id=qwen3tts-0115)）
- Qwen3-ASR-1.7B — 本地语音识别模型（首次安装自动下载）

## 许可

MIT
