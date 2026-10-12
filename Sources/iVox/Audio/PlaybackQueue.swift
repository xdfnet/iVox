import Foundation
import iVoxKit

struct PlaybackJob: Sendable {
    let text: String
    let voiceID: String
    let source: String
    /// 所属流式轮次；nil = 传统整段播报（ivox speak / hook.sh）
    var turnID: String? = nil
}

actor PlaybackQueue {
    private var jobs: [PlaybackJob] = []
    private var currentTask: Task<Void, Never>?
    private var generation: UInt = 0
    /// 当前播报所属轮次；与新请求的 turnID 不同即触发打断
    private var currentTurn: String?
    /// 当前轮次是否仍在流式生成（true 时句间队列瞬时排空也不恢复音乐）
    private var turnOpen = false
    /// processNext 在 turnOpen 下等待新 job 的挂起点；入队/结束/打断时恢复
    private var jobWaiters: [CheckedContinuation<Void, Never>] = []
    private let player: AudioPlayer
    private let engine: TTSEngine
    private let media: MediaController
    private let config: PlaybackConfig

    init(engine: TTSEngine, config: PlaybackConfig, mediaController: MediaController) {
        self.engine = engine
        self.config = config
        self.player = AudioPlayer()
        self.media = mediaController
    }

    func shutdown() {
        Log.info("PlaybackQueue 退出")
        currentTask?.cancel()
        jobs.removeAll()
        player.cancelPendingPlayback()
        player.stop()
        Task { await media.resume() }   // 退出时确保 music 恢复，避免 daemon 重启后卡暂停
    }

    /// 队列中等待播放的条数（/health 用）
    var pendingCount: Int { jobs.count }
    /// 是否有正在处理的播报（/health 用）
    var isProcessing: Bool { currentTask != nil }

    /// 取消所有播放（正在播的和队列中等待的）
    func cancelAll() async {
        await bargeIn()
        currentTurn = nil
        turnOpen = false
    }

    /// 空闲时恢复音乐（由外部调用，如语音输入结束后）
    func resumeIfIdle() async {
        guard jobs.isEmpty, currentTask == nil else { return }
        await media.resume()
    }

    /// 流式轮次开始（首帧）：打断旧轮/普通播报，标记本轮仍在生成（句间不恢复音乐）。
    func beginTurn(_ id: String) async {
        if currentTurn != id {
            await bargeIn()
            await awaitCurrentPipelineFinished()   // 否则同轮首个 enqueue 可能误复用已取消的旧管道
        }
        currentTurn = id
        turnOpen = true
    }

    /// 流式轮次正常结束：放开音乐保活并唤醒管道，让其排空后退出、恢复音乐。
    /// 已被更新轮次顶掉的旧轮：其迟到的 {end}/EOF 一律忽略，残尾不再开口。
    func endTurn(_ id: String) async {
        guard currentTurn == id else { return }
        turnOpen = false
        signalJobs()
        if jobs.isEmpty, currentTask == nil { await media.resume() }
    }

    /// 流式轮次被取消（用户 Escape）：丢弃本轮未播内容并恢复音乐。
    func cancelTurn(_ id: String) async {
        guard currentTurn == id else { return }
        await bargeIn()
        turnOpen = false
        await media.resume()
    }

    /// 打断：取消在播任务、清空队列（新轮或无 turn 的普通播报调用）。
    /// 不在此清 currentTask——由旧 processNext 自然结束时自清；调用方若要立刻起新管道，
    /// 必须 `await currentTask?.value`（线性化点），否则新旧两个 consumer 会并发 write
    /// 同一个 player、争夺单一背压 continuation 槽，造成 continuation 泄漏/竞态。
    private func bargeIn() async {
        currentTask?.cancel()
        jobs.removeAll()
        signalJobs()
        await engine.cancelActiveSynthesis()   // 显式作废旧纪元排队合成，不依赖任务取消传播
        player.cancelPendingPlayback()
    }

    /// 线性化点：等当前管道（producer+consumer）彻底退出后再起新的。
    private func awaitCurrentPipelineFinished() async {
        guard let old = currentTask else { return }
        _ = await old.value
        currentTask = nil
    }

    /// 恢复等待新 job 的管道（turnOpen 下 processNext 挂在 waitForJobs 上）。
    private func signalJobs() {
        let waiters = jobWaiters
        jobWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// 批量入队：一次 append 完再启动处理。
    /// 逐条 await enqueue 时，若分块之间队列瞬时为空，processNext 会提前 resume 音乐，
    /// 下一块再 pause —— 表现为播报中音乐反复跳动。批量入口消除这个窗口。
    /// - Parameter turnID: 流式轮次。与当前轮不同（含 nil 普通播报）先打断旧轮；同轮追加。
    func enqueue(_ newJobs: [PlaybackJob], turnID: String? = nil) async {
        guard !newJobs.isEmpty else { return }
        var mustStart = false
        if let turnID {
            // 已被更新轮次顶掉的旧轮：迟到帧（含 EOF 残尾）静默丢弃，
            // 不 bargeIn——否则旧轮残音会反杀新轮，用户会听到上一轮冒半句。
            if let cur = currentTurn, cur != turnID { return }
            if currentTurn == nil {
                await bargeIn()
                await awaitCurrentPipelineFinished()   // 线性化：旧管道退净再起新的
                currentTurn = turnID
                mustStart = true
            }
            turnOpen = true
        } else {
            // 普通 ivox speak / hook.sh：作为新一轮打断当前在播
            await bargeIn()
            await awaitCurrentPipelineFinished()
            currentTurn = nil
            turnOpen = false
            mustStart = true
        }
        jobs.append(contentsOf: newJobs)
        signalJobs()
        Log.debug("队列状态: pending=\(jobs.count) processing=\(currentTask != nil) turn=\(turnID ?? "-")")

        // 打断后必须新起；同轮追加则复用正在跑的管道（while 自动消费新 job）
        if mustStart || currentTask == nil {
            currentTask = Task { await processNext() }
        }
    }

    func enqueue(_ job: PlaybackJob) async {
        await enqueue([job], turnID: job.turnID)
    }

    /// 连续播放管道：合成 / 播放拆成两条并发 task，中间用有界流接 PCM。
    /// - 合成 task 不停取下一句合成，句间经 `awaitPrefetchCapacity` 门控（排队音频超 4s 就先别
    ///   开下一句），因此始终领先播放一两句，设备不会在句间播空；
    /// - 播放 task 只负责 `player.write`，背压只阻塞播放、不再挡合成。
    /// turnOpen 下队列瞬时排空，合成 task 挂起等下一批 job（保活音乐不恢复）；轮次结束且排空才收尾。
    private func processNext() async {
        generation &+= 1
        let gen = generation
        await media.pause()

        // PCM 管道：unbounded 只承接「预取门控允许的提前量」（领先一两句），
        // 真正的容量上移到句间 awaitPrefetchCapacity 判定，不会无限堆积。
        let (pcmAsync, pcmContinuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)

        let producer = Task {
            defer { pcmContinuation.finish() }
            while !Task.isCancelled {
                if jobs.isEmpty {
                    if turnOpen {
                        await waitForJobs()   // 被入队/endTurn/打断恢复
                        continue
                    }
                    return
                }
                // 门控/等待可能挂起较久，返回后先看取消：已被 bargeIn 就别再发起合成
                try Task.checkCancellation()
                let job = jobs[0]
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

                    jobs.removeFirst()  // claim：确定要合成才拿出
                    claimed = true
                    let stream = await engine.synthesizeStream(text: job.text, voiceID: job.voiceID)

                    for try await pcm in stream {
                        // MLX 流不响应中途取消：一旦发起本句只能跑完，但取消后不再向下游灌 PCM
                        if Task.isCancelled { break }
                        pcmContinuation.yield(pcm)
                    }
                    try Task.checkCancellation()
                } catch is CancellationError {
                    Log.info("TTS 合成已取消 [\(job.source)-\(batchID)]")
                    throw CancellationError()
                } catch {
                    if !claimed, !jobs.isEmpty { jobs.removeFirst() }   // 合成失败跳过此 job，避免死循环
                    Log.error("TTS 合成失败: \(error)")
                }
                let elapsed = String(format: "%.1f", -startedAt.timeIntervalSinceNow)
                Log.info("TTS 合成完成 [\(job.source)-\(batchID)] \(elapsed)s")
            }
        }

        // 播放 task：消费 PCM 连续排队，句间零停顿；取消后绝不再 write
        //（否则会和下一轮管道并发争用 player 的单一背压 continuation，造成泄漏/串音）。
        let consumer = Task {
            for await pcm in pcmAsync {
                if Task.isCancelled { break }
                await player.write(pcm)
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
        currentTask = nil
        await Task.yield()
        // turnOpen 时同轮后续分块马上到，不能恢复音乐，否则句间反复 pause/resume
        if jobs.isEmpty, gen == generation, !turnOpen, !Task.isCancelled {
            await media.resume()
        }
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
