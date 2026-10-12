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
    /// 背压等待者：每个挂起的 writer 独立槽。密集打断时新旧管道的 writer 可能短暂同时
    /// 在场，用数组而非单槽——单槽会被后到者覆盖，先到者的 continuation 永不 resume（泄漏）。
    private var backpressureWaiters: [CheckedContinuation<Void, Never>] = []
    /// 合成预取门控：排队音频超高水位时挂起「下一句合成」，降到高水位放行，
    /// 让合成领先播放一两句即可，不无限预取。与 write 的背压分离（两级流水线）。
    /// 同样用等待者数组，避免多 producer 极端时序下互相覆盖泄漏。
    private var prefetcherWaiters: [CheckedContinuation<Void, Never>] = []
    private static let drainSlack: TimeInterval = 2.0   // drain 超时余量（秒）
    private var needsPrime = true  // 是否需要先调度前导静音 buffer 唤醒 player node
    // 背压水位：排队音频超过 4s 暂停合成，降到 2s 再放行（留足预取掩盖下一句合成启动）
    private let highWaterFrames: Int
    private let lowWaterFrames: Int

    deinit {
        serialQueue.sync {
            drainedContinuation?.resume()
            backpressureWaiters.forEach { $0.resume() }
            prefetcherWaiters.forEach { $0.resume() }
            drainedContinuation = nil
            backpressureWaiters.removeAll()
            prefetcherWaiters.removeAll()
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
        // 进入时所属世代：被 bargeIn（cancelPendingPlayback 递增世代）唤醒后据此判定本 writer
        // 已作废，直接退出、绝不碰 node/prime，避免新旧管道两个 writer 争用同一播放节点。
        // 只在 serialQueue 上读写 generation，避免跨线程数据竞争。
        let enterGen: Int = serialQueue.sync { generation }

        // 背压：已排队音频太多就等设备先消费，避免无限占内存、同时构成合成预取上限。
        // 每个 writer 独立挂到等待者数组，杜绝单槽覆盖导致的 continuation 泄漏。
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                serialQueue.async {
                    if self.pendingFrames <= self.highWaterFrames {
                        continuation.resume()
                    } else {
                        self.backpressureWaiters.append(continuation)
                    }
                }
            }
        } onCancel: {
            serialQueue.async {
                // 取消时唤醒全部等待者：旧世代者靠下面的世代校验退出，同世代者至多超写
                // 一块（高水位 4s，仅内存余量），下一次 write 重新背压，自我修正。
                let ws = self.backpressureWaiters
                self.backpressureWaiters.removeAll()
                ws.forEach { $0.resume() }
            }
        }

        // 等待期间已被打断（世代推进）：旧管道 writer 到此为止，不再排队/prime。
        serialQueue.sync {
            guard self.generation == enterGen else { return }
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

    /// 已排队未被设备消费的帧数（合成侧预取门控只读，在 serialQueue 上取一致快照）。
    var queuedFrames: Int { serialQueue.sync { pendingFrames } }

    /// 合成预取门控：排队音频超高水位则挂起，等设备消费到低水位放行；取消时由
    /// cancelPendingPlayback/stop 恢复，调用方靠 Task.checkCancellation 退出。
    func awaitPrefetchCapacity() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                serialQueue.async {
                    if self.pendingFrames <= self.highWaterFrames {
                        continuation.resume()
                    } else {
                        self.prefetcherWaiters.append(continuation)
                    }
                }
            }
        } onCancel: {
            serialQueue.async {
                let ws = self.prefetcherWaiters
                self.prefetcherWaiters.removeAll()
                ws.forEach { $0.resume() }
            }
        }
    }

    /// 一块 buffer 被设备消费：更新计数，按需恢复背压等待 / drain 等待。必须在 serialQueue 内。
    private func onConsumed(frames: Int) {
        pendingCount -= 1
        pendingFrames = max(0, pendingFrames - frames)
        if pendingFrames <= lowWaterFrames, !backpressureWaiters.isEmpty {
            let ws = backpressureWaiters
            backpressureWaiters.removeAll()
            ws.forEach { $0.resume() }
        }
        // 预取门控：合成比实时快时应尽量跑在前面攒垫，只在超 4s 上限时短暂停，
        // 回落到高水位即放行（保持厚垫），绝不等低水位——否则下一句合成期间会欠载断句。
        if pendingFrames <= highWaterFrames, !prefetcherWaiters.isEmpty {
            let ws = prefetcherWaiters
            prefetcherWaiters.removeAll()
            ws.forEach { $0.resume() }
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
            // 恢复可能卡在背压/预取门控上的生产者，让它靠 Task 取消退出（世代校验拦住旧 writer）
            backpressureWaiters.forEach { $0.resume() }
            backpressureWaiters.removeAll()
            prefetcherWaiters.forEach { $0.resume() }
            prefetcherWaiters.removeAll()
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
            backpressureWaiters.forEach { $0.resume() }
            prefetcherWaiters.forEach { $0.resume() }
            drainedContinuation = nil
            backpressureWaiters.removeAll()
            prefetcherWaiters.removeAll()
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
