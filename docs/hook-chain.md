# Hook 链路

从 AI 助手回复到耳朵听到声音的完整路径。

## 总览

```
┌─ Claude Code ────┐    ┌─ Codex ────────┐
│ Stop event       │    │ Stop event     │
│ settings.json    │    │ hooks.json     │
└─────┬────────────┘    └─────┬──────────┘
      │                       │
      │    hook.sh <source> <text>   │
      │                       │
      └──────────┬────────────┘
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
                    │   (手动守护)         │
                    │                     │
                    │   ┌───────────────┐ │
                    │   │ TextCleaner   │ │  ← 去代码噪音
                    │   │ cleanText()   │ │
                    │   └───────┬───────┘ │
                    │           ▼         │
                    │   ┌───────────────┐ │
                    │   │ PlaybackQueue │ │  ← 连续管道 / turn 打断
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

| 工具 | 提交即打断 | 回复完成播报 | 配置位置 |
|------|-----------|-------------|----------|
| Claude Code | UserPromptSubmit → `hook.sh interrupt` | Stop → `hook.sh claude` | `~/.claude/settings.json` |
| Codex | UserPromptSubmit → `hook.sh interrupt` | Stop → `hook.sh codex` | `~/.codex/hooks.json` |
| Qwen Code | UserPromptSubmit → `hook.sh interrupt` | Stop → `hook.sh qwen` | `~/.qwen/settings.json` |
| pi 扩展 | `message_start` 用户消息即 `{cancel}` 旧轮 + 新轮首帧（beginTurn 的 bargeIn 清场） | `message_update` 流式 | `~/.pi/agent/extensions/ivox.ts` |
| DeepSeek Harness | 新一轮 `start` 帧自动 bargeIn | `agent/assistant-stream` 逐 token 流式（主）；socket 不可用时 turn-stopping 整段直投 hook.sh（兜底） | `~/.dsh/profiles/desktop/cordis.patch.yml` |

**打断时机对齐真人对话**：hook 类工具（Claude/Codex/Qwen）挂两个钩子——`UserPromptSubmit` 在**你一提交 prompt、AI 还没开口**时就跑 `hook.sh interrupt`（发 `__IVOX_STOP_PLAYBACK__`），上一轮还在念的内容立刻停；`Stop` 在回复写完后才念新回复。这样「你一开口（提交），对方就停」，而不是等新回复到达才打断。哨兵的语义是**你开口 = 全场闭嘴**：当场静音之外，还会把**所有**流式轮（含 pi/dsh 正在生成的那一轮）一并作废——该轮后续增量不再开口。

Claude Code 和 Codex 的 Stop 事件在每次 AI 回复完成时触发，payload 自带 `last_assistant_message`。

DeepSeek Harness 不同：它内置的桥接插件（`dsh-hooks-claude-code` / `dsh-hooks-codex`）的 Stop payload **不含回复文本**（`stopPayload()` 只给 `session_id` / `cwd` / `hook_event_name`；codex 版把 `last_assistant_message` 写死成 `null`）。文本由本地 cordis 插件 `ivox-tts` 在内存中取出。**默认走与 pi 同构的第二层流式**，只在 socket 连不上时退回整段 hook.sh：

```
模型生成中
  └─ ctx.on("agent/assistant-stream")  frame=start/chunk/end
        chunk.chunk.type==="text-delta" → 增量原文帧写长连接（跳过 reasoning/tool-call）
一轮结束
  └─ ctx.on("agent/turn-stopping")  发 {end} 关流
        · 已流式成功 → 结束
        · socket 不可用 → spawn: bash hook.sh dsh
              stdin: {hook_event_name:"Stop", last_assistant_message:"<最终文本>"}
          （最终文本仍由 session/event 缓存的最后一条非空 assistant/message 选出）
```

> `assistant/message`/`attempt` 的 `data.stream` 是该 step 的**累计**紧凑流，不能逐帧转发；真增量只在 `agent/assistant-stream` 的 chunk frame。

装在 `~/.dsh/profiles/desktop/plugins/ivox-tts.mjs`，由 `scripts/install-hooks.sh` 安装，源码在仓库 `integrations/dsh/`。

机制细节、安装步骤、踩坑清单（`.mjs` 后缀要求、匿名 `package.json`、子代理过滤、旧的 zstd 取文本方案为何废弃）见 **[`dsh-tts.md`](dsh-tts.md)**。

### 2. Hook 脚本

`~/.config/ivox/hook.sh`

两种模式：

- **`hook.sh <source>`（Stop）**：接收来源参数（如 `codex` / `claude` / `dsh`），从 stdin JSON 提取 `last_assistant_message`。dsh 的这份 payload 由本地插件 `ivox-tts` 直接投喂（见上），脚本里已没有读 zstd 会话日志的分支。
  - 从 stdin 读取 Hook payload，提取最后一条 assistant message
  - 调用 `ivox speak --source <source> <text>`，后台运行 (`&`)，**不阻塞** AI 工具
- **`hook.sh interrupt`（UserPromptSubmit）**：不读文本、不发声，丢弃 stdin payload 后调 `ivox quiet`（发送 `__IVOX_STOP_PLAYBACK__`），负责打断当前播报**并作废全部流式轮**（你开口 = 全场闭嘴，含 pi/dsh 正在生成的轮次）。daemon 未运行时静默成功。

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
| `Paragraph` / `Heading` / `ListItem` / `BlockQuote` | 保留文本，块末补「。」 |
| `Link` | 保留链接标题 |
| `Emphasis` / `Strong` | 保留内部文本 |
| `InlineCode` | 保留（函数名、API 名有信息量），前后按需补分词空格 |
| `CodeBlock` | **跳过**：源码逐 token 念出来对听众没有信息量，一段代码能占几分钟 |
| `HTMLBlock` / `InlineHTML` / `ThematicBreak` | 跳过 |
| `Image` | 保留 alt 文字（通常是一句人话描述） |
| `Table` | 保留单元格文字；单元格之间强制补空格、每行末补「。」 |

块的句末判断取「最后一个非空白字符」，否则嵌套块（`ListItem` 内含 `Paragraph`）会补出重复的「。 。」。
相邻文本节点之间只在**一侧是拉丁字母/数字**时才补空格——中日韩文本天然分词，硬插空格会产生伪停顿（如「加粗 普通」）。

不再单独处理 `<artifact>`：输入被视为完整 Markdown，artifact 如果需要跳过，应由上游输出为标准 Markdown 代码块或其他可解析结构。

#### 5.2 行内噪音过滤

AST 提取文本后，按固定顺序做 token 清理。顺序不可调换：**URL 必须在路径规则之前**（否则 URL 会被当路径砍成 `https:b` 残片），**噪音必须在 `removingEmoji` 之前**（符号清理会把 `:` `/` `[` 换成空格，正则就匹配不到了）。

| 规则 | 匹配内容 | 处理 |
|------|----------|------|
| URL | `https://...` | 删除 |
| 路径 | 绝对/家目录路径（`/Users/...`、`~/...`）、多段相对路径（`Sources/iVox/TextCleaner.swift`） | 只保留文件名（`TextCleaner.swift`）——念文件名有用，念整条路径没用 |
| UUID | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` | 删除（须排在 hash 规则之前，否则末段 12 位会先被吃掉） |
| Commit Hash | ≥12 位、且至少含一个字母的十六进制串 | 删除；纯数字长串（订单号/时间戳）保留 |
| ANSI 转义 | `\x1b[31m` | 删除 |
| JSON 对象 | 同时含「冒号 + 引号」的 `{...}`（支持嵌套） | 删除；「{待办}」这类无引号文本不受影响 |
| 传输速度 | `12MB/s`、`1.5kb/s` | 删除 |
| 剩余时间 | `ETA`、`预计剩余`、`剩余时间` | 删除 |
| Emoji / 状态符号 | `✅`、`❌`、`🎉`、肤色修饰符 | 删除 |
| 箭头 | `→` | 替换为「到」 |
| 其余 ASCII 符号 | `_`、`=`、`@`、`&`、`<`、`>` 等 | 转空格，避免 `loadRefAudio_12` 粘成 `loadRefAudio12` 导致破音 |

保留的内容：版本号、API 名、函数名、百分比、品牌名（Codex、ChatGPT、OpenAI、iVox 等）、中文标点和语义文本。
各类空白（Tab / NBSP / 全角空格 / 连续半角空格）统一折叠成一个空格。

### 6. PlaybackQueue

`Sources/iVox/Audio/PlaybackQueue.swift`

- `actor` 保证线程安全
- **连续播放管道**：`processNext` 跨所有 job 循环，逐句合成→连续排队，句间不 drain，设备零停顿
- **轮次（turn）语义**：同一 `turnID` 的分块顺序 append 不打断；新 turn（用户发言）触发 `bargeIn`，取消在播 + 清空旧轮队列；**无 turn 的普通播报（`ivox speak` / hook.sh）只 append 排队，不抢麦**
- 流式轮次未结束（`turnOpen`）时队列排空就挂起等下一批，不恢复音乐；轮次结束排空后才收尾
- 打断只有两途径，且都源于**用户开口**：right⌘ 说话与 `hook.sh interrupt` 哨兵（提交即打断）都触发 `cancelAll()`（清空并取消全部 + 作废全部流式轮），或用户给 pi/dsh 发言时的新轮次 `bargeIn`；普通键/Esc/方向键不打断，**agent 回复到达时的普通播报也不打断（排队）**

### 7. MediaController

`Sources/iVox/Audio/MediaController.swift`

- 播放前调 iDict HTTP API → 暂停音乐
- 播放完调 iDict HTTP API → 恢复音乐
- 地址、暂停路径、恢复路径由 `mediaControl` 配置控制
- 不需要媒体控制时可设置 `mediaControl.enabled=false`
- 不依赖设备控制与数据访问权限

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

- 基于 `AVAudioEngine` + 单个常驻 `AVAudioPlayerNode`
- `scheduleBuffer` 连续排队，整条播报复用、句间不重启设备
- **高低水位背压**：已排队音频 >4s 暂停合成、降到 2s 放行
- prime 静音（50ms）只在设备真正播空 / 取消后补一次
- `drain()` 仅在整条管道末端调用一次（超时兜底，防回调丢失）
- `ensureHealthy()` 在写入前自检 engine/node，异常时重建

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
| 日志空 | daemon 是否在运行？`pgrep -fl "ivox serve"` |
| 日志有收到但没播放 | 代码签名失效？`codesign -dv ~/.local/share/ivox/runtime/iVox` |
| 日志有播放但没声音 | AudioPlayer 引擎异常？音量设置？扬声器？ |
| 播放完音乐没恢复 | iDict 是否运行？`curl http://127.0.0.1:8888/api/ping` |
| Hook 不触发 | settings.json / hooks.json 配置是否正确？Shell 权限？ |
| DSH 播报不触发 | `~/.dsh/profiles/desktop/plugins/ivox-tts.mjs` 在不在？`cordis.patch.yml` 有没有 `ivox-tts` 挂载？改完重启 dsh 了没？ |
| DSH 每次请求都在 prepare 阶段报错（如 auto-review REQUEST_EXTENSION） | `plugins/package.json` 匿名包缺失，原因见 [`dsh-tts.md`](dsh-tts.md) |
| DSH 念了过程话 / 播到上一轮 | 是否被改回「读 zstd 轮询」的老实现？正常实现只在 `agent/turn-stopping` 取该轮最后一条 `assistant/message` |

## 参考

- [架构总览](architecture.md)
- [CHANGELOG](CHANGELOG.md)
- iDict: https://github.com/xdfnet/iDict
- Qwen3-TTS: https://github.com/QwenLM/Qwen3-TTS
