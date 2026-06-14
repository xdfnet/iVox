# iVox

<p align="center">
  <img src="https://img.shields.io/badge/Swift-6.0-FA7343?logo=swift&logoColor=white" alt="Swift 6.0">
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple_Silicon-M1%2B-A2AAAD?logo=apple&logoColor=white" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/TTS-iLLM_API-7B68EE?logo=mlflow&logoColor=white" alt="iLLM API TTS">
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

## 前置依赖

iVox 本身不做 TTS / ASR 推理，需要搭配 [iLLM](https://github.com/xdfnet/iLLM) 服务提供语音合成与识别能力：

```bash
# 安装 iLLM（提供 TTS API）
git clone https://github.com/xdfnet/iLLM && cd iLLM
make install
```

确保 iLLM 服务运行在 `tcp://127.0.0.1:8150`（默认端口）。

## 安装

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
ivox voice add -i my -n "我的音色" --description "自定义音色"
ivox voice remove my     # 删除音色
```

| 音色 ID | 名称 | 说明 |
|---------|------|------|
| mizai | 米仔 | 温暖自然，默认音色 |
| taozi | 甜妹桃子 | 活泼甜美，Claude 默认 |
| wanwan | 湾湾小何 | 温柔知性，Codex 默认 |
| dayi | 大易 | 沉稳可靠，Pi 默认 |

> 音色由 iLLM 服务端管理，需在 iLLM 的 `config.json` 中配置对应 voice 的参考音频。

音色匹配规则：`显式指定 --voice` > `sourceVoices 映射` > `defaultVoice`

### Hook 集成

安装后自动接入三个 AI 工具：

- **Claude Code** → `~/.claude/settings.json` — Stop Hook
- **Codex** → `~/.codex/hooks.json` — Stop Hook（首次触发时授权即可）
- **Pi** → `~/.pi/agent/settings.json` — Extension 注册

Codex 用户注意：首次触发 Hook 时需要确认允许，之后自动生效。

### 文本过滤

iVox 会在播报前做两层清洗：

- Markdown 结构过滤：跳过代码块、行内代码、HTML、图片、表格、分隔线
- 行内噪音过滤：清掉 URL、常见绝对路径、commit hash、UUID、终端转义、下载速度和 ETA 等朗读噪音

版本号、API 名、百分比和普通语义文本会保留。

## 开发

```bash
make build                # 编译 release
make deploy               # 部署 runtime 文件
make run                  # 编译 + 前台启动（看日志）
make clean                # 清理 .build
```

## 配置

`~/.config/ivox/config.json`：

```json
{
  "api": {
    "baseURL": "tcp://127.0.0.1:8150",
    "ttsModel": "Qwen3-TTS-12Hz-1.7B-Base-8bit"
  },
  "speechInput": {
    "enabled": true,
    "language": "zh",
    "autoEnter": true,
    "maxRecordingSeconds": 30,
    "model": "Qwen3-ASR-1.7B-4bit"
  },
  "defaultVoice": "mizai",
  "sourceVoices": { "claude": "taozi", "codex": "wanwan", "pi": "dayi" },
  "voices": [
    { "id": "mizai", "name": "米仔", "description": "默认音色" }
  ]
}
```

部署文件全部在 `~` 下，删掉项目目录不影响运行。

## 依赖

- macOS 14 Sonoma+
- Apple Silicon (M1+)
- Swift 6 / Xcode 15+
- [iLLM](https://github.com/xdfnet/iLLM) — TTS 语音合成 + ASR 语音识别服务
- [iDict](https://github.com/xdfnet/iDict) — 媒体控制（保持运行即可，无需额外配置）

## 许可

MIT
