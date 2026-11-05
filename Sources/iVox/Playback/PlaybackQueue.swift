import Foundation
import iVoxKit

// 播报播放层：只管「怎么把字念出来」——连续播放管道（合成/播放两条并发 task + 有界 PCM 流）、
// 掐（断在播）与字幕。队列里有哪些页、哪一页被放弃全归 `PlaybackSession`（身份层）。
// **不碰音乐的播放状态**——暂停/恢复只归语音输入（录音时音乐会串进麦克风、干扰识别）；
// 汽水音乐压音量也不归它：那是「屏幕上有没有东西占着」的判据，归浮窗服务
// （`OverlayService`，见 `SodaVolumeDucker`）。
// 播报四层文档见 docs/playback/：purpose（目的/取舍）→ sources → requirements → queue。

/// 一条待播报的文本（合成单位）。身份字段（来源）原样带给 Session，本层不做判断。
struct PlaybackJob: Sendable {
    let text: String
    let voiceID: String
    let source: String

    init(text: String, voiceID: String, source: String) {
        self.text = text
        self.voiceID = voiceID
        self.source = source
    }

}

/// 管道里流的一小块音频：PCM +（**仅句首**）这句的文本。
/// 文本跟着音频一起流到播放器，句首被设备读出时正好用它报字幕——
/// 队列不必另存一张「已合成待播句子表」，省掉一处要跟打断/取消对齐的状态。
private struct AudioChunk: Sendable {
    let pcm: Data
    let sentenceText: String?
    /// 这一批 PCM 属于哪一句（`PlaybackSentence.seq`）。透传到 `AudioPlayer.write` 后由它
    /// 在设备读出时上报，身份层据此推进发声点——**打断起点由此与合成进度彻底分家**。
    let seq: UInt
}

/// 打断归因（档位 × 入口）见 `InterruptOrigin.swift`。
///
/// 与 `PlaybackJob.source`（这段播报是谁发的）是一对账的标识——前者回答「谁在说」，
/// 这个回答「这次打断是谁干的、动了哪一档」。打断权**只归用户物理快捷键**
/// （Ctrl+1 掀页 / Ctrl+2 全掀）；接入方的增量只排队、不打断。
///
/// **右⌘说话不在这里**：那是「你停一下」（`pausePlayback()`：设备停渲染、内容一条不删），
/// 不是「你别说了」（这两档：内容丢弃）。
actor PlaybackQueue {
    /// 身份层：页→句的容器与全部身份记账。
    private let session: PlaybackSession

    private var currentTask: Task<Void, Never>?
    /// 管道代号：起新管道 / 掐断时递增。在跑管道靠「自己的代号是否已过期」判断
    /// 该不该继续——非结构化 `Task {}` 的子任务不继承取消，单靠 cancel 停不住它们。
    private var pipelineSeq: UInt = 0
    /// `currentTask` 的代号，用于身份校验：仅当代号仍指向自己时才允许清空/接管。
    private var currentTaskSeq: UInt = 0
    private var generation: UInt = 0
    /// 打断归因：**按管道代号记**，不记「最近一次」。
    ///
    /// 为什么不能只留一个单槽：一次打断作废的是**当时在跑的那条管道**，
    /// 单槽会被后一次打断覆盖——于是先被掐的那条管道的合成日志会写成后一次打断的人
    /// （2026-10-26 修：查「谁打断的」查错人，比查不到更坏）。
    /// 管道自己的日志回头查它自己的代号，故不会认错人。
    ///
    /// 不用 actor 并发考虑——打断本身串行，写入与 processNext 读它都在本 actor 上。
    private var interruptOriginBySeq: [UInt: InterruptOrigin] = [:]

    /// 正在念译文（插队节点在出声）：同时只允许一个。
    private var isSpeakingInterruption = false
    /// 最近一帧字幕：暂停/恢复时用它把字幕**接回去**（译文念完，字幕回到原来那一页）。
    private var lastCaptionFrame: CaptionFrame?
    /// **播报总开关**：关掉后进来的内容一律丢弃、正在念的立刻闭嘴；
    /// 守护进程与其余能力（热键、翻译、微信、Web 控制台）照常在跑。
    private var enabled: Bool

    /// 播报字幕接收端（Daemon 在配置开启时注入）：每开始念一句广播**歌词式的一帧**
    ///（这一页的句子 + 念到第几句），收起广播 nil。
    /// 在**本 actor 上**被调用，实现方自己切回主线程再碰 UI。
    private var onCaption: (@Sendable (CaptionFrame?) -> Void)?
    private let player: AudioPlayer
    private let engine: any TTSProviding
    private let media: MediaController
    /// 等设备静音的上限（秒）：设备卡死时不至于把收尾也带死。
    private static let maxSilenceWaitSeconds: Double = 10
    init(engine: any TTSProviding, mediaController: MediaController,
         enabled: Bool = PlaybackConfig.defaultEnabled) {
        self.engine = engine
        self.player = AudioPlayer()
        self.media = mediaController
        self.enabled = enabled
        // 队列落盘：daemon 挂了之后靠它把没播完的内容捞回来（开不了就只在内存里）
        self.session = PlaybackSession(store: PlaybackStore.makeDefault())
        // 字幕跟**播放**走（不是合成）：句首被设备读出时才报，与声音对齐。
        // 回调在播放器的 serialQueue 上，跳回本 actor 再转发（onCaption 是本 actor 状态）。
        player.onSentenceStarted = { [weak self] text, seq in
            Task { await self?.emitCaption(seq) }
        }
        // 发声点：播放器报「哪一句的 PCM 被设备读出」这个**事实**，身份层存位置、推导起点。
        // 本层一个字的推导都不做——三层各干各的（见 PlaybackSession 文件头）。
        player.onBlockConsumed = { [weak session] seq in
            Task { await session?.noteConsumed(seq) }
        }
    }

    func shutdown() {
        Log.info("PlaybackQueue 退出")
        // 退出会取消在跑合成：给那条管道打上「退出清场」的归因，
        // 免得它的合成日志读成上一次打断的残留。
        let origin = InterruptOrigin(.shutdown, .system)
        noteInterrupt(origin)
        pipelineSeq &+= 1      // 让在跑管道的 producer/consumer 退出
        currentTask?.cancel()
        Task { await session.discardAll() }
        player.cancelPendingPlayback()
        player.stop()
        // 退出时的**安全网**，与"谁借的"无关：播报已不碰音乐（暂停/恢复只归语音输入），
        // 这里只为兜住"任何原因留下的暂停"——例如正在录音时 daemon 重启，不还就再也出不来。
        Task { await media.resume() }
    }

    /// 播报总开关的当前状态（`ivox status` / `/health` 报它）。
    var isEnabled: Bool { enabled }

    /// 开/关播报能力。
    ///
    /// **关**：正在念的立刻闭嘴、排队的全清空、之后进来的内容一律丢弃
    /// （不留着等开回来——攒着一大批突然开闸更难收拾），**并把 TTS 模型释放掉**
    /// （人主动关的，模型就没了存在理由——留着白占几 G 显存）。
    /// **开**：从下一条新内容开始照常念；刚才丢弃的内容不会补播。模型按需重新加载。
    func setEnabled(_ newValue: Bool) async {
        guard newValue != enabled else { return }
        enabled = newValue
        if newValue {
            Log.info("播报已开启")
            // 模型重新加载（后台跑，不挡着这次调用返回；队列「等引擎就绪」那一步会等）
            await engine.resumeModel()
        } else {
            // 清场走「全掀」那条路：掐在播 + 清队列 + 收字幕，一次到位。
            await bargeIn(InterruptOrigin(.disablePlayback, .request("ivox-playback")))
            // 模型还回去：释放的是**内存**，不是「再也合成不了」——
            // 别的入口（socket 直连 {type:tts}）真要声音时，仍会按需把它加载回来。
            await engine.releaseModel()
            Log.info("播报已关闭：正在念的停了，排队的清空，之后进来的内容丢弃，TTS 模型已释放")
        }
    }

    /// **收件口的闸**：播报关着的时候，进来的内容一律丢弃。
    /// 所有进队路径（整页 / 插队朗读）都过这一处，一处判完。
    private func accept(_ jobs: [PlaybackJob]) -> Bool {
        guard enabled else {
            let chars = jobs.reduce(0) { $0 + $1.text.count }
            Log.info("播报已关闭，丢弃 \(jobs.count) 句（\(chars) 字）")
            return false
        }
        return true
    }

    /// 注入播报字幕接收端（`nil` = 关闭字幕）。
    /// 时机来自**播放侧**（`AudioPlayer.onSentenceStarted`：句首被设备读出），不是合成侧——
    /// 合成领先播放一两句，从那儿取会让字幕比声音早。
    /// 把上次没播完的内容捞回来（daemon 起来时做一次，在接单之前）。
    func restorePersisted() async {
        await session.restoreIfNeeded()
        // **恢复出来的内容得有人开管道**：管道是「入队」时起的，
        // 恢复这条路不经过它——不显式起一次，内容就躺在队列里没人念
        //（2026-10-26 实测踩到：恢复日志打了、health 里 queued=2，就是不播）。
        await pumpOrSettle()
    }

    func setCaptionSink(_ sink: (@Sendable (CaptionFrame?) -> Void)?) {
        onCaption = sink
    }

    /// 收起字幕（同时清掉「暂停时要接回去的那句」——内容都没了，没什么可接的）。
    private func hideCaption() {
        lastCaptionFrame = nil
        onCaption?(nil)
    }

    /// 音频侧报「这句开始响」（带着句号）→ 问身份层要「这一页的句子 + 第几句」→ 给字幕。
    private func emitCaption(_ seq: UInt) async {
        guard let ctx = await session.captionContext(forSeq: seq) else { return }
        let frame = CaptionFrame(lines: ctx.lines, index: ctx.index)
        lastCaptionFrame = frame
        onCaption?(frame)
    }

    /// 队列中等待播放的条数（/health 用）
    var pendingCount: Int { get async { await session.pendingCount } }
    /// 是否有正在处理的播报（/health 用）
    var isProcessing: Bool { currentTask != nil }
    /// 用户此刻正在听的页（/health 用）。
    ///
    /// **这是打断起点的对外只读投影**：掀页取的就是它（`session.takeHeadPage()`），
    /// 所以黑盒脚本按压前后各读一次，就能量出「掀掉的是不是正在听的那一页」。
    /// nil = 还没出声（冷启动）或设备已播空。
    /// `audiblePage` 是**资料室自编的页号**，任何来源都报得出。
    var audiblePage: Int? { get async { await session.headPageNo } }

    // MARK: - 入队

    /// **入队一页**（一条 assistant 消息）。
    ///
    /// **队列纯粹先来先进**：页按到达顺序排，不分组、不排队次。
    /// 一个接入方的一轮回复有多页，就有多页挨着进队列；另一个接入方此刻送来的页
    /// 排在它们后面——谁都不插队。
    ///
    /// - Returns: 这一页的自编页号（`nil` = 内容为空）。
    @discardableResult
    func enqueuePage(text: String, jobs: [PlaybackJob]) async -> Int? {
        guard !jobs.isEmpty else { return nil }
        guard accept(jobs) else { return nil }
        let source = jobs[0].source
        let pageNo = await session.appendPage(text: text,
                                              sentences: jobs.map(\.text),
                                              voiceID: jobs[0].voiceID,
                                              source: source)
        guard let pageNo else { return nil }
        // **播报员报备**：把资料室刚给的页号原样播出来。
        // 有了它，「哪一块属于哪一页」从收下那一刻就在日志里，掀的时候不必再推断——
        // 掀变成查号，所以怎么按都不会掀错。
        Log.info("资料室收下：第\(pageNo)页 来源=\(source) 字数=\(text.count) 句=\(jobs.count)")
        await pumpOrSettle()
        return pageNo
    }

    // MARK: - 打断（掐 + 掀）：两个原子动作，热键层不再接触掐

    /// 取消所有播放（正在播的和排队中的）。
    /// 形象说法：**把桌上所有稿纸全扫到地上**——一声不响（背景音乐不归它管）。
    ///
    /// **这是「你别说了」**：内容丢。**不留墓碑**——这一下之后再来的内容照常播。
    ///
    /// **档位（全掀）在这里落定**，调用方只负责说「谁干的」（`trigger`）——
    /// 档位由「调用哪个方法」决定，一处写死，别的层只带入口下来。
    func cancelAll(_ trigger: InterruptTrigger) async {
        let origin = InterruptOrigin(.skipAll, trigger)
        Log.info("打断（来源=\(origin)）：作废全部排队内容")
        await bargeIn(origin)   // bargeIn 内部丢弃 Session 全部内容
    }

    // MARK: - 暂停（用户要说话）：停一下，不删

    /// **暂停输出，内容一条不删。**
    ///
    /// 与手动打断的区别就是飞哥那两句：**手动 = 「你别说了」（丢）**，
    /// **说话 = 「你停一下」（留着）**。右⌘说话时麦克风会拾到正在播的声音、识别就乱，
    /// 所以要让设备先闭嘴；但用户没说「不要听」，话说完就该接着播。
    ///
    /// 只停**设备渲染**，管道与容器一概不动：已排队的音频原样留在设备队列里，
    /// 队列里的内容照旧排队，Claude 期间送来的页照旧入队。说话结束 `resumePlayback()` 从原处接着播。
    func pausePlayback() {
        player.pauseOutput()
    }

    /// 恢复输出：从暂停处接着播（用户说完话了）。
    func resumePlayback() {
        player.resumeOutput()
    }

    /// 掀页（Ctrl+1）：掐掉正在念的这一句，并丢掉**用户此刻正在听的那一页**的剩余内容，
    /// 从下一页接着念。形象说法：**这页不要了，听下一页**（一页 = 一个 MessageDisplay）。
    ///
    /// 起点取「正在听的那一页」——纯容器结构事实。
    /// **且必须在掐之前就摘走**（`takeHeadPage` 即摘走）：掐在播要 await 旧管道退净，
    /// 那期间游标会 commit 掉正在响的最后一句、越到下一页，再取靶心就晚了
    ///（2026-10-17 18:52 实测：摞级现场，页级同一个偏差）。
    func skipCurrentPage(_ trigger: InterruptTrigger) async {
        let origin = InterruptOrigin(.skipPage, trigger)
        let taken = await session.takeHeadPage()   // 起点此刻定死，掐不掐都拿它
        await preemptCurrent(origin)
        hideCaption()   // 被跳掉的内容立刻从字幕撤下；下一页开始响时会重新报
        await awaitCurrentPipelineFinished()   // 线性化：旧管道退净再起，避免两个 consumer 抢 player
        // **合成进度退回续播点**：掐管道时已经把「排好队但还没出声」的音频作废了，
        // 而游标已经越过它们 → 那些页再也不会被合成、再也听不到（2026-11-03 实测：
        // 合成跑在播放前 7 页，掀掉正在听的那页后，第 11~17 页整片消失）。
        // 退回去等于让它们回到「还没合成」，重新排队、重新出声。
        let requeued = await session.resumeSynthesis(from: taken?.nextSeq ?? 0)
        // 起点与丢了多少都要落日志：掀页与"没翻动"在外部看起来一样（都是没声音），
        // 只有这两行能区分「当时没东西可掀」和「确实翻过去了、翻的是哪一页」。
        Log.info("这页不要了，听下一页（来源=\(origin)）：已掀 第\(taken?.pageNo.description ?? "-")页 句=\(taken?.dropped ?? 0) 重新排队=\(requeued)句")
        await pumpOrSettle()   // 还有内容则接着播；没有则收尾
    }

    /// 用户主动要求开口（Opt+Z 念译文）：**插队**——掐掉正在播的那一句让译文立刻响，
    /// 但**不掀桌**：其余排队内容照旧（播完译文接着播）。
    ///
    /// 与 `enqueuePage` 的「只排队」语义**相反**——那条是 agent 自动汇报，
    /// 不该抢麦（否则两个后台会话收尾会互相掐掉对方的内容）；这条是用户自己按的，必须立刻响。
    /// 做成**一个原子方法**而不在调用方 `掐 + 入队` 两步拼：actor 可重入，两步之间会插进别的消息。
    func speakUserInitiated(_ newJobs: [PlaybackJob]) async {
        guard !newJobs.isEmpty else { return }
        guard accept(newJobs) else { return }
        guard !isSpeakingInterruption else {
            Log.info("用户主动开口（Opt+Z 划词译文）：上一个译文还在念，这次忽略")
            return
        }
        isSpeakingInterruption = true
        defer { isSpeakingInterruption = false }

        Log.info("用户主动开口（Opt+Z 划词译文）：播报暂停，译文走独立节点念，念完接着播（内容一条不删）")
        // 暂停前的那一帧字幕：译文念完，字幕要接回去
        let resumeFrame = lastCaptionFrame
        player.pauseOutput()   // 只是暂停：缓冲原样留着（和右⌘说话一个语义）
        do {
            for job in newJobs {
                // 译文不进队列管道，管道那两条「TTS 合成开始/完成」不覆盖它——
                // 译文没出声时若日志里什么都不留，事后无从判断是合成失败还是根本没触发。
                // 故这里单打一对带来源的日志，自检与人工排查都认它。
                Log.info("译文合成开始 [\(job.source)] chars=\(job.text.count)")
                let startedAt = Date()
                let stream = await engine.synthesizeStream(
                    text: job.text, voiceID: job.voiceID,
                    trace: TTSTrace(seq: 0, source: job.source))
                var isFirst = true
                for try await pcm in stream {
                    await player.writeInterruption(pcm: pcm, startsSentence: isFirst ? job.text : nil)
                    isFirst = false
                }
                let elapsed = String(format: "%.1f", -startedAt.timeIntervalSinceNow)
                Log.info("译文合成完成 [\(job.source)] \(elapsed)s")
            }
            await player.waitInterruptionFinished()   // 译文真的念完了再恢复主节点
        } catch {
            Log.warn("译文朗读失败：\(error.localizedDescription)")
        }
        player.stopInterruption()
        player.resumeOutput()   // 从暂停处接着播
        // 字幕接回原来那一页——**但只在它没被收走、也没被新的一页顶掉时**：
        // 念译文这段时间主队列可能正好播完、已经收尾（hideCaption 把字幕收了），
        // 这时再把旧帧塞回去 = 字幕复活，而且后面再没人收 → 字幕永远留在屏上。
        if let frame = resumeFrame, lastCaptionFrame == frame { onCaption?(frame) }
    }

    // MARK: - 内部

    /// 收敛点（**必须原子**）：任何路径结束时都在这里落一次——
    /// 还有待播就补起管道；队列空了且声音停了就收尾（收起字幕、还汽水音乐音量）。
    private func pumpOrSettle() async {
        // 容器卫生先做：回收已听完的页。它不影响待播量（回收的都是发声点之后的），
        // 但不回收就会让打断起点落在早已播完的页上——那页往往之后才到，一掀就哑。
        await session.retireSpentPages()
        // 队列状态（DEBUG）：自检脚本按这行数「还有多少句没播」——它是唯一不依赖
        // 时序的判据（数句数，不猜「现在在播哪句」）。
        Log.debug("队列状态: pending=\(await session.pendingCount) processing=\(currentTask != nil) 页=\((await session.headPageNo) ?? -1)")
        if await session.hasPending {
            startPipelineIfPending()
            return
        }
        // 队列空了：等设备把尾音播完，再收尾。
        await settleIfQuiet()
    }

    /// 收尾（队列空了 + 设备静了）：收起字幕、还汽水音乐音量、打收尾日志。
    ///
    /// **为什么还要等设备静**：最后一句被取走去合成时它还在响，立刻收尾会把尾音砍掉
    /// （字幕先撤、声音还在）。这里等的是**声音真的停下**。
    ///
    /// - Parameter afterSilence: 已确认设备静音时为真——这时连「正在响的」那一句也已响完，
    ///   可以连它一起回收（发声点永远停在最后一句上，不给这条后门，`/health` 会一直撒谎）。
    private func settleIfQuiet(afterSilence: Bool = false) async {
        if !afterSilence {
            await waitUntilQuiet()
            guard !(await session.hasPending) else { return }   // 等的过程中又来了新页
        }
        await session.retireSpentPages(afterSilence: true)
        hideCaption()
        Log.info("播报结束: 队列已空，字幕收起")
    }

    /// 等设备把已排队音频播完（声音真的停下），最多等 `maxSilenceWaitSeconds`。
    ///
    /// 用轮询而不是"播空回调 + continuation"：① 这段只持续最后一句的播放时长、粒度是秒，200ms 一问足够；
    /// ② **回调式挂起在设备卡死时会永久卡住**，反而把收尾也带死——轮询天然带超时，卡到上限就走，
    /// 收尾照样能到。代价是每 200ms 唤醒一次 actor，只发生在队列见底的这几秒。
    private func waitUntilQuiet() async {
        guard player.queuedFrames > 0 else { return }
        let deadline = Date().addingTimeInterval(Self.maxSilenceWaitSeconds)
        while player.queuedFrames > 0, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// 掐掉「正在播的这一句」：作废管道代号 + 取消在播 + 取消已排队合成与音频。
    /// **不动 Session 容器**——它是「插队」与「全掀」的公共前置：插队（Opt+Z 译文）只掐在播、
    /// 保留其余排队内容；全掀（bargeIn）先清场再调它。
    /// 不在此清 currentTask——由旧 processNext 自然结束时自清；调用方若要立刻起新管道，
    /// 必须 `await awaitCurrentPipelineFinished()`（线性化点），否则新旧两个 consumer 会并发
    /// write 同一个 player、争夺单一背压 continuation 槽，造成 continuation 泄漏/竞态。
    private func preemptCurrent(_ origin: InterruptOrigin) async {
        noteInterrupt(origin)   // 归因挂在**被作废的那条管道**上：它自己的日志回头查自己的代号
        pipelineSeq &+= 1      // 作废在跑管道：其 producer/consumer 靠代号不等立即停止
        currentTask?.cancel()
        await engine.cancelActiveSynthesis(reason: origin.description)   // 显式作废旧纪元排队合成，不依赖任务取消传播
        player.cancelPendingPlayback()
    }

    /// 记下「这条管道是被谁掐的」。
    ///
    /// 挂在 `currentTaskSeq`（**正在跑的那条**）上，且**先到先得**：
    /// 一次打断的 `cancel()` 是异步生效的，紧跟着的第二次打断还会看到同一条管道——
    /// 那时若覆盖，归因就成了「后一次的人」，而真正掐死它的是前一次。
    private func noteInterrupt(_ origin: InterruptOrigin) {
        guard currentTask != nil else { return }
        if interruptOriginBySeq[currentTaskSeq] == nil {
            interruptOriginBySeq[currentTaskSeq] = origin
        }
    }

    /// 这条管道是**被谁**掐的。查不到就是「不是打断掐的」，不猜。
    private func interruptOriginText(for seq: UInt) -> String {
        interruptOriginBySeq[seq]?.description ?? "非打断"
    }

    /// 全掀：掐掉在播 + 清空全部排队内容。
    private func bargeIn(_ origin: InterruptOrigin) async {
        let n = await session.pendingCount
        Log.info("打断（来源=\(origin)）：取消在播、清空队列(pending=\(n))")
        await session.discardAll()   // 清容器
        hideCaption()                // 全掀：字幕立刻收
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

        // PCM 管道：unbounded 只承接「预取门控允许的提前量」（领先一两句），
        // 真正的容量上移到句间 awaitPrefetchCapacity 判定，不会无限堆积。
        let (pcmAsync, pcmContinuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)

        let producer = Task {
            defer { pcmContinuation.finish() }
            while !Task.isCancelled {
                if pipelineSeq != seq { return }   // 已被掐断作废：立即退出，不再合成
                guard let cursor = await session.nextCursor() else {
                    // 没有内容可播了 → 整条管道退出，收尾交给 `pumpOrSettle`。
                    return
                }
                let job = cursor.sentence
                // 门控/等待可能挂起较久，返回后先看取消：已被掐断就别再发起合成
                try Task.checkCancellation()

                let batchID = String(UUID().uuidString.prefix(6))
                Log.info("TTS 合成开始 [\(job.source)-\(batchID)] seq=\(job.seq) chars=\(job.text.count)")
                let startedAt = Date()
                var claimed = false
                do {
                    // **不问引擎状态**：引擎自己在 `synthesizeStream` 入口问那一次
                    // （问不到就等、报 failed 就当场作废这一句）——队列再问一遍是
                    // 同一件事的两份，每句白搭两条 socket 连接（2026-11-05）。
                    try Task.checkCancellation()

                    // 预取门控：已排队音频足够多就先别开下一句，等设备消费到低水位。
                    try await player.awaitPrefetchCapacity()
                    try Task.checkCancellation()   // 门控返回时可能已被取消，绝不带取消进模型

                    // claim：门控挂起期间可能被掀掉。**游标不弹出容器**，所以这里不用改容器，
                    // 只要确认这一句还在（在播）就合成；不在了（掀掉了）就跳过它、游标照常前移。
                    if await session.nextCursor()?.seq != cursor.seq { continue }
                    claimed = true
                    // 句号（助理自编、这一句的唯一身份）跟着这次合成递到引擎，远程时是
                    // 誊清员进程——它那边的日志据此认领是哪一句，跨文件串得起来。
                    let stream = await engine.synthesizeStream(
                        text: job.text, voiceID: job.voiceID,
                        trace: TTSTrace(seq: job.seq, source: job.source))

                    // 句首捎上这句的文本：播放器在它被设备读出时报字幕（跟随声音，而非合成）
                    var isFirst = true
                    for try await pcm in stream {
                        // MLX 流不响应中途取消：一旦发起本句只能跑完，但被作废后不再向下游灌 PCM
                        if Task.isCancelled || pipelineSeq != seq { break }
                        pcmContinuation.yield(AudioChunk(pcm: pcm,
                                                         sentenceText: isFirst ? job.text : nil,
                                                         seq: job.seq))
                        isFirst = false
                    }
                    try Task.checkCancellation()
                } catch is CancellationError {
                    Log.info("TTS 合成已取消 [\(job.source)-\(batchID)]（打断来源=\(interruptOriginText(for: seq))）")
                    throw CancellationError()
                } catch {
                    // 身份标识必须带全：这是「播到一半没了」最该留线索的一行，
                    // 而同一循环里成功/取消/作废三条路径都带 [来源-批次号]。
                    Log.error("TTS 合成失败 [\(job.source)-\(batchID)] seq=\(job.seq) voice=\(job.voiceID) chars=\(job.text.count): \(error)")
                }
                let elapsed = String(format: "%.1f", -startedAt.timeIntervalSinceNow)
                if pipelineSeq != seq {
                    // MLX 不响应中途取消：打断后被掐的这句仍跑完，但已作废。别让它显示成
                    // 普通「完成」（打断后紧邻的完成会被人误读成「没掐住」）。
                    //
                    // ⚠️ **被掐断的这句不算「过去了」——游标不前移**（2026-11-02 实测撞到）：
                    // 它根本没出声，前移等于把它吃掉。掀页时在跑的那句**常常是下一页的预取**
                    // （预取领先播放一句），吃掉它 → 「掀页」变成「掀光队列」，
                    // 需求里的「从下一页接着念」落空。不前移 → 它留在容器里，
                    // 新管道重新合成它 → 下一页照播。
                    // （全掀不受影响：容器已清空，这句不会被重播。）
                    Log.info("TTS 合成作废（MLX 不响应中途取消，这句跑完才停）[\(job.source)-\(batchID)]（打断来源=\(interruptOriginText(for: seq))） \(elapsed)s")
                    continue
                }
                // 游标前移：合成成功或失败，这一句都过去了——不前移就是死循环。
                await session.commit(cursor)
                if claimed {
                    Log.info("TTS 合成完成 [\(job.source)-\(batchID)] seq=\(job.seq) \(elapsed)s")
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
                await player.write(chunk.pcm, startsSentence: chunk.sentenceText, seq: chunk.seq)
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
        // **声音停了，字幕就撤**（2026-10-25 修）：字幕原先跟着**队列结算**走，
        // 而结算要等收尾信号或空闲宽限 —— 中间屏幕上一直挂着上一句。
        // 这里跟**声音**走：管道排空即撤。
        // 只在**自己还是当前管道**时撤：被顶替的旧管道不能把新管道刚报的那句擦掉。
        if currentTaskSeq == seq { hideCaption() }
        if currentTaskSeq == seq { currentTask = nil }   // 已被新管道顶替则不清
        interruptOriginBySeq.removeValue(forKey: seq)   // 这条管道的归因用完了（它的日志已打过）
        await Task.yield()
        // 收尾窗口兜底：drain 等待尾音期间新入队的内容，旧管道正在收尾、currentTask 尚非 nil，
        // 入队路径不肯起新管道——这里须回头收敛一次，否则新内容永久躺着
        //（漏播根因，实测 17:14 claude 317字 5块入队后躺在队列零合成）。
        await pumpOrSettle()
    }
}
