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
    private let player = AudioPlayer()
    private let engine: TTSEngine
    private let media = MediaController()

    init(engine: TTSEngine) {
        self.engine = engine
    }

    func shutdown() {
        Log.info("PlaybackQueue 退出")
        isProcessing = false
        jobs.removeAll()
        player.stop()
    }

    func enqueue(_ job: PlaybackJob) {
        // 新请求进来时，丢弃所有尚未开始播的（正在播的已从 jobs 取出）
        if !jobs.isEmpty {
            Log.info("丢弃待播: \(jobs.count) 条")
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

            Log.info("TTS 播放开始 [\(job.source)]")
            let startedAt = Date()

            do {
                player.prepareForPlayback()
                let stream = await engine.synthesizeStream(text: job.text, voiceID: job.voiceID)
                var totalBytes = 0
                var chunkCount = 0
                for try await pcm in stream {
                    chunkCount += 1
                    totalBytes += pcm.count
                    player.write(pcm)
                }
                Log.info("播放写入: chunks=\(chunkCount) bytes=\(totalBytes)")
                await player.drain(chunks: chunkCount)
                Log.info("TTS 播放完成 [\(job.source)] \(String(format: "%.1f", -startedAt.timeIntervalSinceNow))s")
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
}
