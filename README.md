# iVox

<p align="center">
  <img src="https://img.shields.io/badge/Swift-6.4-FA7343?logo=swift&logoColor=white" alt="Swift 6.4">
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple_Silicon-M1%2B-A2AAAD?logo=apple&logoColor=white" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/TTS%2FASR-MLX_Local-7B68EE?logo=mlflow&logoColor=white" alt="MLX Local TTS/ASR">
  <img src="https://img.shields.io/badge/license-MIT-green?logo=opensourceinitiative&logoColor=white" alt="MIT">
</p>

<p align="center">
  <b>macOS 本地语音助手</b> — TTS 播报 · ASR 语音输入 · 划词翻译 · 微信消息桥接<br>
  语音全本地 MLX 推理；划词翻译默认 Google，也可换任意 OpenAI 兼容服务
</p>

---

## 功能

| | 能力 | 说明 | 怎么用 |
|---|---|---|---|
| 🗣️ | **自动播报** | AI 回复边生成边念，跳过代码与噪音；开口或 `Ctrl+Esc` 即打断 | 装好即用 |
| 🎛️ | **媒体控制** | Web 控制台：远程控制音乐播放 / 暂停 / 切歌 / 音量 | 打开 `127.0.0.1:8888`，手机同局域网用 `http://<本机IP>:8888` |
| 🎙️ | **语音输入** | 按住说话，松开识别粘贴，浮窗实时显示波形 | 右 ⌘ / 右 ⌃ |
| 📖 | **划词翻译** | 选中即译，鼠标旁浮窗出译文并可朗读 | `Cmd+D` |
| ⚡ | **快速操作** | 在当前目录开终端 / 分别跑 `claude`、`codex`、`pi` / 复制路径 | `Opt+Z` · `Opt+A/X/Q` · `Opt+C` |
| 💬 | **微信桥接** | 微信消息直通常驻 Claude，回复自动播报并转发回微信 | `ivox wechat setup` |

---

播报前暂停音乐，播完自动恢复。一条命令安装，用 `ivox autostart on/off` 控制启停（LaunchAgent 托管：登录自启 + 崩溃自动重启）。

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/xdfnet/iVox/main/scripts/install-binary.sh | bash
```

需要编译？克隆后 `make` 即可（需 Swift 6.4 开发快照 + Xcode 26+）。

## 使用

安装完服务已在后台运行。常用命令：

```bash
ivox speak "你好"           # 手动播报
ivox translate "hello"      # 划词翻译（--selection 取当前选中文本，--json 结构化输出）
ivox voice list             # 列出音色
ivox status                 # 版本、各功能健康状态、权限、模型/音色文件体检
ivox listen -f 录音.wav     # 语音识别
ivox autostart on/off       # 启动 / 停止（LaunchAgent 托管，含登录自启）
ivox upgrade                # 检查 GitHub 最新版并自动升级（备份旧版、重签、重启）
```

**健康检查**（Web UI 端口，默认 8888）：

```bash
curl -s 127.0.0.1:8888/health
# {"status":"ok","version":"3.6.1","model":"Qwen3-TTS-…","engine":"ready","queued":0,"playing":false}
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
| 湾湾小何 wanwan | 温柔知性，Codex 默认 |
| 米仔 mizai | 温暖自然 |
| 大易 dayi | 沉稳可靠 |

> 音色基于 `refAudio` + `refText` 做声音克隆。可自定义：`ivox voice add -i my -n "我的" --ref-audio ~/voice.wav --ref-text "内容"`

## 开发

```bash
make build     # release 编译（自动使用 Swift 6.4 开发快照）
make run       # 编译 + 前台调试
make update    # 停服 + 编译 + 部署 + 启动守护进程
make test      # 运行测试（iVoxKit 纯逻辑，秒级）
make check-tts # 播报黑盒自检（压真实 daemon，发版前手动跑）
make clean     # 清除 .build
```

> `make check-tts` 需先 `ivox autostart on` 且模型就绪（缺 node 会提示 `brew install node`）。它通过 Unix socket + `/health` + 增量 tail `daemon.log` 校验协议、合成时长、轮次隔离、密集打断、尾音完整等 12 个用例，**静音运行、不进设备**，无音频设备的环境自动 skip 相关用例。常用：`make check-tts ARGS="-f tail"` 只跑某组、`ARGS="--strict"` 让 advisory 用例也计入失败、`ARGS="--managed"` 由脚本自行重启守护进程。

> 需要 Swift 6.4 开发快照（`swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-06-15-a`）。早期快照的编译器崩溃已在该版本修复，详见 [`docs/archive/incident-swift-compiler-crash.md`](docs/archive/incident-swift-compiler-crash.md)。

## 配置

`~/.config/ivox/config.json` 主要字段：

| 字段 | 说明 |
|------|------|
| `models.ttsPath` / `models.asrPath` | 本地 MLX 模型路径 |
| `tts.streamingInterval` | 流式输出间隔，默认 0.08s |
| `speechInput.enabled` | 语音输入开关 |
| `translation.provider` | 划词翻译服务：`google`（默认，免配置）/ `openai`（OpenAI 兼容） |
| `translation.speechEnabled` | 划词翻译后是否朗读译文 |
| `translation.proxyURL` | 直连不通时的兜底代理，如 `http://192.168.100.6:10808`（只在直连失败后才用） |
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
                                            ├── GlobalKeyTap (键盘事件层：一个 tap，按归属路由)
                                            │       ├─ SpeechInput  (右 ⌘ / 右 ⌃ + ASR)
                                            │       ├─ Translation  (Cmd+D 划词翻译 + 浮窗)
                                            │       ├─ QuickActions (Opt+Z/A/Q/X/C)
                                            │       └─ Ctrl+Esc     (手动闭嘴：打断播报 + 恢复音乐)
                                            └── MediaHTTPServer (Web UI)
```

微信消息经守护进程发给一个常驻 `claude` Agent（Swift 经 stdio NDJSON 直连，无 node 依赖），后台任务可跨消息持续运行；Agent 工作目录隔离在 `~/.config/ivox/wechat/workspace`，发 `/new` 可开新会话。

详见 [架构文档](docs/architecture.md)。

## 权限

| 权限 | 用途 | 是否必需 |
|------|------|:--------:|
| **麦克风** | 语音输入（按住右 ⌘ / 右 ⌃ 说话 → ASR） | 不用语音输入可不给 |
| **设备控制与数据访问** | ① 监听修饰键 ② 剪贴板粘贴注入 ③ 媒体控制 | **是** |
| **输入监控** | 划词翻译的 `Cmd+D` 等**普通键**热键 | 要划词翻译才需要 |
| **自动化（Finder）** | QuickActions 读取 Finder 当前目录 / 选中项 | 只用 Opt+Z/A/Q/X/C 才需要 |
| **代码签名** | ad-hoc 自签，每次重建哈希变化 → TCC 权限失效 | 部署后重新勾选 |

> **划词翻译要「输入监控」**：只给"设备控制与数据访问"时，右 ⌘ 语音照常，但 `Cmd+D` 毫无反应——tap 明明创建成功，却收不到普通键，最难排查。`ivox status` 的「划词翻译」一行会如实反映。

设备控制与数据访问路径：系统设置 → 隐私与安全性 → 设备控制与数据访问 → 勾选 `ivox`。

> 重建二进制后 ad-hoc 签名变化，TCC 记录的权限会失效。`make update`（`deploy-bin`）会自动重新签名，但如果权限丢了，需要去系统设置重新勾选。

## 依赖

- macOS 14+ / Apple Silicon
- Swift 6.4 开发快照 / Xcode 26+
- [Claude Code](https://claude.com/claude-code) CLI — 微信常驻 Agent（Swift 经 stdio 直连）
- [Ghostty](https://ghostty.org) — 终端模拟器；快速操作的「开终端跑 `claude`/`codex`/`pi`」（`Opt+A`/`Opt+X`/`Opt+Q`）用它（`brew install --cask ghostty`）
- [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) — 本地 MLX 推理
- [Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS) — TTS 模型（[官方博客](https://qwen.ai/blog?id=qwen3tts-0115)）
- Qwen3-ASR-1.7B — 本地语音识别模型（首次安装自动下载）

## 许可

MIT
