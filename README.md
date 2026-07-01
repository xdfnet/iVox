# iVox

<p align="center">
  <img src="https://img.shields.io/badge/Swift-6.0-FA7343?logo=swift&logoColor=white" alt="Swift 6.0">
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
| Claude Code / Codex 回复自动朗读<br>跳过代码和噪音，只说人话 | 按住 ⌘ 键说话，松开识别粘贴<br>纯语音输入，不碰键盘 | 微信消息→注入 Claude Code<br>AI 回复自动转发回微信 |

播报前暂停音乐，播完自动恢复。一条命令安装，守护进程自启动。

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/xdfnet/iVox/master/scripts/install-binary.sh | bash
```

需要编译？克隆后 `make` 即可（需 Swift 6.3.2 + Xcode 26+）。

## 使用

安装完服务已在后台运行。常用命令：

```bash
ivox speak "你好"           # 手动播报
ivox voice list             # 列出音色
ivox status                 # 服务状态
ivox listen -f 录音.wav     # 语音识别
ivox restart                # 重启服务
```

**微信**：配置后微信消息自动注入 Claude Code，AI 回复通过 TTS 播报并转发回微信。

```bash
ivox wechat setup              # 扫码登录微信机器人的 ilink bot
ivox wechat status             # 查看配置状态
```

音色匹配：`--voice` 指定 > `sourceVoices` 映射 > `defaultVoice`

| 音色 | 说明 |
|------|------|
| 米仔 mizai | 温暖自然，默认 |
| 甜妹桃子 taozi | 活泼甜美，Claude 默认 |
| 湾湾小何 wanwan | 温柔知性，Codex 默认 |
| 大易 dayi | 沉稳可靠 |

> 音色基于 `refAudio` + `refText` 做声音克隆。可自定义：`ivox voice add -i my -n "我的" --ref-audio ~/voice.wav --ref-text "内容"`

## 开发

```bash
make build     # release 编译（自动使用 Swift 6.3.2）
make run       # 编译 + 前台调试
make update    # 编译 + 部署 + 重启 launchd 服务
make test      # 运行测试
make clean     # 清除 .build
```

Swift 6.4 快照有编译器 bug（MLXAudioTTS 在 `-O` 下崩溃），详见 [`docs/compiler-bugs.md`](docs/compiler-bugs.md)。

## 配置

`~/.config/ivox/config.json` 主要字段：

| 字段 | 说明 |
|------|------|
| `models.ttsPath` / `models.asrPath` | 本地 MLX 模型路径 |
| `tts.streamingInterval` | 流式输出间隔，默认 0.15s |
| `speechInput.enabled` | 语音输入开关 |
| `mediaControl.httpServerEnabled` | Web UI（端口 8888） |
| `wechat.token` | 微信 ilink bot token |
| `voice.xx.refAudio` | 音色参考音频路径 |

完整配置说明见 [`docs/api.md`](docs/api.md)。

## 架构

```
Claude Code / Codex → hook → Unix Socket → Daemon
                                            ├── TTSEngine (本地 MLX)
                                            ├── WeChatPlatform (ilink 长轮询)
                                            ├── SpeechInput (⌘ 键 + ASR)
                                            └── MediaHTTPServer (Web UI)
```

详见 [架构文档](docs/architecture.md)。

## 权限

| 权限 | 用途 | 是否必需 |
|------|------|:--------:|
| **麦克风** | 语音输入（按住 ⌘ 键说话 → ASR） | 不用语音输入可不给 |
| **辅助功能** | ① 监听 ⌘ 键 ② 剪贴板粘贴注入 ③ 媒体控制 | **是** |
| **代码签名** | ad-hoc 自签，每次重建哈希变化 → TCC 权限失效 | 部署后重新勾选 |

辅助功能路径：系统设置 → 隐私与安全性 → 辅助功能 → 勾选 `ivox`。

> 重建二进制后 ad-hoc 签名变化，TCC 记录的权限会失效。`make deploy` 会自动重新签名，但如果权限丢了，需要去系统设置重新勾选。

## 依赖

- macOS 14+ / Apple Silicon
- Swift 6.3.2 / Xcode 26+
- [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) — 本地 MLX 推理

## 许可

MIT
