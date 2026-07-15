import Foundation
import iVoxKit

struct PlaybackJob: Sendable {
    let text: String
    let voiceID: String
    let source: String
}

actor PlaybackQueue {
    private var jobs: [PlaybackJob] = []
    private var currentTask: Task<Void, Never>?
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
    }

    /// 取消所有播放（正在播的和队列中等待的）
    func cancelAll() {
        currentTask?.cancel()
        currentTask = nil
        jobs.removeAll()
        player.cancelPendingPlayback()
    }

    /// 取消正在播的当前 job，保留队列里等待的（ESC 用）
    func cancelCurrent() async {
        let oldTask = currentTask
        currentTask = nil
        oldTask?.cancel()
        player.cancelPendingPlayback()
        _ = await oldTask?.value  // 等旧 task 退出再启动新的，避免并发写 player

        if !jobs.isEmpty {
            currentTask = Task { await processNext() }
        }
    }

    func enqueue(_ job: PlaybackJob) async {
        jobs.append(job)
        Log.debug("队列状态: pending=\(jobs.count) processing=\(currentTask != nil)")

        // 正在播就不打断；当前 task 跑完 processNext 的 while 会自动消费新 job
        if currentTask == nil {
            currentTask = Task { await processNext() }
        }
    }

    private func processNext() async {
        await media.pause()

        while !jobs.isEmpty {
            let job = jobs.removeFirst()

            let batchID = String(UUID().uuidString.prefix(6))
            Log.info("TTS 播放开始 [\(job.source)-\(batchID)]")
            let startedAt = Date()

            do {
                try Task.checkCancellation()
                try await waitUntilEngineReady()
                try Task.checkCancellation()

                let stream = await engine.synthesizeStream(text: job.text, voiceID: job.voiceID)
                for try await pcm in stream {
                    try Task.checkCancellation()
                    player.write(pcm)
                }

                try Task.checkCancellation()
                try await player.drain()
            } catch is CancellationError {
                player.cancelPendingPlayback()
                Log.info("TTS 播放已取消 [\(job.source)-\(batchID)]")
                currentTask = nil
                Task { await media.resume() }
                return
            } catch {
                player.cancelPendingPlayback()
                Log.error("TTS 合成失败: \(error)")
            }

            let elapsed = String(format: "%.1f", -startedAt.timeIntervalSinceNow)
            Log.info("TTS 播放完成 [\(job.source)-\(batchID)] \(elapsed)s")
        }

        currentTask = nil
        Task { await media.resume() }
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
