# 播报实现层

> **四层里的最后一份，只在要动代码时才读。** 它回答：**今天代码怎么写的、改它有什么坑。**
> 读法顺序：**目的层 → 接入方层 → 需求层 → 实现层（本文）**。有分歧先翻 [目的层](purpose.md)；
> 「必须做到什么」见 [需求层](requirements.md)。
>
> 本文只写**现状**。设计取舍归 [目的层](purpose.md)，需求场景归 [需求层](requirements.md)，
> 事故与历史复盘归 `../archive/`。本文与代码不符时**以代码为准**，但请顺手改本文。
> 改播报核心后跑 `make check-tts` 全量（黑盒自检，20 条用例）。

## 这一层最关键的三个设计决定

**① 队列是页的 FIFO，容器只有两层：页 → 句。**

一页 = 一条 assistant 消息 = 队列里唯一的单位（`PlaybackPage`）。
页里装的是若干**句**（`PlaybackSentence`，合成单位，≤80 字）。

- **页按到达顺序排**（`PlaybackSession.pages` 是个数组，索引 0 = 队首）。谁都不插队。
- **页号与句号各发各的**（`PlaybackPage.localID` / `PlaybackSentence.seq`），都全局单调、自增不复用。
  「第 7 页」是一个维度、「句 42」是另一个维度，别混。
- **外部编号不进容器**：`turn_id`、`message_id` 只进日志。身份是容器自己的事。
- **容器里只有一层**：译文不上桌（它走独立播放节点，见下），所以没有「加急层 + 常规层」。

2026-11-02 之前容器是三层（段 → 页 → 块），配一整套配套机制
（外部号↔自编号对照表、墓碑、收尾记账、空闲宽限、Stop 收尾信号）。
那些机制**整套没了**：队列排空即收尾。理由与判据见 [目的层](purpose.md)「不凑合」一节。

**② 游标不弹出容器。** 游标指向当前句但不把它取走，播完（或作废）才前移
（`PlaybackSession.commit`）。容器因此永远包含正在合成的那一句，掀页时它自然在被删范围内——
不必靠 `pipelineSeq` 间接作废，也就没有「当前在播哪一页」这个需要另外维护、且会陈旧的变量
（2026-10-17 的陈旧靶心缺陷正是这么来的）。
**游标不能只存整数下标**：掀页会把整页删掉，下标全部失效。所以游标是
`(句号 seq, 该句)`（`PlaybackSession.swift`）——句号是全局单调的，删页删不掉它。
删页后要重定位到「下一页第一句」，那一步由 `headPageTarget()` **现算**：
先看发声点此刻落在哪页（`audiblePageTarget()`），冷启动没有发声点才退回队首
（`firstPendingPageIndex()`）。

**③ 会炸的那一层不住在同一间屋子。** MLX 的 Metal 命令编码器析构时重复释放 GPU 命令
队列 → SIGTRAP，上游未修且 Swift 侧拿不到 encoder 引用无从拦截。故合成整个搬进子进程
`ivox tts --serve`（`TTSServer`），主进程只持有 `TSPRemote`：隔着 Unix socket 一句一问
一句一答（协议与 `handleTTSPCM` 同构）。`IVOX_TTS=local` 可退回进程内合成，仅供排障对照。

配套的三条纪律：

- **进度只存在主进程**。「发到第几句、收到第几帧」是主进程的数，子进程无状态——它崩了
  主进程据此丢弃那一句、重启它、从队列的下一句继续。队列内容因此不受它影响。
- **不重发已送出的 PCM**。崩之前送出去的帧已经进了播报员，重发得到「前半截 + 从头再来
  一遍」，比直接作废更糟。所以崩溃 = 这一句作废（见下一条），**不是**重试。
  ⚠️ 但**一帧都没送出**时重发是安全的（没播出去过，重发不会变成重复播）——2026-10-24 起
  `TSPRemote` 会重发一次，日志是「合成未出一帧，重发一次」。引擎已经死掉时重发只会连不上，
  于是仍走「作废」，黑盒 `R1`（杀誊清员 → 这句作废 → 队列继续 → 监督者重拉）照旧过。
- **读超时不是断流**。`SO_RCVTIMEO` 只保证「这一趟 read 最多等这么久」，合成慢（MLX 首帧慢、
  GPU 被抢）就会空转一次 `EAGAIN`——那不是对方挂了，继续等就是了。判「断了」只有 EOF 一样东西。
  ⚠️ 2026-10-24 修：合成流原先沿用控制 socket 的 10 秒读超时，于是「合成慢」被当成
  「对端断了」→ `truncated` → **那一句内容整块丢弃**（真对话里连丢 4 句，52~76 字，一字没念，
  飞哥反馈「听听着就少了一部分」）。现在读超时继续等，另加整句总时限兜底（「对端活着但不再
  吐数据」），时间口径集中在 `iVoxKit/SocketStream.swift` 一处（`SocketTimeout`）。
- **引擎没就绪先等就绪**。请求撞上「模型正在加载」会被誊清员直接拒掉，那一句就白丢了
  （2026-10-24 实测：引擎重启瞬间发出的请求全丢，黑盒 `F` 用例因此空 PCM）。
  `TSPRemote.synthesizeStream` 只在状态明确不就绪时等（上限 120 秒），正常路径不额外建立连接。
- **半句必须能认出来**。对面崩在一句话中途时读端只拿到 EOF，与正常念完表象完全一样。
  故 `StreamFrame.parseChunks` 报告「是否见到结束标志」，`TSPRemote` 据此抛
  `truncated`，`PlaybackQueue` 落成一行带 `seq` 的错误并**无条件前移游标**——播报员
  不会拿到半句，队列继续。日志是 `誊清中断，这一句作废：truncated seq=N`。

**④ 由此带来的两处必处理**（改 producer/掀页路径时逐条对照）：

1. **合成失败/取消时游标必须前移**，否则卡在同一句死循环
   —— **但「被掐断而作废」的那一句例外：不前移**（2026-11-02 修，理由见下）。
   作废 = 这一句**根本没出声**（管道代号已换、PCM 没进播放器），前移游标等于把它吃掉。
   合成变快后，掀页时在飞的那句**常常是下一页的预取**（预取领先播放一句），
   吃掉它 →「掀页」变成「掀光队列」，需求里的「从下一页接着念」落空。
   不前移 → 它留在容器里，新管道重新合成它 → 下一页照播。
   （全掀不受影响：容器已清空，这句不会被重播。）
2. **预取门控期间用户掀了这一页**：`awaitPrefetchCapacity()` 挂起期间容器被改动，醒来发现
   当前句已不存在 → 安全跳过（`session.nextCursor()?.seq != cursor.seq` 就 `continue`）。
   同类风险踩过（对空数组 `removeFirst` 曾致 `EXC_BREAKPOINT`），沿用「先读后弹 + 醒来复核」的做法

---

下面记的是**今天代码怎么写的**：连续播放管道、背压、管道代号、以及踩过的坑。
身份层是独立的 `PlaybackSession.swift`。

## 核心原则：背景音乐只归语音输入

**播报队列不发任何 media 命令**（判据见 [目的层](purpose.md) 的裁决：借还音乐曾造成
17 次抖动，整条删除）。语音输入那侧照借照还，用 `suspendedByUs` 护栏避免「我们暂停的」
被当成「本来就没在放」而误恢复。

## 连续播放管道（常驻 node + 背压）

> v3.6 改造，修复流式短句「一个字一个字蹦」。旧实现每个 job 独立 `generateStream → write → await drain()`，句间播空后重置 `needsPrime`、下一 job 重补 50ms 静音并重排调度——等于把连续语音流每句掐断。对照 ai-stack（Python `sounddevice.OutputStream` 常驻 + `queue(maxsize=16)` + 阻塞 write），改为一条跨 job 的常驻管道。

**AudioPlayer（`AudioPlayer.swift`）**

- 整条播报复用同一个 `AVAudioPlayerNode`，分块连续 `scheduleBuffer` 排队，设备从不在句间重启。
- **两级流水线（v3.6.2）**：合成（producer）与播放（consumer）拆成两条 Task，中间用 `AsyncStream<Data>(.unbounded)` 接 PCM。播放侧 `write()` 的背压只阻塞 consumer，**不再反压卡住下一句合成**——旧的「合成→write 串行」在 write 等 4s 高水位时连带阻塞下一句合成，是句间卡顿根因。真正的预取上限上移到 producer 句间的 `awaitPrefetchCapacity()`（见下条），unbounded 流只承接这「领先一两句」的提前量。
- **两套独立门控、阈值不同**：
  - **预取门控（给 producer 用）**：排队音频超 4s 高水位就先别开下一句合成，**回落到高水位即放行**（保持厚垫），绝不等低水位——否则下一句合成（约 3~5s）期间会欠载断句。
  - **write 背压（给 consumer 用）**：超高水位挂起、降到 2s 低水位才放行。
- 两者都用**等待者数组**而非单一 continuation 槽：密集打断时新旧管道的 writer/producer 会短暂同时在场，单槽会被后到者覆盖、先到者的 continuation 永不 resume（`SWIFT TASK CONTINUATION MISUSE ... leaked`）。每个挂起者独立入数组，唤醒时全 resume，谁也不覆盖谁。
- **write 世代守卫**：`write` 入场时在 serialQueue 上快照 `generation`，背压醒来后重新校验；若已被 `cancelPendingPlayback`（bargeIn 递增世代）作废，直接 return、**绝不碰 node/prime**，避免新旧管道两个 writer 争用同一播放节点（曾表现为打断瞬间两次 prime）。⚠️ 这是「**进入时才取世代**」：作废之后**新进来的** `write` 会取到新世代、照样通过校验——所以消费侧必须自己逐句比对 `pipelineSeq`（见 `processNext` 条目），否则旧轮已缓冲的 PCM 会一路排进播放器：表现为**打断后旧音频照念、新轮卡在 `awaitCurrentPipelineFinished` 干等**（pi「收到新消息，没打断」的根因，实测旧管道要多灌 8.7s 才退）。
- **设备断流看门狗 `recoverIfDeviceStalled()`**（serialQueue 上 1s 一跳自续，`stop()` 后停跳）：背压等待**只能**由 `onConsumed` 唤醒、`ensureHealthy()` 又只在「进入等待**之前**」检查——蓝牙音箱断流 / 设备被系统挂起时 `dataConsumed` 回调不再触发，writer 就永久挂起：整条管道卡死（`/health` 恒 `playing=true`）、此后所有播报一律哑掉，只能靠一次打断解救（蓝牙输出下实测必现，日志里只有「前导静音已调度」再无下文）。判定：`pendingCount>0` 且连续 `stallGrace`（10s）无任何消费回调。处置：`rebuildEngine()` 重新激活设备、按「已丢」清掉排队 buffer 计数（`node.stop()` 本就已把它们丢出节点）、唤醒全部等待者，让管道继续灌后续 PCM 或收尾退出。正常消费是连续实时的，不会误判。
- **prime 静音只在「设备真正播空（`pendingCount==0`）/ `cancelPendingPlayback`」后做一次**（`needsPrime`），连续排队的句间不再触发。静音长度 200ms 并在排缓冲前显式 `node.play()`：系统音频电源管理会挂起长时间空闲（实测十几分钟）的 node，50ms 太短、首个音频 chunk 仍会被吞（「第一句开头没声」）。
- **`drain()` 只在整条管道末端调用一次**（等跨句尾音播完），句间不再 drain。
- 取消链：`write()`/预取挂起时，`cancelPendingPlayback()`/`stop()` 一定会 resume 全部等待者；旧世代者靠世代校验退出，同世代者靠 `Task.checkCancellation` 退出，不会永久挂住。

**PlaybackQueue.processNext（`PlaybackQueue.swift`）**

- producer：跨所有 job 的 `while !Task.isCancelled` 循环，逐句 `awaitPrefetchCapacity() → synthesizeStream → for await pcm { pcmContinuation.yield(pcm) }`，**句间不 drain**；consumer：`for await pcm { await player.write(pcm) }`，**每句先比对 `pipelineSeq`**——已被 bargeIn 作废就立即 break、绝不再灌 PCM（`write` 的世代校验拦不住作废后新进来的调用，见上文 AudioPlayer 的世代守卫）。
- **尾音不丢（v3.6.2 关键修复）**：producer 正常结束时 `defer { pcmContinuation.finish() }`，consumer 的 `for await` 会把流里**仍缓冲着的最后一句多块 PCM 排空后自然终止**——因此正常路径**绝不能提前 `consumer.cancel()`**：此前 producer 一结束就 cancel，consumer 在下一块的 `isCancelled` 处 break，AsyncStream 里的尾音整块丢弃、drain 只等到已 schedule 的部分，表现为「内容没念完就恢复音乐」。只有整条任务真被 bargeIn 取消（`Task.isCancelled`）时才 cancel consumer 弃残余。
- **MLX 串行闸门 + epoch 作废（v3.6.2，修并发崩溃与废句雪崩）**：MLX 模型非并发安全，且 MLX 流不响应中途 Task 取消（一句发起后必须跑完）。`TTSEngine` 用单调世代闸门：第 N 代合成本须等第 N−1 代完全离开模型才进 `generateStream`，否则新旧推理并发砸同一模型触发 `Fatal error: expected a non-empty mlx_array vector.cpp:51`、daemon 崩溃；`bargeIn → cancelActiveSynthesis()` 额外递增 `epoch` 并唤醒所有 gate 排队者，旧 epoch 排队者放行后检查到纪元失配立即抛 `CancellationError`、**绝不进 MLX**（不依赖 Swift 任务取消能否传播到内部 Task），密集连打下只让「恰好撞在推理中」的那一句跑完。
- **线性化点**：掐只 cancel 旧任务不清 `currentTask`；**要立刻往播放器写数据的调用方**（掀页 / 全掀 / Opt+Z 插队）必须 `await currentTask.value`（`awaitCurrentPipelineFinished()`）等旧 producer+consumer **彻底退出**，否则两个 consumer 并发 write 同一 player。**入队路径不需要这句**——它只是「有活就起管道」，`startPipelineIfPending()` 见 `currentTask != nil` 就补不起，活交给旧管道退净后自己那轮 `pumpOrSettle()` 去做。
  ⚠️ 反过来说，`pumpOrSettle()` 里**绝不能** await 这句等旧管道退净：被掐的管道可能挂在 `player.drain()` 或预取背压的 continuation 上迟迟不退出，一等就把后面所有收尾逻辑（起管道、收字幕）全带死（2026-10-17 `P3` 实测：队列已空、health 已空闲，两条收尾日志一条都没打）。
- **管道排空即退出**（2026-11-02）：producer 发现「没有下一句了」就**直接退出管道**，不等任何东西。
  收尾（收字幕、还音量）由 `pumpOrSettle()` 统一负责。**没有宽限、没有收尾信号、没有「还有话没说完」这回事**——
  页的 FIFO 没有「这一摞还有没有下文」要问。
- **管道自己收尾时会撤字幕**：管道排空即 `hideCaption()`（字幕跟**声音**走，不是跟队列结算走）。
  只在**自己还是当前管道**时撤：被顶替的旧管道不能把新管道刚报的那句擦掉。
- **作废一轮靠递增 `pipelineSeq`**：`Task {}` 是结构化外的子任务，**不继承取消**——`bargeIn` 的
  `currentTask?.cancel()` 根本停不住已进 MLX 的 producer。故 `bargeIn`/`shutdown` 递增 `pipelineSeq`，
  producer 每轮循环、consumer 每次循环都比对「代号是否仍是自己的」，不等即立即退场。
  `currentTaskSeq` 同理：管道收尾只在 `currentTaskSeq == 自己` 时才清 `currentTask`，防止旧管道把新起的管道清掉。
- **收敛兜底 `pumpOrSettle()`**：任何路径结束都在这里落一次——回收已念完的页 → 有活补起管道 →
  没活则等设备静下来再收尾（收字幕、还汽水音量、打「播报结束: 队列已空，字幕收起」）。
  ⚠️ **等它退净**：遇到「管道仍在退出中 + 已取消 + 无待播」时必须等（`awaitCurrentPipelineFinished()`），
  不能一律直接返回——否则 `currentTask` 还非 nil，收字幕那一支进不去，字幕就永远挂在屏幕上。
- **`drain()` 超时定时器绑定自身序号 `drainSeq`**：超时兜底的 `asyncAfter` 闭包必须校验 `drainSeq == 自己`，否则**上一次 drain 遗留的定时器会提前放行下一次 drain**，表现为尾音被掐（曾实测 `drain 超时强制返回（pendingCount=28 尾音=1.12s）`）。
- **门控挂起回来要复核目标句还在**（旧形态的 `removeFirst from empty` → `EXC_BREAKPOINT` 的等价物）：producer 在 `awaitPrefetchCapacity()` 之前读游标、回来后确认「游标之后的第一句还是我读到的那个」，不是就跳过。掀页会删页，所以复核的是「这一句还在不在」。
- **删除容器不要 `remove(at:)` 配 `indices` 遍历**：删完索引整体前移，下一轮越界 → `Index out of range` → daemon 崩、LaunchAgent 拉起，一批用例集体假红（2026-10-17 实测，崩溃报告 `iVox-2026-10-17-135311.ips`）。要删的先 `filter` 出来算数量，再用 `removeAll` 一次性删。

> **历史事故与修复记录已移入 archive/**（本文只写现状）：历史修复清单
> [`incident-playback-queue-fixes.md`](../archive/incident-playback-queue-fixes.md)、
> drain 回调丢失复盘 [`incident-audio-drain-callback.md`](../archive/incident-audio-drain-callback.md)、
> 文本泄漏进播报 [`incident-hook-tts-leak.md`](../archive/incident-hook-tts-leak.md)。
> 那些记录里 media 与 `↓` 跳段相关的部分都是 v4.0.0 之前的旧形态。

## 入队与打断（身份层的四个动作）

**入队一页**（`PlaybackQueue.enqueuePage(text:jobs:)`）：清洗与切句在**接入侧**做完
（`ConnectionHandler` 里 `cleanText` → `splitSentences`，真源只在 Swift 一份），
这里只负责排队与发号：

```
accept(jobs)                  ← 播报关着就丢弃（收件口的闸，所有进队路径共用一处）
session.appendPage(...)       ← 发页号、发句号、落盘
Log.info("资料室收下：第 N 页 来源=… 字数=… 句=…")
pumpOrSettle()                ← 收敛点在这里，不在入队处判断
```

**两档打断**（形象说法与键位见 [paper.md 的两档一节](paper.md)，本文**不重复比喻**
——两份各写一遍就会各自漂移，2026-10-20 那次键位全反正是这么来的）：

- **掀页 `Ctrl+1` → `skipCurrentPage`**：`takeHeadPage()`（在 Session 内**领走即摘**当前页）→
  掐 → 等旧管道退净 → 下一句接着播。**没有独立页号可领时退化成「只掐在播」**。
  ⚠️ **「下一句接着播」的前提**：被掐断而作废的那一句**不前移游标**（见上文 ④ 的第 1 条）——
  掐断时在飞的那句往往是**下一页的预取**，前移游标就把它吃了。
  ⚠️ **靶心必须领走即摘，不能只读一次**：`takeHeadPage()` 与「删这一页」之间隔着 `await`
  （等播放器退净），actor 在挂起点可重入，第二次按压会插进来、又领到同一个页号，两次都去删同一页
  （2026-10-17 `P2` 实测两下都报同一页，随后 daemon 崩）。**领走即摘**两半都要：
  领走后第二次按压拿不到靶心，退化成「只掐在播」。
- **全掀 `Ctrl+2` → `cancelAll`**：掐在播 + 清空容器（`discardAll()`）+ 收字幕。
  **不留墓碑**——这一下之后再来的内容照常入队照常播。
  **右⌘ 说话不走这条路**——它是「你停一下」（`pausePlayback`：设备闭嘴、内容一条不删），
  不是「你别说了」。背景音乐不归它管。
- **译文插队 → `speakUserInitiated`**（**译文不进容器**：主节点暂停 + 独立节点念 + 念完接着播）。

**打断归因（谁打断的）**：`InterruptOrigin` = **档位 × 入口**（`Sources/iVox/Playback/InterruptOrigin.swift`）。
**档位只写一处**：由「调用哪个方法」决定（`cancelAll`→全掀、`skipCurrentPage`→掀页、
`discardAll`→关播报、退出→清场），别的层只负责把**入口**带下来
（键盘带实际生效的键位、外部请求带请求方自报的身份、系统）。
⚠️ **归因按管道代号记，不记「最近一次」**（2026-10-26 改）：一次打断作废的是**当时在跑的那条管道**，
全局单槽会被后一次打断覆盖——先被掐的那条管道的合成日志会写成后一次打断的人（查错人比查不到更坏）。

**「掐在播」与「清场」拆成两层**：`preemptCurrent` 只作废管道代号 + 取消在播合成与已排队音频，
**不动容器**；`bargeIn` 则是「先 `discardAll()` 再调它」= 全掀。由此派生两个「只掐不清」的入口：

- **Opt+Z 念译文 = 插一脚，不改队列**（2026-10-26 改）：`speakUserInitiated` =
  主节点 `pauseOutput()`（缓冲原样留着，**正在念的那一句不掐断**）→ 译文从**独立播放节点**
  `AudioPlayer.writeInterruption` 出声 → 念完 `resumeOutput()` 从原处接着播，字幕也接回原来那一页。
  **译文不进容器**，所以队列顺序一点没变、其余内容一个不丢。**为什么要有第二个节点**：
  同一个 `AVAudioPlayerNode` 只有一个播放位置——已经播出去的声音没法往回退，译文也插不到
  「已排队的音频」前面；要同时做到「译文先念」与「正在播的一句不丢」，只能各占一个节点。
  **入口有两个，落到同一条路**：`ConnectionHandler` 的 `{now:1}` 字段（CLI `ivox speak --now`），
  以及 `TranslationCoordinator` 的 Opt+Z 快捷键。加 socket/CLI 入口是为了让自检能压到它。
- **Ctrl+2 = 掐 + 全掀**：`cancelAll` = `bargeIn` → `discardAll()` → `pumpOrSettle()`；
  没有下一句则收尾。

**右⌘说话 → `pausePlayback()`（暂停，不是打断）**：`AudioPlayer.pauseOutput()` = `node.pause()`，
设备停渲染，**已排队的音频原样留在设备队列里**，队列与管道一概不动，说完 `resumePlayback()`
从原处接着播。**内容一条不删**——用户在说话期间 Claude 送来的页照常入队，等说完一起播。
三个必须记住的坑：① 断流看门狗要认「人为暂停」（否则暂停满 10 秒会被当成设备断流，
重建引擎把排队音频丢掉）；② `ensureHealthy()` 在暂停时不能判「异常」（`node.isPlaying == false`
是故意的，重建同样丢音频）；③ 前导静音那步的 `node.play()` 在暂停时不能调（那等于解除暂停）。

## 队列落盘（SQLite）：内存只是工作副本

**真源在磁盘**：`~/.config/ivox/ivox-queue.db`（SQLite，系统自带 libsqlite3；队列库路径跟 socket 走，
隔离实例各写各的）。里面**只存还没播出去的东西**。

**两张表**（2026-11-02 起）：

| 表 | 列 | 一行是什么 |
|---|---|---|
| `pages` | `page INTEGER PRIMARY KEY`、`source TEXT`、`voice TEXT`、`text TEXT` | **一页**：页号、来源（端）、音色、整页原文 |
| `sentences` | `seq INTEGER PRIMARY KEY`、`page INTEGER`、`text TEXT` | **一句**：句号、所属页号、文本 |

**没有 turn_id / session_id 列**——它们只进日志，不参与排队、也不落库。
老库（一张 `blocks` 表，装的是旧的三层结构）启动时改名成 `blocks_legacy` 保留，不删也不读
（旧结构和新结构不是一回事，读不出来，留着只是备查）。

- 写点：入队（存那一页 + 它的每一句）、播完（删已交给合成的句，句见底时那一页也删）、
  被掀（掀页 / 全掀 / 撤页 → 删）
- 恢复：`daemon` 起来时（**接单之前**）由 `restorePersisted()` 把它们重新排队
  （页按页号恢复 = 队列顺序；句号沿用落盘里的原值，不重新发号）
- **恢复出来的内容要显式开管道才有人念**（恢复不经过入队那条起管道的路），
  故 `restorePersisted` 里补一次 `pumpOrSettle()`
- 写盘失败只记警告，不挡播报
- **什么时候从库里删**：`commit()` 在**那一句合成完成**时调用（成功/失败/被取消都算「过去了」）
  → 删掉那一句；这一页的句子见底 → 连这页一起删。掀页删页、全掀全清。
  **所以库里永远只剩「还没合成过」的内容。**
- ⚠️ **代价：合成领先播放，所以「从库里删掉」比「听到声音」早**——实测常态早 **2~4 秒**；
  队列深、合成快于播放时可到**几十秒甚至几分钟**（2026-11-02 实测 551 轮：p50 3.8s / p90 26.9s / max 137s）。
  那段时间里 daemon 崩掉，这部分内容就**丢了**（已删不会重播）。
  这是「宁可少一句，不重复一句」的取舍；改成「播完才删」则崩了会重播已听过的内容。

**为什么必须有**：`ivox on` / `make update` 走 `launchctl kickstart -k`，那是 **SIGKILL**
（旧 daemon 瞬间死、抓不到、atexit 也不跑）——**每次部署都会杀一次 daemon**。
队列只在内存里，就等于每次部署都丢一次排队。

## 播报总开关（`playback.enabled`）

`PlaybackQueue.setEnabled(_:)` 是总开关的唯一入口：

- **关**：走 `cancelAll` 那条路（掐在播 + 清队列 + 收字幕）**并释放 TTS 模型**
  （`engine.releaseModel()`——人主动关的，模型就没了存在理由）
- **开**：`engine.resumeModel()` 按需重新加载（后台跑，不挡开关返回）
- 所有进队路径都过收件口的闸 `accept(_:)`：播报关着时进来的内容一律丢弃，不攒着等开回来
- 归因档位多一档 `disablePlayback`（`ivox playback off` 触发，与用户两档打断分开记）

## 维护约束

`cancelPendingPlayback()` 是唯一能解开挂起 drain 的路径（`node.stop` 会丢回调）；新增超时逻辑不要改变
`drain()` 在 `processNext` 中的调用语义（await 之后仍执行取消检查）。其余逐条遵守：

1. **播报队列不发任何 media 命令**——借还背景音乐只归语音输入（`SpeechInputService`）。理由：曾整套借还，Claude 的回复分批送来、批间停顿一超过 2 秒宽限就误判「说完了」而还音乐，下一批到达又借，实测一天内「借了不到 10 秒就还」17 次，最短 0.0 秒
2. **新增退出/收敛条件时只改 `pumpOrSettle()`**——所有路径的收尾都收敛到它（有活补起管道 / 没活收字幕）。别在 `processNext` 或各个动作方法里各自判断要不要起管道：那正是「旧播报收尾期间新入队被吞成漏播」的成因
3. **新增触发点（如新快捷键）只走 `cancelAll` 或 `bargeIn`**——不要直接 `currentTask?.cancel()`
4. **保持 `await oldTask?.value`**——这是串行化的线性化点，去掉会重新引入竞态
5. **`cancelPendingPlayback()` 会递增 `generation`**——write 回调经 `guard generation == gen` 丢弃旧世代回调；不要移除该 guard，也不要绕过 `cancelPendingPlayback` 直接清零 `pendingCount`，否则旧回调会把计数减成负数
6. **`scheduleBuffer` 必须带 `completionCallbackType: .dataConsumed`**——旧 API（不带 callbackType）是 `.dataPlayedBack` 语义，播放末尾引擎 auto-shutdown 时回调永不触发，会重新引入 drain 超时；`.dataConsumed` 在数据被读出即回调，不依赖引擎存活
7. **一条页的句子一次性入队**（`enqueuePage`）——逐句 `await` 入队时，若两批之间队列瞬时为空，会白起停一次管道与收尾。批量入口先 append 完再启动处理，消除该窗口
8. **不要在句之间重新引入 `await player.drain()`**——句间接力靠 AudioPlayer 连续 `scheduleBuffer` 排队，逐句 drain 会播空设备、重补 prime、重启调度，重新引入逐字卡顿。drain 只允许出现在 `processNext` 末端一次
9. **页的容器只有 `PlaybackSession` 一处**——不要在别处另建一份「页/句」的记账（早先的「外部 group ↔ 助理摞号」对照表就是这么长出来的，代价是身份两套、掀的时候掀错）
10. **背压水位（4s/2s）调整只改 `AudioPlayer` 的 `highWaterFrames/lowWaterFrames`**——高水位是内存上限也是合成预取上限（约 48kHz Int16 单声道 ≈ 384KB/4s），低水位须低于高水位以形成滞后区间，避免在阈值边缘反复挂起/放行
11. **播报只有一个入口**（2026-11-02）：`ivox speak --source X --voice Y -- "<正文>"`，
    一次请求 = 一页。各端自己拼命令（`hook.sh` 与 pi 扩展各自读 `config.toml` 查音色），
    **服务端照单念，不猜来源、不猜音色**。曾有的流式连接（长度帧 / `{end}` / `{cancel}` /
    `chain.hop` 帧序保证）随 pi 改走唯一入口整套删除——没有第二个入口，就没有两套语义
