import AVFoundation
import Foundation
import iVoxKit

/// 常驻播放管道：整条播报（跨多个分块/句子）复用一条 AVAudioPlayerNode，
/// 分块连续 `scheduleBuffer` 排队、设备从不逐句重启（对齐 ai-stack 的单个 OutputStream）。
/// 背压靠已排队未播放帧数的高低水位：生产者（TTS 合成）始终提前排队，排满高水位才等待，
/// 等价 sounddevice 阻塞 write + queue(maxsize)。prime 静音只在「真正播空/取消」后做一次。
final class AudioPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let serialQueue = DispatchQueue(label: "ivox.audio")
    private var pendingCount = 0
    private var pendingFrames = 0   // 已排队未被设备消费的帧数（实时，背压 + drain 估算共用）
    private var generation = 0      // 世代：cancelPendingPlayback 递增，旧 buffer 回调据此丢弃
    private var started = false
    private var drainedContinuation: CheckedContinuation<Void, Never>?
    private var backpressureContinuation: CheckedContinuation<Void, Never>?
    private static let drainSlack: TimeInterval = 2.0   // drain 超时余量（秒）
    private var needsPrime = true  // 是否需要先调度前导静音 buffer 唤醒 player node
    // 背压水位：排队音频超过 4s 暂停合成，降到 2s 再放行（留足预取掩盖下一句合成启动）
    private let highWaterFrames: Int
    private let lowWaterFrames: Int

    deinit {
        serialQueue.sync {
            drainedContinuation?.resume()
            backpressureContinuation?.resume()
            drainedContinuation = nil
            backpressureContinuation = nil
        }
    }

    init() {
        format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: false)!
        highWaterFrames = Int(format.sampleRate) * 4
        lowWaterFrames = Int(format.sampleRate) * 2

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
        waitForNodePlaying()
        started = true
    }

    /// 写入一块 PCM。排队音频超高水位时挂起，等设备消费到低水位再返回（背压）。
    /// 被取消时由 cancelPendingPlayback 恢复挂起，调用方靠 Task.checkCancellation 退出。
    func write(_ pcm: Data) async {
        guard started, !pcm.isEmpty else { return }
        let frames = AVAudioFrameCount(pcm.count / 2)

        // 背压：已排队音频太多就等设备先消费，避免无限占内存、同时构成合成预取上限
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            serialQueue.async {
                if self.pendingFrames <= self.highWaterFrames {
                    continuation.resume()
                } else {
                    self.backpressureContinuation = continuation
                }
            }
        }

        serialQueue.sync {
            if !ensureHealthy() { return }

            // 前导静音：唤醒休眠的 player node，避免首个 audio chunk 被跳过。
            // 连续排队时 pendingCount 句间不归零，这里整轮只会触发一次。
            if needsPrime {
                let primeFrames = AVAudioFrameCount(format.sampleRate / 20)  // 50ms 静音
                guard let primeBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: primeFrames) else {
                    Log.warn("前导静音 buffer 分配失败，跳过唤醒")
                    return
                }
                primeBuf.frameLength = primeFrames
                if let dst = primeBuf.int16ChannelData?.pointee {
                    dst.initialize(repeating: 0, count: Int(primeFrames))
                }
                let gen = generation
                pendingCount += 1
                pendingFrames += Int(primeFrames)
                node.scheduleBuffer(primeBuf, completionCallbackType: .dataConsumed) { [weak self] _ in
                    guard let self else { return }
                    self.serialQueue.async {
                        guard self.generation == gen else { return }
                        self.onConsumed(frames: Int(primeFrames))
                    }
                }
                Log.debug("前导静音已调度唤醒 player node")
                needsPrime = false
            }

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
            buffer.frameLength = frames
            pcm.withUnsafeBytes { src in
                guard let srcPtr = src.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
                if let dst = buffer.int16ChannelData?.pointee {
                    dst.initialize(from: srcPtr, count: Int(frames))
                }
            }
            let gen = generation
            pendingCount += 1
            pendingFrames += Int(frames)
            // .dataConsumed：数据被播放器读出即回调，不依赖引擎在播放末尾是否 auto-shutdown
            node.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
                guard let self else { return }
                self.serialQueue.async {
                    guard self.generation == gen else { return }   // 已被取消的旧世代回调直接丢弃
                    self.onConsumed(frames: Int(frames))
                }
            }
        }
    }

    /// 一块 buffer 被设备消费：更新计数，按需恢复背压等待 / drain 等待。必须在 serialQueue 内。
    private func onConsumed(frames: Int) {
        pendingCount -= 1
        pendingFrames = max(0, pendingFrames - frames)
        if pendingFrames <= lowWaterFrames, let cont = backpressureContinuation {
            backpressureContinuation = nil
            cont.resume()
        }
        if pendingCount == 0 {
            needsPrime = true   // 设备真正播空：下次写入重新唤醒（覆盖电源管理休眠）
            if let cont = drainedContinuation {
                drainedContinuation = nil
                cont.resume()
            }
        }
    }

    /// 等所有已排队音频播完（只在整条管道末端调用一次，不再逐句调用）。
    func drain() async throws {
        let deadline = serialQueue.sync { () -> DispatchTime in
            let ms = Int((Double(pendingFrames) / format.sampleRate + Self.drainSlack) * 1000)
            return DispatchTime.now() + .milliseconds(ms)
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let wasDrained = serialQueue.sync { () -> Bool in
                if pendingCount == 0 { return true }
                drainedContinuation = continuation
                return false
            }
            if wasDrained {
                continuation.resume()
            } else {
                // buffer 播放回调丢失（如 AudioEngine 被系统事件停止）时兜底，避免管道永久阻塞
                serialQueue.asyncAfter(deadline: deadline) { [weak self] in
                    guard let self else { return }
                    if let cont = self.drainedContinuation {
                        self.drainedContinuation = nil
                        Log.warn("drain 超时强制返回（pendingCount=\(self.pendingCount)）")
                        cont.resume()
                    }
                }
            }
        }
    }

    func cancelPendingPlayback() {
        serialQueue.sync {
            generation += 1        // 使已排队 buffer 的回调失效
            pendingCount = 0
            pendingFrames = 0
            drainedContinuation?.resume()
            drainedContinuation = nil
            // 恢复可能卡在背压上的生产者，让它靠 Task 取消退出
            backpressureContinuation?.resume()
            backpressureContinuation = nil
            needsPrime = true      // 取消后新播放段需要重新唤醒
            node.stop()
            if engine.isRunning {
                node.play()
                waitForNodePlaying()
            }
        }
    }

    func stop() {
        serialQueue.sync {
            started = false
            drainedContinuation?.resume()
            backpressureContinuation?.resume()
            drainedContinuation = nil
            backpressureContinuation = nil
            node.stop()
            engine.stop()
        }
    }

    /// 流式写入前自检：engine 未运行或 node 未在播 → 重建一次。必须在 serialQueue 内调用。
    private func ensureHealthy() -> Bool {
        if engine.isRunning && node.isPlaying { return true }

        Log.warn("AudioEngine 异常，尝试重建: engine.isRunning=\(engine.isRunning) node.isPlaying=\(node.isPlaying)")

        node.stop()
        engine.stop()
        engine.reset()

        do {
            try engine.start()
            node.play()
            waitForNodePlaying()
            Log.info("AudioEngine 重建成功")
            return true
        } catch {
            Log.error("AudioEngine 重建失败: \(error)")
            started = false
            return false
        }
    }

    /// 等待 player node 真正进入播放状态，最多 50ms。必须在 serialQueue 内调用。
    private func waitForNodePlaying(timeoutMs: Int = 50) {
        let deadline = DispatchTime.now() + .milliseconds(timeoutMs)
        while !node.isPlaying && DispatchTime.now() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
    }
}
