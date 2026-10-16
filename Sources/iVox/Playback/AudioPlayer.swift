import AVFoundation
import Foundation
import iVoxKit

// 音频播放：常驻 AVAudioEngine + 连续 scheduleBuffer。

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
    private var lastConsumedAt = DispatchTime.now()   // 上次设备消费回调时刻（断流看门狗用）
    private var started = false
    private var drainedContinuation: CheckedContinuation<Void, Never>?
    private var drainSeq: UInt = 0         // drain 序号：让超时兜底只对自己的那次 drain 生效
    private var drainTailSec: Double = 0   // 本次 drain 入口的快照尾音秒数（正常排空时打日志）
    /// 背压等待者：每个挂起的 writer 独立槽。密集打断时新旧管道的 writer 可能短暂同时
    /// 在场，用数组而非单槽——单槽会被后到者覆盖，先到者的 continuation 永不 resume（泄漏）。
    private var backpressureWaiters: [CheckedContinuation<Void, Never>] = []
    /// 合成预取门控：排队音频超高水位时挂起「下一句合成」，降到高水位放行，
    /// 让合成领先播放一两句即可，不无限预取。与 write 的背压分离（两级流水线）。
    /// 同样用等待者数组，避免多 producer 极端时序下互相覆盖泄漏。
    private var prefetcherWaiters: [CheckedContinuation<Void, Never>] = []
    private static let drainSlack: TimeInterval = 2.0   // drain 超时余量（秒）
    /// 设备断流判定门槛（秒）：有排队音频却这么久无任何消费回调 = 设备已死（正常消费是连续的）
    private static let stallGrace: TimeInterval = 10
    /// 「某句开始被设备消费」回调（字幕用）：句首块被读出时触发——**比从合成侧取准得多**
    /// （合成领先播放一两句，字幕会早到）。由 PlaybackQueue 在 init 时一次性注入，之后只读。
    var onSentenceStarted: (@Sendable (String) -> Void)?
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
        scheduleStallWatchdog()
    }

    /// 写入一块 PCM。排队音频超高水位时挂起，等设备消费到低水位再返回（背压）。
    /// 被取消时由 cancelPendingPlayback 恢复挂起，调用方靠 Task.checkCancellation 退出。
    /// - Parameter startsSentence: 非 nil 表示这是**某句的第一块**，值是这句的文本；
    ///   该块被设备读出（≈ 这句开始响）时回调 `onSentenceStarted`，让字幕跟声音对齐。
    func write(_ pcm: Data, startsSentence: String? = nil) async {
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

            // 前导静音：唤醒被系统音频电源管理挂起的 player node，避免首个 audio chunk 被跳过。
            // 连续排队时 pendingCount 句间不归零，这里整轮只会触发一次。
            // 长时间空闲（实测十几分钟）后 50ms 太短、首句开头仍会被吞，故用 200ms，并在排
            // 缓冲前显式 node.play()（幂等，playing 中调用无副作用）确保节点真正进入渲染。
            if needsPrime {
                let primeFrames = AVAudioFrameCount(format.sampleRate / 5)  // 200ms 静音
                guard let primeBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: primeFrames) else {
                    Log.warn("前导静音 buffer 分配失败，跳过唤醒")
                    return
                }
                primeBuf.frameLength = primeFrames
                if let dst = primeBuf.int16ChannelData?.pointee {
                    dst.initialize(repeating: 0, count: Int(primeFrames))
                }
                node.play()
                waitForNodePlaying()
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
                Log.debug("前导静音已调度唤醒 player node (200ms)")
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
                    // 句首块被读出 ≈ 这句开始响：此刻才报字幕。世代校验已过，被掐掉的旧句不会误报
                    if let text = startsSentence { self.onSentenceStarted?(text) }
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
        lastConsumedAt = .now()   // 设备在消费（活性看门狗据此判定断流）
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
                Log.info(String(format: "播放收尾完成: 尾音=%.2fs", drainTailSec))
                cont.resume()
            }
        }
    }

    /// 等所有已排队音频播完（只在整条管道末端调用一次，不再逐句调用）。
    func drain() async throws {
        // 入口快照尾部排队 PCM 秒数：正常收尾时打点（供黑盒播报自检断言尾音没被提前掐掉）。
        let tailAtEntry = serialQueue.sync { () -> (DispatchTime, Double) in
            let ms = Int((Double(pendingFrames) / format.sampleRate + Self.drainSlack) * 1000)
            let tailSec = Double(pendingFrames) / format.sampleRate
            return (DispatchTime.now() + .milliseconds(ms), tailSec)
        }
        let deadline = tailAtEntry.0
        let tailSecAtEntry = tailAtEntry.1
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let pending = serialQueue.sync { () -> UInt? in
                if pendingCount == 0 { return nil }
                drainSeq &+= 1
                drainedContinuation = continuation
                drainTailSec = tailSecAtEntry   // 供 onConsumed 正常排空时打点
                return drainSeq
            }
            guard let mySeq = pending else {
                Log.info(String(format: "播放收尾完成: 尾音=%.2fs", tailSecAtEntry))
                continuation.resume()
                return
            }
            // buffer 播放回调丢失（如 AudioEngine 被系统事件停止）时兜底，避免管道永久阻塞。
            // 只对自己的那次 drain 生效：上一次 drain 遗留的计时器不得误放行本次（序号校验）。
            serialQueue.asyncAfter(deadline: deadline) { [weak self] in
                guard let self, self.drainSeq == mySeq, let cont = self.drainedContinuation else { return }
                self.drainedContinuation = nil
                Log.warn("drain 超时强制返回（pendingCount=\(self.pendingCount) 尾音=\(String(format: "%.2f", tailSecAtEntry))s）")
                cont.resume()
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

        guard rebuildEngine() else { return false }
        Log.info("AudioEngine 重建成功")
        return true
    }

    /// 重建引擎与播放节点（系统音频事件 / 设备断流后重新激活设备用）。必须在 serialQueue 内调用。
    /// 注意 `node.stop()` 会丢弃已排队的 buffer——调用方须同步清掉这些 buffer 的计数。
    private func rebuildEngine() -> Bool {
        node.stop()
        engine.stop()
        engine.reset()

        do {
            try engine.start()
            node.play()
            waitForNodePlaying()
            return true
        } catch {
            Log.error("AudioEngine 重建失败: \(error)")
            started = false
            return false
        }
    }

    /// 起设备活性看门狗（串行队列上 1s 一跳自续，stop() 后停跳）。
    private func scheduleStallWatchdog() {
        serialQueue.asyncAfter(deadline: .now() + .seconds(1)) { [weak self] in
            guard let self, self.started else { return }
            self.recoverIfDeviceStalled()
            self.scheduleStallWatchdog()
        }
    }

    /// 设备停止消费兜底。蓝牙音箱断流 / 设备被系统挂起时 CoreAudio 不再回调 `dataConsumed`——
    /// 而背压等待**只能**由 `onConsumed` 唤醒、`ensureHealthy` 又只在「进入等待之前」检查，
    /// 于是 writer 永久挂起：整条管道卡死（/health 恒 playing=true），此后所有播报一律哑掉，
    /// 只能靠一次打断解救（实测蓝牙输出下必现，日志里只有「前导静音已调度」再无下文）。
    /// 判定：有排队音频却连续 `stallGrace` 秒毫无消费回调 = 设备已断流。处置：重建引擎重新激活
    /// 设备、按「已丢」清掉排队 buffer 的计数（这些音频本就无声，`rebuildEngine` 也已把它们丢出
    /// 节点）、唤醒全部等待者，让管道继续灌后续 PCM 或收尾退出。必须在 serialQueue 内调用。
    private func recoverIfDeviceStalled() {
        guard pendingCount > 0 else {
            lastConsumedAt = .now()
            return
        }
        guard DispatchTime.now() >= lastConsumedAt + .seconds(Int(Self.stallGrace)) else { return }

        Log.warn("音频设备 \(Int(Self.stallGrace))s 无消费回调（蓝牙断流/设备挂起？），重建引擎并丢弃排队音频: pending=\(pendingCount) frames=\(pendingFrames)")
        _ = rebuildEngine()
        pendingCount = 0
        pendingFrames = 0
        needsPrime = true
        lastConsumedAt = .now()
        backpressureWaiters.forEach { $0.resume() }
        backpressureWaiters.removeAll()
        prefetcherWaiters.forEach { $0.resume() }
        prefetcherWaiters.removeAll()
    }

    /// 等待 player node 真正进入播放状态，最多 50ms。必须在 serialQueue 内调用。
    private func waitForNodePlaying(timeoutMs: Int = 50) {
        let deadline = DispatchTime.now() + .milliseconds(timeoutMs)
        while !node.isPlaying && DispatchTime.now() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
    }
}
