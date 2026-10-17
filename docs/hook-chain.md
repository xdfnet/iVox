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
                    │   │  TTSEngine    │ │  ← MLX GPU 推理
                    │   │ synthesize()  │ │     Qwen3-TTS
                    │   └───────┬───────┘ │
                    │           ▼         │
                    │   ┌───────────────┐ │
                    │   │  AudioPlayer  │ │  ← 扬声器输出
                    │   │  scheduleBuffer│ │
                    │   └───────────────┘ │
                    └─────────────────────┘
```

## 各环节详解

### 1. AI 工具触发

| 工具 | 回复完成播报 | 配置位置 |
|------|-------------|----------|
| Claude Code | MessageDisplay → `hook.sh msgdisplay claude` | `~/.claude/settings.json` |
| Codex | Stop → `hook.sh speak codex` | `~/.codex/hooks.json` |
| pi 扩展 | `message_update` 流式（新轮排队，不打断） | `~/.pi/agent/extensions/ivox.ts` |

> ⚠️ **不再挂「提交即打断」钩子**：hook 类工具原先的 `UserPromptSubmit → hook.sh interrupt <source>`（发停止帧）已被移除/忽略——**打断权只归 ivox 快捷键**（右⌘ 说话 / Cmd+D 译文插队 / 手动三档：Ctrl+2 读下一页 · Ctrl+1 跳整摞 · Ctrl+Esc 掀桌）。在 Claude Code 里提交、后台 agent 轮次、pi 新轮均不再打断当前播报，只排队等播全再播。`hook.sh` 也已**移除 interrupt 分支**（手动打断改由命令行 `ivox skip` 承担）。

Claude Code 的播报**只走 `MessageDisplay`**（`hook.sh msgdisplay claude`）：assistant 消息流式显示时按行批触发、取 `delta` 增量逐句播，final 批含完整结尾，故不再挂 `Stop`（否则与 MessageDisplay 同播重复）。Codex 仍用 `Stop`（payload 自带 `last_assistant_message`，Codex 无 MessageDisplay 事件就只能终了一次）。

### 2. Hook 脚本

`~/.config/ivox/hook.sh`

播报模式：

- **`hook.sh msgdisplay <source>`（MessageDisplay，Claude Code 交互会话主路径）**：assistant 消息流式显示时按行批触发，`delta` = 自上一批以来新完成的整行文本。**必须极快返回**（Claude Code 等本钩子返回才渲染该批），故 delta 提取 + 审计用单个 python、播报用后台 `&`。走 `ivox speak --source <source> <text>` 排队入队，过程内容（分步/工具多段）逐句播报；最后一条 assistant 即完整结尾。空/过短纯西文 delta 不播。
- **`hook.sh speak <source>`（Stop / ivox speak 场景）**：从 stdin JSON 提取 `last_assistant_message`。调用 `ivox speak` 后台运行，不阻塞 AI 工具。
  - 注：Claude Code 交互会话现有配置**只挂 `MessageDisplay`**（不再挂 Stop），因 MessageDisplay 的 final 批已含完整结尾、与 Stop 同播会重复；`speak` 模式保留给其他工具/手动 `ivox speak`。

> **`interrupt` 分支已从 hook.sh 移除**——打断权只归 ivox 快捷键（右⌘/Cmd+D/Ctrl+Esc/Ctrl+1/Ctrl+2）与命令行 `ivox skip`（同三档），不再经 hook.sh 自动打断（UserPromptSubmit 亦不挂）。

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
| 路径 | 绝对/家目录路径（`/Users/...`、`~/...`）、多段相对路径（`Sources/iVoxKit/TextCleaner.swift`） | 只保留文件名（`TextCleaner.swift`）——念文件名有用，念整条路径没用 |
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

`Sources/iVox/Playback/PlaybackQueue.swift`

- `actor` 保证线程安全
- **连续播放管道**：`processNext` 跨所有 job 循环，逐句合成→连续排队，句间不 drain，设备零停顿
- **轮次（turn）语义**：队列**按轮排队，播全播完**——同一 `turnID` 的分块并入同一段顺序 append；新 turn 在队尾追加新段（`enqueue` 的新 turn / `beginTurn`），**不再 bargeIn**；**无 turn 的普通播报（`ivox speak` / hook.sh）也独立成段排队**。`processNext` 播完队首段才前移。（容器与游标见 [playback/queue.md](playback/queue.md)：一段 = 一摞，游标指向当前块但不把它弹出容器。）
- 某段 sealed（`sealTurn` / `Stop` 的 `finishTurn` / 宽限的 `sealIdle()` 标记）才允许空段前移；流动中（未 sealed）空段挂起等下一批，不封口；全部段都封且空才收尾（收字幕，打「播报收尾」）。**收尾主力是 `Stop` 钩子**（按 `session_id` 反查出 turn_id 精确收）；**空闲宽限**兜底：先等设备把已排队音频播完，再最多等 2 秒，等不到新块就判「这一摞说完了」。
- 用户快捷键共 **5 个入口**（手动打断三档 + 插队 + 说话），每个带**来源**标识：
  | 用户动作 | 入口 | 来源 |
  |---------|------|------|
  | 说话 | right⌘ / right⌃ → `cancelAll` | `speech` |
  | 划词翻译 | Cmd+D → `speakUserInitiated`（掐在播 + 译文进加急段插到最前，其余段全保留）；另有 `{now:1}` / `ivox speak --now` 同一条路 | `dict` |
  | 掀桌 | Ctrl+Esc → `cancelAll` | `esc` |
  | 跳整摞（中） | Ctrl+1 → `skipCurrentBucket` | `skip` |
  | 读下一页（轻） | Ctrl+2 → `skipCurrentPage` | `skip-page` |
  这个标识与 `PlaybackJob.source`（这段播报是谁发的）成对——前者回答「谁在说」，后者回答「这次是谁打断的」。**Claude 的 `Stop` 钩子只作「收尾信号」**（`hook.sh end`：丢弃 payload、不发一个字，只让队列收尾当前摞）——当年摘它是因为它连正文一起送、与 MessageDisplay 重复播两遍，现在这条不出声。以下讲的是**旧的停止帧**：**`{type:stop}` 已完全失效且无发送方**（`hook.sh interrupt` 已摘、`ivox quiet` 已删），daemon 收到只记日志忽略、不再打断（这一支留作护栏：它走正文分支，删掉会把旧脚本发来的帧当内容念出来）。流式新轮（pi）不再顶替——排队。Escape 放弃自己那轮（`cancelTurn`）只删该轮自己那段，不占打断来源。**agent 回复到达时一律排队，不抢麦**。

### 7. MediaController

`Sources/iVox/MediaControl/MediaController.swift`

- **本地直接控制**：`MRMediaRemoteSendCommand`（播放 / 暂停 / 切歌）与 `CGEvent`（音量 / 静音 / 方向键 / 锁屏）
- **只给麦克风让路**：语音输入按下 `pause()`、松手 `resume()`（录音要干净，音乐会串进麦克风）。**播报不再经由它**——播报不碰背景音乐
- 不需要媒体控制时可设置 `mediaControl.enabled = false`
- 只有 play/pause/next/prev 免权限；音量 / 静音 / 方向键 / 锁屏要「设备控制与数据访问」（`MediaHTTPServer` 对这几个动作会做权限校验）

### 8. TTSEngine

`Sources/iVox/Playback/TTSEngine.swift`

- 调用 MLX 本地模型：Qwen3-TTS-12Hz-1.7B-Base-8bit
- **纯本地推理，不上传任何数据**
- 流式生成 PCM chunk，间隔由 `tts.streamingInterval` 控制
- 按模型采样率重采样到 `tts.outputSampleRate`，再转为 int16 PCM

Qwen3-TTS 不支持特殊标签（如 `<laughter>`），情感通过文本语义和标点控制。

### 9. AudioPlayer

`Sources/iVox/Playback/AudioPlayer.swift`

- 基于 `AVAudioEngine` + 单个常驻 `AVAudioPlayerNode`
- `scheduleBuffer` 连续排队，整条播报复用、句间不重启设备
- **高低水位背压**：已排队音频 >4s 暂停合成、降到 2s 放行
- prime 静音（200ms，即 `sampleRate / 5`）只在设备真正播空 / 取消后补一次
- `drain()` 仅在整条管道末端调用一次（超时兜底，防回调丢失）
- `ensureHealthy()` 在写入前自检 engine/node，异常时重建

### 10. 日志

`~/.config/ivox/daemon.log`

关键追踪点：

```
Socket 接入: fd=22 bytes=1791             # ConnectionHandler 收到连接
请求解析: source=claude voice=taozi       # 解析出来源与音色
队列入队: source=claude … 分块=13          # 入队
队列状态: pending=13 processing=false     # PlaybackQueue 状态
TTS 合成开始 [claude-B5AAC5] chars=11     # 开始合成（带批次号）
TTS 合成完成 [claude-B5AAC5] 2.2s         # 本句合成完
打断（来源=esc）：取消在播、清空队列…     # 快捷键打断（speech/esc/dict 之一）、作废管道序号
TTS 合成已取消（打断来源=esc）             # 引擎底层取消也能对上同一来源
TTS 合成作废（MLX 不响应中途取消…）[…]（打断来源=esc）  # 被掐的这句跑完但已作废
播放收尾完成: 尾音=0.8s                    # 整轮播完
```

打断来源与播报来源成对地出现在日志里：`TTS 合成开始 [<source>-<batch>]` 回答「谁在说」，`打断（来源=<origin>）` 与 `TTS 合成已取消/作废（打断来源=<origin>）` 回答「这次谁掐的」。`<origin>` 只可能是 `speech` / `esc` / `dict`（用户快捷键）——`stop:…` 停止帧与 `turn:…` 新轮已不再是打断来源，前者收到即忽略、后者只排队。

## 代码签名

macOS 要求所有可执行文件有效签名。iVox 的开发签名证书 Hash：

`4A287668E97BC130AA6D19F4D64799394CAACBAD`

签名命令：

```bash
codesign --force --sign 4A287668E97BC130AA6D19F4D64799394CAACBAD ~/.local/share/ivox/runtime/iVox
```

**注意**：`make update` 会重新编译二进制并 ad-hoc 重签（`runtime.sh deploy-bin`），签名变了 TCC 权限可能要重勾。

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
| 播完字幕不收 / 队列不判收尾 | 日志里有没有「播报收尾: 队列已空，字幕收起」；Web 服务在不在 `curl http://127.0.0.1:8888/health` |
| Hook 不触发 | settings.json / hooks.json 配置是否正确？Shell 权限？ |

## 参考

- [架构总览](architecture.md)
- [CHANGELOG](CHANGELOG.md)
- iDict: https://github.com/xdfnet/iDict
- Qwen3-TTS: https://github.com/QwenLM/Qwen3-TTS
