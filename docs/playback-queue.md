# PlaybackQueue 状态机与场景矩阵

> ⚠️ **部分内容已过时**：下文围绕 `skipCurrent()` 与「↓ 键跳段」的状态矩阵，在改为「真人对话」打断模型后**该方法与 ↓ 键已整体删除**。随后**打断权进一步收紧**：只保留用户快捷键（手动打断三档：Ctrl+2 读下一页 · Ctrl+1 跳整摞 · Ctrl+Esc 掀桌；Cmd+D 译文改为**插队**——只掐在播、不清场），`stop` 停止帧与流式新轮顶替均不再打断（队列改为**按轮分桶排队、播全播完**）。（注意：现行的 Ctrl+1 / Ctrl+2（`skipCurrentBucket` / `skipCurrentPage`）与下文历史里的 `skipCurrent` 是两回事，后者已随 ↓ 跳段一并删除。）媒体命令源头唯一、连续播放管道等原则仍有效；凡出现 ↓ / skipCurrent 的小节请视为历史记录，打断相关表述以本行下方的最新版为准。

> PlaybackQueue 是 iVox 的 TTS 播放调度核心（actor）。本文档固化其媒体控制的状态转移规则，防止后续修改重新引入 race。

## 概念（术语表）

讨论播报**只用这四个词**。其它说法（"assistant"、"一句"、"一段"）都会造成误解——历史上我们就在这些词上反复对不上。

| 概念 | 是什么 | 谁划分的 | 系统里的身份 |
|---|---|---|---|
| **摞** | **一次回复**：你发一条信息 → AI 答一次 | **你按下回车**那一刀 | `turn_id`（Claude 的 MessageDisplay 每批都带） |
| **页** | 一摞里"说了一段"的一次 | Claude 流式显示，按行批触发 | `message_id` |
| **块** | 1～80 字的**合成单位**（**纯内部**）：页上的文字被切开、送去合成的最小粒度 | iVox 自己切（`cleanText → splitSentences`） | `PlaybackJob` |
| **桶** | 队列里的**排队单位** | PlaybackQueue | `QueueBucket` |

**一摞 = 一桶。**（pi 的一轮 = 一桶；一次普通播报 `ivox speak`/hook = 一桶；只有 Claude 这条通路是"一摞 = 一桶"。）

### 上下关系

```
一摞（= 一桶）        一次回复                    ← 你按回车划分
 ├─ 页               一个 MessageDisplay
 │   ├─ 块           内部撕下来合成播放的一条
 │   └─ 块
 └─ 页
```

### 读法

手里捏着队首那一摞 → 翻到当前页 → **撕下一个块**去合成播放 → 这页撕完翻下一页 → 这一摞说完（下一条回复到来把它盖上）→ 换下一摞。

### 按键对应哪一层

| 键 | 单位 | 干什么 |
|---|---|---|
| **Ctrl+2** | **页** | 这一页剩下的不念了，**翻下一页** |
| **Ctrl+1** | **摞**（= 桶） | 整摞不要了；它后面还没到的页也不会再开口 |
| **Ctrl+Esc** | 全部 | 掀桌，音乐回来 |

### 作废的旧说法

- ~~"assistant"~~ —— 一会儿指"一次回复"、一会儿指"一路会话"，混乱就是从这儿来的。**说"摞"**。
- ~~"一叠 = 一轮、一张 = 一句"~~ —— 旧比喻，层级对不上。**现在是：一摞 = 一次回复、一页 = 一个 MessageDisplay，块只是内部的条**。
- ~~"跳这句"~~ —— 实现里没有"句"这个单位（块可能含好几句话，也可能是半句）——**说"页"**。

## 核心原则：媒体命令源头唯一

`media.pause()` / `media.resume()` 命令只能从**两处**发出，其他路径一律不允许：

| 命令 | 发出位置 | 触发条件 |
|------|---------|---------|
| `media.pause()` | `processNext` 入口 | 每次管道启动 |
| `media.resume()` | `processNext` 退出且队列空（`jobs.isEmpty && gen==generation && !turnOpen`）| 自然完成 / daemon 退出 |
| `media.resume()` | `pumpOrResume()`（`endTurn`/`cancelAll`/`resumeIfIdle` 收尾）| 无管道且队列空时的收敛兜底；有活则改为补起管道 |

`catch CancellationError` 分支**不发**任何 media 命令（只清本地状态）。`media` 状态由 PlaybackQueue 统一管理，避免多分支并发发出命令造成 resume↔pause 竞态。

## 连续播放管道（常驻 node + 背压 + turn 保活）

> v3.6 改造，修复流式短句「一个字一个字蹦」。旧实现每个 job 独立 `generateStream → write → await drain()`，句间播空后重置 `needsPrime`、下一 job 重补 50ms 静音并重排调度——等于把连续语音流每句掐断。对照 ai-stack（Python `sounddevice.OutputStream` 常驻 + `queue(maxsize=16)` + 阻塞 write），改为一条跨 job 的常驻管道。

**AudioPlayer（`AudioPlayer.swift`）**

- 整条播报复用同一个 `AVAudioPlayerNode`，分块连续 `scheduleBuffer` 排队，设备从不在句间重启。
- **两级流水线（v3.6.2）**：合成（producer）与播放（consumer）拆成两条 Task，中间用 `AsyncStream<Data>(.unbounded)` 接 PCM。播放侧 `write()` 的背压只阻塞 consumer，**不再反压卡住下一句合成**——旧的「合成→write 串行」在 write 等 4s 高水位时连带阻塞下一句合成，是句间卡顿根因。真正的预取上限上移到 producer 句间的 `awaitPrefetchCapacity()`（见下条），unbounded 流只承接这「领先一两句」的提前量。
- **两套独立门控、阈值不同**：
  - **预取门控（给 producer 用）**：排队音频超 4s 高水位就先别开下一句合成，**回落到高水位即放行**（保持厚垫），绝不等低水位——否则下一句合成（约 3~5s）期间会欠载断句。
  - **write 背压（给 consumer 用）**：超高水位挂起、降到 2s 低水位才放行。
- 两者都用**等待者数组**而非单一 continuation 槽：密集打断时新旧管道的 writer/producer 会短暂同时在场，单槽会被后到者覆盖、先到者的 continuation 永不 resume（`SWIFT TASK CONTINUATION MISUSE ... leaked`）。每个挂起者独立入数组，唤醒时全 resume，谁也不覆盖谁。
- **write 世代守卫**：`write` 入场时在 serialQueue 上快照 `generation`，背压醒来后重新校验；若已被 `cancelPendingPlayback`（bargeIn 递增世代）作废，直接 return、**绝不碰 node/prime**，避免新旧管道两个 writer 争用同一播放节点（曾表现为打断瞬间两次 prime）。⚠️ 这是「**进入时才取世代**」：作废之后**新进来的** `write` 会取到新世代、照样通过校验——所以消费侧必须自己逐块比对 `pipelineSeq`（见 `processNext` 条目），否则旧轮已缓冲的 PCM 会一路排进播放器：表现为**打断后旧音频照念、新轮卡在 `awaitCurrentPipelineFinished` 干等**（pi「收到新消息，没打断」的根因，实测旧管道要多灌 8.7s 才退）。
- **设备断流看门狗 `recoverIfDeviceStalled()`**（serialQueue 上 1s 一跳自续，`stop()` 后停跳）：背压等待**只能**由 `onConsumed` 唤醒、`ensureHealthy()` 又只在「进入等待**之前**」检查——蓝牙音箱断流 / 设备被系统挂起时 `dataConsumed` 回调不再触发，writer 就永久挂起：整条管道卡死（`/health` 恒 `playing=true`）、此后所有播报一律哑掉，只能靠一次打断解救（蓝牙输出下实测必现，日志里只有「前导静音已调度」再无下文）。判定：`pendingCount>0` 且连续 `stallGrace`（10s）无任何消费回调。处置：`rebuildEngine()` 重新激活设备、按「已丢」清掉排队 buffer 计数（`node.stop()` 本就已把它们丢出节点）、唤醒全部等待者，让管道继续灌后续 PCM 或收尾退出。正常消费是连续实时的，不会误判。
- **prime 静音只在「设备真正播空（`pendingCount==0`）/ `cancelPendingPlayback`」后做一次**（`needsPrime`），连续排队的句间不再触发。静音长度 200ms 并在排缓冲前显式 `node.play()`：系统音频电源管理会挂起长时间空闲（实测十几分钟）的 node，50ms 太短、首个音频 chunk 仍会被吞（「第一句开头没声」）。
- **`drain()` 只在整条管道末端调用一次**（等跨 job 尾音播完），句间不再 drain。
- 取消链：`write()`/预取挂起时，`cancelPendingPlayback()`/`stop()` 一定会 resume 全部等待者；旧世代者靠世代校验退出，同世代者靠 `Task.checkCancellation` 退出，不会永久挂住。

**PlaybackQueue.processNext（`PlaybackQueue.swift`）**

- producer：跨所有 job 的 `while !Task.isCancelled` 循环，逐句 `awaitPrefetchCapacity() → synthesizeStream → for await pcm { pcmContinuation.yield(pcm) }`，**句间不 drain**；consumer：`for await pcm { await player.write(pcm) }`，**每块先比对 `pipelineSeq`**——已被 bargeIn 作废就立即 break、绝不再灌 PCM（`write` 的世代校验拦不住作废后新进来的调用，见上文 AudioPlayer 的世代守卫）。
- **尾音不丢（v3.6.2 关键修复）**：producer 正常结束时 `defer { pcmContinuation.finish() }`，consumer 的 `for await` 会把流里**仍缓冲着的最后一句多块 PCM 排空后自然终止**——因此正常路径**绝不能提前 `consumer.cancel()`**：此前 producer 一结束就 cancel，consumer 在下一块的 `isCancelled` 处 break，AsyncStream 里的尾音整块丢弃、drain 只等到已 schedule 的部分，表现为「内容没念完就恢复音乐」。只有整条任务真被 bargeIn 取消（`Task.isCancelled`）时才 cancel consumer 弃残余。
- **MLX 串行闸门 + epoch 作废（v3.6.2，修并发崩溃与废句雪崩）**：MLX 模型非并发安全，且 MLX 流不响应中途 Task 取消（一句发起后必须跑完）。`TTSEngine` 用单调世代闸门：第 N 代合成本须等第 N−1 代完全离开模型才进 `generateStream`，否则新旧推理并发砸同一模型触发 `Fatal error: expected a non-empty mlx_array vector.cpp:51`、daemon 崩溃；`bargeIn → cancelActiveSynthesis()` 额外递增 `epoch` 并唤醒所有 gate 排队者，旧 epoch 排队者放行后检查到纪元失配立即抛 `CancellationError`、**绝不进 MLX`**（不依赖 Swift 任务取消能否传播到内部 Task），密集连打下只让「恰好撞在推理中」的那一句跑完。
- **线性化点**：bargeIn 只 cancel 旧任务不清 `currentTask`；要立刻起新管道的调用方（enqueue/beginTurn）必须 `await currentTask.value`（`awaitCurrentPipelineFinished()`）等旧 producer+consumer **彻底退出**后才起新的，否则两个 consumer 并发 write 同一 player。
- 队列瞬时排空时：`turnOpen == true`（流式轮次还在生成）→ 挂起在 `waitForJobs()`（continuation 存入 `jobWaiters`），**不退出、不恢复音乐**；`turnOpen == false` → 退出循环 → consumer 排空 → 末端 drain → 恢复音乐。
- `signalJobs()` resume 并清空所有 `jobWaiters`，调用点只有：`enqueue`（新 job 到达）、`endTurn`（轮次结束）、`preemptCurrent`（打断/插队/跳桶的公共前置）。三者覆盖了挂起的全部唤醒路径，无 continuation 泄漏。
- 轮次语义（分桶排队）：**打断权只归用户快捷键**，手动打断三档——**轻** Ctrl+2 读下一页、**中** Ctrl+1 跳整摞、**掀桌** Ctrl+Esc（全场清）/ 右⌘ 说话；Cmd+D 译文走**插队**（`speakUserInitiated`：只掐在播、译文桶插到队首，其余桶全保留）。`stop` 停止帧与 pi 新轮**不再打断**播报。队列按到达序存桶（每桶一轮，nil-turn 桶=普通播报），`processNext` 播完队首桶才前移：**旧轮播全、播完才进下一轮**——这是「按轮排队」的载体。同 `turnID` 的分块并入同桶顺序 append；新 turn 在队尾追加新桶，不打断在播旧轮。
  **两类轮次**：`turnID`（pi 流式，走 `turnStack` 认证 + `endTurn`）与**弱分组**（Claude 的 MessageDisplay，`enqueueGrouped`，**刻意不进 `turnStack`**——那是 pi 双流认证专用，混进来会把「属主交还」判错、pi 整轮没声音）。弱分组的**分组号是 `turn_id`（一次回复 = 一摞）**，不是 `message_id`（一条 message = 一页）——一次回复夹工具调用就有好几页，按页分桶的话 Ctrl+1 只能跳掉一页。**收尾判据 = 「新的 turn 来了就把上一个盖上」**，不挂 `Stop`、不用定时器；页级 `final` 只说明"这页说完"，认不得"整摞说完"，所以不拿它收尾。**已知代价**：多个来源交错时会**互相盖**（实测：一条真实回复与另一组测试交错，两边互相收尾）→ 那一摞可能被拆成几个桶、Ctrl+1 跳不干净；单个来源（日常）不触发。`skipCurrentBucket` 按轮丢**该轮的全部桶**——弱分组下一轮可能散在几个桶里，只弹队首会留下残部继续念。
- **播报字幕（可选）取「播放侧」而非合成侧**：每句的**首块音频**捎上该句文本（`AudioChunk.sentenceText`），`AudioPlayer` 在它被设备读出（`.dataConsumed`）时回调 → 队列转发给 `onCaption`。合成领先播放一两句，**从合成侧取会让字幕比声音早**（实测踩过，飞哥听出来了）；播放侧取则与声音对齐（误差约一个 IO 缓冲）。打断天然正确——被掐掉的句子的回调本就过不了世代校验；整队播完 / 掀桌（`bargeIn`）广播 `nil` 收起。
- **三档打断的形象说法**（跟实现**同构**，动这段代码前先读它）：
  把播报想成一个**播音员 + 一叠叠稿纸**——**一叠 = 一桶 = 一轮话**（一次 AI 回复、一批普通播报、一条译文，各是一叠），**一张纸 = 一句**。
  要紧的是：**正在念的那张纸已经拿在手里、不在叠里了**（实现上就是 `popFrontJob` 把它弹出桶的那一刻）。
  - **轻（Ctrl+2）= 这一页剩下的不念了，翻页** → 从下一页的第一块接着念。实现：`preemptCurrent` 掐在播 + 丢掉桶里属于当前页的剩余块（`playingPageID` 是靶心），其余页的块原样留着
  - **中（Ctrl+1）= 整叠都不要了** → 连还没印出来的也不印（该轮后续分块立墓碑），直接拿下一叠。实现：`skipCurrentBucket`
  - **掀桌（Ctrl+Esc）= 把桌上所有稿纸全扫到地上** → 一声不响、音乐回来。右⌘ 说话同理：你要开口了，全场让路。实现：`cancelAll`
  - **Cmd+D 译文 = 不抢别人的叠，只把译文这张插到最上面** → 掐掉手里正念的那张让它先响，其余叠一张没动。实现：`speakUserInitiated`
- **⚠️ 调用顺序必须先于状态判定：连接内的四个操作要按帧序落地**（`ConnectionHandler.StreamOpChain` 串成一链）。`{type:stream}` 首帧、每个入队块、`{end}`/`{cancel}` 原先各自 `Task {}` 投递到本 actor，**落地顺序全凭调度器**。实测 `{end}` 的 Task 抢在同一连接后一个入队 Task 之前执行：`endTurn` 已把轮次关闭（`turnOpen=0`），迟到的**同轮** `enqueue` 走同轮分支又把它打开，而此时再无帧可关它——分块全部播完后管道永久停在 `waitForJobs()`：`/health` 恒 `playing=true`、`queued=0`、无「播放收尾完成」，而**两把兜底都够不着**（背压看门狗要求 `pendingCount>0`，此刻已 0；drain 还没轮到）。黑盒 A-tail / E3 用例的「未收尾」即此，现场探针原始顺序为 `enqueue(open=1) → endTurn(open=0) → enqueue(open=1)`，6 秒后进入永久挂起。
- **轮次身份靠「轮次栈 + 墓碑」判定**（`turnStack` / `deadTurns`），**消费靠「队首桶」**：
  - **`turnStack` 只做 pi 双流的空流 `{cancel}` 认证**（回答「这个 turnID 是不是合法新轮、属主该不该交还」）；**`currentTurn` 是消费视角 = `frontBucket?.turnID`**（队首待播桶的轮），二者解耦、正交。非当前桶的迟到帧静默 return。
  - **`{cancel}` 的轮出栈**：被取消的轮没有内容需要保护，属主交还给被它顶掉的那一轮。**这条是 pi 「整轮没声音」的修复关键**：pi 一个用户消息会开两条流、其中一条刚开就被 `{cancel}`，而承载正文的是先开的那条——若取消的轮继续占着栈顶，正文那条就被永久判成过期旧轮、整轮哑掉。
  - **墓碑 `deadTurns`**：`{cancel}`、用户开口（`cancelAll()`）、Ctrl+1 跳过（`skipCurrentBucket`）之后该轮不再开口，含客户端关闭连接后 EOF 兜底补出的残尾。容量 64，防止无限增长。
  只判「不等于 currentTurn」是不够的：那会把新轮的首帧和旧轮的迟到帧混为一谈；只按「见过没见过」判也不行：会把**并行那条空流**的取消算到真正在跑的轮头上。
- **`cancelAll()` = 「全场闭嘴」的语义：停当场 + 作废全部流式轮**（`buryAllTurns()` + `bargeIn()`）。调用方只有右⌘（`speech`）与 Ctrl+Esc（`esc`）。**`{type:stop}` 停止帧已完全失效**（hook.sh interrupt / ivox quiet 不再打断），收到时 ConnectionHandler 仅记日志忽略。`turn` 顶替也不再经 bargeIn——新轮排队。
- **「掐在播」与「清场」拆成两层**：`preemptCurrent` 只作废管道代号 + 取消在播合成与已排队音频，**不动 `buckets`**；`bargeIn` 则是「先 `removeAll()` 再调它」= 掀桌。由此派生三个「只掐不清」的入口：
  - **Cmd+D 念译文 = 插队**：`speakUserInitiated` = `preemptCurrent(.dict)` → 等旧管道退净 → 译文桶 `insert(at: 0)` **插到队首**。其余桶一个不丢，播完译文接着播（若想连当前桶一起丢，那是 Ctrl+1 的语义）。
  - **Ctrl+1 = 跳整轮（中档）**：`skipCurrentBucket` = 给当前轮立墓碑（`bury`，该轮后续分块也不再开口）→ `preemptCurrent` → 丢队首桶 → `pumpOrResume()` 接着播下一桶；没有下一桶则收尾恢复音乐。
  - **Ctrl+2 = 读下一页（轻档）**：`skipCurrentPage` = `preemptCurrent` → 丢掉桶里 `pageID == 当前页` 的剩余块 → `pumpOrResume()`。**页号要在 claim 时记进 `playingPageID`**——正在念的那块早已弹出桶，光看桶认不出它属于哪页；页号为 nil（非 Claude 路径）时退化成「只掐在播」。
- **`pipelineSeq` 代号作废在途管道（修「旧 producer 消费新轮任务」）**：`Task {}` 是结构化外的子任务，**不继承取消**——`bargeIn` 的 `currentTask?.cancel()` 根本停不住已进 MLX 的 producer。故 `bargeIn`/`shutdown` 递增 `pipelineSeq`，producer 每轮循环、consumer 每次循环都比对「代号是否仍是自己的」，不等即立即退场。`currentTaskSeq` 同理：管道收尾只在 `currentTaskSeq == 自己` 时才清 `currentTask`，防止旧管道把新起的管道清掉。
- **收敛兜底 `pumpOrResume()`**：轮次顶替时序可能留下「有 job 但没管道」的孤儿态。`endTurn`/`cancelAll` 收尾统一走它——无管道且有活就补起管道，否则才 `media.resume()`。任何路径结束都不会挂住。⚠️ **恢复归属**：管道自身收尾只在**未被取消**时恢复音乐，被取消的轮次由调用方补——所以 `pumpOrResume` 遇到「管道仍在退出中 + 已取消 + 无待播」时必须**等它退净再补恢复**，不能一律直接返回（`guard currentTask == nil else { return }` 的旧写法就是这样）：两边都不恢复，音乐永久卡在暂停。手动 `ivox quiet` 的停止帧恰好落在旧管道退出窗口时必现，且因为「没有恢复日志」，黑盒自检的收尾断言会一路等到超时（实测跑测时被别的会话打断即触发）。
- **`drain()` 超时定时器绑定自身序号 `drainSeq`**：超时兜底的 `asyncAfter` 闭包必须校验 `drainSeq == 自己`，否则**上一次 drain 遗留的定时器会提前放行下一次 drain**，表现为尾音被掐（曾实测 `drain 超时强制返回（pendingCount=28 尾音=1.12s）`）。
- **`removeFirst` 前必须双重校验**：门控挂起期间 `bargeIn` 会 `jobs.removeAll()`，醒来后直接 `removeFirst()` 会 `EXC_BREAKPOINT`。先 `guard let job = jobs.first`，弹出前再确认 `jobs.first?.text == job.text`（队首仍是自己读到的那个 job）。

## 状态机

```
                 ┌──────────────────────────────────────┐
                 │                                      │
                 ▼                                      │
   ┌─────────────────────┐    enqueue     ┌────────────────┐
   │   idle              │ ──────────────▶│  processing    │
   │ (jobs=[])           │                │ (jobs 累积中)   │
   │ (currentTask=nil)   │                │ (currentTask)  │
   │ media: 用户原始状态  │ ◀─────────────  └────────────────┘
   └─────────────────────┘   while 退出      │
        ▲                      + yield         │
        │                      + jobs 空       │ ↓ (jobs 非空)
        │                                      │
        │ skipCurrent                          │
        │ (jobs 空)                            │
        │ shutdown                             │
        └──────────────────────────────────────┘
                      media.resume()
```

## 场景矩阵

### 用户主动操作

| # | 场景 | 行为 | media 命令 | OK |
|---|------|------|-----------|----|
| 1 | 空闲 → enqueue | spawn processNext → pause → 播 | pause×1 | ✅ |
| 2 | 播放中 → enqueue | jobs 累积，while 自动取下一个 | 不发 | ✅ |
| 3 | 播放中 → ↓，队列非空 | 取消旧 task → spawn 新 → 播下一个 | pause×1（no-op） | ✅ |
| 4 | 播放中 → ↓，队列空 | 取消旧 task → resume music | resume×1 | ✅ |
| 5 | 空闲 → ↓ | `guard currentTask != nil` 拦截 | 不发 | ✅ |
| 6 | 播放中 → ⌘ 录音 | pause music + cancelAll TTS | pause×1（外部） | ✅ |
| 7 | 录音中 → ↓ | guard 拦截 | 不发 | ✅ |
| 8 | 录音中 → ⌘ | state guard 拦截 | 不发 | ✅ |
| 9 | ⌘ 松开 | resume music | resume×1（外部） | ✅ |
| 10 | daemon 退出 | cancel task + resume | resume×1 | ✅ |

### 内部状态转换

| # | 场景 | 行为 | media 命令 | OK |
|---|------|------|-----------|----|
| 11 | processNext 自然完成 | while 退出 → yield → 检查 jobs → resume | resume×1 | ✅ |
| 12 | processNext 被 ↓ 取消 | catch 分支只清本地状态 | 不发 | ✅ |
| 13 | TTS 合成失败 | catch error → 继续 while（直到成功或队列空） | 不发 | ✅ |
| 14 | 连续 ↓ 多次 | 每次都触发 skipCurrent | resume×0~1 | ✅ |
| 15 | processNext 退出 + 立刻 enqueue | yield 让 enqueue 插入 → 若 jobs 非空不 resume，由新 processNext 接管 | resume×0 / pause×1 | ✅ |

## 关键时序

### ↓ 按下（队列非空）

```
T0   processNext 播 job1，music 已暂停
T1   按 ↓
T2   skipCurrent: oldTask.cancel() + player.cancelPendingPlayback()
T3   _ = await oldTask?.value  ← 串行化点：旧 task 全部退出
T4   旧 task catch 分支：清本地状态、return（**不发 resume**）
T5   skipCurrent: jobs 不空 → 启动新 processNext
T6   新 processNext 入口 await media.pause()（no-op）
T7   新 processNext 播 job2
```

### ↓ 按下（队列空）

```
T0-T4  同上
T5   skipCurrent: jobs 空 → Task { await media.resume() }
T6   media 收到 play 命令 → music 恢复
```

### 自然完成 + 立刻 enqueue（场景 15）

```
T0   processNext while 退出（jobs 空）
T1   currentTask = nil
T2   await Task.yield()  ← 让 enqueue 有机会插入
T2.5 (可能的) enqueue 加新 job + spawn 新 processNext
T3   processNext 重新获得 actor：检查 jobs.isEmpty
       - false → 不 resume，新 processNext 入口 pause（接管）
       - true  → resume music
```

`Task.yield()` 是修复 race 的关键。它让 `enqueue` 在 `currentTask = nil` 之后、`media.resume` 之前有机会进入 actor，避免两个独立 Task 同时发 resume 和 pause。

## 修复历史

v2.7.0 期间发现并修复的 4 个问题：

| 问题 | 触发条件 | 修复 |
|------|---------|------|
| 媒体命令多源头竞态 | 旧 task catch 与新 processNext 入口同时发命令 | catch 分支不再发 resume，统一交给 skipCurrent / processNext 退出点 |
| 空闲按 ↓ 误发 resume | currentTask=nil 时仍走 resume 分支 | `skipCurrent` 加 `guard currentTask != nil` |
| daemon 退出 music 卡暂停 | shutdown 不发 resume | shutdown 末尾补 `Task { await media.resume() }` |
| 自然完成 + 立即 enqueue race | 老 resume 与新 pause 时序不可控 | processNext 退出前 `await Task.yield()`，yield 后再决策 |
| AudioPlayer.drain 永久挂起 | buffer 播放回调丢失（AudioEngine 被系统事件停止）→ `pendingCount` 永不归零 | `drain()` 加超时兜底：按本段已写帧数估算播放时长 + 2s 余量，超时强制返回并打 warn |
| cancel 后旧 buffer 回调污染计数 | skip/换段后旧世代回调触发 → `pendingCount` 减成负数（曾见 -772），drain 必走超时、账目失真 | `cancelPendingPlayback` 递增 `generation`，write 回调经 `guard generation == gen` 丢弃旧世代回调（v2.8.7） |
| 播放末尾 buffer 回调丢失（drain 超时） | `scheduleBuffer` 旧 API（无 `completionCallbackType`，`.dataPlayedBack` 语义）在引擎停止/auto-shutdown 时回调永不触发 → `pendingCount` 残留大值 | 改用 `completionCallbackType: .dataConsumed`，数据被读出即回调、不依赖引擎存活；drain 会提前最后一块 buffer 的播放时长返回，但 node 串行播放保证无缝衔接（v2.8.7） |

## 修复记录：AudioPlayer.drain 永久挂起（2026-08-01 修复）

> 已修复并移入上文「修复历史」表。保留分析过程备查。

### 现象

`processNext` 中 `await player.drain()` 永久不返回 → 播放队列被单个 job 卡死，后续请求全部排队，**只有按 ↓（跳到下一段）能解锁**。

### 日志证据（2026-08-01，daemon.log）

正常 vs 挂起（同为 22 字 test 文本）：

| 阶段 | 正常（14:11） | 挂起（16:07） |
|------|--------------|--------------|
| TTS 播放开始 | 14:11:17.248 | 16:07:16.111 |
| TTS 流式完成 | 14:11:18.883（42 chunk） | 16:07:17.797（43 chunk） |
| TTS 播放完成 | 14:11:20.815（+2s ✅） | 20:01:53.978（+4h，由 ↓ 触发） |

当天共 5 次挂起，均为 `source=test`：

```
test-52F1AC  14077.9s   ← 3.9 小时
test-60082B   5814.8s   ← 1.6 小时
test-7EB680   1099.8s   ← 18 分钟
test-65D2E4    129.2s
test-B53180     26.2s
```

挂起期间队列堆积到 `pending=14`，claude 播报最长延误约 4 小时（16:07:58 的播报 20:01:53 才播出）。

### 根因

`drain()` 依赖 `pendingCount` 归零（AudioPlayer.swift:60），而 `pendingCount` 只在 buffer 播放完成回调里 `-= 1`（AudioPlayer.swift:56-64）。一旦 node 中途处于非播放状态，**已排队的 buffer 完成回调全部丢失** → `pendingCount` 永不归零 → `drain()`（PlaybackQueue.swift:102）无超时地永久 await。

当天无 `AudioEngine 异常，尝试重建` 日志，排除 `ensureHealthy` 重建路径——属偶发回调丢失竞态。

### 影响

单个 job 卡死 → 整个播放队列阻塞。唯一解开路径是 `skipCurrent` → `cancelPendingPlayback()`（强制 `pendingCount = 0` 并 resume continuation）。

### 已实施修复

`drain()` 加超时兜底：按本段已写帧数 / 采样率 + 2s 余量计算超时，超时强制返回并打 warn（日志关键字 `drain 超时强制返回`）。回调丢失时队列仍能继续，不被单个 job 堵死。

### 维护约束

修复时注意：`cancelPendingPlayback()` 当前是唯一能解开挂起 drain 的路径（`node.stop` 会丢回调）；新增超时逻辑不要改变 `drain()` 在 `processNext` 中的调用语义（await 之后仍执行 `checkCancellation`）。

## 维护约束

修改 PlaybackQueue 时请遵守：

1. **不要在 `catch` 分支发任何 media 命令**——所有 `media.pause/resume` 都通过两个固定出口
2. **新增退出条件时只改 `processNext` 末尾的 `if jobs.isEmpty`**——决策点集中在一处
3. **新增触发点（如新快捷键）只走 `cancelAll` 或 `bargeIn`**——不要直接 `currentTask?.cancel()`（`skipCurrent()` 已随「↓ 跳段」一并删除）
4. **保持 `await oldTask?.value`**——这是串行化的线性化点，去掉会重新引入竞态
5. **`cancelPendingPlayback()` 会递增 `generation`**——write 回调经 `guard generation == gen` 丢弃旧世代回调；不要移除该 guard，也不要绕过 `cancelPendingPlayback` 直接清零 `pendingCount`，否则旧回调会把计数减成负数
6. **`scheduleBuffer` 必须带 `completionCallbackType: .dataConsumed`**——旧 API（不带 callbackType）是 `.dataPlayedBack` 语义，播放末尾引擎 auto-shutdown 时回调永不触发，会重新引入 drain 超时；`.dataConsumed` 在数据被读出即回调，不依赖引擎存活
7. **多条 job 一次性入队时走批量入口 `enqueue([PlaybackJob])`**——逐条 `await enqueue` 时，若两段之间队列瞬时为空，`processNext` 末尾的 `if jobs.isEmpty` 会提前 resume 音乐、下一段再 pause，表现为播报中音乐反复跳动（对应场景 15 的窗口）。批量入口先 append 完再启动处理，消除该窗口
8. **不要在 job 之间重新引入 `await player.drain()`**——句间接力靠 AudioPlayer 连续 `scheduleBuffer` 排队，逐句 drain 会播空设备、重补 prime、重启调度，重新引入逐字卡顿。drain 只允许出现在 `processNext` 末端一次
9. **新增 `waitForJobs()` 的唤醒出口时必须同步加到 `signalJobs()`**——turnOpen 下管道挂起在 `jobWaiters`，任何让它该醒来的事件（入队/结束/打断）都必须经过 `signalJobs`，否则 continuation 永久挂起
10. **背压水位（4s/2s）调整只改 `AudioPlayer` 的 `highWaterFrames/lowWaterFrames`**——高水位是内存上限也是合成预取上限（约 48kHz Int16 单声道 ≈ 384KB/4s），低水位须低于高水位以形成滞后区间，避免在阈值边缘反复挂起/放行
11. **弱分组只在 `enqueueGrouped` 里管，绝不要接进 `turnStack`/`claimTurn`**——`turnStack` 是 pi 双流「属主交还」的认证栈，混入别的 id 会让 pi 的正文流被判成过期旧轮（**整轮没声音**）。弱分组要的只有两件事：「同 group 并桶」和「墓碑拦住后续批次」，都不需要栈。跳桶时记得连墓碑一起立（`skipCurrentBucket` 已做），掀桌时记得把桶里的分组也立上（`buryAllTurns` 已做，它们不在 `turnStack` 里，不捞一遍就拦不住）
12. **流式连接的队列操作一律走 `ConnectionHandler` 的 `chain.hop {}`，不许直接 `Task { await queue.… }`**——顺序是协议语义的一部分（`{end}` 之后再无帧可关轮次）；裸 `Task {}` 落地乱序会让已关轮次被迟到分块重新打开，管道永久挂起（见上「按帧序落地」条）