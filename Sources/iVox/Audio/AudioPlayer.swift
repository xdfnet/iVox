// @unchecked Sendable: AVAudioEngine 需要在实时音频线程操作，不能使用 actor。
// 所有可变状态通过 serialQueue 串行化，线程安全由手工保证。
import AVFoundation
import AppKit
import Foundation
import iVoxKit

final class AudioPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let serialQueue = DispatchQueue(label: "ivox.audio")
    private var pendingCount = 0
    private var started = false
    private var lastActivity = Date()
    private var needsEngineRevive = false
    private var lastReviveFailure: Date?
    private let reviveCooldown: TimeInterval = 30
    private let config: PlaybackConfig

    init(config: PlaybackConfig) {
        self.config = config
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

        // 主动监听：休眠唤醒 / 耳机插拔 / 设备变更
        observeSystemEvents()
    }

    func write(_ pcm: Data) {
        guard started, !pcm.isEmpty else { return }
        let frames = AVAudioFrameCount(pcm.count / 2)
        serialQueue.sync {
            reviveIfNeeded()
            lastActivity = Date()
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
                self.serialQueue.async { self.pendingCount -= 1 }
            }
        }
    }

    func prepareForPlayback() {
        serialQueue.sync {
            // 引擎永久失败后定期重试
            if !started, let lastFail = lastReviveFailure,
               Date().timeIntervalSince(lastFail) > reviveCooldown {
                Log.info("引擎上次异常退出已超过 \(Int(reviveCooldown))s 冷却期，尝试重初始化")
                if reinitializeEngine() {
                    started = true
                    lastReviveFailure = nil
                }
            }
            reviveIfNeeded()
            if needsEngineRevive {
                Log.info("音频配置已变更，播报前重启引擎")
                reviveEngine()
            } else if Date().timeIntervalSince(lastActivity) > config.idleReviveSeconds {
                // 长时间空闲后引擎可能静默挂掉（isRunning=true 但不工作），播报前复活，避免写入首段音频时重启。
                Log.info("空闲超过 \(Int(config.idleReviveSeconds)) 秒，播报前主动复活引擎")
                reviveEngine()
            }
        }
    }

    func drain(chunks: Int) async {
        let baseTimeout = Int(config.drainBaseTimeoutSeconds.rounded(.up))
        let maxWait = max(baseTimeout, Int(Double(chunks) * 0.08) + baseTimeout)
        let polls = maxWait * 20
        var drained = false
        for _ in 0..<polls {
            let done = serialQueue.sync { pendingCount == 0 }
            if done { drained = true; break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if !drained {
            Log.error("播放超时 (\(chunks) 块未完成)，AudioEngine 可能已挂，重启")
            serialQueue.sync {
                pendingCount = 0
                reviveEngine()
            }
        }
    }

    func cancelPendingPlayback() {
        serialQueue.sync {
            pendingCount = 0
            node.stop()
            if engine.isRunning {
                node.play()
            }
            lastActivity = Date()
        }
    }

    func stop() {
        serialQueue.sync {
            started = false
            node.stop()
            engine.stop()
        }
    }

    // MARK: - 内部

    private func reviveIfNeeded() {
        if !engine.isRunning {
            Log.info("AudioEngine 已停止，自动重启")
            reviveEngine()
        } else if !node.isPlaying {
            Log.info("AudioPlayerNode 已停止，自动恢复播放")
            node.play()
        }
    }

    /// 全量重初始化：重新创建并启动 engine（attach/connect/start），用于永久失败后的冷却重试
    private func reinitializeEngine() -> Bool {
        node.stop()
        engine.stop()
        pendingCount = 0

        // 断开所有旧连接
        engine.disconnectNodeOutput(node)
        engine.disconnectNodeInput(engine.mainMixerNode)

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()

        for attempt in 1...3 {
            do {
                try engine.start()
                node.play()
                needsEngineRevive = false
                Log.info("AudioEngine 重初始化成功 (第 \(attempt)/3 次)")
                return true
            } catch {
                Log.error("AudioEngine 重初始化失败 (第 \(attempt)/3 次): \(error)")
                if attempt < 3 {
                    Thread.sleep(forTimeInterval: 1.0)
                }
            }
        }
        return false
    }

    /// 重启引擎：stop → start → play，重试 3 次，间隔 1s
    private func reviveEngine() {
        node.stop()
        engine.stop()
        pendingCount = 0

        for attempt in 1...3 {
            do {
                try engine.start()
                node.play()
                needsEngineRevive = false
                Log.info("AudioEngine 重启成功 (第 \(attempt)/3 次)")
                return
            } catch {
                Log.error("AudioEngine 重启失败 (第 \(attempt)/3 次): \(error)")
                if attempt < 3 {
                    Thread.sleep(forTimeInterval: 1.0)
                }
            }
        }
        lastReviveFailure = Date()
        Log.error("AudioEngine 重启最终失败，\(Int(reviveCooldown))s 冷却期后将重试")
    }

    // MARK: - 系统事件

    private func observeSystemEvents() {
        let player = self

        // 休眠唤醒 → 延迟 1s 等硬件初始化，然后检查+重启
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { _ in
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                player.serialQueue.sync { player.reviveIfNeeded() }
            }
        }

        // 耳机插拔 / 设备变更 / 采样率变化
        // Apple 文档：延迟+异步，否则死锁。注意此通知有时不触发，被动检测仍是主防线
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { _ in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                player.serialQueue.sync {
                    Log.info("音频配置变更，标记下次播报前重启引擎")
                    player.needsEngineRevive = true
                }
            }
        }
    }
}
