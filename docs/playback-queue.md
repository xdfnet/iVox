# 播报队列技术方案（第三层）

> **上游是需求层**：播报必须满足什么、场景清单、顺序底线、解耦约束见
> [playback-requirements.md](playback-requirements.md)；再往上是接入方层
> [playback-sources.md](playback-sources.md)（谁在说话）。
>
> 本文前半是**目标方案**（尚未实施），后半是**当前实现**（连续播放管道、背压、踩过的坑）。
> 需求变了先改上游文档，方案变了先改本文前半。

## 目标

把「这一摞还活着吗」这类**身份问题**从播放队列里搬出去，让播放队列退化成一个只认
「按顺序到来的块」的东西。搬完后的直接收益：

1. **陈旧靶心类 bug 从结构上不可能发生**——「当前在播什么」住在容器里，没有独立变量可忘。
2. 接一个新接入方**不用碰队列内部**，只写一个适配器。
3. 三档打断在所有来源下行为一致，无需退化分支。

## 组件边界

```
┌─ PlaybackSession（actor，新增）─────────────────────────┐
│  唯一持有容器：段 → 页 → 块                                │
│  管身份：开段、翻页、封段、墓碑、迟帧丢弃、宽限兜底          │
│  协议：帧版本、字段解析（约束二、三）                      │
└──────────────┬─────────────────────────────────────────┘
               │ 队列按「位置」拉取，不问身份
               ▼
┌─ PlaybackQueue（actor，瘦身）───────────────────────────┐
│  合成、背压、掐 —— 只认「顺序到来的块」                    │
│  四个动作方法：掐() / 掀页() / 掀段() / 全掀()            │
└──────────────────────────────────────────────────────────┘
```

**队列按位置拉取、不问身份**。它调 `nextBlock()` 得到下一个该播的块，不问也不需要知道
这来自哪个接入方的哪一页；要掀时只告诉 Session「把当前这一页掀了」——**身份判定全在 Session**。

这条边界就是需求层解耦约束一「队列不认摞，只放有序的块」的落地：不是把摞从数据结构里
删掉，而是**把「号从哪来、该不该封、死了没」全部推出队列**。

## 数据结构

```
Segment  { id: String?        段标识（有身份才有；无来源的播报为 nil）
           sealed: Bool       是否已封——队列不判断何时封，只执行封
           pages: [Page] }

Page     { id: String?        页号；无页来源为 nil（页固定存在，无号即匿名页）
           blocks: [Block] }

Block    { text, voiceID, source }
```

**页是固定的一层**，无页来源退化成「页号为 nil 的那一页」——这样三档打断在所有来源下
行为一致，不必写退化分支（需求层「三个已定的结构决定」第二条）。

## 游标：核心改动

**现状**：块在合成前就被弹出桶（`popFrontJob`）。于是「正在合成的这块」游离在容器之外，
掀页时它不在被删的列表里，只能靠 `pipelineSeq` 作废间接处理。「当前在播哪一页」因此
必须在别处单独记（就是 `playingPageID`）——**陈旧靶心 bug 正是这么来的**。

**方案**：游标指向当前块，**不弹出**；播完或作废后才前移。

```
Segment.pages[i].blocks[j]     ← 游标指向这里
```

于是：

- 容器里**永远包含**正在合成的块 → 掀页时它自然在被删范围内
- 「当前」不再需要单独记一个页号 → **没有可陈旧的东西**
- **掐** = 作废 + 前移游标；**掀** = 删容器里的一层。两者都是容器操作

游标**不能只存整数下标**——掀页会把整页删掉，下标全部失效。必须表示成
`(段序号, 页序号, 块序号)` 或持容器引用，删页后重定位到下一页第一块。

### 游标不弹出带来的三处必处理

1. **合成失败/取消时游标必须前移**，否则卡在同一块死循环（现有 catch 分支已有等价逻辑，搬过来）
2. **掀页后游标要重定位**：指向的块被删了，落到下一页第一块；没有下一页则落到下一段
3. **预取门控期间用户掀了这一页**：`awaitPrefetchCapacity` 挂起期间容器被改动，醒来发现
   当前块已不存在 → 安全跳过。同类风险现有代码已踩过（`removeFirst from empty` 曾致
   `EXC_BREAKPOINT`），新结构要沿用「先读后弹 + 醒来复核」的做法

## 接口

**Session 交给队列**（全是位置与信号，没有语义）：

| 接口 | 用途 |
|---|---|
| `nextBlock() -> Block?` | 取下一个该播的块 |
| `waitForContent() async -> Bool` | 挂起等新内容；`false` = 兜底宽限到点 |
| `discardCurrentPage()` | 掀当前页（队列报游标位置） |
| `discardCurrentSegment()` | 掀当前段 |
| `seal(segment)` | 接入层判定该封了 → 队列执行封 |

**队列交给 Session**（全是事件，没有命令）：

| 通知 | 何时 |
|---|---|
| `didStart(block)` | 队列开始播某块（Session 据此更新「当前」） |
| `didPlayThroughSegment()` | 整段播完 |
| `didFinishSegment()` | 播完且该段已封 → 可释放 |

**掀在队列**（决策依据：只有队列知道「当前在哪」；接入层要知道就得反向订阅队列进度，
凭空多一条依赖）。

## 四个动作方法

**每个动作是一个原子方法，调用方不接触掐。** 依据：用户按一下期望「立刻安静 + 内容丢掉 +
下一个接上」，这个复合动作不能由调用方分两步拼——拼错会出「掐了但没掀」或「掀了但还在播」
两类极难测的 bug。先例：`speakUserInitiated` 已经是这么做的，注释写明「actor 可重入，
两步之间会插进别的消息」。

```
掐()          作废管道代号 + 取消在播合成与已排队音频；游标前移
掀页()        掐() → session.discardCurrentPage() → 接上（没有就收字幕）
掀段()        掐() → session.discardCurrentSegment()（同时立墓碑） → 接上
全掀()        掐() → 清空全部段 + 作废所有身份 → 接上
```

## 身份记账搬家清单

以下全属身份问题，**全部搬到 Session**：

| 现状 | 去处 |
|---|---|
| `enqueue` / `enqueueGrouped` / `beginTurn` / `endTurn` / `finishTurn` / `cancelTurn` | Session 的入队口 |
| `claimTurn` / `turnStack` / `bury` / `deadTurns` / `buryAllTurns` / `closeGroup` | Session |
| `sealIdleTurns` + `idleGraceSeconds` | Session 的兜底收尾 |
| **pi 双流「属主交还」** | **pi 适配器**——那是「这个号认不认得、属主是谁」的认证，与播放无关 |
| `playingPageID` | **消失**——游标取代 |

留在队列的：合成、背压、`pipelineSeq` 代号、连续播放管道、`waitForJobs` 挂起、
四个动作方法。

## 迁移路径

分步，每步都能独立验证。**每一步结束都跑 `make check-tts` 全量**——播报队列核心改动必须全量跑，
自检会悄悄腐烂成假绿。

| 步 | 做什么 | 验证 |
|---|---|---|
| 1 | 把身份记账整体搬进 Session（容器与游标不动，块仍弹出） | 全量绿；这一步是纯搬家，不改行为 |
| 2 | `playingPageID` 换成游标记录「当前页」 | 全量绿；顺手验一次「连按两下 Ctrl+2 不误删新内容」 |
| 3 | 游标改为不弹出 + 删页后重定位 | 全量绿；重点验预取门控期间掀页 |
| 4 | 四个动作收成原子方法，热键层不再接触掐 | 全量绿 |
| 5 | 接入层加帧版本号（约束三） | 旧客户端发老帧仍能播 |
| 6 | pi 的 TS 帧格式加跨语言契约测试（约束四） | 故意改坏一处 Swift 解析，测试必须红 |

## 风险

| 风险 | 说明 | 怎么防 |
|---|---|---|
| 掀页的彻底性 | 页号每批才送来，掀不彻底（需求层已写明的能力边界） | 不是本次能解；要解得让接入方预分配页号（协议变更） |
| `lastturn/` 时序错位 | Claude 的 Stop 反查可能指认错摞 | 风险在 hook 端，不在队列；接入层应能容忍收尾信号指认不到 |
| 容器大 | 一摞最多见过 19 页，段多时线性查找变慢 | 段/页用数组 + 游标记序号，不做字典；真慢了再上索引 |
| 迁移期两套逻辑并存 | 步骤之间可能出现「容器一份、真相一份」 | 每步都全量绿；不合并步骤 |

---

---

# 当前实现（尚未按上方方案重写）

这一半记的是**今天代码怎么写的**：连续播放管道、背压、管道代号、踩过的坑。
方案实施后，这一半要按新形态重写，届时本文上半的「迁移路径」即成为决策记录。

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
- **线性化点**：bargeIn 只 cancel 旧任务不清 `currentTask`；要立刻起新管道的调用方（enqueue/beginTurn）必须 `await currentTask.value`（`awaitCurrentPipelineFinished()`）等旧 producer+consumer **彻底退出**后才起新的，否则两个 consumer 并发 write 同一 player。
- 队列瞬时排空时：`turnOpen == true`（流式轮次还在生成）→ 挂起在 `waitForJobs()`（continuation 存入 `jobWaiters`），**不退出、不盖章**，但最多挂 2 秒（起点在等设备播空之后）——超时唤醒返回 false，由 `sealIdleTurns()` 把未结束的桶盖上，下一圈自然走进收尾；`turnOpen == false` → 退出循环 → consumer 排空 → 末端 drain → 收字幕（打「播报收尾」）。
- `signalJobs()` resume 并清空所有 `jobWaiters`，调用点只有：`enqueue`（新 job 到达）、`endTurn`（轮次结束）、`preemptCurrent`（掐的公共前置：打断/插队/掀摞）。三者覆盖了挂起的全部唤醒路径，无 continuation 泄漏。
- 轮次语义（分桶排队）：**打断权只归用户快捷键**，手动打断三档全是「掐 + 掀」——Ctrl+2 掐+掀当前页、Ctrl+1 掐+掀当前摞、Ctrl+Esc 掐+全掀 / 右⌘ 说话；Cmd+D 译文走**插队**（`speakUserInitiated`：只掐在播、译文桶插到队首，其余桶全保留）。`stop` 停止帧与 pi 新轮**不再打断**播报。队列按到达序存桶（每桶一轮，nil-turn 桶=普通播报），`processNext` 播完队首桶才前移：**旧轮播全、播完才进下一轮**——这是「按轮排队」的载体。同 `turnID` 的分块并入同桶顺序 append；新 turn 在队尾追加新桶，不打断在播旧轮。
  **两类轮次**：`turnID`（pi 流式，走 `turnStack` 认证 + `endTurn`）与**弱分组**（Claude 的 MessageDisplay，`enqueueGrouped`，**刻意不进 `turnStack`**——那是 pi 双流认证专用，混进来会把「属主交还」判错、pi 整轮没声音）。弱分组的**分组号是 `turn_id`（一次输入引发的全部回复 = 一摞）**，不是 `message_id`（一条 assistant 消息 = 一页）——一摞夹工具调用就有好几页，按页分桶的话 Ctrl+1 只能跳掉一页。**收尾主力 = `Stop` 钩子**：按 `session_id` 反查出 turn_id 精确收尾（`finishTurn`，只标 `ended`、**不立墓碑**——在途的页还要让它播完）。**空闲宽限兜底**：队列见底又仍有未结束的轮，先等设备播空（`waitUntilSilent()`：声音真停下才算起点），再静候 2 秒（`idleGraceSeconds`），等不到新内容就由 `sealIdleTurns()` 判说完（同样只盖章、不立墓碑，之后来页会揭封续播）。页级 `final` 只说明"这页说完"，认不得"整摞说完"，所以也不拿它收尾。（旧的「新的 turn 来了就把上一个盖上」判据**已删除**：它用全局单值认"上一个"，两个会话并行时会互相盖。）`skipCurrentBucket` 按轮丢**该轮的全部桶**——弱分组下一轮可能散在几个桶里，只弹队首会留下残部继续念。
- **播报字幕（可选）取「播放侧」而非合成侧**：每句的**首块音频**捎上该句文本（`AudioChunk.sentenceText`），`AudioPlayer` 在它被设备读出（`.dataConsumed`）时回调 → 队列转发给 `onCaption`。合成领先播放一两句，**从合成侧取会让字幕比声音早**（实测踩过，飞哥听出来了）；播放侧取则与声音对齐（误差约一个 IO 缓冲）。打断天然正确——被掐掉的句子的回调本就过不了世代校验；整队播完 / 全掀（`bargeIn`）广播 `nil` 收起。
- **三档打断的形象说法**（跟实现**同构**，动这段代码前先读它）：
  把播报想成一个**播音员 + 一摞摞稿纸**——**一摞 = 一桶**（一次输入引发的全部回复、一批普通播报、一条译文，各是一摞），**一张纸 = 一句**。
  要紧的是：**正在念的那张纸已经拿在手里、不在叠里了**（实现上就是 `popFrontJob` 把它弹出桶的那一刻）。
  - **轻（Ctrl+2）= 这一页剩下的不念了，翻页** → 从下一页的第一块接着念。实现：`preemptCurrent` 掐在播 + 丢掉桶里属于当前页的剩余块（`playingPageID` 是靶心），其余页的块原样留着
  - **中（Ctrl+1）= 整摞都不要了** → 连还没印出来的也不印（该摞后续分块立墓碑），直接拿下一摞。实现：`skipCurrentBucket`
  - **全掀（Ctrl+Esc）= 把桌上所有稿纸全扫到地上** → 一声不响（背景音乐不归它管）。右⌘ 说话同理：你要开口了，全场停播并让出麦克风。实现：`cancelAll`
  - **Cmd+D 译文 = 不抢别人的叠，只把译文这张插到最上面** → 掐掉手里正念的那张让它先响，其余叠一张没动。实现：`speakUserInitiated`
- **⚠️ 调用顺序必须先于状态判定：连接内的四个操作要按帧序落地**（`ConnectionHandler.StreamOpChain` 串成一链）。`{type:stream}` 首帧、每个入队块、`{end}`/`{cancel}` 原先各自 `Task {}` 投递到本 actor，**落地顺序全凭调度器**。实测 `{end}` 的 Task 抢在同一连接后一个入队 Task 之前执行：`endTurn` 已把轮次关闭（`turnOpen=0`），迟到的**同轮** `enqueue` 走同轮分支又把它打开，而此时再无帧可关它——分块全部播完后管道永久停在 `waitForJobs()`：`/health` 恒 `playing=true`、`queued=0`、无「播放收尾完成」，而**两把兜底都够不着**（背压看门狗要求 `pendingCount>0`，此刻已 0；drain 还没轮到）。黑盒 A-tail / E3 用例的「未收尾」即此，现场探针原始顺序为 `enqueue(open=1) → endTurn(open=0) → enqueue(open=1)`，6 秒后进入永久挂起。
- **轮次身份靠「轮次栈 + 墓碑」判定**（`turnStack` / `deadTurns`），**消费靠「队首桶」**：
  - **`turnStack` 只做 pi 双流的空流 `{cancel}` 认证**（回答「这个 turnID 是不是合法新轮、属主该不该交还」）；**`currentTurn` 是消费视角 = `frontBucket?.turnID`**（队首待播桶的轮），二者解耦、正交。非当前桶的迟到帧静默 return。
  - **`{cancel}` 的轮出栈**：被取消的轮没有内容需要保护，属主交还给被它顶掉的那一轮。**这条是 pi 「整轮没声音」的修复关键**：pi 一个用户消息会开两条流、其中一条刚开就被 `{cancel}`，而承载正文的是先开的那条——若取消的轮继续占着栈顶，正文那条就被永久判成过期旧轮、整轮哑掉。
  - **墓碑 `deadTurns`**：`{cancel}`、用户开口（`cancelAll()`）、Ctrl+1 跳过（`skipCurrentBucket`）之后该轮不再开口，含客户端关闭连接后 EOF 兜底补出的残尾。容量 64，防止无限增长。
  只判「不等于 currentTurn」是不够的：那会把新轮的首帧和旧轮的迟到帧混为一谈；只按「见过没见过」判也不行：会把**并行那条空流**的取消算到真正在跑的轮头上。
- **`cancelAll()` = 「全场闭嘴」的语义：停当场 + 作废全部流式轮**（`buryAllTurns()` + `bargeIn()`）。调用方只有右⌘（`speech`）与 Ctrl+Esc（`esc`）。**`{type:stop}` 停止帧已完全失效且无发送方**（hook.sh interrupt 已摘、ivox quiet 已删），收到时 ConnectionHandler 仅记日志忽略（留作护栏，防止旧帧被当正文念出来）。`turn` 顶替也不再经 bargeIn——新轮排队。
- **「掐在播」与「清场」拆成两层**：`preemptCurrent` 只作废管道代号 + 取消在播合成与已排队音频，**不动 `buckets`**；`bargeIn` 则是「先 `removeAll()` 再调它」= 全掀。由此派生三个「只掐不清」的入口：
  - **Cmd+D 念译文 = 插队**：`speakUserInitiated` = `preemptCurrent(.dict)` → 等旧管道退净 → 译文桶 `insert(at: 0)` **插到队首**。其余桶一个不丢，播完译文接着播（若想连当前桶一起丢，那是 Ctrl+1 的语义）。
  - **Ctrl+1 = 掐 + 掀当前摞**：`skipCurrentBucket` = 给当前摞立墓碑（`bury`，该摞后续分块也不再开口）→ `preemptCurrent` → 丢队首桶 → `pumpOrSettle()` 接着播下一桶；没有下一桶则收尾。
  - **Ctrl+2 = 掐 + 掀当前页**：`skipCurrentPage` = `preemptCurrent` → 丢掉桶里 `pageID == 当前页` 的剩余块 → `pumpOrSettle()`。**页号要在 claim 时记进 `playingPageID`**——正在念的那块早已弹出桶，光看桶认不出它属于哪页；页号为 nil（非 Claude 路径）时退化成「只掐在播」。
- **`pipelineSeq` 代号作废在途管道（修「旧 producer 消费新轮任务」）**：`Task {}` 是结构化外的子任务，**不继承取消**——`bargeIn` 的 `currentTask?.cancel()` 根本停不住已进 MLX 的 producer。故 `bargeIn`/`shutdown` 递增 `pipelineSeq`，producer 每轮循环、consumer 每次循环都比对「代号是否仍是自己的」，不等即立即退场。`currentTaskSeq` 同理：管道收尾只在 `currentTaskSeq == 自己` 时才清 `currentTask`，防止旧管道把新起的管道清掉。
- **收敛兜底 `pumpOrSettle()`**（原名 `pumpOrResume`——它那一步"恢复音乐"已随播报不再碰音乐而删除）：轮次顶替时序可能留下「有 job 但没管道」的孤儿态。`endTurn`/`cancelAll`/掀页掀摞 收尾统一走它——无管道且有活就补起管道，否则等旧管道退净、按需收字幕。任何路径结束都不会挂住。⚠️ **等它退净**：遇到「管道仍在退出中 + 已取消 + 无待播」时必须等（`awaitCurrentPipelineFinished()`），不能一律直接返回——否则 `currentTask` 还非 nil，收字幕那一支进不去，字幕就永远挂在屏幕上。
- **`drain()` 超时定时器绑定自身序号 `drainSeq`**：超时兜底的 `asyncAfter` 闭包必须校验 `drainSeq == 自己`，否则**上一次 drain 遗留的定时器会提前放行下一次 drain**，表现为尾音被掐（曾实测 `drain 超时强制返回（pendingCount=28 尾音=1.12s）`）。
- **`removeFirst` 前必须双重校验**：门控挂起期间 `bargeIn` 会 `jobs.removeAll()`，醒来后直接 `removeFirst()` 会 `EXC_BREAKPOINT`。先 `guard let job = jobs.first`，弹出前再确认 `jobs.first?.text == job.text`（队首仍是自己读到的那个 job）。

> **⚠️ v4.0.0 起：播报不再碰背景音乐。** 「修复历史」里的媒体竞态条目与 `↓ 跳段`
> 相关记录，都是 **4.0.0 之前**的设计——那时播报会借还音乐、且用单个 `↓` 跳段。
> 如今播报队列**一条媒体命令都不发**（借还只归语音输入，见上文「核心原则」），
> 打断也改成了三档快捷键。读「修复历史」时把 media 与 `↓` 相关行当历史即可。

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

1. **播报队列不发任何 media 命令**——借还背景音乐只归语音输入（`SpeechInputService`）。历史上这里有过两个固定出口（`processNext` 入口发 pause、退出点发 resume），v4.0.0 已整条删除
2. **新增退出条件时只改 `processNext` 末尾的 `if jobs.isEmpty`**——决策点集中在一处
3. **新增触发点（如新快捷键）只走 `cancelAll` 或 `bargeIn`**——不要直接 `currentTask?.cancel()`（`skipCurrent()` 已随「↓ 跳段」一并删除）
4. **保持 `await oldTask?.value`**——这是串行化的线性化点，去掉会重新引入竞态
5. **`cancelPendingPlayback()` 会递增 `generation`**——write 回调经 `guard generation == gen` 丢弃旧世代回调；不要移除该 guard，也不要绕过 `cancelPendingPlayback` 直接清零 `pendingCount`，否则旧回调会把计数减成负数
6. **`scheduleBuffer` 必须带 `completionCallbackType: .dataConsumed`**——旧 API（不带 callbackType）是 `.dataPlayedBack` 语义，播放末尾引擎 auto-shutdown 时回调永不触发，会重新引入 drain 超时；`.dataConsumed` 在数据被读出即回调，不依赖引擎存活
7. **多条 job 一次性入队时走批量入口 `enqueue([PlaybackJob])`**——逐条 `await enqueue` 时，若两段之间队列瞬时为空，`processNext` 会提前走一次收尾、下一段再重启管道（历史上表现为"播报中音乐反复跳动"，音乐现已不归播报管，但白起停管道仍要避免）。批量入口先 append 完再启动处理，消除该窗口
8. **不要在 job 之间重新引入 `await player.drain()`**——句间接力靠 AudioPlayer 连续 `scheduleBuffer` 排队，逐句 drain 会播空设备、重补 prime、重启调度，重新引入逐字卡顿。drain 只允许出现在 `processNext` 末端一次
9. **新增 `waitForJobs()` 的唤醒出口时必须同步加到 `signalJobs()`**——turnOpen 下管道挂起在 `jobWaiters`，任何让它该醒来的事件（入队/结束/打断）都必须经过 `signalJobs`，否则 continuation 永久挂起
10. **背压水位（4s/2s）调整只改 `AudioPlayer` 的 `highWaterFrames/lowWaterFrames`**——高水位是内存上限也是合成预取上限（约 48kHz Int16 单声道 ≈ 384KB/4s），低水位须低于高水位以形成滞后区间，避免在阈值边缘反复挂起/放行
11. **弱分组只在 `enqueueGrouped` 里管，绝不要接进 `turnStack`/`claimTurn`**——`turnStack` 是 pi 双流「属主交还」的认证栈，混入别的 id 会让 pi 的正文流被判成过期旧轮（**整轮没声音**）。弱分组要的只有两件事：「同 group 并桶」和「墓碑拦住后续批次」，都不需要栈。掀摞时记得连墓碑一起立（`skipCurrentBucket` 已做），全掀时记得把桶里的分组也立上（`buryAllTurns` 已做，它们不在 `turnStack` 里，不捞一遍就拦不住）
12. **流式连接的队列操作一律走 `ConnectionHandler` 的 `chain.hop {}`，不许直接 `Task { await queue.… }`**——顺序是协议语义的一部分（`{end}` 之后再无帧可关轮次）；裸 `Task {}` 落地乱序会让已关轮次被迟到分块重新打开，管道永久挂起（见上「按帧序落地」条）