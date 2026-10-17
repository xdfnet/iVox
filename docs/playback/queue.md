# 播报实现层

> **四层里的最后一份，只在要动代码时才读。** 它回答：**今天代码怎么写的、改它有什么坑。**
> 读法顺序：**目的层 → 接入方层 → 需求层 → 实现层（本文）**。有分歧先翻 [目的层](purpose.md)；
> 「必须做到什么」见 [需求层](requirements.md)。
>
> 本文只写**现状**。设计取舍归 [目的层](purpose.md)，需求场景归 [需求层](requirements.md)，
> 事故与历史复盘归 `../archive/`。本文与代码不符时**以代码为准**，但请顺手改本文。
> 改播报核心后跑 `make check-tts` 全量（黑盒自检，19 条用例）。

## 这一层最关键的两个设计决定

**① 游标不弹出容器。** 游标指向当前块但不把它取走，播完（或作废）才前移。容器因此永远包含
正在合成的那一块，掀页时它自然在被删范围内——不必靠 `pipelineSeq` 间接作废，也就没有
「当前在播哪一页」这个需要另外维护、且会陈旧的变量（2026-10-17 的陈旧靶心缺陷正是这么来的）。
**游标不能只存整数下标**：掀页会把整页删掉，下标全部失效，所以表示成 `(段序号, 页序号, 块序号)`，
删页后重定位到下一页第一块；没有下一页则落到下一段第一页第一块。

**② 由此带来的三处必处理**（改 producer/掀页路径时逐条对照）：

1. **合成失败/取消时游标必须前移**，否则卡在同一块死循环
2. **掀页后游标要重定位**：指向的块被删了，落到下一页第一块；没有下一页则落到下一段
3. **预取门控期间用户掀了这一页**：`awaitPrefetchCapacity()` 挂起期间容器被改动，醒来发现
   当前块已不存在 → 安全跳过。同类风险踩过（对空数组 `removeFirst` 曾致 `EXC_BREAKPOINT`），
   沿用「先读后弹 + 醒来复核」的做法

---

下面记的是**今天代码怎么写的**：连续播放管道、背压、管道代号、宽限、以及踩过的坑。
身份层是独立的 `PlaybackSession.swift`。个别条目会提到「桶 / playingPageID / `waitForJobs`」
等旧符号——它们描述的是 2026-10-17 重构前的形态，**只作为反面对照留着**
（说明某个坑是怎么来的、现在换成了什么），不是当前实现。

## 核心原则：背景音乐只归语音输入

`media.pause()` / `media.resume()` **只从一处**发出：`SpeechInputService`。

理由：背景音乐**只影响麦克风采集**——录音时它会串进去、干扰识别，所以录音必须让它停。播报**不需要**它让路。播报队列曾整套借还音乐（管道启动 pause、队列见底 resume），结果是"借了还、还了借"的抖动：Claude 的回复分批送来，批间停顿一超时就被误判成"说完了"而还音乐，下一批到又借走。**不借就不会乱**，故整条删除。

| 命令 | 发出位置 | 触发条件 |
|------|---------|---------|
| `media.pause()` | `SpeechInputService` 按下 right⌘/⌃ | 开始录音前（串行排在 `cancelAll` 之后） |
| `media.resume()` | `SpeechInputService` 松手 | 结束录音 |
| `media.resume()` | `PlaybackQueue.shutdown()` | **退出安全网**，与"谁借的"无关：兜住任何原因留下的暂停 |

`MediaController` 自带护栏：`resume()` 只对"我们发过的暂停"生效（`suspendedByUs`），你自己手动暂停的音乐它不碰。

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
- **线性化点**：掐只 cancel 旧任务不清 `currentTask`；**要立刻往播放器写数据的调用方**（掀页 / 掀摞 / Cmd+D 插队）必须 `await currentTask.value`（`awaitCurrentPipelineFinished()`）等旧 producer+consumer **彻底退出**，否则两个 consumer 并发 write 同一 player。**入队与收尾路径不需要这句**——它们只是「有活就起管道」，`startPipelineIfPending()` 见 `currentTask != nil` 就补不起，活交给旧管道退净后自己那轮 `pumpOrSettle()` 去做。
  ⚠️ 反过来说，`pumpOrSettle()` 里**绝不能** await 这句等旧管道退净：被掐的管道可能挂在 `player.drain()` 或预取背压的 continuation 上迟迟不退出，一等就把后面所有收尾逻辑（起宽限、收字幕）全带死（2026-10-17 `P3` 实测：队列已空、health 已空闲，两条收尾日志一条都没打）。
- **空闲宽限归身份层，不归管道**（2026-10-17 重构）：producer 发现「没有下一块了」就**直接退出管道**（不再挂在 `waitForJobs()` 上）。「还有摞没收尾」的等待由 `PlaybackSession.waitForContent()` 单独管，计时器是队列侧的 `graceTask`，**与管道死活无关**。旧形态把 2 秒计时器挂在管道循环里，于是「块被掀光、摞没收尾」时管道不起、计时器也没人跑——那一摞永远悬着、字幕收不掉（`P3` 实测挂死 47 秒）。
- **宽限的启动不要求「当前没有管道」**，也**排在「等旧管道退净」之前**：起它的判据只是「没有待播块、还有摞没收尾」，管道在不在、退出得干不干净都与它无关。
- **`signal()` 只在真有新内容时发**（入队、轮次开始/结束、掐的公共前置）。**删除路径（掀页、掀摞）不发**——`signal` 的含义是「来新货了，宽限不必再等」，掀页是在**删**东西，发了会让宽限误判「有新内容、别盖印」而作废，且作废后没有接班人（`P3` 实测在同一毫秒自唤醒）。
- **作废一轮宽限靠递增 `graceEpoch`，不靠 `cancel()`**：挂在 `withCheckedContinuation` 上的 Task 被 cancel **不会**解开 continuation，那个 Waiter 会永远留在等待表里，来几轮就把状态搅乱。`idleGraceElapsed` 收尾时若发现是被新一轮取代的 epoch，直接返回、**不去动别人的 `graceTask`**；若是被唤醒（来了新货），**必须再 `pumpOrSettle()` 一次**——那次起宽限可能正好撞上 `graceTask` 还占着而被挡，不补这一下就没人接班。
- 轮次语义（按段排队）：**打断权只归用户快捷键**，手动打断三档全是「掐 + 掀」——Ctrl+2 掐+掀当前页、Ctrl+1 掐+掀当前摞、Ctrl+Esc 掐+全掀 / 右⌘ 说话；Cmd+D 译文走**插队**（`speakUserInitiated`：只掐在播、译文段插到加急位，其余全保留）。`stop` 停止帧与 pi 新轮**不再打断**播报。容器按到达序存段（一段一轮，无分组段=普通播报），producer 播完队首段才前移：**旧轮播全、播完才进下一轮**——这是「按轮排队」的载体。同 `turnID` 的分块并入同段顺序 append；新 turn 在队尾追加新段，不打断在播旧轮。
  > 旧形态这里叫「桶」（`QueueBucket`），一摞散在几个桶里——那是实现语言，不是用户语言；现已并入 `PlaybackSession` 的「段」。
  **两类轮次**：`turnID`（pi 流式，走 `turnStack` 认证 + `endTurn`）与**弱分组**（Claude 的 MessageDisplay，`enqueueGrouped`，**刻意不进 `turnStack`**——那是 pi 双流认证专用，混进来会把「属主交还」判错、pi 整轮没声音）。弱分组的**分组号是 `turn_id`（一次输入引发的全部回复 = 一摞）**，不是 `message_id`（一条 assistant 消息 = 一页）——一摞夹工具调用就有好几页，按页分桶的话 Ctrl+1 只能跳掉一页。**收尾主力 = `Stop` 钩子**：按 `session_id` 反查出 turn_id 精确收尾（`finishTurn`，只盖印、**不立墓碑**——在途的页还要让它播完）。**空闲宽限兜底**：见底又仍有没收尾的摞，先等设备播空（`waitUntilQuiet()`：声音真停下才算起点），再静候 2 秒（`idleGraceSeconds`），等不到新内容就由 `PlaybackSession.sealIdle()` 判说完（同样只盖印、不立墓碑，之后来页会揭封续播）。页级 `final` 只说明"这页说完"，认不得"整摞说完"，所以也不拿它收尾。（旧的「新的 turn 来了就把上一个盖上」判据**已删除**：它用全局单值认"上一个"，两个会话并行时会互相盖。）`skipCurrentBucket` 按轮丢**该轮的全部桶**——弱分组下一轮可能散在几个桶里，只弹队首会留下残部继续念。
- **播报字幕（可选）取「播放侧」而非合成侧**：每句的**首块音频**捎上该句文本（`AudioChunk.sentenceText`），`AudioPlayer` 在它被设备读出（`.dataConsumed`）时回调 → 队列转发给 `onCaption`。合成领先播放一两句，**从合成侧取会让字幕比声音早**（实测踩过，飞哥听出来了）；播放侧取则与声音对齐（误差约一个 IO 缓冲）。打断天然正确——被掐掉的句子的回调本就过不了世代校验；整队播完 / 全掀（`bargeIn`）广播 `nil` 收起。
- **三档打断的形象说法**（跟实现**同构**，动这段代码前先读它）：
  把播报想成一个**播音员 + 一摞摞稿纸**——每一摞是一次输入引发的全部回复（普通播报、译文各算一摞），一张纸是一**页**（一条 assistant 消息），一张纸再撕成若干**块**送去合成。
  **要紧的是：正在念的那张纸始终在叠里**（游标只记「已播到哪一号」，不从叠里取走）。旧形态是 `popFrontJob` 把块弹出桶、正念的那块游离在容器之外，于是得另记一份 `playingPageID` 当靶心——那份会陈旧（第二次按压拿旧页号删掉后到的内容）。
  - **轻（Ctrl+2）= 这一页剩下的不念了，翻页** → 从下一页的第一块接着念。实现：`claimCurrentPage`（在 Session 内**占位**领走当前页）→ 掐 → 删这一页
  - **中（Ctrl+1）= 整摞都不要了** → 连还没印出来的也不印（该摞后续分块立墓碑），直接拿下一摞。实现：`discardCurrentSegment`
  - **全掀（Ctrl+Esc）= 把桌上所有稿纸全扫到地上** → 一声不响（背景音乐不归它管）。右⌘ 说话同理：你要开口了，全场停播并让出麦克风。实现：`cancelAll`
  - **Cmd+D 译文 = 不抢别人的叠，只把译文这张插到最上面** → 掐掉手里正念的那张让它先响，其余叠一张没动。实现：`speakUserInitiated`（译文进独立的「加急段」列表）
  > **掀页的靶心必须占位，不能只读一次**：`claimCurrentPage` 与「删这一页」之间隔着 `await`（等播放器退净），actor 在挂起点可重入，第二次按压会插进来、又领到同一个页号，两次都去删同一页（2026-10-17 `P2` 实测两下都报同一页，随后 daemon 崩）。**领走即焚 + 占位**两半都要：领走后第二次按压拿不到靶心，退化成「只掐在播」。
- **⚠️ 调用顺序必须先于状态判定：连接内的四个操作要按帧序落地**（`ConnectionHandler.StreamOpChain` 串成一链）。`{type:stream}` 首帧、每个入队块、`{end}`/`{cancel}` 原先各自 `Task {}` 投递到本 actor，**落地顺序全凭调度器**。实测 `{end}` 的 Task 抢在同一连接后一个入队 Task 之前执行：`endTurn` 已把该轮盖印，迟到的**同轮** `enqueue` 又把它揭回未收尾，而此时再无帧可关它——分块全部播完后那一摞永远收不掉：`/health` 恒 `playing=true`、`queued=0`、无「播放收尾完成」，而**两把兜底都够不着**（背压看门狗要求 `pendingCount>0`，此刻已 0；drain 还没轮到）。
  > 旧形态下这里的后果更硬：管道本身**也**永久停在 `waitForJobs()` 里。新形态里 producer 发现没块就退出管道（见上「空闲宽限归身份层」），悬住的是宽限那条等待，而宽限有 2 秒上限——所以即便帧序再乱，也不会像从前那样永久挂死。黑盒 A-tail / E3 用例的「未收尾」即此，现场探针原始顺序为 `enqueue(open=1) → endTurn(open=0) → enqueue(open=1)`，6 秒后进入永久挂起。
- **轮次身份靠「轮次栈 + 墓碑」判定**（`turnStack` / `deadTurns`，都在 `PlaybackSession` 里），**消费靠游标**：
  - **`turnStack` 只做 pi 双流的空流 `{cancel}` 认证**（回答「这个 turnID 是不是合法新轮、属主该不该交还」）；消费视角是「游标之后那一块」，二者解耦、正交。已作废轮的迟到帧静默丢弃。
  - **`{cancel}` 的轮出栈**：被取消的轮没有内容需要保护，属主交还给被它顶掉的那一轮。**这条是 pi 「整轮没声音」的修复关键**：pi 一个用户消息会开两条流、其中一条刚开就被 `{cancel}`，而承载正文的是先开的那条——若取消的轮继续占着栈顶，正文那条就被永久判成过期旧轮、整轮哑掉。
  - **墓碑 `deadTurns`**：`{cancel}`、用户开口（`cancelAll()`）、Ctrl+1 跳过（`skipCurrentBucket`）之后该轮不再开口，含客户端关闭连接后 EOF 兜底补出的残尾。容量 64，防止无限增长。
  只判「不等于 currentTurn」是不够的：那会把新轮的首帧和旧轮的迟到帧混为一谈；只按「见过没见过」判也不行：会把**并行那条空流**的取消算到真正在跑的轮头上。
- **`cancelAll()` = 「全场闭嘴」的语义：停当场 + 作废全部流式轮**（`discardAll()` + `bargeIn()`）。⚠️ `discardAll()` **必须连 `turnStack` 里的轮一起立墓碑**，不只是容器里已有的段：那些是「已声明、块还没到」的轮，此刻容器里还没有它们的段，只按段立碑就会漏掉——打断之后它们陆续送来的字照常播（2026-10-17 `E7` 实测：清空队列时 `pending=0`，墓碑一个没立，打断后同一轮照样开口）。调用方只有右⌘（`speech`）与 Ctrl+Esc（`esc`）。**`{type:stop}` 停止帧已完全失效且无发送方**（hook.sh interrupt 已摘、ivox quiet 已删），收到时 ConnectionHandler 仅记日志忽略（留作护栏，防止旧帧被当正文念出来）。`turn` 顶替也不再经 bargeIn——新轮排队。
- **「掐在播」与「清场」拆成两层**：`preemptCurrent` 只作废管道代号 + 取消在播合成与已排队音频，**不动容器**；`bargeIn` 则是「先 `discardAll()` 再调它」= 全掀。由此派生三个「只掐不清」的入口：
  - **Cmd+D 念译文 = 插队**：`speakUserInitiated` = `preemptCurrent(.dict)` → 等旧管道退净 → 译文进**加急段**（独立于常规段的 `front` 列表，`nextCursor()` 先扫它）→ 立刻起管道。其余内容一个不丢，播完译文接着播（若想连当前摞一起丢，那是 Ctrl+1 的语义）。**入口有两个，落到同一条路**：`ConnectionHandler` 的 `{now:1}` 字段（CLI `ivox speak --now`），以及 `TranslationCoordinator` 的 Cmd+D 快捷键。加 socket/CLI 入口是为了让自检能压到它（`I1-insert-front-keeps-queue`）——机器里唯一被允许插队的内容没有自动化回归保护是不成的。
  - **Ctrl+1 = 掐 + 掀当前摞**：`skipCurrentBucket` = `preemptCurrent` → `discardCurrentSegment()`（内部含立墓碑，该摞后续分块也不再开口）→ `pumpOrSettle()` 接着播；没有下一摞则收尾。
  - **Ctrl+2 = 掐 + 掀当前页**：`skipCurrentPage` = `claimCurrentPage()`（占位领靶心）→ `preemptCurrent` → 等旧管道退净 → `discardClaimedPage()` → `pumpOrSettle()`。页号为 nil（非 Claude 路径）时走 `discardCurrentSegmentBlocks()`：清掉游标所在**那一段**的全部块、**不立墓碑**（与 Ctrl+1 的区别就在这——`ivox speak` 这类普通播报没有摞可掀，别牵连它的后续增量）；没块在播时退化成「只掐在播」。
- **`pipelineSeq` 代号作废在途管道（修「旧 producer 消费新轮任务」）**：`Task {}` 是结构化外的子任务，**不继承取消**——`bargeIn` 的 `currentTask?.cancel()` 根本停不住已进 MLX 的 producer。故 `bargeIn`/`shutdown` 递增 `pipelineSeq`，producer 每轮循环、consumer 每次循环都比对「代号是否仍是自己的」，不等即立即退场。`currentTaskSeq` 同理：管道收尾只在 `currentTaskSeq == 自己` 时才清 `currentTask`，防止旧管道把新起的管道清掉。
- **收敛兜底 `pumpOrSettle()`**（原名 `pumpOrResume`——它那一步"恢复音乐"已随播报不再碰音乐而删除）：轮次顶替时序可能留下「有 job 但没管道」的孤儿态。`endTurn`/`cancelAll`/掀页掀摞 收尾统一走它——无管道且有活就补起管道，否则等旧管道退净、按需收字幕。任何路径结束都不会挂住。⚠️ **等它退净**：遇到「管道仍在退出中 + 已取消 + 无待播」时必须等（`awaitCurrentPipelineFinished()`），不能一律直接返回——否则 `currentTask` 还非 nil，收字幕那一支进不去，字幕就永远挂在屏幕上。
- **`drain()` 超时定时器绑定自身序号 `drainSeq`**：超时兜底的 `asyncAfter` 闭包必须校验 `drainSeq == 自己`，否则**上一次 drain 遗留的定时器会提前放行下一次 drain**，表现为尾音被掐（曾实测 `drain 超时强制返回（pendingCount=28 尾音=1.12s）`）。
- **门控挂起回来要复核目标块还在**（旧形态的 `removeFirst from empty` → `EXC_BREAKPOINT` 的等价物）：producer 在 `awaitPrefetchCapacity()` 之前读游标、回来后确认「游标之后的第一块还是我读到的那个」，不是就跳过。现在**容器不会被 producer 改动**（它只读游标），但掀页/掀摞会删——所以复核的是「这一块还在不在」，在就合成、不在就跳。
- **`sweepPages` 不能 `remove(at:)` 配 `indices` 遍历**：删完索引整体前移，下一轮越界 → `Index out of range` → daemon 崩、LaunchAgent 拉起，一批用例集体假红（2026-10-17 实测，崩溃报告 `iVox-2026-10-17-135311.ips`）。要删的先 `filter` 出来算块数，再用 `removeAll` 一次性删。

> **历史事故与修复记录已移入 archive/**（本文只写现状）：历史修复清单
> [`incident-playback-queue-fixes.md`](../archive/incident-playback-queue-fixes.md)、
> drain 回调丢失复盘 [`incident-audio-drain-callback.md`](../archive/incident-audio-drain-callback.md)、
> 文本泄漏进播报 [`incident-hook-tts-leak.md`](../archive/incident-hook-tts-leak.md)。
> 那些记录里 media 与 `↓` 跳段相关的部分都是 v4.0.0 之前的旧形态。

## 维护约束

`cancelPendingPlayback()` 是唯一能解开挂起 drain 的路径（`node.stop` 会丢回调）；新增超时逻辑不要改变
`drain()` 在 `processNext` 中的调用语义（await 之后仍执行取消检查）。其余逐条遵守：

1. **播报队列不发任何 media 命令**——借还背景音乐只归语音输入（`SpeechInputService`）。理由：曾整套借还，Claude 的回复分批送来、批间停顿一超过 2 秒宽限就误判「说完了」而还音乐，下一批到达又借，实测一天内「借了不到 10 秒就还」17 次，最短 0.0 秒
2. **新增退出/收敛条件时只改 `pumpOrSettle()`**——所有路径的收尾都收敛到它（有活补起管道 / 没活收字幕 / 仍有未封的段就起空闲宽限）。别在 `processNext` 或各个动作方法里各自判断要不要起管道：那正是「旧播报收尾期间新入队被吞成漏播」的成因
3. **新增触发点（如新快捷键）只走 `cancelAll` 或 `bargeIn`**——不要直接 `currentTask?.cancel()`（`skipCurrent()` 已随「↓ 跳段」一并删除）
4. **保持 `await oldTask?.value`**——这是串行化的线性化点，去掉会重新引入竞态
5. **`cancelPendingPlayback()` 会递增 `generation`**——write 回调经 `guard generation == gen` 丢弃旧世代回调；不要移除该 guard，也不要绕过 `cancelPendingPlayback` 直接清零 `pendingCount`，否则旧回调会把计数减成负数
6. **`scheduleBuffer` 必须带 `completionCallbackType: .dataConsumed`**——旧 API（不带 callbackType）是 `.dataPlayedBack` 语义，播放末尾引擎 auto-shutdown 时回调永不触发，会重新引入 drain 超时；`.dataConsumed` 在数据被读出即回调，不依赖引擎存活
7. **多条块一次性入队时走批量入口 `enqueue([PlaybackJob])`**——逐条 `await enqueue` 时，若两批之间队列瞬时为空，会白起停一次管道与收尾。批量入口先 append 完再启动处理，消除该窗口
8. **不要在 job 之间重新引入 `await player.drain()`**——句间接力靠 AudioPlayer 连续 `scheduleBuffer` 排队，逐句 drain 会播空设备、重补 prime、重启调度，重新引入逐字卡顿。drain 只允许出现在 `processNext` 末端一次
9. **新增「有新内容」的入口时必须让它走到 `PlaybackSession.signal()`**——空闲宽限挂在 `waitForContent()` 的等待表上，任何让它该醒来的事件（入队/轮次开始/结束/掐）都必须经过 `signal`，否则宽限只能等满 2 秒才判。**反过来：删除路径（掀页/掀摞/全掀）绝不能发 `signal`**——`signal` 的语义是「来新货了」，删除发了会让宽限误判成有更新而作废，且作废后没有接班人，这一摞永远收不掉
9b. **作废宽限只能递增 `graceEpoch`，不能 `graceTask?.cancel()`**——取消挂在 `withCheckedContinuation` 上的 Task 不会解开 continuation，Waiter 会永远留在等待表里。`idleGraceElapsed` 发现自己已被取代就直接返回、不动别人的 `graceTask`；被唤醒（来新货）则**必须再 `pumpOrSettle()` 一次**，否则那次起宽限可能被「`graceTask` 还占着」挡掉而没人接班
10. **背压水位（4s/2s）调整只改 `AudioPlayer` 的 `highWaterFrames/lowWaterFrames`**——高水位是内存上限也是合成预取上限（约 48kHz Int16 单声道 ≈ 384KB/4s），低水位须低于高水位以形成滞后区间，避免在阈值边缘反复挂起/放行
11. **弱分组只在 `appendGrouped` 里管，绝不要接进 `turnStack`**——`turnStack` 是 pi 双流「属主交还」的认证栈，混入别的 id 会让 pi 的正文流被判成过期旧轮（**整轮没声音**）。弱分组要的只有两件事：「同 group 并段」和「墓碑拦住后续批次」，都不需要栈。掀摞时记得连墓碑一起立（`discardCurrentSegment` 已做），**全掀时记得连 `turnStack` 里的轮一起立**（`discardAll` 已做——它们「已声明、块还没到」，此刻容器里还没有对应的段，只按段立墓碑就漏掉了，打断之后它们陆续送来的字照常播，`E7` 实测）
12. **流式连接的队列操作一律走 `ConnectionHandler` 的 `chain.hop {}`，不许直接 `Task { await queue.… }`**——顺序是协议语义的一部分（`{end}` 之后再无帧可关轮次）；裸 `Task {}` 落地乱序会让已关轮次被迟到分块重新打开，管道永久挂起（见上「按帧序落地」条）