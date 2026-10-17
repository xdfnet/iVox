import Foundation
import iVoxKit

// 播报播放层：只管「怎么把字念出来」——连续播放管道（合成/播放两条并发 task + 有界 PCM 流）、
// 掐（断在播）与字幕。谁在说话、说到哪、哪层被作废全归 `PlaybackSession`（身份层）。
// **不碰背景音乐**——暂停/恢复只归语音输入（录音时音乐会串进麦克风、干扰识别）。
// 四层文档见 docs/playback-purpose.md（目的）→ playback-sources.md → playback-requirements.md → playback-queue.md。

/// 一条待播报的文本。身份字段（摞/页）原样带给 Session，本层不做判断。
struct PlaybackJob: Sendable {
    let text: String
    let voiceID: String
    let source: String
    /// 所属摞（`turn_id`）；nil = 传统整段播报（ivox speak / hook.sh）
    let turnID: String?
    /// 这一块属于哪**页**（Claude 的 `message_id`）。掀页靠它；nil = 非 Claude 路径。
    let pageID: String?

    init(text: String, voiceID: String, source: String, turnID: String? = nil, pageID: String? = nil) {
        self.text = text
        self.voiceID = voiceID
        self.source = source
        self.turnID = turnID
        self.pageID = pageID
    }

    var asBlock: PlaybackBlock {
        PlaybackBlock(seq: 0, text: text, voiceID: voiceID, source: source, pageID: pageID)
    }
}

/// 管道里流的一小块音频：PCM +（**仅句首块**）这句的文本。
/// 文本跟着音频一起流到播放器，句首块被设备读出时正好用它报字幕——
/// 队列不必另存一张「已合成待播句子表」，省掉一处要跟打断/取消对齐的状态。
private struct AudioChunk: Sendable {
    let pcm: Data
    let sentenceText: String?
}

/// 打断来源：与 `PlaybackJob.source`（这段播报是谁发的）是一对账的标识——
/// 前者回答「谁在说」，这个回答「这次打断是谁干的」。打断权**只归用户物理快捷键**
/// （right⌘ 说话、Cmd+D 译文、Ctrl+Esc 闭嘴）；agent 流式轮只排队、不打断。
enum InterruptSource: Sendable, CustomStringConvertible {
    /// right⌘ / right⌃ 语音说话（SpeechInputService 检测到用户开口录音）
    case speech
    /// Cmd+D 划词翻译（用户主动朗读，speakUserInitiated）
    case dict
    /// Ctrl+Esc 手动闭嘴（GlobalKeyTap 组合热键）：用户不想说话、只想安静，静音播报即可。
    /// **不碰背景音乐**——借还音乐是右⌘ 录音那条的事（见文件头）
    case esc
    /// Ctrl+1 掀摞：丢正在播的这一**摞**（一次回复，连同后来的页），从下一摞接着播。
    /// 与 `.esc` 的分工——那个全场闭嘴，这个只掀当前、后面的照播。
    case skip
    /// Ctrl+2 掀页：丢掉当前这一**页**剩下的块，从下一页接着念。
    /// 手动打断三档里的「轻」（`.skip` = 中：掀整摞；`.esc`/`.speech` = 掀桌：全掀）。
    case skipPage
    /// 守护进程退出（shutdown），系统级清场，不是用户主动打断
    case shutdown

    var description: String {
        switch self {
        case .speech: return "speech"
        case .dict: return "dict"
        case .esc: return "esc"
        case .skip: return "skip"
        case .skipPage: return "skip-page"
        case .shutdown: return "shutdown"
        }
    }
}

actor PlaybackQueue {
    /// 身份层：段→页→块的容器与全部身份记账（墓碑、盖印、空闲宽限）。
    private let session = PlaybackSession()

    private var currentTask: Task<Void, Never>?
    /// 管道代号：起新管道 / 掐断时递增。在跑管道靠「自己的代号是否已过期」判断
    /// 该不该继续——非结构化 `Task {}` 的子任务不继承取消，单靠 cancel 停不住它们。
    private var pipelineSeq: UInt = 0
    /// `currentTask` 的代号，用于身份校验：仅当代号仍指向自己时才允许清空/接管。
    private var currentTaskSeq: UInt = 0
    private var generation: UInt = 0
    /// 最近一次打断的来源：底层取消日志（TTS 合成已取消）据此对上「是谁打断的」。
    /// 不用 actor 并发考虑——打断本身串行，写入与 processNext 读它都在本 actor 上。
    private var lastInterrupt: InterruptSource? = nil
    /// 空闲宽限的计时任务。**它不属于任何管道**——「还有话没说完」是身份层的事，
    /// 管道不起的时候也得有人在计时（2026-10-17 `P3`：块被掀光但摞没收尾时，
    /// 宽限寄生在管道循环里就永远没人跑，收尾挂死 47 秒）。
    private var graceTask: Task<Void, Never>?
    /// 宽限的世代号。作废一轮宽限靠**递增它**，不靠 cancel——
    /// 挂在 `withCheckedContinuation` 上的 Task 被 cancel **不会**解开 continuation，
    /// 那个 Waiter 会永远留在 Session 的等待表里，多来几轮就把状态搅乱（宽限时灵时不灵）。
    /// cancel 只加不删，是这里最隐蔽的一种泄漏。
    private var graceEpoch: UInt = 0

    /// 等「声音播完」的上限：设备卡死时别把宽限的起点也一起带死
    ///（宁可早一点判"这摞说完"，也不能再出现"永远判不完"）。
    private static let maxSilenceWaitSeconds: Double = 10

    /// 播报字幕接收端（Daemon 在配置开启时注入）：每开始念一句广播该句文本，收起广播 nil。
    /// 在**本 actor 上**被调用，实现方自己切回主线程再碰 UI。
    private var onCaption: (@Sendable (String?) -> Void)?
    private let player: AudioPlayer
    private let engine: TTSEngine
    private let media: MediaController
    init(engine: TTSEngine, mediaController: MediaController) {
        self.engine = engine
        self.player = AudioPlayer()
        self.media = mediaController
        // 字幕跟**播放**走（不是合成）：句首块被设备读出时才报，与声音对齐。
        // 回调在播放器的 serialQueue 上，跳回本 actor 再转发（onCaption 是本 actor 状态）。
        player.onSentenceStarted = { [weak self] text in
            Task { await self?.emitCaption(text) }
        }
    }

    func shutdown() {
        Log.info("PlaybackQueue 退出")
        lastInterrupt = .shutdown   // 退出会取消在跑合成，打上标识免得读成上一次打断的残留
        pipelineSeq &+= 1      // 让在跑管道的 producer/consumer 退出
        currentTask?.cancel()
        Task { await session.discardAll() }
        player.cancelPendingPlayback()
        player.stop()
        // 退出时的**安全网**，与"谁借的"无关：播报已不碰音乐（暂停/恢复只归语音输入），
        // 这里只为兜住"任何原因留下的暂停"——例如正在录音时 daemon 重启，不还就再也出不来。
        Task { await media.resume() }
    }

    /// 注入播报字幕接收端（`nil` = 关闭字幕）。
    /// 文本来自**播放侧**（`AudioPlayer.onSentenceStarted`：句首块被设备读出），不是合成侧——
    /// 合成领先播放一两句，从那儿取会让字幕比声音早。
    func setCaptionSink(_ sink: (@Sendable (String?) -> Void)?) {
        onCaption = sink
    }

    /// 音频侧报「这句开始响」→ 转发给字幕（已在本 actor 上）。
    private func emitCaption(_ text: String) {
        onCaption?(text)
    }

    /// 队列中等待播放的条数（/health 用）
    var pendingCount: Int { get async { await session.pendingCount } }
    /// 是否有正在处理的播报（/health 用）
    var isProcessing: Bool { currentTask != nil }

    // MARK: - 入队

    /// 流式轮次开始（pi 首帧）。**不打断旧轮**——打断权只归用户快捷键，新轮在队尾排队。
    func beginTurn(_ id: String, source: String) async {
        guard await session.beginTurn(id) else { return }   // 已作废 / 被顶掉的旧轮：忽略
        Log.info("流式轮次开始: source=\(source) turn=\(id)（排队，不打断）")
        await pumpOrSettle()
    }

    /// 流式轮次正常结束：盖印（空段可前移），放开宽限并唤醒管道。
    func endTurn(_ id: String) async {
        await session.sealTurn(id)
        await pumpOrSettle()
    }

    /// 流式轮次被取消（pi 空流 `{cancel}`）：丢弃本轮内容，自取消不占打断来源。
    func cancelTurn(_ id: String) async {
        Log.info("用户取消轮次 \(id)：丢弃本轮未播内容，自取消不占打断来源")
        await session.cancelTurn(id)
        await pumpOrSettle()   // 还有待播则补起管道，否则收尾（统一收敛点）
    }

    /// 常规入队（无分组整段播报）。
    /// **不抢麦**：回复到达时的播报若去抢，两个后台会话收尾就会互相掐掉对方的内容
    /// （实测 868 字长回复被 199ms 后的 84 字短回复整条掐掉）。按到达序排队、播全播完。
    func enqueue(_ newJobs: [PlaybackJob], turnID: String? = nil) async {
        guard !newJobs.isEmpty else { return }
        if let turnID {
            // pi 的轮：认证通过才入队，已作废的轮迟到帧静默丢弃。
            let accepted = await session.appendGrouped(newJobs.map(\.asBlock), group: turnID)
            guard accepted else { return }
        } else {
            await session.appendPlain(newJobs.map(\.asBlock))
        }
        await logQueueState(turn: turnID)
        await pumpOrSettle()
    }

    func enqueue(_ job: PlaybackJob) async {
        await enqueue([job], turnID: job.turnID)
    }

    /// 弱分组入队（Claude 的 MessageDisplay：一次回复按行批分多次短连接送来）。
    /// 分组号是 **`turn_id`（一次回复 = 一摞）**，不是 `message_id`（一条 message = 一页）——
    /// 「一摞 = 一段」是「Ctrl+1 掀整摞」成立的前提：一次回复里夹了工具调用就会有**好几页**，
    /// 按页分段的话 Ctrl+1 只能掀掉一页。
    func enqueueGrouped(_ newJobs: [PlaybackJob], group: String) async {
        guard await session.appendGrouped(newJobs.map(\.asBlock), group: group) else { return }
        await logQueueState(group: group)
        await pumpOrSettle()
    }

    /// 收尾指定的那一摞（Stop 钩子按 `session_id` 反查出的 `turn_id`）。**日常收尾的主力就是它**——
    /// Claude 一说"这轮完了"，字幕立刻归还，不必等空闲宽限。
    /// 只盖印、**不立墓碑**：Stop 说"我说完了"不等于该轮已死（同一摞的页可能还在路上）。
    func finishTurn(_ id: String) async {
        Log.info("收尾信号（这一摞说完了）: turn=\(id)")
        await session.sealTurn(id)
        await pumpOrSettle()
    }

    private func logQueueState(turn: String? = nil, group: String? = nil) async {
        let n = await session.pendingCount
        let id = turn ?? group ?? "-"
        Log.debug("队列状态: pending=\(n) processing=\(currentTask != nil) turn=\(id)")
    }

    // MARK: - 打断（掐 + 掀）：四个原子动作，热键层不再接触掐

    /// 取消所有播放（正在播的和排队中的），并作废全部流式轮次。
    /// 形象说法：**把桌上所有稿纸全扫到地上**——一声不响（背景音乐不归它管）。
    func cancelAll(origin: InterruptSource) async {
        Log.info("打断（来源=\(origin)）：作废全部流式轮次")
        lastInterrupt = origin
        await bargeIn(origin)   // bargeIn 内部丢弃 Session 全部内容并立墓碑
    }

    /// 掀页（Ctrl+2）：掐掉正在念的这一块，并丢掉容器里**属于当前页**的剩余块，从下一页接着念。
    /// 形象说法：**这一页撕到一半，剩下的不念了，翻页**（一页 = 一个 MessageDisplay）。
    /// 「跳播放块」没有意义——用户听不出块边界在哪，他感知的单位是页。
    ///
    /// **靶心用完即焚**：页靶心取的是「游标之后那一块所在的页」——正是他听到的那一页，
    /// 取完这次就作废，下次按压重新取。为什么必须这样：Claude 同一页按行批分多次增量入队，
    /// 掀掉当时已有的块之后这一页还可能继续来块；靶心若不清，第二次按压（他以为已经翻过去了、
    /// 并没有东西可跳）就会拿旧页号去删**刚到的新块**——表现就是"只按了一次该跳的，新内容却被跳过"。
    /// 取不到页号（page 为 nil，或当前没有块在播）时退化成"只掐在播"，不误删。
    func skipCurrentPage(_ origin: InterruptSource) async {
        // 领靶心（Session 内占位，用完即焚 + 治重入）与掐之间隔着 await，第二次按压会插进来：
        // 占位让它拿不到靶心，只掐不掀——见 PlaybackSession.claimCurrentPage 的注释。
        let page = await session.claimCurrentPage()
        Log.info("读下一页（来源=\(origin)）：丢掉当前页（\(page ?? "-")）的剩余块，从下一页接着念")
        await preemptCurrent(origin)
        onCaption?(nil)   // 被跳掉的内容立刻从字幕撤下；下一页开始响时会重新报
        await awaitCurrentPipelineFinished()   // 线性化：旧管道退净再起，避免两个 consumer 抢 player
        let dropped = await session.discardClaimedPage()
        // 丢了几块要落日志：翻页与"没翻动"在外部看起来一样（都是没声音），
        // 只有这一行能区分"靶心没对上（page 空 / 页号不匹配）"和"确实翻过去了"
        Log.info("本页剩余块已丢: page=\(page ?? "-") 块=\(dropped)")
        await pumpOrSettle()   // 还有块则接着播；若这摞正等下一批字则原地等
    }

    /// 掀摞（Ctrl+1）：掐掉正在念的这一块，并丢掉当前这一**摞**的全部内容，从下一摞接着播。
    /// 形象说法：**整摞都不要了**（一摞 = 一次回复），连还没印出来的也不再印。
    /// 与 `cancelTurn` 的区别：那个是「自取消不占打断来源」、也不掐在播（等它自己播完）；
    /// 这个是用户主动掀，必须立刻掐在播、丢段、前移。与 `cancelAll` 的区别：那个清全场，
    /// 这个只丢当前、后面的照播。
    func skipCurrentBucket(_ origin: InterruptSource) async {
        Log.info("跳过当前摞（来源=\(origin)）：丢整摞，从下一摞接着播")
        await preemptCurrent(origin)
        onCaption?(nil)   // 被掀掉的那一摞立刻从字幕撤下；下一摞开始响时会重新报
        await awaitCurrentPipelineFinished()   // 线性化：旧管道退净再前移
        await session.discardCurrentSegment()   // 内含立墓碑：后续增量不再开口
        await pumpOrSettle()   // 有下一摞则起管道接着播；没有则收尾
    }

    /// 用户主动要求开口（Cmd+D 念译文）：**插队**——掐掉正在播的那一句让译文立刻响，
    /// 但**不掀桌**：其余排队内容照旧（播完译文接着播）。
    ///
    /// 与 `enqueue(_:turnID: nil)` 的「只排队」语义**相反**——那条是 agent 自动汇报，
    /// 不该抢麦（否则两个后台会话收尾会互相掐掉对方内容）；这条是用户自己按的，必须立刻响。
    /// 做成**一个原子方法**而不在调用方 `掐 + 入队` 两步拼：actor 可重入，两步之间会插进别的消息。
    func speakUserInitiated(_ newJobs: [PlaybackJob]) async {
        guard !newJobs.isEmpty else { return }
        Log.info("用户主动开口（Cmd+D 划词译文）：插队到队首，其余排队内容保留")
        await preemptCurrent(.dict)
        await awaitCurrentPipelineFinished()   // 线性化：旧管道退净再起新的
        // 译文自成一段插到队首立刻播；其余段顺序不动。
        await session.appendFirst(newJobs.map(\.asBlock))
        if currentTask == nil { startPipeline() }
    }

    // MARK: - 内部

    /// 收敛点（**必须原子**）：任何路径结束时都在这里落一次——
    /// 还有待播就补起管道；队列空了且没有没收尾的摞就收字幕；
    /// **没有块但还有摞没收尾时，起空闲宽限计时**（不依赖管道在跑）。
    private func pumpOrSettle() async {
        // **宽限先起，且不等任何管道**：它等的是「还有摞没收尾」这件事本身。排在
        // `awaitCurrentPipelineFinished()` 后面会被管道带死——那条 await 在预取背压的
        // continuation 上卡住时退不净，宽限就永远起不来，收尾锚点日志一辈子不出现
        //（2026-10-17 `P3` 实测：两次掀页行为全对，之后日志直接断掉）。
        if !(await session.hasPending), await session.anyUnsealed {
            startIdleGrace()
        }
        // **这里刻意不等旧管道退净**：被掐的管道可能挂在 `player.drain()` 或预取背压的
        // continuation 上迟迟不退出，这一等就把后面所有收尾逻辑（起宽限、收字幕）全带死
        //（2026-10-17 `P3` 实测：队列已空、health 已空闲，但两条收尾日志一条都没打）。
        // 线性化由**旧管道自己**保证：它在收尾时把 `currentTask` 置 nil，再回头调一次
        // `pumpOrSettle()`；此处 `startPipelineIfPending` 见 `currentTask != nil` 就补不起新管道，
        // 活交给旧管道退净后那一轮去做。真正要「立刻写播放器」的地方（掀页/掀摞/插队）各自
        // 显式 `await awaitCurrentPipelineFinished()`，不受影响。
        if await session.hasPending {
            startPipelineIfPending()
            return
        }
        if currentTask == nil, !(await session.anyUnsealed) {
            invalidateIdleGrace()
            onCaption?(nil)
            Log.info("播报收尾: 队列已空，字幕收起")
        }
    }

    /// 空闲宽限计时：没有块可播，但还有摞没收尾 → 等 2 秒；到点若仍无新内容就判「说完了」。
    ///
    /// 这一段**曾经寄生在播放管道的循环里**，于是「块被掀光、摞没收尾」时管道不起、
    /// 计时器也没人跑——那一摞永远悬着，字幕收不掉（2026-10-17 `P3` 实测挂死 47 秒）。
    /// 现在它归身份层：等的是「还有话没说完」这件事，跟当前有没有管道在播无关。
    private func startIdleGrace() {
        guard graceTask == nil else { return }
        graceEpoch &+= 1
        let epoch = graceEpoch
        graceTask = Task { [weak self] in
            guard let self else { return }
            let received = await self.session.waitForContent { [weak self] in
                await self?.waitUntilQuiet()
            }
            await self.idleGraceElapsed(epoch: epoch, receivedContent: received)
        }
    }

    /// 作废当前这轮宽限（不 cancel 它的 Task，见 `graceEpoch` 的注释）。
    private func invalidateIdleGrace() {
        graceEpoch &+= 1
        graceTask = nil
    }

    private func idleGraceElapsed(epoch: UInt, receivedContent: Bool) async {
        guard epoch == graceEpoch else { return }   // 已被新一轮取代，别去动别人的 graceTask
        graceTask = nil
        // 等来了新货：入队路径已经起了管道/起了新宽限，但**这里必须再收敛一次**——
        // 那次起宽限可能正好撞上 graceTask 还占着而被挡（2026-10-17 `P3` 实测），
        // 不补这一下就没人接班，这一摞永远收不掉。
        guard !receivedContent else { await pumpOrSettle(); return }
        // 又来了活（管道起播期间新内容到）：宽限只是猜「说完了」，不能在播到一半时盖印。
        guard !(await session.hasPending) else { return }
        await session.sealIdle()
        await pumpOrSettle()
    }

    /// 等设备把已排队音频播完（声音真的停下），最多等 `maxSilenceWaitSeconds`。
    ///
    /// 用轮询而不是"播空回调 + continuation"：① 这段只持续最后一块的播放时长、粒度是秒，200ms 一问足够；
    /// ② **回调式挂起在设备卡死时会永久卡住**，反而把宽限的起点也带死——轮询天然带超时，卡到上限就走，
    /// 收尾照样能到。代价是每 200ms 唤醒一次 actor，只发生在队列见底的这几秒。
    private func waitUntilQuiet() async {
        guard player.queuedFrames > 0 else { return }
        let deadline = Date().addingTimeInterval(Self.maxSilenceWaitSeconds)
        while player.queuedFrames > 0, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// 掐掉「正在播的这一句/这一轮」：作废管道代号 + 取消在播 + 取消已排队合成与音频。
    /// **不动 Session 容器**——它是「插队」与「掀桌」的公共前置：插队（Cmd+D 译文）只掐在播、
    /// 保留其余排队内容；掀桌（bargeIn）先清场再调它。
    /// 不在此清 currentTask——由旧 processNext 自然结束时自清；调用方若要立刻起新管道，
    /// 必须 `await awaitCurrentPipelineFinished()`（线性化点），否则新旧两个 consumer 会并发
    /// write 同一个 player、争夺单一背压 continuation 槽，造成 continuation 泄漏/竞态。
    private func preemptCurrent(_ origin: InterruptSource?) async {
        // nil = 自取消（用户放弃自己那轮），不是从别人手里抢喇叭，不占打断来源。
        let label = origin?.description ?? "自取消"
        lastInterrupt = origin
        pipelineSeq &+= 1      // 作废在跑管道：其 producer/consumer 靠代号不等立即停止
        currentTask?.cancel()
        await session.signal()  // 挂在 Session 里的宽限等待立刻作废（掐了就不必再宽限）
        await engine.cancelActiveSynthesis(reason: label)   // 显式作废旧纪元排队合成，不依赖任务取消传播
        player.cancelPendingPlayback()
    }

    /// 掀桌：掐掉在播 + 清空全部排队内容（右⌘ 说话 / Ctrl+Esc 闭嘴）。
    private func bargeIn(_ origin: InterruptSource?) async {
        let label = origin?.description ?? "自取消"
        let n = await session.pendingCount
        Log.info("打断（来源=\(label)）：取消在播、清空队列(pending=\(n))、作废管道 seq\(pipelineSeq&+1)")
        await session.discardAll()   // 清容器 + 所有摞立墓碑（后续增量一律不开口）
        onCaption?(nil)   // 掀桌：字幕立刻收（插队/掀摞不走这里——它们的字幕由下一句广播接续）
        await preemptCurrent(origin)
    }

    /// 线性化点：等当前管道（producer+consumer）彻底退出后再起新的。
    private func awaitCurrentPipelineFinished() async {
        guard let old = currentTask else { return }
        let seq = currentTaskSeq
        _ = await old.value
        if currentTaskSeq == seq { currentTask = nil }   // 挂起期间若已起新管道，别把它清掉
    }

    /// 起一条新管道（producer+consumer），并登记其身份序号。
    private func startPipeline() {
        pipelineSeq &+= 1
        let seq = pipelineSeq
        currentTaskSeq = seq
        invalidateIdleGrace()   // 有活要播了，宽限不必再等
        currentTask = Task { await processNext(seq: seq) }
    }

    /// 仅在无管道且有活时起新管道（拆旧管道后的补起）。
    private func startPipelineIfPending() {
        if currentTask == nil { startPipeline() }
    }

    /// 连续播放管道：合成 / 播放拆成两条并发 task，中间用有界流接 PCM。
    /// - 合成 task 不停取下一句合成，句间经 `awaitPrefetchCapacity` 门控（排队音频超 4s 就先别
    ///   开下一句），因此始终领先播放一两句，设备不会在句间播空；
    /// - 播放 task 只负责 `player.write`，背压只阻塞播放、不再挡合成。
    private func processNext(seq: UInt) async {
        generation &+= 1
        let gen = generation
        // 这里原本是 `await media.pause()`（播报"让路"、借走背景音乐）。**已删**：借还背景音乐
        // 只留给语音输入——录音才真的需要安静（音乐会串进麦克风、干扰识别），播报不碰它。
        // 全项目现在只有 `SpeechInputService` 调 pause/resume。

        // PCM 管道：unbounded 只承接「预取门控允许的提前量」（领先一两句），
        // 真正的容量上移到句间 awaitPrefetchCapacity 判定，不会无限堆积。
        let (pcmAsync, pcmContinuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)

        let producer = Task {
            defer { pcmContinuation.finish() }
            while !Task.isCancelled {
                if pipelineSeq != seq { return }   // 已被掐断作废：立即退出，不再合成
                guard let cursor = await session.nextCursor() else {
                    // 没有块可播了。有没收尾的摞就交给宽限（**这里不能等**：管道下方就是
                    // `pumpOrSettle`，它会另起 graceTask，与本管道无关），没有就整条退出。
                    return
                }
                let job = cursor.block
                // 门控/等待可能挂起较久，返回后先看取消：已被掐断就别再发起合成
                try Task.checkCancellation()

                let batchID = String(UUID().uuidString.prefix(6))
                Log.info("TTS 合成开始 [\(job.source)-\(batchID)] chars=\(job.text.count)")
                let startedAt = Date()
                var claimed = false
                do {
                    try await waitUntilEngineReady()
                    try Task.checkCancellation()

                    // 预取门控：已排队音频足够多就先别开下一句，等设备消费到低水位。
                    try await player.awaitPrefetchCapacity()
                    try Task.checkCancellation()   // 门控返回时可能已被取消，绝不带取消进模型

                    // claim：门控挂起期间可能被掀掉。**游标不弹出容器**，所以这里不用改容器，
                    // 只要确认这一块还在（在播）就合成；不在了（掀掉了）就跳过它、游标照常前移。
                    if await session.nextCursor()?.seq != cursor.seq { continue }
                    claimed = true
                    let stream = await engine.synthesizeStream(text: job.text, voiceID: job.voiceID)

                    // 句首块捎上这句的文本：播放器在它被设备读出时报字幕（跟随声音，而非合成）
                    var isFirstBlock = true
                    for try await pcm in stream {
                        // MLX 流不响应中途取消：一旦发起本句只能跑完，但被作废后不再向下游灌 PCM
                        if Task.isCancelled || pipelineSeq != seq { break }
                        pcmContinuation.yield(AudioChunk(pcm: pcm,
                                                         sentenceText: isFirstBlock ? job.text : nil))
                        isFirstBlock = false
                    }
                    try Task.checkCancellation()
                } catch is CancellationError {
                    Log.info("TTS 合成已取消 [\(job.source)-\(batchID)]（打断来源=\(lastInterrupt?.description ?? "自取消")）")
                    throw CancellationError()
                } catch {
                    Log.error("TTS 合成失败: \(error)")
                }
                // 游标前移：无论合成成功、失败、被取消，这一块都过去了——不前移就是死循环。
                await session.commit(cursor)
                let elapsed = String(format: "%.1f", -startedAt.timeIntervalSinceNow)
                if pipelineSeq != seq {
                    // MLX 不响应中途取消：打断后被掐的这句仍跑完，但已作废。别让它显示成
                    // 普通「完成」（打断后紧邻的完成会被人误读成「没掐住」）。
                    Log.info("TTS 合成作废（MLX 不响应中途取消，这句跑完才停）[\(job.source)-\(batchID)]（打断来源=\(lastInterrupt?.description ?? "自取消")） \(elapsed)s")
                } else if claimed {
                    Log.info("TTS 合成完成 [\(job.source)-\(batchID)] \(elapsed)s")
                }
            }
        }

        // 播放 task：消费 PCM 连续排队，句间零停顿；取消后绝不再 write
        //（否则会和下一轮管道并发争用 player 的单一背压 continuation，造成泄漏/串音）。
        let consumer = Task {
            for await chunk in pcmAsync {
                if Task.isCancelled { break }
                // 已被掐断作废：立刻停止灌 PCM。write 是「进入时取世代」，作废后再进来的
                // write 会取到新世代、通过世代校验，把旧轮的缓冲 PCM 排进播放器——旧音频因此继续
                // 响（打断失效），旧管道也迟迟不退出（新轮在 awaitCurrentPipelineFinished 干等）。
                if pipelineSeq != seq { break }
                await player.write(chunk.pcm, startsSentence: chunk.sentenceText)
            }
        }

        // producer 正常 finish → defer 里 finish 流，consumer 的 for-await 排空剩余 PCM 后
        // 自然结束。正常路径绝不能提前 consumer.cancel()：此刻 AsyncStream 里可能还缓冲着
        // 最后一句的多块 PCM，cancel 后循环在 isCancelled 处 break，会整块丢掉尾音、drain
        // 只等到已 schedule 的部分，表现为「内容没念完就收尾、字幕提前收起」。
        // 仅当整条任务真被掐断取消时，才 cancel consumer 让它立刻弃掉残余。
        _ = try? await producer.value
        if Task.isCancelled { consumer.cancel() }
        _ = try? await consumer.value

        // 整条管道末端：等所有已排队音频真正播完（含跨块的尾音）；在途音频作废由
        // bargeIn/cancelAll 的 cancelPendingPlayback 完成（其已递增 generation）。
        if !Task.isCancelled, gen == generation {
            try? await player.drain()
        }
        if currentTaskSeq == seq { currentTask = nil }   // 已被新管道顶替则不清
        await Task.yield()
        // 收尾窗口兜底：drain 等待尾音期间新入队的内容，旧管道正在收尾、currentTask 尚非 nil，
        // 入队路径不肯起新管道——这里须回头收敛一次，否则新内容永久躺着
        //（漏播根因，实测 17:14 claude 317字 5块入队后躺在队列零合成）。
        await pumpOrSettle()
    }

    private func waitUntilEngineReady() async throws {
        try Task.checkCancellation()
        switch await engine.state {
        case .ready: return
        case .failed(let msg): throw PlaybackError.ttsUnavailable(msg)
        case .notStarted, .loading:
            Log.debug("TTS 模型尚未就绪，等待通知")
            await engine.waitUntilReady()
        }
    }
}

enum PlaybackError: Error {
    case ttsUnavailable(String)
}
