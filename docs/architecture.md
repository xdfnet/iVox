# iVox 架构

## 整体

```
┌─ Claude Code ──┐    ┌─ Codex ────────┐    ┌─ Pi ──────────┐
│ hook-speak.sh   │    │ hook-speak.sh  │    │ ivox.ts       │
│ bash ... claude │    │ bash ... codex │    │ ivox speak    │
└────┬────────────┘    └────┬───────────┘    └────┬───────────┘
     │                      │                      │
     └──────────────────────┼──────────────────────┘
                            │ ivox speak --source <name> <text>
                            ▼
                   Unix Socket (~/.config/ivox/ivox.sock)
                            │
                            ▼
┌───────────────────────────────────────────────────────────┐
│                   iVox Daemon (launchd)                   │
│                                                            │
│  SocketServer → ConnectionHandler                          │
│      解析 {source:claude,voice:wanwan}                      │
│      + TextCleaner 清洗 Markdown                           │
│                         │                                  │
│                         ▼                                  │
│                  PlaybackQueue (actor)                      │
│                    ┌─────┴─────┐                            │
│                    │ MediaController│  ← iDict HTTP API      │
│                    │  pause/resume │    暂停/恢复音乐       │
│                    └─────┬─────┘                            │
│              ┌──────────┴──────────┐                       │
│              ▼                     ▼                       │
│        TTSEngine              AudioPlayer                  │
│     synthesizeStream()      scheduleBuffer()               │
│     iLLM API 流式调用         流式播放                       │
│     (HTTP chunked)          (AVAudioEngine)                 │
└───────────────────────────────────────────────────────────┘
                            │
                            ▼
              iLLM 服务 (http://127.0.0.1:8150/v1)
              └── /audio/speech → Qwen3-TTS MLX 推理
```

## 命令体系

两个入口，职责分离。

### `make` — 构建 + 部署

```
make            = 全流程（日常用这条）
make init       = 配置 + hook（第 1 层，幂等）
make build      = 编译（第 2 层）
make deploy     = 编译 + 部署 runtime 文件（第 2 层）
make launchd    = 注册自启 + 启动 daemon（第 3 层）
make uninstall  = 停服务 + 删文件
make run        = 前台调试
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
| `TTS/` | `Sources/iVox/TTS/TTSEngine.swift` | iLLM API 流式调用，内置重试 2 次 |
| `Utilities/` | `Sources/iVox/Utilities/Logger.swift` | OSLog + 文件日志，5MB 轮转 |
| `iVoxKit/` | `Sources/iVoxKit/` | 共享库：Config、TextCleaner、AudioPipeline |
| `scripts/` | `scripts/install-hooks.py` | 安装 hook 到 Claude / Codex / Pi |

`SetupCommand`、`ModelCommand`、`HookInstaller` 已移除，逻辑迁入 Makefile + `scripts/`。

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
   - 新请求入队 → 丢弃所有 pending 旧任务
   - MediaController 调 iDict /api/pause — 暂停音乐
5. TTSEngine.synthesizeStream() → AsyncThrowingStream<Data>
   - POST http://127.0.0.1:8150/v1/audio/speech (stream=true)
   - URLSession.bytes(for:) 流式读取 HTTP chunked 响应
   - 解析 WAV 头 → 提取 float32 样本
   - audioToPCM: 24k→48k 上采样 + float32→int16
   - 失败自动重试 2 次，间隔 500ms
6. AudioPlayer.write(pcm) → scheduleBuffer 流式播放
7. player.drain() — 轮询等待 buffer 播完
8. MediaController 调 iDict /api/play — 恢复音乐
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

> 音色由 iLLM 服务端通过参考音频实现声音克隆，iVox 只传递 voice ID。

## 媒体控制

`MediaController` 通过调用 [iDict](https://github.com/xdfnet/iDict) 的 `/api/pause` 和 `/api/play` 来实现播报时暂停音乐、播完恢复。  
需要 iDict 运行在 `127.0.0.1:8888`（iDict 默认端口），**不再需要辅助功能权限或代码签名**。

## 日志

`~/.config/ivox/daemon.log`，超过 5MB 自动归档为 `.old`。

## 部署结构

所有运行时文件在 `~` 下，删除项目目录不影响运行：

```
~/.local/bin/ivox                          # CLI 入口
~/.local/share/ivox/runtime/iVox          # 二进制
~/.config/ivox/config.json                 # 配置（指向 iLLM API）
~/.config/ivox/hook-speak.sh               # Hook 脚本
~/.config/ivox/ivox.ts                    # Pi 扩展
~/Library/LaunchAgents/com.user.ivox.plist  # launchd 守护
```

不再需要本地 TTS 模型和参考音频文件，全部由 iLLM 服务管理。

## Hook 集成

| 工具 | 配置文件 | 方式 |
|------|----------|------|
| Claude Code | `~/.claude/settings.json` | Stop → hook-speak.sh claude |
| Codex | `~/.codex/hooks.json` | Stop → hook-speak.sh codex（首次触发时授权即可） |
| Pi | `~/.pi/agent/settings.json` | Extension → ivox.ts → ivox speak --source pi |

由 `scripts/install-hooks.py` 统一安装，已存在则跳过。`make init` 幂等调用。
