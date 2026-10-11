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
    func cancelAll() {
        bargeIn()
        currentTurn = nil
        turnOpen = false
    }

    /// 跳过当前正在播的 job，直接播队列里下一个；队列空才真的停
    func skipCurrent() async {
        guard let oldTask = currentTask else { return }
        generation &+= 1
        currentTask = nil
        oldTask.cancel()
        player.cancelPendingPlayback()
        _ = await oldTask.value

        if jobs.isEmpty {
            await media.resume()
        } else if currentTask == nil {
            currentTask = Task { await processNext() }
        }
    }

    /// 空闲时恢复音乐（由外部调用，如语音输入结束后）
    func resumeIfIdle() async {
        guard jobs.isEmpty, currentTask == nil else { return }
        await media.resume()
    }

    /// 流式轮次开始（首帧）：打断旧轮/普通播报，标记本轮仍在生成（句间不恢复音乐）。
    func beginTurn(_ id: String) {
        if currentTurn != id { bargeIn() }
        currentTurn = id
        turnOpen = true
    }

    /// 流式轮次正常结束：放开音乐保活；若已播完则恢复音乐。
    func endTurn(_ id: String) async {
        guard currentTurn == id else { return }
        turnOpen = false
        if jobs.isEmpty, currentTask == nil { await media.resume() }
    }

    /// 流式轮次被取消（用户 Escape）：丢弃本轮未播内容并恢复音乐。
    func cancelTurn(_ id: String) async {
        guard currentTurn == id else { return }
        bargeIn()
        turnOpen = false
        await media.resume()
    }

    /// 打断：取消在播任务、清空队列（新轮或无 turn 的普通播报调用）。
    private func bargeIn() {
        currentTask?.cancel()
        currentTask = nil
        jobs.removeAll()
        player.cancelPendingPlayback()
    }

    /// 批量入队：一次 append 完再启动处理。
    /// 逐条 await enqueue 时，若分块之间队列瞬时为空，processNext 会提前 resume 音乐，
    /// 下一块再 pause —— 表现为播报中音乐反复跳动。批量入口消除这个窗口。
    /// - Parameter turnID: 流式轮次。与当前轮不同（含 nil 普通播报）先打断旧轮；同轮追加。
    func enqueue(_ newJobs: [PlaybackJob], turnID: String? = nil) async {
        guard !newJobs.isEmpty else { return }
        if let turnID {
            if currentTurn != turnID {
                bargeIn()
                currentTurn = turnID
                turnOpen = true
            }
        } else {
            // 普通 ivox speak / hook.sh：作为新一轮打断当前在播
            bargeIn()
            currentTurn = nil
            turnOpen = false
        }
        jobs.append(contentsOf: newJobs)
        Log.debug("队列状态: pending=\(jobs.count) processing=\(currentTask != nil) turn=\(turnID ?? "-")")

        // 正在播就不打断；当前 task 跑完 processNext 的 while 会自动消费新 job
        if currentTask == nil {
            currentTask = Task { await processNext() }
        }
    }

    func enqueue(_ job: PlaybackJob) async {
        await enqueue([job], turnID: job.turnID)
    }

    private func processNext() async {
        generation &+= 1
        let gen = generation
        await media.pause()

        // peek + claim：队首 job 直到真正开始播放才拿出，避免 cancel 时丢段
        while let job = jobs.first {
            let batchID = String(UUID().uuidString.prefix(6))
            Log.info("TTS 播放开始 [\(job.source)-\(batchID)]")
            let startedAt = Date()
            var consumed = false   // job 是否已从 jobs 拿出

            do {
                try Task.checkCancellation()
                try await waitUntilEngineReady()
                try Task.checkCancellation()

                let stream = await engine.synthesizeStream(text: job.text, voiceID: job.voiceID)
                consumed = true
                jobs.removeFirst()  // claim：拿到 stream 后才同步拿出，cancel 不会撞上

                for try await pcm in stream {
                    try Task.checkCancellation()
                    player.write(pcm)
                }

                try Task.checkCancellation()
                try await player.drain()
            } catch is CancellationError {
                if consumed { player.cancelPendingPlayback() }
                // 未 consumed 时队首 job 留在 jobs，新 task 会继续消费
                Log.info("TTS 播放已取消 [\(job.source)-\(batchID)]")
                currentTask = nil
                // 媒体恢复交给 skipCurrent 统一处理，避免跟新 processNext 入口的 pause 竞速
                return
            } catch {
                if !consumed { jobs.removeFirst() }   // 合成失败时跳过此 job，避免死循环
                player.cancelPendingPlayback()
                Log.error("TTS 合成失败: \(error)")
            }

            let elapsed = String(format: "%.1f", -startedAt.timeIntervalSinceNow)
            Log.info("TTS 播放完成 [\(job.source)-\(batchID)] \(elapsed)s")
        }

        currentTask = nil
        await Task.yield()
        // turnOpen 时同轮后续分块马上到，不能恢复音乐，否则句间反复 pause/resume
        if jobs.isEmpty, gen == generation, !turnOpen {
            await media.resume()
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
