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
            guard engine.isRunning, node.isPlaying else { return }
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
}
