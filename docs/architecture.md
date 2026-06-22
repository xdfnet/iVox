# iVox 架构

## 整体

```
┌─ Claude Code ──┐    ┌─ Codex ────────┐
│ hook-speak.sh   │    │ hook-speak.sh  │
│ bash ... claude │    │ bash ... codex │
└────┬────────────┘    └────┬───────────┘
     │                      │
     └──────────┬───────────┘
                │ ivox speak --source <name> <text>
                ▼
       Unix Socket (~/.config/ivox/ivox.sock)
                            │
                            ▼
┌───────────────────────────────────────────────────────────┐
│                   iVox Daemon (launchd)                   │
│                                                            │
│  SocketServer → ConnectionHandler       后台加载 TTS/ASR    │
│      解析 {source:claude,voice:wanwan}                      │
│      + TextCleaner 清洗 Markdown                           │
│                         │                                  │
│                         ▼                                  │
│                  PlaybackQueue (actor)                      │
│                    ┌─────┴─────┐                            │
│                    │ MediaController│  ← 原生引擎控制媒体     │
│                    │  pause/resume │    暂停/恢复音乐       │
│                    └─────┬─────┘                            │
│              ┌──────────┴──────────┐                       │
│              ▼                     ▼                       │
│        TTSEngine              AudioPlayer                  │
│     synthesizeStream()      scheduleBuffer()               │
│     本地 MLX 流式推理          流式播放                       │
│     (mlx-audio-swift)       (AVAudioEngine)                 │
└───────────────────────────────────────────────────────────┘
```

## 命令体系

两个入口，职责分离。

### `make` — 构建 + 部署

```
make / install = 首次安装：检查 + 配置 + 模型 + 构建 + 部署 + 启动
make update    = 日常更新：构建 + 参考音频 + 部署 + 重启
make restart   = make update 的兼容别名
make init       = 配置 + hook，幂等
make models     = 从 ModelScope mlx-community 下载默认 MLX 模型（已存在则跳过）
make voices     = 初始化默认参考音频（只补缺失，不覆盖用户文件）
make build      = 编译 release（使用 -Osize，规避 MLXAudioTTS 的 -O 编译器崩溃）
make deploy     = 构建 + 初始化参考音频 + 部署 runtime 文件
make launchd    = 写入 launchd plist + 启动 daemon
make uninstall  = 停服务 + 删文件
make run        = 前台调试
make test       = 运行测试
make version    = 发版（make version V=vX.Y.Z）
make clean      = 删除 .build
```

### `ivox` — 运行时操作

```
ivox serve   = 启动 daemon（默认命令）
ivox speak   = 发送播报
ivox voice   = 音色管理
ivox stop    = 停止 daemon
ivox status  = 查看状态
ivox version = 版本信息
ivox restart = 重启 daemon
```

`ivox setup`、`ivox model` 已移除，由 `make` 替代。

### 日常使用

```bash
# 首次安装
git clone ... && cd iVox
make

# 改完代码后更新
make

# 卸载重装
make uninstall
make

# 运行时操作
ivox status
ivox speak "你好"
ivox voice list
```

## 模块

| 模块 | 路径 | 职责 |
|------|------|------|
| `EntryPoint` | `Sources/iVox/EntryPoint.swift` | CLI 入口，7 个子命令 |
| `Commands/` | `Sources/iVox/Commands/` | serve / speak / voice / stop / status / version / restart |
| `Daemon/` | `Sources/iVox/Daemon/Daemon.swift` | 守护进程：监听 Socket → TTS → 播放 |
| `Network/` | `Sources/iVox/Network/` | Unix Socket 服务器 + ConnectionHandler |
| `Audio/` | `Sources/iVox/Audio/` | AudioPlayer + PlaybackQueue + MediaController |
| `TTS/` | `Sources/iVox/TTS/TTSEngine.swift` | 本地 MLX 流式推理，支持配置化重试 |
| `Utilities/` | `Sources/iVox/Utilities/Logger.swift` | OSLog + 文件日志，5MB 轮转 |
| `iVoxKit/` | `Sources/iVoxKit/` | 共享库：Config、TextCleaner、AudioPipeline |
| `scripts/` | `scripts/install-hooks.py` | 安装 hook 到 Claude / Codex |

`SetupCommand`、`ModelCommand`、`HookInstaller` 已移除。Makefile 只保留流程编排，配置、参考音频、二进制部署和 launchd 操作集中在 `scripts/runtime.sh`，模型下载在 `scripts/download-models.py`。

## 模型下载

默认模型来源固定为 ModelScope 的 [mlx-community](https://www.modelscope.cn/organization/mlx-community)：

```
mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit → ~/.config/ivox/model/Qwen3-TTS-12Hz-1.7B-Base-8bit
mlx-community/Qwen3-ASR-1.7B-4bit          → ~/.config/ivox/model/Qwen3-ASR-1.7B-4bit
```

`make models` 使用项目私有的 ModelScope Python 环境：

```
~/.local/share/ivox/modelscope-venv/
```

下载逻辑在 `scripts/download-models.py` 中。目标目录已有 `config.json` 和权重文件时直接跳过，避免重复下载。

## 数据流

```
1. CLI: ivox speak -s codex "你好"
2. SpeakCommand 拼 {source:codex}你好 → Unix Socket
3. ConnectionHandler.handle()
   - 解 {source:codex} → source="codex"
   - 查 config.sourceVoices["codex"] → voiceID="wanwan"
   - 显式 {voice:xxx} 可覆盖
   - cleanText() 清洗 Markdown 和行内噪音
4. PlaybackQueue.enqueue(job)
   - 新请求入队 → 丢弃 pending 旧任务，并取消正在合成/播放的旧任务
   - MediaController 调 MediaRemote.sendCommand(.pause) — 暂停音乐
5. TTSEngine.synthesizeStream() → AsyncThrowingStream<Data>
   - Daemon 先启动 socket，再后台加载/预热模型
   - TTS 未就绪时 PlaybackQueue 等待模型 ready，不阻塞 socket
   - `mlx-audio-swift` 加载本地 Qwen3-TTS 模型
   - 按音色读取 `refAudio` + `refText`
   - `generateStream()` 流式产出 float32 样本
   - `audioToPCM`: 按模型采样率重采样到 48k + float32→int16
   - 语言、流式间隔、重试次数、重试间隔、输出采样率由 `tts` 配置控制
6. AudioPlayer.write(pcm) → scheduleBuffer 流式播放
7. player.drain() — 轮询等待 buffer 播完
8. MediaController 调 MediaRemote.sendCommand(.play) — 恢复音乐
```

## 文本过滤

`TextCleaner` 只在 daemon 侧执行，Hook 脚本不做内容清洗。过滤分两层：

1. Markdown AST 结构过滤
   - 使用 `swift-markdown` 解析完整回复
   - 跳过 `CodeBlock`、`InlineCode`、`HTMLBlock`、`InlineHTML`、`Image`、`Table`、`ThematicBreak`
   - 保留标题、段落、列表项、引用、链接标题、加粗/斜体文本
2. 行内噪音过滤
   - 删除 URL、常见绝对路径和 `~/...`
   - 删除 UUID、12-40 位 commit hash、ANSI 终端转义
   - 删除 `12MB/s` 这类速度噪音和 `ETA` / `预计剩余` / `剩余时间`
   - 删除 `✅`、`❌`、`✓`、`✗`，把 `→` 转成"到"

清洗后的段落用中文逗号（`，`）拼接。版本号、API 名、百分比和普通语义文本保留。

## 音色匹配

优先级：`显式 voice > sourceVoices 映射 > defaultVoice`

```
ConnectionHandler.extractVoicePrefix():
  if {voice:xxx} in payload  → 直接用 xxx
  else if {source:s}         → sourceVoices[s] ?? defaultVoice
  else                       → defaultVoice
```

> 音色由本地 TTS 模型通过 `refAudio` + `refText` 实现声音克隆；不配置参考音频时使用模型默认声音。

## 媒体控制

`MediaController` 通过 MediaRemote 系统框架直接控制媒体播放，播报时暂停音乐、播完恢复。
支持本地原生模式（默认）和远程 HTTP 模式（`baseURL` 非空时）。本地模式使用 `MRMediaRemoteSendCommand` 系统 API，无需辅助功能权限。

## 日志

`~/.config/ivox/daemon.log`，超过 5MB 自动归档为 `.old`。

## 部署结构

所有运行时文件在 `~` 下，删除项目目录不影响运行：

```
~/.local/bin/ivox                          # CLI 入口
~/.local/share/ivox/runtime/iVox          # 二进制
~/.config/ivox/config.json                 # 配置（模型路径、音色、语音输入）
~/.config/ivox/model/                      # 本地 TTS / ASR 模型
~/.config/ivox/voices/                     # 可选参考音频
~/.config/ivox/hook-speak.sh               # Hook 脚本
~/Library/LaunchAgents/com.user.ivox.plist  # launchd 守护
```

TTS / ASR 在本机加载模型推理，不需要额外启动 iLLM 服务。

## Hook 集成

| 工具 | 配置文件 | 方式 |
|------|----------|------|
| Claude Code | `~/.claude/settings.json` | Stop → hook-speak.sh claude |
| Codex | `~/.codex/hooks.json` | Stop → hook-speak.sh codex（首次触发时授权即可） |

由 `scripts/install-hooks.py` 统一安装，已存在则跳过。`make init` 幂等调用。
