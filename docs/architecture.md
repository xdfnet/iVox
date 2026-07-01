# iVox 架构

## 概览

macOS 本地语音助手守护进程，全栈 actor 化。输入侧接 AI 工具（Claude Code、Codex）和微信，输出侧走本地 MLX TTS/ASR + 系统媒体控制。

```
                          用户
                       ┌──┴──┐
                       │ 微信 │
                       └──┬──┘
               ┌──────────┤
          ilink 长轮询     │ hook-speak.sh
               │          │ (Claude Code / Codex Stop Hook)
               ▼          │
         WeChatPlatform   │
         ───────────────  │
         接收 → 注入      │ Unix Socket
                         ▼
              ┌─────────────────────┐
              │   Daemon (actor)    │
              │                     │
              │  WeChatPlatform ←──┤
              │  SocketServer ←────┤
              │  SpeechInput ←─────┤  ←  ⌘ 键 CGEvent 监听
              │  MediaHTTPServer   │  →  Web UI (8888)
              │         │          │
              │         ▼          │
              │  PlaybackQueue     │
              │  (actor)           │
              │   ├─ TTSEngine     │  mlx-audio-swift 流式推理
              │   └─ AudioPlayer   │  AVAudioEngine 播放
              │         │          │
              │  MediaController   │  MRMediaRemoteSendCommand
              │  (暂停/恢复音乐)    │
              └─────────────────────┘
```

## 子系统

### Daemon — 生命周期管理

`Sources/iVox/Daemon/Daemon.swift`

所有服务的所有者。按顺序：init（加载配置/状态）→ run（并行启动各服务）→ cleanup（SIGINT/SIGTERM 优雅关闭）。各服务以 `Task` 运行，取消传播到所有子任务。

```swift
// run() 内部大致结构
async let ws: Void = wechat?.start(handler: handleWeChatMsg)
async let sock = socketServer.start(handler: handleSocketMsg)
async let mic = speechInput.start()
// ...
await ws; await sock; await mic
```

### WeChatPlatform — 微信 ilink 长轮询

`Sources/iVox/WeChat/WeChatPlatform.swift`

- Actor 封装，通过 `WeChatClient` 调用微信 ilink API
- 长轮询 `getupdates` 获取新消息，`GetUpdatesResp.ret` 为 `Int?`（空响应不返回此字段）
- 手动 `withThrowingTaskGroup` 超时（URLSession 空闲超时在 TCP 保活下不触发）
- 消息去重（5 分钟窗口），`allow_from` 白名单过滤
- Typing 指示器（10 分钟 ticket 缓存，每 5 秒刷新）
- 状态持久化：`get_updates.buf` 和 `context_tokens.json` 到 `~/.config/ivox/wechat/`

收到消息 → 写 `pending_user` 文件 → `ClipboardInjector`（`osascript` Cmd+V）注入 Claude Code。

### SocketServer — Unix Domain Socket IPC

`Sources/iVox/Network/`

- `~/.config/ivox/ivox.sock`，JSON 行协议
- 支持 TTS 播报（`{source:claude,voice:wanwan}` 前缀）和 ASR 识别
- 详见 [`docs/api.md`](api.md)

### TTSEngine — 本地语音合成

`Sources/iVox/TTS/TTSEngine.swift`

- `mlx-audio-swift` 加载本地 Qwen3-TTS 模型
- `generateStream()` 流式合成 float32 PCM → 重采样 48kHz → int16
- 按音色读取 `refAudio` + `refText` 做声音克隆
- 可配置重试（`maxRetries`、`retryDelayMs`）、流式间隔（`streamingInterval`）

### PlaybackQueue — 播放调度

`Sources/iVox/Audio/PlaybackQueue.swift`

- Actor，管理播报队列
- 新请求入队时丢弃旧 pending 任务、取消正在合成/播放的任务
- 等待 TTS 模型就绪后再开始合成
- 播报前通过 `MediaController` 暂停音乐，播完恢复

### AudioPlayer — 音频播放

`Sources/iVox/Audio/AudioPlayer.swift`

- `AVAudioEngine` + `AVAudioPlayerNode.scheduleBuffer()` 流式播放
- `drain()` 轮询等待缓冲播完

### MediaController — 系统媒体控制

`Sources/iVox/Audio/MediaController.swift`

- `MRMediaRemoteSendCommand` 系统框架直接控制媒体播放
- 支持播放/暂停/切换/下一曲，无需辅助功能权限

### SpeechInput — 语音输入

`Sources/iVox/SpeechInput/`

- `CGEvent.tapCreate()` 监听右侧 ⌘ 键按下/松开
- 按下开始录音（`AVAudioRecorder`），松开触发 ASR
- ASR 结果通过 `CGEvent` 模拟键盘输入 + `NSPasteboard` 粘贴
- 需要辅助功能权限（`AXIsProcessTrustedWithOptions`）

### MediaHTTPServer — Web UI

`Sources/iVox/Audio/MediaHTTPServer.swift`

- 嵌入式 HTTP 服务器，端口 8888
- Web UI：播放/暂停/下一曲控制 + 状态展示
- REST API：`/api/config`、`/api/speak` 等

### iVoxKit — 共享库

`Sources/iVoxKit/`（无 MLX 依赖，可独立测试）

| 文件 | 职责 |
|------|------|
| `Config.swift` | JSON 配置模型（TTS/ASR 路径、音色、媒体控制、微信等） |
| `Logger.swift` | 日志工具，输出到 daemon.log，5MB 轮转 |
| `TextCleaner.swift` | Markdown AST 过滤 + 行内噪音（URL/路径/哈希/ANSI） |
| `AudioPipeline.swift` | 音频格式转换工具 |
| `TextSplitter.swift` | 按句切分 ≤80 字 |

## 并发模型

所有服务都是 **actor**，跨 actor 通信走 `await`。关键 actor 边界：

```
Daemon (actor)
  ├── WeChatPlatform (actor)   ← await 调用 WeChatClient (actor)
  ├── PlaybackQueue (actor)    ← await 调度 TTSEngine / AudioPlayer
  ├── SocketServer (非 actor)  → 回调 Daemon 的 actor 隔离方法
  └── SpeechInputService       → CGEvent 回调 → actor 方法
```

Swift 6 严格并发下，`@Sendable` 闭包不能捕获 actor 内的 `var`。用 `let capture = varValue` 创建值拷贝再传入闭包。

## 数据流

### TTS 播报

```
1. Hook 脚本 → `ivox speak -s claude "文本"`
2. SpeakCommand → Unix Socket `{source:claude}文本`
3. ConnectionHandler.handle():
   - 解析前缀 → source="claude"
   - voice = sourceVoices["claude"] ?? defaultVoice
   - 显式 `{voice:xxx}` 可覆盖
   - cleanText() 清洗 Markdown + 行内噪音
4. PlaybackQueue.enqueue(job)
   → 丢弃旧任务，MediaController.pause()
5. TTSEngine.synthesizeStream() → AsyncThrowingStream<Data>
6. AudioPlayer.write(pcm) → scheduleBuffer 流式播放
7. drain() 等待播放完成
8. MediaController.resume()
```

### 微信消息

```
1. WeChatPlatform 长轮询 getupdates（每 ~35 秒）
2. 收到消息 → 去重 → 白名单过滤 → 提取文本
3. Daemon.handleWeChatMessage()
   → 写 pending_user → ClipboardInjector Cmd+V 注入
4. Claude Code Stop Hook → ivox speak --source claude
```

## 文本过滤

`TextCleaner` 只在 daemon 侧执行，分两层：

1. **Markdown AST**（`swift-markdown` 库）
   - 跳过：CodeBlock、InlineCode、HTMLBlock、Image、Table、ThematicBreak
   - 保留：标题、段落、列表、引用、链接标题、加粗/斜体
2. **行内噪音**
   - 删除 URL、绝对路径、UUID、12-40 位哈希、ANSI 转义
   - 删除速度/ETA 噪音（`12MB/s`、`预计剩余`）
   - 符号替换：✅❌✓✗→

## 音色匹配

优先级：`显式 voice > sourceVoices 映射 > defaultVoice`

```
ConnectionHandler.extractVoicePrefix():
  if {voice:xxx} in payload  → xxx
  else if {source:s}         → sourceVoices[s] ?? defaultVoice
  else                       → defaultVoice
```

## 部署结构

所有运行时文件在 `~` 下，项目目录可删：

```
~/.local/bin/ivox                          # CLI 入口（符号链接）
~/.local/share/ivox/runtime/iVox          # 实际二进制
~/.config/ivox/config.json                 # 配置
~/.config/ivox/model/                      # TTS/ASR MLX 模型
~/.config/ivox/voices/                     # 参考音频
~/.config/ivox/wechat/                     # 微信轮询状态
~/.config/ivox/daemon.log                  # 日志（5MB 轮转）
~/Library/LaunchAgents/com.user.ivox.plist  # launchd 守护
```

`make deploy` 构建 → 签名 → 拷贝二进制 → 重启 launchd 服务。

## 构建系统

`Makefile` 使用 `TOOLCHAINS=swift-6.3.2-RELEASE`（Swift 6.4 快照在编译 MLXAudioTTS 时有编译器崩溃，见 [`compiler-bugs.md`](compiler-bugs.md)）。

关键 target：

| Target | 作用 |
|--------|------|
| `make build` | `swift build -c release -Xswiftc -Osize` |
| `make deploy` | build + voices + deploy-bin + sign |
| `make update` | deploy + launchd restart |
| `make run` | build + 前台运行（调试） |
| `make test` | 运行 iVoxKit 测试 |

## Hook 集成

| 工具 | 配置文件 | 触发 |
|------|----------|------|
| Claude Code | `~/.claude/settings.json` | Stop Hook → hook-speak.sh |
| Codex | `~/.codex/hooks.json` | Stop Hook → hook-speak.sh |

`hook-speak.sh` 提取 `last_assistant_message`，调用 `ivox wechat text` 和 `ivox speak`。
