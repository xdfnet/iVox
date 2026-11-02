# Hook 链路

从 AI 助手回复到耳朵听到声音的完整路径。

## 总览

```
┌─ Claude Code ─┐   ┌─ pi 扩展 ─┐
│ MessageDisplay│   │ 长连接流式 │
│（攒成整页一次）│   │ agent_start→agent_end │
└──────┬────────┘   └─────┬──────┘
       │  hook.sh          │  TS 扩展直连
       │ <source>          │
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
       │   PlaybackQueue     │  ← 排成一页页的队 / 调度 / 打断两档
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
| Claude Code | MessageDisplay → `hook.sh claude` | `~/.claude/settings.json` |
| pi 扩展 | `agent_start`→`agent_end` 一条流跨整次输入；**一条 assistant 消息 = 一页**，`message_end` 时整页一次发出（不逐字转发） | `~/.pi/agent/extensions/ivox.ts` |

> ⚠️ **不再挂「提交即打断」钩子**：hook 类工具原先的 `UserPromptSubmit → hook.sh interrupt <source>`（发停止帧）已被移除/忽略——**打断权只归 ivox 快捷键**（右⌘ 说话 / Opt+Z 译文插队 / 手动两档：Ctrl+1 掀页 · Ctrl+2 全掀）。在 Claude Code 里提交、后台 agent 轮次、pi 新页均不再打断当前播报，只排队等播全再播。`hook.sh` 也已**移除 interrupt 分支**（手动打断改由命令行 `ivox skip` 承担）。

Claude Code 的播报**只走 `MessageDisplay`**（`hook.sh claude`）：assistant 消息流式显示时按行批触发，hook 按 `message_id` **攒成整页**（`final=True` 那一批到齐才交出去），交由助理自己切句排队。一页早先被拆成十几批碎片依次入队，听着不像一页，队列顺序也被切碎（2026-10-19 改）。

⚠️ **不再挂 `Stop` 钩子**（2026-11-02）：队列里不再有「摞」，端也不再报告「这一轮说完了」——
**队列排空即收尾**。早先那条 Stop 收尾信号与正文赛跑，还害得最后一页被静默丢弃，整条拆掉了。
安装器不再挂新的 Stop 钩子；存量那条（`hook.sh end claude`）留着无害——hook.sh 只认来源
（`claude` / `wechat`），`end` 不在白名单里，静默退出。

### 2. Hook 脚本

`~/.config/ivox/hook.sh`

播报模式：

- **`hook.sh <source>`（MessageDisplay，Claude Code 交互会话主路径）**：assistant 消息流式显示时按行批触发，`delta` = 自上一批以来新完成的整行文本。hook 按 `message_id` 把各批正文追加进 `~/.config/ivox/pagebuf/`，`final=True`（这一页说完了）时把**整页**交给 daemon。**不带动作名**——收尾信号整条删除后只剩「搬一页」这一件事，再挂个 `msgdisplay` 的名字纯属多余。来源只认 `claude` / `wechat`，别的静默退出。**必须极快返回**（Claude Code 等本钩子返回才渲染该批），故攒页 + 审计用单个 python、播报用后台 `&`。走 `ivox speak --source <source> -- "<整页正文>"`，一次请求 = daemon 队列里的一页。空/过短纯西文 delta 不播。
  ⚠️ **`<source>` 优先取环境变量 `IVOX_SOURCE`**（`${IVOX_SOURCE:-$2}`）：微信链路的 claude 由 daemon spawn，注入 `IVOX_SOURCE=wechat` → hook 把来源标成 `wechat` → daemon 按 `[wechat] speak`（默认 false＝不念）裁决要不要播。hook 只标来源，不自己决定。
  ⚠️ **hook 里调 `ivox` 用绝对路径** `~/.local/bin/ivox`：hook 由 claude 拉起、继承 claude 的环境；微信侧 claude 继承 launchd 托管 daemon 的残缺 PATH（`/usr/bin:/bin:/usr/sbin:/sbin`），裸名 `ivox` 找不到 → 播报静默失效（2026-10-26 实测）。
- **旧的 Stop 收尾信号**：**已删除**——收尾信号整套没了（队列排空即收尾）。
  老配置里若还挂着 `hook.sh end claude`，它会被来源白名单挡掉，静默退出、不出声、不留痕。

Hook 脚本不清洗内容；文本过滤统一由 daemon 侧 `TextCleaner` 执行。脚本不传配置文件路径，daemon 固定读 `~/.config/ivox/config.toml`（`config.json` 是更早的遗留格式，已不再读取）。

### 3. ivox speak

`~/.local/bin/ivox`

- 解析 `--source` / `--voice` / `--now` 参数
- 拼装 payload：`{source:claude}整页正文`
- 写入 Unix Socket：`~/.config/ivox/ivox.sock`
- 退出（不等待播放完成）
- 本机 socket 通信，**无网络开销**

幂等：`ivox speak` 本身不依赖代码签名，但 CLI 二进制需要签名才能被执行（macOS Gatekeeper）。签名由 `make sign` 或手动 `codesign -f -s <HASH>` 维护。

### 4. Daemon 接收 (ConnectionHandler)

`Sources/iVox/Network/`

- 解析 payload 头：`{source:claude}` / `{voice:wanwan}`
- 如果文本前面有 `{source:claude}` 前缀且带额外内容，截取 `source` 和 `voice`
- 查 `playback.sourceVoices` 映射 → 确定音色 ID
- 调用 `cleanText()` 清洗 → `splitSentences()` 切句 → **一次请求 = 一页**入队（`enqueuePage`）

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
- **队列 = 页的 FIFO**（2026-11-02）：一页 = 一条 assistant 消息，页里装若干句（合成单位）。
  页按**到达顺序**排，谁都不插队；**没有轮次、没有分组、没有墓碑、没有收尾信号**。
  一次请求（Claude 的一整页 / pi 的一个长度帧）= 一页。（容器与游标见
  [playback/queue.md](playback/queue.md)：游标指向当前句但不把它弹出容器。）
- **收尾 = 队列排空**：等设备把已排队音频播完（声音真停下）→ 收字幕、还汽水音乐音量，
  打「播报结束: 队列已空，字幕收起」。**不需要端报「说完了」**，也没有空闲宽限。
- 用户快捷键共 **4 个入口**（手动打断两档 + 插队 + 说话），其中**两档手动打断**带**归因**（谁按的什么键、掀的是哪一档）：
  | 用户动作 | 入口 | 打断归因（日志里那一串） |
  |---------|------|------|
  | 说话 | right⌘ / right⌃ → `pausePlayback` / `resumePlayback`（**暂停不删**：设备闭嘴让麦克风干净，队列与内容一概不动，说完接着播） | 无（不是打断） |
  | 划词翻译 | Opt+Z → `speakUserInitiated`（播报暂停 + 译文走独立播放节点，念完从原处接着播；不进队列）；另有 `{now:1}` / `ivox speak --now` 同一条路 | 无（不是打断：译文走独立节点，队列内容一条不删） |
  | 全掀 | Ctrl+2 → `cancelAll` | `全掀·键盘 ctrl+2` |
  | 掀页 | Ctrl+1 → `skipCurrentPage` | `掀页·键盘 ctrl+1` |
  归因 = **档位 × 入口**（`InterruptOrigin`，见 `Sources/iVox/Playback/InterruptOrigin.swift`）：**档位只写一处**，由「调用哪个方法」决定（掀页的方法配了全掀的档位就是自相矛盾），别的层只负责把**入口**带下来。**入口有三种**：键盘（带**实际生效的键位**——键位可配，写死 "Ctrl+2" 就是句假话）、外部请求（`ivox skip` 发的 `{type:skip,…,by:ivox-skip}`，**请求方自报**身份；查内核里的对端 pid 不可靠——`ivox skip` 发完就退，帧到时进程早没了）、系统（退出清场）。接入方自己发的 `{cancel}` 记 `撤回来路·请求方 <source>`。
  这个标识与 `PlaybackJob.source`（这段播报是谁发的）成对——前者回答「谁在说」，后者回答「这次是谁打断的」。**旧的停止帧 `{type:stop}` 已完全失效且无发送方**（`hook.sh interrupt` 已摘、`ivox quiet` 已删），daemon 收到只记日志忽略、不再打断（这一支留作护栏：它走正文分支，删掉会把旧脚本发来的帧当内容念出来）。接入方放弃自己送来的那几页（`{cancel}` → `discardPages`）只撤它自己那几页，不掐在播、也不动别人的页。**agent 回复到达时一律排队，不抢麦**。

### 7. MediaController

`Sources/iVox/MediaControl/MediaController.swift`

- **本地直接控制**：`MRMediaRemoteSendCommand`（播放 / 暂停 / 切歌）与 `CGEvent`（音量 / 静音 / 方向键 / 锁屏）
- **只给麦克风让路**：语音输入按下 `pause()`、松手 `resume()`（录音要干净，音乐会串进麦克风）。**播报不经由它**——播报不改音乐的播放状态（播报期间压汽水音乐音量走 `SodaVolumeDucker`，改的是数值不是状态）
- 媒体控制**没有外部开关**：`mediaControl` 是代码内配置（`MediaControlConfig`），写在 `config.toml` 里会被配置审计点名说「写了不生效」
- 只有 play/pause/next/prev 免权限；音量 / 静音 / 方向键 / 锁屏要「设备控制与数据访问」（`MediaHTTPServer` 对这几个动作会做权限校验）

### 8. 誊清员 — 合成引擎（跨进程）

主进程侧 `Sources/iVox/Playback/TTS/TSPRemote.swift`，子进程侧同目录的 `TTSServer.swift` +
`TTSEngine.swift`（`ivox tts --serve`）。

- 模型：Qwen3-TTS-12Hz-1.7B-Base-8bit，**纯本地推理，不上传任何数据**
- **默认是另一个 iVox 进程**（Unix socket + `StreamFrame` 长度帧）——因为 MLX 崩了修不动，
  把会炸的那一层圈出去；`IVOX_TTS=local` 可退回进程内 `TTSEngine`，仅供调试对照
- `TSPRemote` 兼监督者：先问 socket 再问 child，断了自动重拉；崩溃验收见
  [`docs/playback/queue.md`](playback/queue.md)
- 流式生成 PCM chunk；间隔与输出采样率是**代码内配置**（`TTSConfig.default`：间隔 0.15 秒、输出 48 kHz），外部配置里没有 `tts` 段
- **句号 `seq` 是跨进程归因的主键**——两侧日志都打它，`~/.config/ivox/tts.log` 与
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
| `~/.config/ivox/hook.log` | `hook.sh` | 每批增量的审计行（截前 40 字）。超过 5M 轮转成 `hook.log.old`（旧文件被覆盖） |

崩溃现场：`crash.log`（主）/ `tts-crash.log`（誊清员），累计次数 `crash.count` /
`tts-crash.count`。`daemon.log` 的关键行：

> ⚠️ 段落里这些追踪点需要 `IVOX_LOG_LEVEL=debug` 才留得下（`Logger` 的级别门限）。

关键追踪点：

```
Socket 接入: fd=22 bytes=1791             # ConnectionHandler 收到连接
请求解析: source=claude voice=taozi       # 解析出来源与音色
队列入队: source=claude … 句=13          # 入队（一次请求 = 一页）
资料室收下：第7页 来源=claude 字数=180 句=13   # 页号由助理自编
队列状态: pending=13 processing=false 页=7     # PlaybackQueue 状态
TTS 合成开始 [claude-B5AAC5] seq=42 chars=11  # 开始合成（带批次号与句号）
TTS 合成完成 [claude-B5AAC5] seq=42 2.2s      # 本句合成完
打断（来源=全掀·键盘 ctrl+2）：取消在播、清空队列…   # 快捷键打断，作废管道序号
TTS 合成已取消（打断来源=掀页·键盘 ctrl+1）            # 引擎底层取消也能对上同一来源
TTS 合成作废（MLX 不响应中途取消…）[…]（打断来源=掀页·键盘 ctrl+1）  # 被掐的这句跑完但已作废
这页不要了，听下一页（来源=掀页·键盘 ctrl+1）：已掀 第7页 句=7   # 掀的是哪一页也报出来
播报结束: 队列已空，字幕收起             # 队列排空即收尾
```

打断来源与播报来源成对地出现在日志里：`TTS 合成开始 [<source>-<batch>]` 回答「谁在说」，`打断（来源=<origin>）` 与 `TTS 合成已取消/作废（打断来源=<origin>）` 回答「这次谁掐的」。`<origin>` = **档位·入口**（`掀页·键盘 ctrl+1`），三样都要说清：**掀的是哪一档**、**谁按的**、**按的什么**。键位**可配**，日志里打的是**实际生效**的那一组（与启动时「热键: skipPage = ctrl+1」同一份 `display`）。
命令行等价物 `ivox skip --page|--all` 走 socket 帧，自报身份 `by:ivox-skip` → `全掀·请求方 ivox-skip`；接入方自己发的 `{cancel}` → `撤回来路·请求方 <source>`。
`stop:…` 停止帧已不再是打断来源，收到即忽略。键位对照**以 `GlobalKeyTap.bindings` 与 `Daemon.setUpHotKeys` 为准**。

⚠️ **归因按管道代号记，不记「最近一次」**（2026-10-26）：一次打断作废的是**当时在跑的那条管道**，记成全局单槽会被后一次打断覆盖——先被掐的那条管道的合成日志会写成后一次打断的人（查错人比查不到更坏）。现在归因挂在管道自己的代号上，它回头查自己的。

## 代码签名

macOS 要求可执行文件有效签名。iVox 用的是**自签的长期身份** `iVox Local Signing`
（10 年有效，Apple 不会吊销），签名身份的选择顺序见 `scripts/runtime.sh` 的 `sign_bin`：
`IVOX_SIGN_IDENTITY` > 自签的 `iVox Local Signing` > 钥匙串里第一个有效证书 > ad-hoc 兜底。

```bash
codesign -dv ~/.local/bin/ivox 2>&1 | grep -E 'Signature|Authority|TeamIdentifier'
```

**为什么不用 ad-hoc**：ad-hoc 签名要求里含 cdhash（= 二进制内容哈希），每次重新构建内容就变、
要求就变 → macOS 的 TCC 授权（麦克风、输入监控）自动作废，表现为「重装后突然不灵」，
得回系统设置重新勾一遍。自签长期身份的 designated requirement 只含**证书指纹**，
重编译重签多少次权限都不掉（2026-10-21 实测：重编译重签后六项能力与三项权限全绿）。

> 证书与私钥备份在 `~/.config/ivox/signing/`（钥匙串重置后按那里的 README 恢复；
> 恢复后指纹仍是同一张 → 权限不用重勾）。将来若要把 iVox **分发给别人**
> （Gatekeeper / 公证），得换 Developer ID 证书——那时签名身份变了，权限会掉一次。
> `make update` 会自动重签。


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
