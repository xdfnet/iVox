import Foundation
import iVoxKit

// 播报队列：单队列 + 连续播放管道，管轮次、打断与音乐保活。串行调度见 docs/playback-queue.md。

/// 一条待播报的文本。
struct PlaybackJob: Sendable {
    let text: String
    let voiceID: String
    let source: String
    /// 所属流式轮次；nil = 传统整段播报（ivox speak / hook.sh）
    var turnID: String? = nil
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
    /// Ctrl+Esc 手动闭嘴（GlobalKeyTap 组合热键）：用户不想说话、只想安静，
    /// 静音播报后由调用方恢复音乐（语义同停止帧，不走右⌘ 的录音暂停）
    case esc
    /// Ctrl+1 跳过当前桶：丢正在播的这一轮（连同其后分块），从下一桶接着播。
    /// 与 `.esc` 的分工——那个全场闭嘴，这个只跳当前、后面的照播。
    case skip
    /// Ctrl+2 跳过当前这句：只丢正在播的这一句，**同一桶剩下的照常念**。
    /// 手动打断三档里的「轻」（`.skip` = 中：丢整桶；`.esc`/`.speech` = 掀桌：全场清）。
    case skipSentence
    /// 守护进程退出（shutdown），系统级清场，不是用户主动打断
    case shutdown

    var description: String {
        switch self {
        case .speech: return "speech"
        case .dict: return "dict"
        case .esc: return "esc"
        case .skip: return "skip"
        case .skipSentence: return "skip-sentence"
        case .shutdown: return "shutdown"
        }
    }
}

/// 一个待播桶：同一轮次的连续 job 序列（turnID 为空 = 普通播报，hook.sh/ivox speak）。
/// 队列按到达序存桶；进 processNext 消费的 = 队首桶。旧桶播完才前移到下一桶——
/// 这就是「按轮排队、播全播完」的载体：新 turn 不再打断旧轮，只在队尾追加新桶。
private struct QueueBucket {
    let turnID: String?
    var jobs: [PlaybackJob]
    /// 该桶的轮是否已 endTurn（普通播报 nil-turn 桶初始即视为 ended）。
    /// 分桶后空桶不一定是「播完/取消」——可能轮还在流式生成、块还没到。只有 ended 的空桶
    /// 才允许前移；仍在的轮（ended=false）空桶要挂起等下一批块或 endTurn。
    var ended: Bool
}

actor PlaybackQueue {
    /// 有序待播桶。代理旧的单一 `jobs` 数组——旧实现靠单值 `currentTurn` 门控
    /// （`processNext` 每取一块按 `t == currentTurn` 过滤）判断轮归属，多轮同处一数组
    /// 时新旧残块必然互相误删。分桶后轮边界由桶隔离，processNext 只消费队首桶，无需跨桶跳块。
    private var buckets: [QueueBucket] = []
    private var currentTask: Task<Void, Never>?
    /// 管道代号：起新管道 / bargeIn 作废时递增。在跑管道靠「自己的代号是否已过期」判断
    /// 该不该继续——非结构化 `Task {}` 的子任务不继承取消，单靠 cancel 停不住它们。
    /// 最近一次打断的来源：底层取消日志（TTS 合成已取消）据此对上「是谁打断的」。
    /// 不用 actor 并发考虑——打断本身串行，写入与 processNext 读它都在本 actor 上。
    private var lastInterrupt: InterruptSource? = nil
    private var pipelineSeq: UInt = 0
    /// `currentTask` 的代号，用于身份校验：仅当代号仍指向自己时才允许清空/接管。
    private var currentTaskSeq: UInt = 0
    private var generation: UInt = 0
    /// 队首待播桶（可能空桶——桶空即应前移/消费完毕）。分桶后「当前在播」= 队首非空桶的轮。
    private var frontBucket: QueueBucket? { buckets.first }
    /// 是否仍有待播内容（含正在消费的队首桶）；全空才视为 idle。
    private var hasPendingBuckets: Bool { buckets.contains { !$0.jobs.isEmpty } }
    /// 当前播报所属轮次 = 队首待播桶的轮（分桶后消费视角）。真正在播的那桶播完才前移，
    /// 因此「当前轮」不再随新轮到达而翻转——这是「按轮排队、播全播完」的基石。
    private var currentTurn: String? { frontBucket?.turnID }
    /// 是否仍有未结束的流式轮（turnID 非空且未 endTurn 的桶）。由每桶 ended 状态推导——
    /// 取代旧全局 turnOpen 单布尔（多轮按序排队时单布尔会在旧轮收盘 set false 而新轮仍在生成、
    /// 或反之，导致「最后一个桶播完音乐不恢复」的误判）。processNext 在还有流动中轮时排空仍等待。
    private var anyTurnInFlight: Bool { buckets.contains { $0.turnID != nil && !$0.ended } }
    /// 轮次认领栈（pi 双流的空流 `{cancel}` 认证用）：**不作「当前在播」判定**——那是 frontBucket 的
    /// 事。只回答「这个 turnID 是不是合法新轮/属主该不该交还」，与分桶消费正交。
    private var turnStack: [String] = []
    /// 已作废轮次墓碑（容量有上限）：`{cancel}`、语音打断、普通 speak 之后，该轮不再开口
    /// （含客户端关闭连接后 EOF 兜底补出的残尾）。
    private var deadTurns: [String] = []
    /// processNext 在 anyTurnInFlight 下等待新 job 的挂起点；入队/结束/打断时恢复
    private var jobWaiters: [CheckedContinuation<Void, Never>] = []
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
        buckets.removeAll()
        player.cancelPendingPlayback()
        player.stop()
        Task { await media.resume() }   // 退出时确保 music 恢复，避免 daemon 重启后卡暂停
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
    var pendingCount: Int { buckets.reduce(0) { $0 + $1.jobs.count } }
    /// 是否有正在处理的播报（/health 用）
    var isProcessing: Bool { currentTask != nil }

    /// 取消所有播放（正在播的和队列中等待的），并作废全部流式轮次。
    /// 「打断权只归用户快捷键」：右⌘ 说话（speech）、Ctrl+Esc 闭嘴（esc）。
    /// Cmd+D 念译文不走这里——它是 `speakUserInitiated` 的「插队」（只掐在播、不清场）。
    /// 停止帧 `{type:stop}` 已失效（hook.sh interrupt / ivox quiet 不再打断播报）。
    /// 当场静音 + 清空全部桶（一个喇叭，你快捷键开口全场停）。
    func cancelAll(origin: InterruptSource) async {
        Log.info("打断（来源=\(origin)）：作废全部流式轮次")
        lastInterrupt = origin
        buryAllTurns()
        await bargeIn(origin)
        // 不在这里恢复/暂停音乐——那是调用方的职责（语音输入要暂停、停止帧打断要恢复），
        // cancelAll 只管打断清场。要恢复的调用方在自己侧调 resumeIfIdle()。
    }

    /// 用户主动要求开口（Cmd+D 念译文）：**插队**——掐掉正在播的那一句让译文立刻响，
    /// 但**不掀桌**：其余排队桶照旧、流式轮不作废（其后分块仍会念，播完译文接着播）。
    ///
    /// 与 `enqueue(_:turnID:)` 无 turnID 路径的「只排队」语义**相反**——那条是 agent 自动汇报，
    /// 不该抢麦（否则两个后台会话收尾会互相掐掉对方内容）；这条是用户自己按的，必须立刻响。
    /// 做成**一个原子方法**而不在调用方 `preemptCurrent + enqueue` 两步拼：actor 可重入，
    /// 两步之间会插进别的消息。
    func speakUserInitiated(_ newJobs: [PlaybackJob]) async {
        guard !newJobs.isEmpty else { return }
        Log.info("用户主动开口（Cmd+D 划词译文）：插队到队首，其余排队内容保留")
        await preemptCurrent(.dict)
        await awaitCurrentPipelineFinished()   // 线性化：旧管道退净再起新的
        // 译文自成一轮（用户主动）：独立的 nil-turn 桶**插到队首**立刻播；其余桶顺序不动。
        buckets.insert(QueueBucket(turnID: nil, jobs: newJobs, ended: true), at: 0)
        signalJobs()
        if currentTask == nil { startPipeline() }
    }

    /// 空闲时恢复音乐（由外部调用：停止帧打断后、语音输入结束后）。
    /// cancelAll 不再碰音乐，恢复责任归调用它的这一侧；被取消的管道还没退净时
    /// 先等它退净再恢复，否则打断在播的一句后音乐会卡在暂停（历史修过两次）。
    func resumeIfIdle() async {
        guard !hasPendingBuckets else { return }
        if let task = currentTask, task.isCancelled {
            await awaitCurrentPipelineFinished()   // 被打断的管道退净（很快），currentTask 才归 nil
        }
        guard currentTask == nil else { return }
        await media.resume()
    }

    /// 流式轮次开始（首帧）：登记轮次并标记仍在生成（句间不恢复音乐）。
    /// **不再打断旧轮**——打断权只归用户快捷键（right⌘/Cmd+D/Ctrl+Esc）；新轮在队尾排队。
    /// 轮次身份仍靠 `claimTurn`/`turnStack` 判定（pi 同消息双流的空流 `{cancel}` 靠栈顶识别，
    /// 与"按桶排队"正交，不可删）。
    func beginTurn(_ id: String, source: String) async {
        // 轮次登记只做 pi 双流认证；「仍在生成」由 anyTurnInFlight 依桶 ended 推导，不需手动标记。
        guard claimTurn(id) else { return }   // 已作废 / 被顶掉的旧轮：忽略
        Log.info("流式轮次开始: source=\(source) turn=\(id)（排队，不打断）")
    }

    /// 流式轮次正常结束：标记该轮桶 ended（空桶可前移），放开保活并唤醒管道。
    /// endTurn 只对自己的桶生效——分桶后可能有多个轮排队、各自在自己时机 endTurn，
    /// 谁结束了谁的桶就允许被消费完前移，不与别的轮互相干扰。
    func endTurn(_ id: String) async {
        // 标记该轮桶 ended：anyTurnInFlight 靠它自动归 false，不再需要全局布尔。
        if let idx = buckets.firstIndex(where: { $0.turnID == id }) {
            buckets[idx].ended = true
        }
        signalJobs()
        await pumpOrResume()
    }

    /// 收敛兜底：还有待播 job 却没有管道在跑（顶替时序可能留下这种孤儿态）就补起管道，
    /// 否则视为已排空、恢复音乐。保证任何路径结束后不留「有活没人干」的挂起。
    /// 管道仍在退出中时多半直接返回（正常收尾的管道自己会恢复音乐）；但**已被取消且无待播**
    /// 的管道按设计不恢复（收尾里的 `!Task.isCancelled`），恢复只能由调用方补——此时若也直接
    /// 返回，恢复就永远丢了：外部停止哨兵（`hook.sh stop`/`ivox quiet`/pi 发言）恰落在旧管道
    /// 退出窗口时必现「音乐卡在暂停」。所以这种情形等它退净（已取消，退出很快）再补恢复。
    private func pumpOrResume() async {
        if let task = currentTask, task.isCancelled, !hasPendingBuckets {
            await awaitCurrentPipelineFinished()
        }
        if hasPendingBuckets {
            startPipelineIfPending()
        } else if currentTask == nil {
            await media.resume()
        }
    }

    /// 流式轮次被取消（pi 空流 `{cancel}`）：丢弃**本轮的桶**并恢复音乐。
    /// 分桶后只删自己这个 turn 的桶、不动其他 agent 排队的桶——空流 `{cancel}` 是 pi 双流里
    /// 那条空流的自扇血，不该把别的排队内容一起清掉（旧实现 bargeIn(nil) 全局清空是单数组下的
    /// 副作用，分桶后必须收敛）。
    func cancelTurn(_ id: String) async {
        Log.info("用户取消轮次 \(id)：丢弃本轮未播内容，自取消不占打断来源")
        // 删除该 turn 对应的桶（若正是队首在播桶，processNext 会在取下一块时发现空叉前移）。
        // 只删自己这轮的桶、不动其他 agent 排队内容——空流 `{cancel}` 不该连带清掉别的轮。
        buckets.removeAll { $0.turnID == id }
        bury(id)
        if turnStack.last == id { turnStack.removeLast() }
        signalJobs()
        await pumpOrResume()   // 还有待播则补起管道，否则恢复音乐（统一收敛点）
    }

    /// 跳过当前桶（Ctrl+1）：丢掉正在播的**这一轮**（连同其后分块），从下一桶接着播。
    /// 与 `cancelTurn` 的区别：那个是「自取消不占打断来源」、也不掐在播（等它自己弹空）；
    /// 这个是用户主动跳，必须立刻掐在播、丢桶、前移。与 `cancelAll` 的区别：那个清全场，
    /// 这个只丢当前、后面的照播。
    func skipCurrentBucket(_ origin: InterruptSource) async {
        guard let head = frontBucket else { return }
        Log.info("跳过当前桶（来源=\(origin)）：丢 turn=\(head.turnID ?? "-") 余 \(head.jobs.count) 块，从下一桶接着播")
        // 整轮丢掉：立墓碑，该轮后续分块（含关连接后 EOF 兜底补出的残尾）也不再开口。
        // 不碰 turnStack——墓碑已在 claimTurn 里优先拦住；出栈会把它顶掉的旧轮重新认成属主，
        // 那是另一个语义，这里不做。
        if let turn = head.turnID { bury(turn) }
        await preemptCurrent(origin)
        await awaitCurrentPipelineFinished()   // 线性化：旧管道退净再前移，避免两个 consumer 抢 player
        if !buckets.isEmpty { buckets.removeFirst() }   // 挂起期间可能已被别的路径清掉，别越界
        signalJobs()
        await pumpOrResume()   // 有下一桶则起管道接着播；没有则收尾并恢复音乐
    }

    /// 跳过当前这句（Ctrl+2）：只丢正在播的这一句，**同一桶剩下的照常念**。
    /// 手动打断三档里的「轻」——`skipCurrentBucket`（中，丢整桶）、`cancelAll`（掀桌，全场清）。
    /// 被掐的那句在合成前就已从桶里弹出（claim），所以「掐在播」天然就是「丢这句」；
    /// 管道重启后 `processNext` 接着取同桶的下一块，无需额外记账。
    func skipCurrentSentence(_ origin: InterruptSource) async {
        Log.info("跳过当前句（来源=\(origin)）：只丢正在播的这句，同轮剩下的接着念")
        await preemptCurrent(origin)
        await awaitCurrentPipelineFinished()   // 线性化：旧管道退净再起，避免两个 consumer 抢 player
        signalJobs()
        await pumpOrResume()   // 同桶还有剩块则接着播；若这轮正等下一批字则原地等
    }

    /// 掐掉「正在播的这一句/这一轮」：作废管道代号 + 取消在播 + 取消已排队合成与音频。
    /// **不动 `buckets`**——它是「插队」与「掀桌」的公共前置：插队（Cmd+D 译文）只掐在播、
    /// 保留其余排队内容；掀桌（bargeIn）先清场再调它。
    /// 不在此清 currentTask——由旧 processNext 自然结束时自清；调用方若要立刻起新管道，
    /// 必须 `await awaitCurrentPipelineFinished()`（线性化点），否则新旧两个 consumer 会并发
    /// write 同一个 player、争夺单一背压 continuation 槽，造成 continuation 泄漏/竞态。
    private func preemptCurrent(_ origin: InterruptSource?) async {
        // nil = 自取消（用户 Esc 放弃自己那轮），不是从别人手里抢喇叭，不占打断来源。
        let label = origin?.description ?? "自取消"
        lastInterrupt = origin
        pipelineSeq &+= 1      // 作废在跑管道：其 producer/consumer 靠代号不等立即停止
        currentTask?.cancel()
        signalJobs()
        await engine.cancelActiveSynthesis(reason: label)   // 显式作废旧纪元排队合成，不依赖任务取消传播
        player.cancelPendingPlayback()
    }

    /// 打断（掀桌）：掐掉在播 + 清空全部排队桶（右⌘ 说话 / Ctrl+Esc 闭嘴）。
    private func bargeIn(_ origin: InterruptSource?) async {
        let label = origin?.description ?? "自取消"
        Log.info("打断（来源=\(label)）：取消在播、清空队列(pending=\(pendingCount))、作废管道 seq\(pipelineSeq&+1)")
        buckets.removeAll()
        onCaption?(nil)   // 掀桌：字幕立刻收（插队/跳桶不走这里——它们的字幕由下一句广播接续）
        await preemptCurrent(origin)
    }

    /// 线性化点：等当前管道（producer+consumer）彻底退出后再起新的。
    private func awaitCurrentPipelineFinished() async {
        guard let old = currentTask else { return }
        let seq = currentTaskSeq
        _ = await old.value
        if currentTaskSeq == seq { currentTask = nil }   // 挂起期间若已起新管道，别把它清掉
    }

    /// 认领轮次：true = 可播（首次出现的新轮，或属主被清空后交还的最新轮）；
    /// false = 已作废的轮，或仍挂在栈里但被更新轮顶掉的旧轮（一律静默丢弃）。
    private func claimTurn(_ id: String) -> Bool {
        if deadTurns.contains(id) { return false }
        if let idx = turnStack.firstIndex(of: id) {
            return idx == turnStack.count - 1   // 在栈中：仅当仍是最新轮才可播
        }
        turnStack.append(id)
        if turnStack.count > 64 { turnStack.removeFirst() }
        return true
    }

    /// 给轮次立墓碑：此后该轮（含关闭连接后 EOF 兜底补出的残尾）不再开口。
    private func bury(_ id: String) {
        guard !deadTurns.contains(id) else { return }
        deadTurns.append(id)
        if deadTurns.count > 64 { deadTurns.removeFirst() }
    }

    /// 作废全部流式轮次（「全场闭嘴」时用：此前所有流式轮一律不再开口）。
    /// 调用方只剩 `cancelAll()`——`speakUserInitiated` 改成插队后不再掀桌；普通播报（无 turnID）只排队，不经过这里。
    private func buryAllTurns() {
        turnStack.forEach { bury($0) }
        turnStack.removeAll()
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
        if currentTask == nil, hasPendingBuckets { startPipeline() }
    }

    /// 恢复等待新 job 的管道（anyTurnInFlight 下 processNext 挂在 waitForJobs 上）。
    private func signalJobs() {
        let waiters = jobWaiters
        jobWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// 批量入队（分桶）：一次 append 完再启动处理，消除逐条入队时队列瞬时为空的音乐跳动窗口。
    /// - Parameter turnID: 流式轮次。分桶后**任何新轮都不打断旧轮**——按到达序 append 新桶，
    ///   由 processNext 播完前桶再前移。同 turn 的后续分块并入已存在的桶。
    func enqueue(_ newJobs: [PlaybackJob], turnID: String? = nil) async {
        guard !newJobs.isEmpty else { return }
        if let turnID {
            // 同轮追加：并入该轮已存在的桶（可能在队首正在播、也可能在队尾排队）。
            if let idx = buckets.firstIndex(where: { $0.turnID == turnID }) {
                buckets[idx].jobs.append(contentsOf: newJobs)
            } else {
                // 首帧或迟到的新轮：**排队，不打断**——认证通过则新增桶在队尾追加。
                guard claimTurn(turnID) else { return }   // 已作废轮：迟到帧静默丢弃
                buckets.append(QueueBucket(turnID: turnID, jobs: newJobs, ended: false))
            }
        } else {
            // 无轮次的普通播报（hook.sh / ivox speak / Cmd+D）：排队，不抢麦。
            // 打断权只归用户快捷键（right⌘/Cmd+D/Ctrl+Esc）——回复到达时的播报若再抢一次，
            // 两个后台会话收尾就会互相掐掉对方的内容（实测 868 字长回复被 199ms 后的
            // 84 字短回复整条掐掉）。这里并入队尾的 nil-turn 桶（或新开），由管道顺序播完。
            if let last = buckets.last, last.turnID == nil {
                buckets[buckets.count - 1].jobs.append(contentsOf: newJobs)
            } else {
                buckets.append(QueueBucket(turnID: nil, jobs: newJobs, ended: true))
            }
        }
        signalJobs()
        Log.debug("队列状态: pending=\(pendingCount) processing=\(currentTask != nil) turn=\(turnID ?? "-")")

        // 有管道则 while 自动消费新 job；无则新起
        if currentTask == nil { startPipeline() }
    }

    func enqueue(_ job: PlaybackJob) async {
        await enqueue([job], turnID: job.turnID)
    }

    /// 连续播放管道：合成 / 播放拆成两条并发 task，中间用有界流接 PCM。
    /// - 合成 task 不停取下一句合成，句间经 `awaitPrefetchCapacity` 门控（排队音频超 4s 就先别
    ///   开下一句），因此始终领先播放一两句，设备不会在句间播空；
    /// - 播放 task 只负责 `player.write`，背压只阻塞播放、不再挡合成。
    /// anyTurnInFlight 下队列瞬时排空，合成 task 挂起等下一批 job（保活音乐不恢复）；全部轮结束且排空才收尾。
    private func processNext(seq: UInt) async {
        generation &+= 1
        let gen = generation
        await media.pause()

        // PCM 管道：unbounded 只承接「预取门控允许的提前量」（领先一两句），
        // 真正的容量上移到句间 awaitPrefetchCapacity 判定，不会无限堆积。
        let (pcmAsync, pcmContinuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)

        let producer = Task {
            defer { pcmContinuation.finish() }
            while !Task.isCancelled {
                if pipelineSeq != seq { return }   // 已被 bargeIn 作废：立即退出，不再合成
                if !hasPendingBuckets {
                    if anyTurnInFlight {
                        await waitForJobs()   // 还有流动中的轮在等块；被入队/endTurn/打断恢复
                        continue
                    }
                    return
                }
                // 门控/等待可能挂起较久，返回后先看取消：已被 bargeIn 就别再发起合成
                try Task.checkCancellation()
                // 先**读**队首（不弹）：前移空桶后取队首待播 job，作为本句的处理目标。
                // 真正弹出留到门控/等待之后——若期间被 bargeIn 清空，job 留在桶里由 bargeIn 一起清走，
                // 不至于「已弹出又不播」的丢失。
                if let fb = frontBucket, fb.jobs.isEmpty, fb.ended {   // 空且已结束的桶前移
                    _ = takeFrontBucket()
                    continue
                }
                // 空但 ended=false：轮还在流式生成、块还没到，不能当空壳弹掉。
                // 这里必须**挂起**等，不能 `continue` 重问：后面若已排了别的桶，上面的
                // `!hasPendingBuckets` 分支就进不去，重问就成了没有挂起点的紧循环——producer
                // 独占本 actor 且永不释放，enqueue/endTurn/cancelAll 一律被饿死（连快捷键打断都
                // 进不来），播报就此永久瘫痪，外加烧满一核。凑齐条件：队首轮已播空正等下一批块
                //（常态）+ 其后已排了别人的话（多 agent 交错）。
                guard let job = frontBucket?.jobs.first else {
                    await waitForJobs()
                    continue
                }
                // 队首桶空则前移到下一桶：这就是「播全播完」——旧桶播完才进新轮。
                // 无需再按 currentTurn 门控跳块（旧实现是单数组 + 单值轮导致新旧残块互删的根源）。
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

                    // claim：门控挂起期间 bargeIn 可能已 removeAll（取消状态尚在传播窗口），
                    // 绝不能对空数组 removeFirst（曾致 EXC_BREAKPOINT「removeFirst from empty」）。
                    // 只在队首仍是我读到的那个 job 时才弹出（popFrontJob 已处理空桶前移）。
                    guard let taken = popFrontJob(), taken.text == job.text else { continue }
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
                    if !claimed, !hasPendingBuckets { _ = popFrontJob() }   // 合成失败跳过队首，避免死循环
                    Log.error("TTS 合成失败: \(error)")
                }
                let elapsed = String(format: "%.1f", -startedAt.timeIntervalSinceNow)
                if pipelineSeq != seq {
                    // MLX 不响应中途取消：打断后被掐的这句仍跑完，但已作废。别让它显示成
                    // 普通「完成」（打断后紧邻的完成会被人误读成「没掐住」）。
                    Log.info("TTS 合成作废（MLX 不响应中途取消，这句跑完才停）[\(job.source)-\(batchID)]（打断来源=\(lastInterrupt?.description ?? "自取消")） \(elapsed)s")
                } else {
                    Log.info("TTS 合成完成 [\(job.source)-\(batchID)] \(elapsed)s")
                }
            }
        }

        // 播放 task：消费 PCM 连续排队，句间零停顿；取消后绝不再 write
        //（否则会和下一轮管道并发争用 player 的单一背压 continuation，造成泄漏/串音）。
        let consumer = Task {
            for await chunk in pcmAsync {
                if Task.isCancelled { break }
                // 已被 bargeIn 作废：立刻停止灌 PCM。write 是「进入时取世代」，作废后再进来的
                // write 会取到新世代、通过世代校验，把旧轮的缓冲 PCM 排进播放器——旧音频因此继续
                // 响（打断失效），旧管道也迟迟不退出（新轮在 awaitCurrentPipelineFinished 干等）。
                if pipelineSeq != seq { break }
                await player.write(chunk.pcm, startsSentence: chunk.sentenceText)
            }
        }

        // producer 正常 finish → defer 里 finish 流，consumer 的 for-await 排空剩余 PCM 后
        // 自然结束。正常路径绝不能提前 consumer.cancel()：此刻 AsyncStream 里可能还缓冲着
        // 最后一句的多块 PCM，cancel 后循环在 isCancelled 处 break，会整块丢掉尾音、drain
        // 只等到已 schedule 的部分，表现为「内容没念完就恢复音乐」。
        // 仅当整条任务真被 bargeIn 取消时，才 cancel consumer 让它立刻弃掉残余。
        _ = try? await producer.value
        if Task.isCancelled { consumer.cancel() }
        _ = try? await consumer.value


        // 整条管道末端：等所有已排队音频真正播完（含跨 job 的尾音）；在途音频作废由
        // bargeIn/cancelAll 的 cancelPendingPlayback 完成（其已递增 generation）。
        if !Task.isCancelled, gen == generation {
            try? await player.drain()
        }
        if currentTaskSeq == seq { currentTask = nil }   // 已被新管道顶替则不清
        await Task.yield()
        // 收尾窗口兜底：drain 等待尾音期间新入队的桶，旧管道正在收尾、currentTask 尚非 nil，
        // enqueue 不肯起新管道——这里须回头检查「有桶待播却无管道」并补起，否则新内容永久躺着
        //（漏播根因，实测 17:14 claude 317字 5块入队后躺在队列零合成）。
        if hasPendingBuckets, currentTask == nil {
            startPipelineIfPending()
        }
        // 还有流动中的轮（未 endTurn）时不恢复音乐——该轮分块可能马上到
        if !hasPendingBuckets, gen == generation, !anyTurnInFlight, !Task.isCancelled {
            onCaption?(nil)   // 整队播完：字幕收起
            await media.resume()
        }
    }

    /// 弹出队首空桶（已播完 / 该 turn 被取消留下的空壳）。用于 processNext 前移桶。
    private func takeFrontBucket() -> QueueBucket? {
        guard !buckets.isEmpty else { return nil }
        return buckets.removeFirst()
    }

    /// 从队首**非空**桶弹出其队首 job（门控后的 claim）。空桶不弹、交给 takeFrontBucket 前移。
    /// 用于 processNext 闭包内同步取/弹——`buckets` 是 actor 存储，闭包里的计算属性
    /// （frontBucket）是 get-only，不能直接 mutating，须经本方法在 actor 上改。
    private func popFrontJob() -> PlaybackJob? {
        guard let head = buckets.first, !head.jobs.isEmpty else { return nil }
        return buckets[0].jobs.removeFirst()
    }

    /// 挂起直到有新 job 入队 / 轮次结束 / 被打断（signalJobs 恢复）。
    private func waitForJobs() async {
        await withCheckedContinuation { continuation in
            jobWaiters.append(continuation)
        }
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
