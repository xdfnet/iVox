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

    func enqueue(_ job: PlaybackJob) async {
        if !jobs.isEmpty {
            Log.debug("丢弃待播: \(jobs.count) 条")
        }

        if config.interruptCurrent, let task = currentTask {
            task.cancel()
            player.cancelPendingPlayback()
            Log.info("打断当前播报，切到最新请求")
        }

        jobs.removeAll()
        jobs.append(job)
        Log.debug("队列状态: pending=\(jobs.count) processing=\(currentTask != nil)")

        currentTask = Task { await processNext() }
    }

    private func processNext() async {
        guard !jobs.isEmpty else { return }
        let job = jobs.removeFirst()

        let batchID = String(UUID().uuidString.prefix(6))
        Log.info("TTS 播放开始 [\(job.source)-\(batchID)]")
        let startedAt = Date()

        do {
            try Task.checkCancellation()
            await media.pause()
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
            return
        } catch {
            player.cancelPendingPlayback()
            Log.error("TTS 合成失败: \(error)")
        }

        let elapsed = String(format: "%.1f", -startedAt.timeIntervalSinceNow)
        Log.info("TTS 播放完成 [\(job.source)-\(batchID)] \(elapsed)s")
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
