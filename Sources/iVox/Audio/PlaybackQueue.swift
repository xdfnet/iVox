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
    private let modelReadyPollNs: UInt64 = 100_000_000

    init(engine: TTSEngine, config: PlaybackConfig, mediaController: MediaController) {
        self.engine = engine
        self.config = config
        self.player = AudioPlayer(config: config)
        self.media = mediaController
    }

    func shutdown() {
        Log.info("PlaybackQueue 退出")
        currentTask?.cancel()
        jobs.removeAll()
        player.cancelPendingPlayback()
        player.stop()
    }

    func enqueue(_ job: PlaybackJob) async {
        if !jobs.isEmpty {
            Log.info("丢弃待播: \(jobs.count) 条")
        }

        if config.interruptCurrent, let task = currentTask {
            task.cancel()
            _ = await task.value
            player.prepareForPlayback()
            Log.info("打断当前播报，切到最新请求")
        }

        jobs.removeAll()
        jobs.append(job)
        Log.info("队列状态: pending=\(jobs.count) processing=\(currentTask != nil)")

        currentTask = Task { await processNext() }
    }

    private func processNext() async {
        defer {
            player.cancelPendingPlayback()
            Task { await media.resume() }
        }

        guard !jobs.isEmpty else { return }
        await media.pause()
        try? Task.checkCancellation()

        let batchID = String(UUID().uuidString.prefix(6))
        var isFirstSegment = true

        while !jobs.isEmpty {
            let job = jobs.removeFirst()

            Log.info("TTS 播放开始 [\(job.source)-\(batchID)]")
            let startedAt = Date()
            let segments = splitSentences(job.text)

            for (idx, seg) in segments.enumerated() {
                do {
                    try Task.checkCancellation()
                    try await waitUntilEngineReady()
                    try Task.checkCancellation()

                    if isFirstSegment {
                        player.prepareForPlayback()
                        isFirstSegment = false
                    }

                    let preview = seg.prefix(60)
                    let segmentLabel = segments.count > 1 ? "段 \(idx + 1)/\(segments.count): \(preview)" : preview
                    Log.info("TTS [\(job.source)-\(batchID)] \(segmentLabel)")

                    let stream = await engine.synthesizeStream(text: seg, voiceID: job.voiceID)
                    var chunkCount = 0
                    for try await pcm in stream {
                        try Task.checkCancellation()
                        chunkCount += 1
                        player.write(pcm)
                    }

                    try Task.checkCancellation()
                    try await player.drain(chunks: chunkCount)
                } catch is CancellationError {
                    Log.info("TTS 播放已取消 [\(job.source)-\(batchID)]")
                    return  // defer + return: stop all remaining segments
                } catch {
                    Log.error("TTS 合成失败: \(error)")
                    // continue to next segment on non-cancellation errors
                }
            }

            let elapsed = String(format: "%.1f", -startedAt.timeIntervalSinceNow)
            Log.info("TTS 播放完成 [\(job.source)-\(batchID)] \(elapsed)s \(segments.count) 段")
        }
    }

    private func waitUntilEngineReady() async throws {
        while true {
            try Task.checkCancellation()
            switch await engine.state {
            case .ready:
                return
            case .failed(let message):
                throw PlaybackError.ttsUnavailable(message)
            case .notStarted, .loading:
                Log.info("TTS 模型尚未就绪，等待加载完成")
                try await Task.sleep(nanoseconds: modelReadyPollNs)
            }
        }
    }
}

private enum PlaybackError: Error {
    case ttsUnavailable(String)
}
