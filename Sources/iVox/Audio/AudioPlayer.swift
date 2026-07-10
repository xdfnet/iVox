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
    private var config: PlaybackConfig
    private var drainedContinuation: CheckedContinuation<Void, Never>?

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

        // 主动监听：休眠唤醒 / 设备变更
        observeSystemEvents()
    }

    func write(_ pcm: Data) {
        guard started, !pcm.isEmpty else { return }
        let frames = AVAudioFrameCount(pcm.count / 2)
        serialQueue.sync {
            // engine 挂了就在这里复活一次，不设冷却期
            if !engine.isRunning {
                Log.debug("AudioEngine 已停止，尝试重启")
                restartEngine()
            } else if !node.isPlaying {
                node.play()
            }
            guard engine.isRunning else { return }
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

    func prepareForPlayback() {
        serialQueue.sync {
            // 播报开始前确保 engine 在线，由 write() 的检查兜底，这里只做一次确认
            if started, !engine.isRunning {
                Log.info("prepareForPlayback: engine 已停止，尝试重启")
                restartEngine()
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

    // MARK: - 内部

    /// 通用重启：stop → start → play，失败直接记录（上层 drain 超时会兜底）
    private func restartEngine() {
        node.stop()
        engine.stop()
        pendingCount = 0

        do {
            try engine.start()
            node.play()
            Log.info("AudioEngine 重启成功")
        } catch {
            Log.error("AudioEngine 重启失败: \(error)")
        }
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
                player.serialQueue.sync {
                    if !player.engine.isRunning {
                        Log.info("系统唤醒，尝试重启 AudioEngine")
                        player.restartEngine()
                    } else if !player.node.isPlaying {
                        player.node.play()
                    }
                }
            }
        }

        // 耳机插拔 / 采样率变化 → 重启 engine
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { _ in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                player.serialQueue.sync {
                    Log.info("音频配置变更，重启 AudioEngine")
                    player.restartEngine()
                }
            }
        }
    }
}
