import Foundation
import iVoxKit

// 播报播放层：只管「怎么把字念出来」——连续播放管道（合成/播放两条并发 task + 有界 PCM 流）、
// 掐（断在播）与字幕。谁在说话、说到哪、哪层被作废全归 `PlaybackSession`（身份层）。
// **不碰音乐的播放状态**——暂停/恢复只归语音输入（录音时音乐会串进麦克风、干扰识别）；
// 播报期间给汽水音乐压音量是另一码事：那是改数值、不切状态，由 `PlaybackSignal`
// 把「要开始播了 / 播完了」两个时刻告诉外面（见 `SodaVolumeDucker`）。
// 播报四层文档见 docs/playback/：purpose（目的/取舍）→ sources（接入方）→ requirements（需求）→ queue（实现）。

/// 一条待播报的文本。身份字段（摞/页）原样带给 Session，本层不做判断。
struct PlaybackJob: Sendable {
    let text: String
    let voiceID: String
    let source: String
    /// 所属摞（`turn_id`）；nil = 传统整段播报（ivox speak / hook.sh）
    let turnID: String?
    /// 这一批属于哪**页**（Claude 的 `message_id`）。**它是「这一批」的页线索，
    /// 不进块**——同一次入队的块整批同页，助理拿它归拢成页并自己发页号。
    let pageID: String?

    init(text: String, voiceID: String, source: String, turnID: String? = nil, pageID: String? = nil) {
        self.text = text
        self.voiceID = voiceID
        self.source = source
        self.turnID = turnID
        self.pageID = pageID
    }

    var asBlock: PlaybackBlock {
        PlaybackBlock(seq: 0, text: text, voiceID: voiceID, source: source)
    }

    /// 这一批的页线索（取第一个块的——同批同页，调用方保证了这一点）。
    var batchPageNote: String? { pageID }
}

/// 管道里流的一小块音频：PCM +（**仅句首块**）这句的文本。
/// 文本跟着音频一起流到播放器，句首块被设备读出时正好用它报字幕——
/// 队列不必另存一张「已合成待播句子表」，省掉一处要跟打断/取消对齐的状态。
private struct AudioChunk: Sendable {
    let pcm: Data
    let sentenceText: String?
    /// 这一批 PCM 属于哪一块（`PlaybackBlock.seq`）。透传到 `AudioPlayer.write` 后由它
    /// 在设备读出时上报，身份层据此推进发声点——**打断起点由此与合成进度彻底分家**。
    let seq: UInt
}

/// 打断来源：与 `PlaybackJob.source`（这段播报是谁发的）是一对账的标识——
/// 前者回答「谁在说」，这个回答「这次打断是谁干的」。打断权**只归用户物理快捷键**
/// （Opt+Z 译文、Ctrl+Esc 掀页 / Ctrl+1 掀摞 / Ctrl+2 全掀）；agent 流式轮只排队、不打断。
///
/// **右⌘说话不在这里**：那是「你停一下」（`pausePlayback()`：设备停渲染、内容一条不删），
/// 不是「你别说了」（本枚举这三档：内容丢弃、这些摞的将来也不再来）。
enum InterruptSource: Sendable, CustomStringConvertible {
    /// Opt+Z 划词翻译（用户主动朗读，speakUserInitiated）
    case dict
    /// Ctrl+2 手动闭嘴（GlobalKeyTap 组合热键）：用户不想说话、只想安静，静音播报即可。
    /// **不碰背景音乐**——借还音乐是右⌘ 录音那条的事（见文件头）
    case esc
    /// Ctrl+1 掀摞：丢正在播的这一**摞**（一次回复，连同后来的页），从下一摞接着播。
    /// 与 `.esc` 的分工——那个全场闭嘴，这个只掀当前、后面的照播。
    case skip
    /// Ctrl+Esc 掀页：丢掉当前这一**页**剩下的块，从下一页接着念。
    /// 手动打断三档里的「轻」（`.skip` = 中：掀整摞；`.esc` = 掀桌：全掀）。
    ///
    /// ⚠️ 键位对照以 `GlobalKeyTap.bindings` 与 `Daemon.setUpHotKeys()` 为准：
    /// Ctrl+Esc 掀页 · Ctrl+1 掀摞 · Ctrl+2 全掀。本枚举曾把前两者写反，
    /// 文档跟着抄错了两份（`requirements.md` / `queue.md`），照错注释抄会再漂回去。
    case skipPage
    /// 守护进程退出（shutdown），系统级清场，不是用户主动打断
    case shutdown

    var description: String {
        switch self {
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
    private let session: PlaybackSession

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
    /// 播报起落信号接收端：起管道时发 `.started`、这一轮真的结束（队列空 + 宽限 + 静默）时发 `.ended`。
    /// 播报之外的「给背景让路」靠它（见 `SodaVolumeDucker`）——播放层自己不碰音乐。
    private var onSignal: (@Sendable (PlaybackSignal) -> Void)?
    private let player: AudioPlayer
    private let engine: any TTSProviding
    private let media: MediaController
    init(engine: any TTSProviding, mediaController: MediaController,
         idleGraceSeconds: Double = PlaybackConfig.defaultIdleGraceSeconds) {
        self.engine = engine
        self.player = AudioPlayer()
        self.media = mediaController
        self.session = PlaybackSession(idleGraceSeconds: idleGraceSeconds)
        // 字幕跟**播放**走（不是合成）：句首块被设备读出时才报，与声音对齐。
        // 回调在播放器的 serialQueue 上，跳回本 actor 再转发（onCaption 是本 actor 状态）。
        player.onSentenceStarted = { [weak self] text in
            Task { await self?.emitCaption(text) }
        }
        // 发声点：播放器报「哪一块的 PCM 被设备读出」这个**事实**，身份层存位置、推导起点。
        // 本层一个字的推导都不做——三层各干各的（见 PlaybackSession 文件头）。
        player.onBlockConsumed = { [weak session] seq in
            Task { await session?.noteConsumed(seq) }
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

    /// 注入播报起落信号接收端（`nil` = 不关心）。形状与 `setCaptionSink` 一致。
    func setSignalSink(_ sink: (@Sendable (PlaybackSignal) -> Void)?) {
        onSignal = sink
    }

    /// 音频侧报「这句开始响」→ 转发给字幕（已在本 actor 上）。
    private func emitCaption(_ text: String) {
        onCaption?(text)
    }

    /// 队列中等待播放的条数（/health 用）
    var pendingCount: Int { get async { await session.pendingCount } }
    /// 是否有正在处理的播报（/health 用）
    var isProcessing: Bool { currentTask != nil }
    /// 用户此刻正在听的摞 / 页（/health 用）。
    ///
    /// **这是打断起点的对外只读投影**：三档打断取的就是它（`session.takeHead*`），
    /// 所以黑盒脚本按压前后各读一次，就能量出「掀掉的是不是正在听的那一摞」。
    /// nil = 还没出声（冷启动）或设备已播空。
    /// `audibleTurn` 是**外部** turn_id——无分组来源（如 `ivox speak`）没有这个号，
    /// 报 null 是如实反映，不是缺数据；`audiblePage` 是资料室自编的页号，任何来源都报得出。
    var audibleTurn: String? { get async { await session.headStackTarget()?.turnID } }
    var audiblePage: Int? { get async { await session.headPageNo } }

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
    /// - Returns: 助理自编的摞号；`turnID` 为 nil 时每次调用都自开新摞（`ivox speak` 的形态：
    ///   一次调用一摞、一摞一页）。
    @discardableResult
    func enqueue(_ newJobs: [PlaybackJob], turnID: String? = nil) async -> Int? {
        guard !newJobs.isEmpty else { return nil }
        let stack: Int?
        if let turnID {
            // pi 的轮：每个 turn_id 自开一摞（后续帧由调用方拿摞号走 appendToStack 并入）
            stack = await session.newStack(newJobs.map(\.asBlock), note: turnID,
                                           pageNote: newJobs.first?.batchPageNote)
        } else {
            stack = await session.appendPlain(newJobs.map(\.asBlock))
        }
        await reportFiling()
        await logQueueState(turn: turnID)
        await pumpOrSettle()
        return stack
    }

    func enqueue(_ job: PlaybackJob) async {
        await enqueue([job], turnID: job.turnID)
    }

    /// 把续批并进**助理自编的摞号** `stack`。外部 `group` / `page` 只作备注。
    /// - Returns: 三态见 `PlaybackSession.StackAccept`。**`dead` 必须丢弃、`gone` 才重开**，
    ///   混为一谈会让「已放弃的摞，其后续增量又播出来」。
    func appendToStack(_ stack: Int, _ newJobs: [PlaybackJob],
                       group: String?, page: String? = nil) async -> PlaybackSession.StackAccept {
        guard !newJobs.isEmpty else { return .appended }
        let note = page ?? newJobs.first?.batchPageNote
        let verdict = await session.appendToStack(stack, newJobs.map(\.asBlock),
                                                  note: group, pageNote: note)
        guard verdict == .appended else { return verdict }
        await reportFiling()
        await logQueueState(group: group)
        await pumpOrSettle()
        return .appended
    }

    /// 弱分组入队（Claude 的 MessageDisplay：一次回复按行批分多次短连接送来）。
    /// 分组号是 **`turn_id`（一次回复 = 一摞）**，不是 `message_id`（一条 message = 一页）——
    /// 「一摞 = 一段」是「Ctrl+1 掀整摞」成立的前提：一次回复里夹了工具调用就会有**好几页**，
    /// 按页分段的话 Ctrl+1 只能掀掉一页。
    ///
    /// **老接口，保留是因为它把「新开一摞」包起来了**；返回助理自编的摞号，
    /// 调用方拿它记住「外部 group ↔ 助理摞号」，后续同摞的页改走 `appendToStack`。
    @discardableResult
    func enqueueGrouped(_ newJobs: [PlaybackJob], group: String) async -> Int? {
        guard let stack = await session.newStack(newJobs.map(\.asBlock), note: group,
                                                 pageNote: newJobs.first?.batchPageNote) else { return nil }
        await reportFiling()
        await logQueueState(group: group)
        await pumpOrSettle()
        return stack
    }

    /// 收尾指定的那一摞（Stop 钩子按 `session_id` 反查出的 `turn_id`）。**日常收尾的主力就是它**——
    /// Claude 一说"这轮完了"，字幕立刻归还，不必等空闲宽限。
    /// 盖印 + 立墓碑：Stop 之后无增量，墓碑拦住该摞后续再来（实际不会来，是兜底）。
    func finishTurn(_ id: String) async {
        Log.info("收尾信号（这一摞说完了）: turn=\(id)")
        await session.sealTurn(id)
        await pumpOrSettle()
    }

    /// **播报员报备**：把资料室刚给的摞号与页号原样播出来。
    /// 有了它，「哪块属于哪一摞哪一页」从收下那一刻就在日志里，掀的时候不必再推断——
    /// 掀变成查号，所以怎么按都不会掀错（2026-10-18：以前掀摞只打得出「无分组 块=34」，
    /// 事后根本看不出掀的是哪一摞，那次 34 块全丢就是这么看糊涂的）。
    private func reportFiling() async {
        guard let f = await session.lastFiling else { return }
        let ext = f.turnID.map { "（外部 \($0)）" } ?? ""
        Log.info("资料室收下：第\(f.stack)摞\(ext) 第\(Self.pageRangeText(f.pages))页")
    }

    /// 页号列表压成人话：单页 `7`、连号 `7~9`、多段 `3, 7~9`。
    private static func pageRangeText(_ pages: [Int]) -> String {
        guard !pages.isEmpty else { return "-" }
        var out: [String] = []
        var i = 0
        while i < pages.count {
            var j = i
            while j + 1 < pages.count, pages[j + 1] == pages[j] + 1 { j += 1 }
            out.append(j > i ? "\(pages[i])~\(pages[j])" : "\(pages[i])")
            i = j + 1
        }
        return out.joined(separator: ",")
    }

    private func logQueueState(turn: String? = nil, group: String? = nil) async {
        let n = await session.pendingCount
        let id = turn ?? group ?? "-"
        Log.debug("队列状态: pending=\(n) processing=\(currentTask != nil) turn=\(id)")
    }

    // MARK: - 打断（掐 + 掀）：四个原子动作，热键层不再接触掐

    /// 取消所有播放（正在播的和排队中的），并作废全部流式轮次。
    /// 形象说法：**把桌上所有稿纸全扫到地上**——一声不响（背景音乐不归它管）。
    ///
    /// **这是「你别说了」**：内容丢、这些摞的将来也不再来。
    /// 「你停一下」（右⌘说话时让设备闭嘴、内容留着）是 `pausePlayback()`，走另一条路。
    func cancelAll(origin: InterruptSource) async {
        Log.info("打断（来源=\(origin)）：作废全部流式轮次")
        lastInterrupt = origin
        await bargeIn(origin)   // bargeIn 内部丢弃 Session 全部内容，并给当前存在的摞立墓碑
    }

    // MARK: - 暂停（用户要说话）：停一下，不删

    /// **暂停输出，内容一条不删。**
    ///
    /// 与三档手动打断的区别就是飞哥那两句：**手动 = 「你别说了」（丢）**，
    /// **说话 = 「你停一下」（留着）**。右⌘说话时麦克风会拾到正在播的声音、识别就乱，
    /// 所以要让设备先闭嘴；但用户没说「不要听」，话说完就该接着播。
    ///
    /// 只停**设备渲染**，管道与容器一概不动：已排队的音频原样留在设备队列里，
    /// 队列里的内容照旧排队，Claude 期间送来的页照旧入队。说话结束 `resumePlayback()` 从原位接着播。
    func pausePlayback() {
        player.pauseOutput()
    }

    /// 恢复输出：从暂停处接着播（用户说完话了）。
    func resumePlayback() {
        player.resumeOutput()
    }

    /// 掀页（Ctrl+2）：掐掉正在念的这一块，并丢掉**用户此刻正在听的那一页**的剩余块，
    /// 从下一页接着念。形象说法：**这页不要了，听下一页**（一页 = 一个 MessageDisplay）。
    /// 「跳播放块」没有意义——用户听不出块边界在哪，他感知的单位是页。
    ///
    /// 起点取「正在听的那一摞里的第一个还有未播块的页」——纯容器结构事实。
    /// **且必须在掐之前就摘走**（`takeHeadPage` 即摘走）：掐在播要 await 旧管道退净，
    /// 那期间游标会 commit 掉正在响的最后一块、越到下一页，再取靶心就晚了
    /// （2026-10-17 18:52 实测：摞级现场，页级同一个偏差）。
    func skipCurrentPage(_ origin: InterruptSource) async {
        let taken = await session.takeHeadPage()   // 起点此刻定死，掐不掐都拿它
        await preemptCurrent(origin)
        onCaption?(nil)   // 被跳掉的内容立刻从字幕撤下；下一页开始响时会重新报
        await awaitCurrentPipelineFinished()   // 线性化：旧管道退净再起，避免两个 consumer 抢 player
        // 起点与丢了多少块都要落日志：掀页与"没翻动"在外部看起来一样（都是没声音），
        // 只有这两行能区分「当时没东西可掀」和「确实翻过去了、翻的是哪一页」。
        // 页号是资料室自编的（`localID`），所以任何来源都报得出「第几页」，不再是「匿名页」。
        Log.info("这页不要了，听下一页（来源=\(origin)）：已掀 第\(taken?.pageNo.description ?? "-")页 块=\(taken?.dropped ?? 0)")
        await pumpOrSettle()   // 还有块则接着播；若这摞正等下一批字则原地等
    }

    /// 掀摞（Ctrl+1）：掐掉正在念的这一块，并丢掉**用户此刻正在听的那一摞**的全部内容，
    /// 从下一摞接着播。形象说法：**这摞不要了，听下一摞**（一摞 = 一次回复）。
    /// 与 `cancelTurn` 的区别：那个是「自取消不占打断来源」、也不掐在播（等它自己播完）；
    /// 这个是用户主动掀，必须立刻掐在播、丢段、前移。与 `cancelAll` 的区别：那个清全场，
    /// 这个只丢当前、后面的照播。
    ///
    /// 同样**掐之前先摘走**（理由见 `skipCurrentPage`）——旧实现正是在 await 之后才取起点，
    /// 游标一越过边界就把用户想听的那一摞掀了。
    func skipCurrentBucket(_ origin: InterruptSource) async {
        let taken = await session.takeHeadStack()   // 起点此刻定死
        await preemptCurrent(origin)
        onCaption?(nil)   // 被掀掉的那一摞立刻从字幕撤下；下一摞开始响时会重新报
        await awaitCurrentPipelineFinished()   // 线性化：旧管道退净再前移
        // 摞号与页号都是资料室自编的，所以**不论来的是 claude / pi / ivox speak，
        // 日志里都报得出「第几摞」**——早先这里打外部 turn_id，无编号的来源只能打「无分组」，
        // 事后无从判断掀掉的到底是哪一摞（18:11 那次 34 块就是这么看糊涂的）。
        let no = taken.map { "\($0.localID)" } ?? "-"
        let turn = taken?.turnID.map { "（外部 \($0)）" } ?? ""
        Log.info("这摞不要了，听下一摞（来源=\(origin)）：已掀 第\(no)摞\(turn) 块=\(taken?.dropped ?? 0)")
        await pumpOrSettle()   // 有下一摞则起管道接着播；没有则收尾
    }

    /// 用户主动要求开口（Opt+Z 念译文）：**插队**——掐掉正在播的那一句让译文立刻响，
    /// 但**不掀桌**：其余排队内容照旧（播完译文接着播）。
    ///
    /// 与 `enqueue(_:turnID: nil)` 的「只排队」语义**相反**——那条是 agent 自动汇报，
    /// 不该抢麦（否则两个后台会话收尾会互相掐掉对方内容）；这条是用户自己按的，必须立刻响。
    /// 做成**一个原子方法**而不在调用方 `掐 + 入队` 两步拼：actor 可重入，两步之间会插进别的消息。
    func speakUserInitiated(_ newJobs: [PlaybackJob]) async {
        guard !newJobs.isEmpty else { return }
        Log.info("用户主动开口（Opt+Z 划词译文）：插队到队首，其余排队内容保留")
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
        // 容器卫生先做：回收已听完且已收尾的段。它不影响待播量（回收的都是发声点之后的），
        // 但不回收就会让打断起点落在早已播完的摞上——那摞往往还在继续送页，一掀就哑。
        await session.retireSpentSegments()
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
            // 这里已经跑过 waitUntilQuiet（宽限的起点就是它），**确认真静音**：
            // 正在响的那一块也已响完，可以连它一起回收 —— 发声点永远停在最后一块上，
            // 不给这条后门，收尾后 audibleTurn 会一直报着一个早就不响的摞。
            await session.retireSpentSegments(afterSilence: true)
            invalidateIdleGrace()
            onCaption?(nil)
            onSignal?(.ended)
            Log.info("播报结束: 队列已空，字幕收起")
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
    /// **不动 Session 容器**——它是「插队」与「掀桌」的公共前置：插队（Opt+Z 译文）只掐在播、
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
        Log.info("打断（来源=\(label)）：取消在播、清空队列(pending=\(n))、作废管道 seq\(pipelineSeq&+1))；后续增量一并作废")
        await session.discardAll()   // 清容器 + 给属主的摞立墓碑（它们后续的增量也别来了）
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
        // 「要开始播了」这一刻：给背景让路的人（汽水音乐压音量）从这里知道。
        // 打在**起管道**而不是「设备真的出声」——合成领先播放一两秒，早动手，
        // 第一句出来时背景已经压下去了。打断后重起管道也会再发一次，
        // 接收端自己按「已让过路就别重复让」处理（见 SodaVolumeDucker）。
        onSignal?(.started)
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
                Log.info("TTS 合成开始 [\(job.source)-\(batchID)] seq=\(job.seq) chars=\(job.text.count)")
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
                    // 块号（助理自编、块的唯一身份）跟着这次合成递到引擎，远程时是
                    // 誊清员进程——它那边的日志据此认领是哪一块，跨文件串得起来。
                    let stream = await engine.synthesizeStream(
                        text: job.text, voiceID: job.voiceID,
                        trace: TTSTrace(seq: job.seq, source: job.source))

                    // 句首块捎上这句的文本：播放器在它被设备读出时报字幕（跟随声音，而非合成）
                    var isFirstBlock = true
                    for try await pcm in stream {
                        // MLX 流不响应中途取消：一旦发起本句只能跑完，但被作废后不再向下游灌 PCM
                        if Task.isCancelled || pipelineSeq != seq { break }
                        pcmContinuation.yield(AudioChunk(pcm: pcm,
                                                         sentenceText: isFirstBlock ? job.text : nil,
                                                         seq: cursor.seq))
                        isFirstBlock = false
                    }
                    try Task.checkCancellation()
                } catch is CancellationError {
                    Log.info("TTS 合成已取消 [\(job.source)-\(batchID)]（打断来源=\(lastInterrupt?.description ?? "自取消")）")
                    throw CancellationError()
                } catch {
                    // 身份标识必须带全：这是「播到一半没了」最该留线索的一行，
                    // 而同一循环里成功/取消/作废三条路径都带 [来源-批次号]。
                    // 以前这里只有一句错误描述，事后无从判断是哪摞的哪一块失败（2026-10-18 补）；
                    // 现在块号是助理自编的 `seq`，拿它能在日志里反查是哪一摞的哪一块
                    // （Block 上不再挂任何外部编号，见 `PlaybackBlock`）。
                    Log.error("TTS 合成失败 [\(job.source)-\(batchID)] seq=\(job.seq) voice=\(job.voiceID) chars=\(job.text.count): \(error)")
                }
                // 游标前移：无论合成成功、失败、被取消，这一块都过去了——不前移就是死循环。
                await session.commit(cursor)
                let elapsed = String(format: "%.1f", -startedAt.timeIntervalSinceNow)
                if pipelineSeq != seq {
                    // MLX 不响应中途取消：打断后被掐的这句仍跑完，但已作废。别让它显示成
                    // 普通「完成」（打断后紧邻的完成会被人误读成「没掐住」）。
                    Log.info("TTS 合成作废（MLX 不响应中途取消，这句跑完才停）[\(job.source)-\(batchID)]（打断来源=\(lastInterrupt?.description ?? "自取消")） \(elapsed)s")
                } else if claimed {
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
