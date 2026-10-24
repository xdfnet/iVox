# Hook 链路

从 AI 助手回复到耳朵听到声音的完整路径。

## 总览

```
┌─ Claude Code ─┐   ┌─ pi 扩展 ─┐
│ MessageDisplay│   │ 长连接流式 │
│ Stop（收尾暗号）│   │  agent_start→agent_end │
└──────┬────────┘   └─────┬──────┘
       │  hook.sh          │  TS 扩展直连
       │ msgdisplay/end    │
       └────────┬──────────┘
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
       │                     │
       │   TextCleaner       │  ← 去代码噪音 + 切句（真源只此一份）
       │        ▼            │
       │   PlaybackQueue     │  ← 归拢成摞 / 调度 / 打断三档
       │        ▼            │
       │   TSPRemote ───────┼──→ ┌──────────────────┐
       │   AudioPlayer       │    │ 誊清员进程        │
       │   scheduleBuffer    │    │ (ivox tts --serve)│
       └─────────────────────┘    │  MLX 推理 + PCM  │
            ↑                     └──────────────────┘
            └── 扬声器               崩了由 TSPRemote 重拉
```

## 各环节详解

### 1. AI 工具触发

| 工具 | 回复完成播报 | 配置位置 |
|------|-------------|----------|
| Claude Code | MessageDisplay → `hook.sh msgdisplay claude` | `~/.claude/settings.json` |
| pi 扩展 | `agent_start`→`agent_end` 一条流跨整次输入，`message_update` 逐 `text_delta` 送（新轮排队，不打断） | `~/.pi/agent/extensions/ivox.ts` |

> ⚠️ **不再挂「提交即打断」钩子**：hook 类工具原先的 `UserPromptSubmit → hook.sh interrupt <source>`（发停止帧）已被移除/忽略——**打断权只归 ivox 快捷键**（右⌘ 说话 / Opt+Z 译文插队 / 手动三档：Ctrl+Esc 读下一页 · Ctrl+1 跳整摞 · Ctrl+2 掀桌）。在 Claude Code 里提交、后台 agent 轮次、pi 新轮均不再打断当前播报，只排队等播全再播。`hook.sh` 也已**移除 interrupt 分支**（手动打断改由命令行 `ivox skip` 承担）。

Claude Code 的播报**只走 `MessageDisplay`**（`hook.sh msgdisplay claude`）：assistant 消息流式显示时按行批触发，**攒成整页**（final=True 那一批到齐才交出去），交由助理自己切句排队。一页早先被拆成十几批碎片依次入队，听着不像一页，队列顺序也被切碎（2026-10-19 改）。

正文之外另挂 **`Stop` → `hook.sh end claude`**，只送「说完了」这个暗号、不出声——当年摘掉的是**连正文一起送**的那条 Stop（与 MessageDisplay 重复播两遍），不是「不许挂 Stop」。

**Claude 的 `Stop` payload 没有 `turn_id`**（2026-10-18 核实官方 hooks reference）：Stop 事件专属字段只有 `stop_hook_active` / `last_assistant_message` / `background_tasks` / `session_crons`，通用字段里是 `prompt_id` 不是 `turn_id`。所以收尾信号只能按 `session_id` 反查 msgdisplay 记下的那一摞；反查不到就不带 group，服务端退化成「收最后打开的那摞」。

### 2. Hook 脚本

`~/.config/ivox/hook.sh`

播报模式：

- **`hook.sh msgdisplay <source>`（MessageDisplay，Claude Code 交互会话主路径）**：assistant 消息流式显示时按行批触发，`delta` = 自上一批以来新完成的整行文本。**必须极快返回**（Claude Code 等本钩子返回才渲染该批），故 delta 提取 + 审计用单个 python、播报用后台 `&`。走 `ivox speak --source <source> <text>` 排队入队，过程内容（分步/工具多段）逐句播报；最后一条 assistant 即完整结尾。空/过短纯西文 delta 不播。
- **`hook.sh end <source>`（Stop 收尾信号）**：只送「这一摞说完了」的暗号，**不带正文、不出声**。作用是让队列立刻判收尾（字幕立刻回来），不必等空闲宽限那 60 秒。没有它也不会错，只是最后那几秒要等满。
  ⚠️ **收尾信号延后 300ms 再发**（2026-10-24）：Stop 与 MessageDisplay 是两次独立的钩子调用，谁先抵达 socket 并不保证——实测 27 轮里 14 轮 Stop 比正文早到 10~20 毫秒，于是**最后一页正文落在 Stop 之后、自成一摞**（用户按 Ctrl+1 想掀整轮，掀不到最后这页），字幕与汽水音量还会在中途收一次又起一次。延后一点让正文先落地，两条通路就按「先内容、后收尾」的顺序到。放在后台：钩子必须立刻返回，不能在这儿睡。

> **`interrupt` 分支已从 hook.sh 移除**——打断权只归 ivox 快捷键（右⌘/Opt+Z/Ctrl+2/Ctrl+1/Ctrl+Esc）与命令行 `ivox skip`（同三档），不再经 hook.sh 自动打断（UserPromptSubmit 亦不挂）。

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

- 解析 payload 头：`{source:claude}` / `{voice:wanwan}`
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
- 某段 sealed（`sealTurn` / `Stop` 的 `finishTurn` / 宽限的 `sealIdle()` 标记）才允许空段前移；流动中（未 sealed）空段挂起等下一批，不封口；全部段都封且空才收尾（收字幕，打「播报结束」）。**收尾主力是 `Stop` 钩子**（按 `session_id` 反查出 turn_id 精确收）；**空闲宽限**兜底：先等设备把已排队音频播完，再最多等 60 秒，等不到新块就判「这一摞说完了」。
  ⚠️ 60 秒不是随手取的（2026-10-24 从 5 秒改）：Claude 一轮里的多页之间常隔 20~130 秒（跑工具、想事情），5 秒的宽限几乎每轮都误判「说完了」→ 一轮被切成好几摞、字幕提前收、汽水音乐音量一升一降。宽限是**兜底**，常态判据是端自己的收尾信号（Stop / `{end}`）——它一到就立刻收，不等宽限。
  ⚠️ **收尾是终判**（2026-10-24）：收尾信号与正文是两条独立通路，谁先到没保证（实测只差 1 毫秒的情形也有）。收尾先到就把这一摞盖了印，后到的正文**不能**再把它揭回「还在说」——否则 `anyUnsealed` 恒为真 → 队列永不结算 → 字幕不收、汽水音量不还。收尾过的摞记在 `PlaybackSession.finishedTurns` 里，后到的正文**照念（一个字不丢）**但不再揭封。宽限封的印照旧可揭（宽限只是猜「说完了」，不是判死）。
- 用户快捷键共 **5 个入口**（手动打断三档 + 插队 + 说话），每个带**来源**标识：
  | 用户动作 | 入口 | 来源 |
  |---------|------|------|
  | 说话 | right⌘ / right⌃ → `pausePlayback` / `resumePlayback`（**暂停不删**：设备闭嘴让麦克风干净，队列与内容一概不动，说完接着播） | 无（不是打断） |
  | 划词翻译 | Opt+Z → `speakUserInitiated`（掐在播 + 译文进加急段插到最前，其余段全保留）；另有 `{now:1}` / `ivox speak --now` 同一条路 | `dict` |
  | 全掀 | Ctrl+2 → `cancelAll` | `esc` |
  | 掀摞（中） | Ctrl+1 → `skipCurrentBucket` | `skip` |
  | 掀页（轻） | Ctrl+Esc → `skipCurrentPage` | `skip-page` |
  这个标识与 `PlaybackJob.source`（这段播报是谁发的）成对——前者回答「谁在说」，后者回答「这次是谁打断的」。**Claude 的 `Stop` 钩子只作「收尾信号」**（`hook.sh end`：丢弃 payload、不发一个字，只让队列收尾当前摞）——当年摘它是因为它连正文一起送、与 MessageDisplay 重复播两遍，现在这条不出声。以下讲的是**旧的停止帧**：**`{type:stop}` 已完全失效且无发送方**（`hook.sh interrupt` 已摘、`ivox quiet` 已删），daemon 收到只记日志忽略、不再打断（这一支留作护栏：它走正文分支，删掉会把旧脚本发来的帧当内容念出来）。流式新轮（pi）不再顶替——排队。Escape 放弃自己那轮（`cancelTurn`）只删该轮自己那段，不占打断来源。**agent 回复到达时一律排队，不抢麦**。

### 7. MediaController

`Sources/iVox/MediaControl/MediaController.swift`

- **本地直接控制**：`MRMediaRemoteSendCommand`（播放 / 暂停 / 切歌）与 `CGEvent`（音量 / 静音 / 方向键 / 锁屏）
- **只给麦克风让路**：语音输入按下 `pause()`、松手 `resume()`（录音要干净，音乐会串进麦克风）。**播报不经由它**——播报不改音乐的播放状态（播报期间压汽水音乐音量走 `SodaVolumeDucker`，改的是数值不是状态）
- 不需要媒体控制时可设置 `mediaControl.enabled = false`
- 只有 play/pause/next/prev 免权限；音量 / 静音 / 方向键 / 锁屏要「设备控制与数据访问」（`MediaHTTPServer` 对这几个动作会做权限校验）

### 8. 誊清员 — 合成引擎（跨进程）

主进程侧 `Sources/iVox/Playback/TSPRemote.swift`，子进程侧 `TTSServer.swift` +
`TTSEngine.swift`（`ivox tts --serve`）。

- 模型：Qwen3-TTS-12Hz-1.7B-Base-8bit，**纯本地推理，不上传任何数据**
- **默认是另一个 iVox 进程**（Unix socket + `StreamFrame` 长度帧）——因为 MLX 崩了修不动，
  把会炸的那一层圈出去；`IVOX_TTS=local` 可退回进程内 `TTSEngine`，仅供调试对照
- `TSPRemote` 兼监督者：先问 socket 再问 child，断了自动重拉；崩溃验收见
  [`docs/playback/queue.md`](playback/queue.md)
- 流式生成 PCM chunk，间隔由 `tts.streamingInterval` 控制；按模型采样率重采样到
  `tts.outputSampleRate`，再转为 int16 PCM
- **块号 `seq` 是跨进程归因的主键**——两侧日志都打它，`~/.config/ivox/tts.log` 与
  `daemon.log` 用它对时间线

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

**三份，各归各的角色**（分家是有意的：出事时「哪个文件里有现场，就是哪个角色的错」）：

| 文件 | 谁写 | 看什么 |
|---|---|---|
| `~/.config/ivox/daemon.log` | 主进程 | 队列状态、打断、播放收尾（>5M 轮转） |
| `~/.config/ivox/tts.log` | 誊清员 | 合成侧；某一块怎么没出来先看它 |
| `~/.config/ivox/hook.log` | `hook.sh` | 每批增量的审计行（截前 40 字）。⚠️ 只增不减、无轮转 |

崩溃现场：`crash.log`（主）/ `tts-crash.log`（誊清员），累计次数 `crash.count` /
`tts-crash.count`。`daemon.log` 的关键行：

> ⚠️ 段落里这些追踪点需要 `IVOX_LOG_LEVEL=debug` 才留得下（`Logger` 的级别门限）。

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
播放开始                                 # 首个块被设备读出（真的出声了）
播放结束: 尾音=0.8s                      # 声音停了
```

打断来源与播报来源成对地出现在日志里：`TTS 合成开始 [<source>-<batch>]` 回答「谁在说」，`打断（来源=<origin>）` 与 `TTS 合成已取消/作废（打断来源=<origin>）` 回答「这次谁掐的」。`<origin>` 只可能是 `speech` / `esc` / `dict` / `skip` / `skipPage`（全来自用户快捷键或其
命令行等价物 `ivox skip --page|--stack|--all`）——`stop:…` 停止帧与 `turn:…` 新轮已不再是打断来源，
前者收到即忽略、后者只排队。键位对照**以 `GlobalKeyTap.bindings` 与 `Daemon.setUpHotKeys` 为准**。

## 代码签名

macOS 要求可执行文件有效签名。iVox 用的是 **ad-hoc 自签名**（没有开发者证书）：

```bash
codesign --force --sign - ~/.local/bin/ivox
```

验证：

```bash
codesign -dv ~/.local/bin/ivox 2>&1 | grep -E 'Signature|flags'
```

期望 `Signature=adhoc`、`flags=0x2(adhoc)`、`TeamIdentifier=not set`——
**没有 TeamIdentifier 才是对的**，有反而说明签成了别的证书。

> ⚠️ **ad-hoc 签名的代价：每次重新构建重签，签名就变，macOS 的 TCC 授权（麦克风、
> 输入监控）可能随之失效**，表现为热键与语音输入毫无反应。遇到这种「重装后突然不灵」
> 先去系统设置重新勾一遍，而不是查代码。`make update` 会自动重签。


## 故障排查

| 症状 | 检查点 |
|------|--------|
| 日志空 | daemon 是否在运行？`pgrep -fl "ivox serve"` |
| 日志有收到但没播放 | 代码签名失效？`codesign -dv ~/.local/bin/ivox`（期望 `Signature=adhoc`） |
| 日志有播放但没声音 | AudioPlayer 引擎异常？音量设置？扬声器？ |
| 播完字幕不收 / 队列不判收尾 | 日志里有没有「播报结束: 队列已空，字幕收起」；Web 服务在不在 `curl http://127.0.0.1:8888/health` |
| Hook 不触发 | `~/.claude/settings.json` 配置是否正确？Shell 权限？ |

## 参考

- [架构总览](architecture.md)
- [CHANGELOG](CHANGELOG.md)
- iDict: https://github.com/xdfnet/iDict
- Qwen3-TTS: https://github.com/QwenLM/Qwen3-TTS
