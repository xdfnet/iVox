# Hook 链路

从 AI 助手回复到耳朵听到声音的完整路径。

## 总览

```
┌─ Claude Code ────┐    ┌─ Codex ────────┐    ┌─ Pi ───────────────┐
│ Stop event       │    │ Stop event     │    │ ivox.ts extension │
│ settings.json    │    │ hooks.json     │    │                     │
└─────┬────────────┘    └─────┬──────────┘    └─────┬───────────────┘
      │                       │                      │
      │    hook-speak.sh <source> <text>             │
      └───────────────────────┼──────────────────────┘
                              │
                              ▼
                    ┌─────────────────────┐
                    │   ivox speak -s X  │
                    │   Unix Socket 写入   │
                    └─────────┬───────────┘
                              │
                              ▼
                    ┌─────────────────────┐
                    │   iVox Daemon      │
                    │   (launchd 守护)     │
                    │                     │
                    │   ┌───────────────┐ │
                    │   │ TextCleaner   │ │  ← 去代码噪音
                    │   │ cleanText()   │ │
                    │   └───────┬───────┘ │
                    │           ▼         │
                    │   ┌───────────────┐ │
                    │   │ PlaybackQueue │ │  ← 只保留最新
                    │   │   (actor)     │ │
                    │   └───────┬───────┘ │
                    │           ▼         │
                    │   ┌───────────────┐ │
                    │   │ MediaController│ │  ← 暂停音乐
                    │   └───────┬───────┘ │
                    │           ▼         │
                    │   ┌───────────────┐ │
                    │   │  TTSEngine    │ │  ← MLX GPU 推理
                    │   │ synthesize()  │ │     Qwen3-TTS
                    │   └───────┬───────┘ │
                    │           ▼         │
                    │   ┌───────────────┐ │
                    │   │  AudioPlayer  │ │  ← 扬声器输出
                    │   │  scheduleBuffer│ │
                    │   └───────┬───────┘ │
                    │           ▼         │
                    │   ┌───────────────┐ │
                    │   │ MediaController│ │  ← 恢复音乐
                    │   └───────────────┘ │
                    └─────────────────────┘
```

## 各环节详解

### 1. AI 工具触发

| 工具 | 触发机制 | 配置位置 |
|------|----------|----------|
| Claude Code | Stop Hook | `~/.claude/settings.json` |
| Codex | Stop Hook | `~/.codex/hooks.json` |
| Pi | Extension | `~/.pi/agent/settings.json` |

Claude Code 和 Codex 的 Stop 事件在每次 AI 回复完成时触发，Pi 通过 Extension 异步调用。

### 2. Hook 脚本

`~/.config/ivox/hook-speak.sh`

接收来源参数（如 `codex` / `claude`），从 Stop Hook 的 stdin JSON 提取最后一条 assistant message。职责：

- 从 stdin 读取 Hook payload
- 提取最后一条 assistant message
- 调用 `ivox speak --source <source> <text>`
- 后台运行 (`&`)，**不阻塞** AI 工具

Hook 脚本不清洗内容；文本过滤统一由 daemon 侧 `TextCleaner` 执行。脚本不传配置文件路径，依赖 `~/.config/ivox/config.json` 自动加载。

### 3. ivox speak

`~/.local/bin/ivox`

- 解析 `--source` / `--voice` 参数
- 拼装 payload：`{source:claude}文本内容`
- 写入 Unix Socket：`~/.config/ivox/ivox.sock`
- 退出（不等待播放完成）
- 本机 socket 通信，**无网络开销**

幂等：`ivox speak` 本身不依赖代码签名，但 CLI 二进制需要签名才能被执行（macOS Gatekeeper）。签名由 `make sign` 或手动 `codesign -f -s <HASH>` 维护。

### 4. Daemon 接收 (ConnectionHandler)

`Sources/iVox/Network/`

- 解析 payload 头：`{source:codex}` / `{voice:wanwan}`
- 如果文本前面有 `{source:claude}` 前缀且带额外内容，截取 `source` 和 `voice`
- 查 `sourceVoices` 映射 → 确定音色 ID
- 调用 `cleanText()` 清洗

### 5. TextCleaner

`Sources/iVoxKit/TextCleaner.swift`

代码噪音过滤，保留自然语言可读性。当前是两层过滤：

#### 5.1 Markdown AST 结构过滤

使用 `swift-markdown` 解析完整回复，由 AST 决定哪些结构适合朗读。

| Markdown 节点 | 处理 |
|----------------|------|
| `Paragraph` / `Heading` / `ListItem` / `BlockQuote` | 保留文本 |
| `Link` | 保留链接标题 |
| `Emphasis` / `Strong` | 保留内部文本 |
| `CodeBlock` / `InlineCode` | 跳过 |
| `HTMLBlock` / `InlineHTML` | 跳过 |
| `Image` / `Table` / `ThematicBreak` | 跳过 |

不再单独处理 `<artifact>`：输入被视为完整 Markdown，artifact 如果需要跳过，应由上游输出为标准 Markdown 代码块或其他可解析结构。

#### 5.2 行内噪音过滤

AST 提取文本后，只做小范围 token 清理：

| 规则 | 匹配内容 | 处理 |
|------|----------|------|
| URL | `https://...` | 删除 |
| 常见路径 | `/Users/...`, `/tmp/...`, `/opt/...`, `~/...` | 删除 |
| UUID | `xxxxxxxx-xxxx-...` | 删除 |
| Commit Hash | 12-40 位小写 hex | 删除 |
| ANSI 转义 | `\x1b[31m` | 删除 |
| 速度噪音 | `12MB/s`, `1.5kb/s` | 删除 |
| 剩余时间 | `ETA`, `预计剩余`, `剩余时间` | 删除 |
| 状态符号 | `✅`, `❌`, `✓`, `✗` | 删除 |
| 箭头 | `→` | 替换为“到” |

保留的内容：版本号、API 名、函数名、百分比、品牌名（Codex、ChatGPT、OpenAI、iVox 等）、中文标点和语义文本。

清洗后的行用中文逗号（`，`）拼接。

### 6. PlaybackQueue

`Sources/iVox/Audio/PlaybackQueue.swift`

- `actor` 保证线程安全
- **新任务入队时丢弃 pending 旧任务**
- `playback.interruptCurrent=true` 时，新任务会取消正在合成/播放的旧任务
- 只说最新那句，避免长文本占住队列

### 7. MediaController

`Sources/iVox/Audio/MediaController.swift`

- 播放前调 iDict HTTP API → 暂停音乐
- 播放完调 iDict HTTP API → 恢复音乐
- 地址、暂停路径、恢复路径由 `mediaControl` 配置控制
- 不需要媒体控制时可设置 `mediaControl.enabled=false`
- 不依赖辅助功能权限

### 8. TTSEngine

`Sources/iVox/TTS/TTSEngine.swift`

- 调用 MLX 本地模型：Qwen3-TTS-12Hz-1.7B-Base-8bit
- **纯本地推理，不上传任何数据**
- 流式生成 PCM chunk，间隔由 `tts.streamingInterval` 控制
- 按模型采样率重采样到 `tts.outputSampleRate`，再转为 int16 PCM
- 重试次数和间隔由 `tts.maxRetries` / `tts.retryDelayMs` 控制

Qwen3-TTS 不支持特殊标签（如 `<laughter>`），情感通过文本语义和标点控制。

### 9. AudioPlayer

`Sources/iVox/Audio/AudioPlayer.swift`

- 基于 `AVAudioEngine` + `AVAudioPlayerNode`
- `scheduleBuffer` 流式写入，边生成边播
- `drain()` 轮询等待所有 buffer 播完（超时自动重启引擎）
- 空闲复活时间由 `playback.idleReviveSeconds` 控制
- 监听休眠唤醒 / 耳机插拔 / 音频配置变更

### 10. 日志

`~/.config/ivox/daemon.log`

关键追踪点：

```
Socket 收到 → "{source:claude}文本..."
source=claude, voice=taozi       # ConnectionHandler 解析
队列状态: pending=0 processing=0  # PlaybackQueue 状态
TTS 播放开始 [claude] "文本..."   # 开始合成
播放写入: chunks=123 bytes=...   # 流式写入完毕
TTS 播放完成 [claude] 3.2s       # 播放结束
```

## 代码签名

macOS 要求所有可执行文件有效签名。iVox 的开发签名证书 Hash：

`4A287668E97BC130AA6D19F4D64799394CAACBAD`

签名命令：

```bash
codesign --force --sign 4A287668E97BC130AA6D19F4D64799394CAACBAD ~/.local/share/ivox/runtime/iVox
```

**注意**：`make deploy` 会重新编译二进制并覆盖签名，部署后需要重新签名。

验证签名：

```bash
codesign -dv ~/.local/share/ivox/runtime/iVox 2>&1 | grep -E 'flags|Signature|TeamIdentifier'
```

期望输出：`flags=0x0(none)`、`Signature size` 存在、`TeamIdentifier=K9UF7A2D7Y`

## 故障排查

| 症状 | 检查点 |
|------|--------|
| 日志空 | daemon 是否在运行？`launchctl list | grep ivox` |
| 日志有收到但没播放 | 代码签名失效？`codesign -dv ~/.local/share/ivox/runtime/iVox` |
| 日志有播放但没声音 | AudioPlayer 引擎异常？音量设置？扬声器？ |
| 播放完音乐没恢复 | iDict 是否运行？`curl http://127.0.0.1:8888/api/ping` |
| Hook 不触发 | settings.json / hooks.json 配置是否正确？Shell 权限？ |

## 参考

- [架构总览](architecture.md)
- [CHANGELOG](CHANGELOG.md)
- iDict: https://github.com/xdfnet/iDict
- Qwen3-TTS: https://github.com/QwenLM/Qwen3-TTS
