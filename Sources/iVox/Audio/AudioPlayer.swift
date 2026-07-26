import AVFoundation
import Foundation
import iVoxKit

final class AudioPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let serialQueue = DispatchQueue(label: "ivox.audio")
    private var pendingCount = 0
    private var started = false
    private var drainedContinuation: CheckedContinuation<Void, Never>?

    deinit {
        serialQueue.sync {
            drainedContinuation?.resume()
            drainedContinuation = nil
        }
    }

    init() {
        format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: false)!

        var ok = true
        serialQueue.sync {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            engine.prepare()
            do {
                try engine.start()
            } catch {
                Log.error("AudioEngine 启动失败: \(error)")
                ok = false
                return
            }
        }
        guard ok else { return }
        node.play()
        started = true
    }

    func write(_ pcm: Data) {
        guard started, !pcm.isEmpty else { return }
        let frames = AVAudioFrameCount(pcm.count / 2)
        serialQueue.sync {
            if !ensureHealthy() { return }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            buffer.frameLength = frames
            pcm.withUnsafeBytes { src in
                guard let srcPtr = src.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
                if let dst = buffer.int16ChannelData?.pointee {
                    dst.initialize(from: srcPtr, count: Int(frames))
                }
            }
            pendingCount += 1
            node.scheduleBuffer(buffer) { [weak self] in
                guard let self else { return }
                self.serialQueue.async {
                    self.pendingCount -= 1
                    if self.pendingCount == 0, let cont = self.drainedContinuation {
                        self.drainedContinuation = nil
                        cont.resume()
                    }
                }
            }
        }
    }

    func drain() async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let wasDrained = serialQueue.sync { () -> Bool in
                if pendingCount == 0 { return true }
                drainedContinuation = continuation
                return false
            }
            if wasDrained { continuation.resume() }
        }
    }

    func cancelPendingPlayback() {
        serialQueue.sync {
            pendingCount = 0
            drainedContinuation?.resume()
            drainedContinuation = nil
            node.stop()
            if engine.isRunning {
                node.play()
            }
        }
    }

    func stop() {
        serialQueue.sync {
            started = false
            drainedContinuation?.resume()
            drainedContinuation = nil
            node.stop()
            engine.stop()
        }
    }

    /// 流式写入前自检：engine 未运行或 node 未在播 → 重建一次。
    /// 已启动的前提下，常规情况下是一次 isRunning 查询（O(1)）。
    /// 必须在 serialQueue 内调用。
    private func ensureHealthy() -> Bool {
        if engine.isRunning && node.isPlaying { return true }

        Log.warn("AudioEngine 异常，尝试重建: engine.isRunning=\(engine.isRunning) node.isPlaying=\(node.isPlaying)")

        node.stop()
        engine.stop()
        engine.reset()

        do {
            try engine.start()
            node.play()
            Log.info("AudioEngine 重建成功")
            return true
        } catch {
            Log.error("AudioEngine 重建失败: \(error)")
            started = false
            return false
        }
    }
}
