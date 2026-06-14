import Foundation
import iVoxKit

struct PlaybackJob: Sendable {
    let text: String
    let voiceID: String
    let source: String
}

actor PlaybackQueue {
    private var jobs: [PlaybackJob] = []
    private var isProcessing = false
    private let player: AudioPlayer
    private let engine: TTSEngine
    private let media: MediaController
    private var playbackGeneration = 0
    private let config: PlaybackConfig
    private let modelReadyPollNs: UInt64 = 100_000_000

    init(engine: TTSEngine, config: PlaybackConfig, mediaControl: MediaControlConfig) {
        self.engine = engine
        self.config = config
        self.player = AudioPlayer(config: config)
        self.media = MediaController(config: mediaControl)
    }

    func shutdown() {
        Log.info("PlaybackQueue 退出")
        isProcessing = false
        playbackGeneration += 1
        jobs.removeAll()
        player.stop()
    }

    func enqueue(_ job: PlaybackJob) {
        if !jobs.isEmpty {
            Log.info("丢弃待播: \(jobs.count) 条")
        }
        if isProcessing, config.interruptCurrent {
            playbackGeneration += 1
            player.cancelPendingPlayback()
            Log.info("打断当前播报，切到最新请求")
        }
        jobs.removeAll()
        jobs.append(job)
        Log.info("队列状态: pending=\(jobs.count) processing=\(isProcessing)")
        if !isProcessing {
            Task { await processNext() }
        }
    }

    private func processNext() async {
        guard !jobs.isEmpty else { isProcessing = false; return }
        isProcessing = true
        await media.pause()

        while !jobs.isEmpty {
            let job = jobs.removeFirst()
            let generation = playbackGeneration

            Log.info("TTS 播放开始 [\(job.source)]")
            let startedAt = Date()

            do {
                try await waitUntilEngineReady(generation: generation)
                player.prepareForPlayback()
                let stream = await engine.synthesizeStream(text: job.text, voiceID: job.voiceID)
                var totalBytes = 0
                var chunkCount = 0
                var interrupted = false
                for try await pcm in stream {
                    if generation != playbackGeneration {
                        interrupted = true
                        break
                    }
                    chunkCount += 1
                    totalBytes += pcm.count
                    player.write(pcm)
                }
                if interrupted {
                    player.cancelPendingPlayback()
                    Log.info("TTS 播放已被新请求打断 [\(job.source)]")
                    continue
                }
                Log.info("播放写入: chunks=\(chunkCount) bytes=\(totalBytes)")
                await player.drain(chunks: chunkCount)
                Log.info("TTS 播放完成 [\(job.source)] \(String(format: "%.1f", -startedAt.timeIntervalSinceNow))s")
            } catch is CancellationError {
                player.cancelPendingPlayback()
                Log.info("TTS 播放已取消 [\(job.source)]")
            } catch {
                Log.error("TTS 合成失败: \(error)")
            }
        }

        isProcessing = false
        await media.resume()

        // 处理期间可能有新任务入队，重新 drain
        if !jobs.isEmpty {
            await processNext()
        }
    }

    private func waitUntilEngineReady(generation: Int) async throws {
        while true {
            if generation != playbackGeneration {
                throw CancellationError()
            }
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
