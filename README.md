# iVox

<p align="center">
  <img src="https://img.shields.io/badge/Swift-6.0-FA7343?logo=swift&logoColor=white" alt="Swift 6.0">
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple_Silicon-M1%2B-A2AAAD?logo=apple&logoColor=white" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/TTS%2FASR-MLX_Local-7B68EE?logo=mlflow&logoColor=white" alt="MLX Local TTS/ASR">
  <img src="https://img.shields.io/badge/license-MIT-green?logo=opensourceinitiative&logoColor=white" alt="MIT">
</p>

<p align="center"><b>让 AI 开口说话、听懂你说话。</b></p>

---

> 写代码时懒得看屏幕？iVox 自动把你的 AI 助手的回复读给你听。  
> 音色自然、反应快、只说最新那句，不打扰你正在播的音乐。

| 🗣️ 替我读 | ⚡ 秒回 | 🧹 少噪音 | 🎵 不打断 | 🔌 开箱即用 |
|:---:|:---:|:---:|:---:|:---:|
| AI 回复自动播报<br>不用盯着屏幕 | 开口不到半秒<br>听到的速度 | 跳过代码/表格<br>清掉路径和 URL | 播报前暂停音乐<br>播完自动恢复 | 一条命令装好<br>自动注册自启动 |

按住右侧 **⌘** 键说话，松开后自动识别并粘贴——纯语音输入，不碰键盘。

| 🎙️ 语音输入 | ⚡ 秒回 | 🧹 少噪音 | ⌨️ 无感 | 🔌 开箱即用 |
|:---:|:---:|:---:|:---:|:---:|
| 按住 ⌘ 说话<br>松开粘贴 | ASR 识别不到半秒<br>听到的速度 | 短录音自动忽略<br>不误触发 | 无需切输入法<br>全局可用 | 守护进程自带<br>无需额外安装 |

---

## 模型

iVox 使用 [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) 在本机做 TTS / ASR 推理。安装时自动从 HuggingFace 下载量化好的 MLX 模型：

```bash
~/.config/ivox/model/Qwen3-TTS-12Hz-1.7B-Base-8bit
~/.config/ivox/model/Qwen3-ASR-1.7B-4bit
```

模型 ID：

```text
mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit
mlx-community/Qwen3-ASR-1.7B-4bit
```

已有完整模型时会自动跳过下载。建议使用 Apple Silicon；模型加载和推理会走 MLX / Metal。

## 安装

### 方式一：下载二进制（推荐，无需 Xcode）

```bash
curl -fsSL https://raw.githubusercontent.com/xdfnet/iVox/master/scripts/install-binary.sh | bash
```

### 方式二：编译安装（需要 Xcode）

```bash
git clone https://github.com/xdfnet/iVox && cd iVox
./install.sh              # 编译 + 部署 + 初始化，一条命令搞定
```

> 播报时通过 [iDict](https://github.com/xdfnet/iDict) 自动暂停/恢复音乐，  
> 需同时安装 iDict 并保持运行。

## 使用

安装完成后，服务已经在后台运行，无需任何操作。AI 助手回复时会自动播报。

### 基本命令

```bash
ivox status              # 查看服务是否在跑
ivox version             # 版本信息
ivox speak "你好"         # 手动播报一段文本
ivox speak -s codex "文本" # 指定来源（匹配音色）
ivox speak -v dayi "文本"  # 指定音色
```

### 管理命令

```bash
ivox restart             # 重启服务
ivox stop                # 停止服务
ivox serve               # 前台启动（调试用）
ivox say                 # 语音输入状态
```

### 音色

```bash
ivox voice list          # 列出所有音色
ivox voice add -i my -n "我的音色" --ref-audio ~/voice.wav --ref-text "参考音频内容" --description "自定义音色"
ivox voice remove my     # 删除音色
```

| 音色 ID | 名称 | 说明 |
|---------|------|------|
| mizai | 米仔 | 温暖自然，默认音色 |
| taozi | 甜妹桃子 | 活泼甜美，Claude 默认 |
| wanwan | 湾湾小何 | 温柔知性，Codex 默认 |
| dayi | 大易 | 沉稳可靠 |

> 音色由本地 TTS 模型根据 `refAudio` + `refText` 生成；不配置参考音频时使用模型默认声音。
> `make deploy` 会把内置默认参考音频初始化到 `~/.config/ivox/voices/`，已有文件不会被覆盖。

音色匹配规则：`显式指定 --voice` > `sourceVoices 映射` > `defaultVoice`

### Hook 集成

安装后自动接入两个 AI 工具：

- **Claude Code** → `~/.claude/settings.json` — Stop Hook
- **Codex** → `~/.codex/hooks.json` — Stop Hook（首次触发时授权即可）

Codex 用户注意：首次触发 Hook 时需要确认允许，之后自动生效。

### 文本过滤

iVox 在播报前做两层处理，专为 Qwen3-TTS 优化朗读自然度：

- **Markdown 结构过滤**：跳过 HTML、图片、表格、分隔线和长代码块；短代码块（≤3行）转为 inline 保留
- **行内噪音过滤**：清掉 URL、路径、16 位以上完整 SHA、UUID、ANSI 转义；保留短 commit hash 和版本号
- **文本自然化**：保留句号/问号/感叹号控制语调节奏，段落间自动加句号闭合，块间以空格分隔
- **符号替换**：✅❌✓✗→ 替换为中文词语，多空格压缩，中文标点前空格清理

## 开发

```bash
make install              # 首次安装：配置 + 模型 + 构建 + 部署 + 启动
make update               # 日常更新：构建 + 参考音频 + 部署 + 重启
make models               # 从 ModelScope 下载默认 MLX 模型
make voices               # 初始化默认参考音频
make build                # 编译 release
make deploy               # 构建 + 初始化参考音频 + 部署 runtime 文件
make restart              # make update 的兼容别名
make run                  # 编译 + 前台启动（看日志）
make test                 # 运行测试
make clean                # 清理 .build
```

## 配置

`~/.config/ivox/config.json`：

```json
{
  "models": {
    "asrPath": "~/.config/ivox/model/Qwen3-ASR-1.7B-4bit",
    "ttsPath": "~/.config/ivox/model/Qwen3-TTS-12Hz-1.7B-Base-8bit"
  },
  "tts": {
    "language": "Chinese",
    "streamingInterval": 0.15,
    "maxRetries": 2,
    "retryDelayMs": 500,
    "outputSampleRate": 48000
  },
  "playback": {
    "interruptCurrent": true,
    "idleReviveSeconds": 600,
    "drainBaseTimeoutSeconds": 10
  },
  "mediaControl": {
    "enabled": true,
    "baseURL": "http://127.0.0.1:8888",
    "pausePath": "/api/pause",
    "resumePath": "/api/play"
  },
  "speechInput": {
    "enabled": true,
    "language": "zh",
    "autoEnter": true,
    "maxRecordingSeconds": 30
  },
  "sourceVoices": { "claude": "taozi", "codex": "wanwan" },
  "defaultVoice": "mizai",
  "voices": [
    {
      "id": "mizai",
      "name": "米仔",
      "refAudio": "~/.config/ivox/voices/ref_mizai.wav",
      "refText": "大家好，我是米仔。",
      "description": "默认音色"
    }
  ]
}
```

JSON 本身不支持注释，字段说明放在这里：

| 字段 | 说明 |
|------|------|
| `models.asrPath` | 本地 ASR 模型目录 |
| `models.ttsPath` | 本地 TTS 模型目录 |
| `tts.language` | TTS 生成语言，中文默认 `Chinese` |
| `tts.streamingInterval` | 流式音频输出间隔，越大音频越连贯，默认 `0.15` |
| `tts.maxRetries` | TTS 合成失败后的重试次数 |
| `tts.retryDelayMs` | TTS 重试间隔，单位毫秒 |
| `tts.outputSampleRate` | 播放器输出采样率，默认 `48000` |
| `playback.interruptCurrent` | 新消息是否立即打断旧播报，默认 `true` |
| `playback.idleReviveSeconds` | 音频引擎空闲多久后播报前主动复活 |
| `playback.drainBaseTimeoutSeconds` | 等待音频缓冲播完的基础超时时间 |
| `mediaControl.enabled` | 是否调用 iDict 暂停/恢复音乐；没运行 iDict 可设为 `false` |
| `mediaControl.baseURL` | iDict 服务地址 |
| `mediaControl.pausePath` | 暂停音乐 API 路径 |
| `mediaControl.resumePath` | 恢复音乐 API 路径 |
| `speechInput.enabled` | 是否启用按住右侧 ⌘ 的语音输入 |
| `speechInput.language` | ASR 识别语言 |
| `speechInput.autoEnter` | 粘贴识别结果后是否自动回车 |
| `speechInput.maxRecordingSeconds` | 单次最长录音秒数 |
| `defaultVoice` | 默认音色 ID |
| `sourceVoices` | 不同来源到音色 ID 的映射 |
| `voices[].refAudio` | 音色参考音频路径 |
| `voices[].refText` | 参考音频对应文本 |

部署文件全部在 `~` 下，删掉项目目录不影响运行。

## 依赖

- macOS 14 Sonoma+
- Apple Silicon (M1+)
- Swift 6 / Xcode 16+
- [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) — 本地 TTS / ASR 推理
- [iDict](https://github.com/xdfnet/iDict) — 媒体控制（保持运行即可，无需额外配置）

## 许可

MIT
