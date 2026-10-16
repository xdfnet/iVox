@preconcurrency import Cocoa
import Foundation
import AVFoundation
import iVoxKit

// 语音输入：右 ⌘ / 右 ⌃ 录音 → ASR → 粘贴。

/// 语音输入：按住右 ⌘ / 右 ⌃ 录音 → ASR → 粘贴到光标处。
/// 键盘事件由 `HotKey/GlobalKeyTap` 送来（本服务不再自建 CGEvent tap）。
final class SpeechInputService: @unchecked Sendable {
    private let config: SpeechInputConfig
    private let media: MediaController
    private let queue: PlaybackQueue
    private let recordDir: URL
    private let asrEngine: ASREngine
    /// 键盘事件层（由 Daemon 注入）：右⌘/右⌃ 的状态变化由它路由进来。
    /// tap 不由本服务持有——它要同时给热键路由用，见 `HotKey/GlobalKeyTap.swift`。
    private let keyTap: GlobalKeyTap

    private enum State {
        case idle
        case recording(recorder: AVAudioRecorder, audioURL: URL)
    }
    private var state: State = .idle
    private let stateQueue = DispatchQueue(label: "com.user.ivox.speechinput.state")
    private let overlay = OverlayPanel()
    private var levelTask: Task<Void, Never>?

    init(config: SpeechInputConfig, mediaController: MediaController, playbackQueue: PlaybackQueue, asrEngine: ASREngine, keyTap: GlobalKeyTap) {
        self.config = config
        self.media = mediaController
        self.queue = playbackQueue
        self.asrEngine = asrEngine
        self.keyTap = keyTap
        self.recordDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ivox/recordings")
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    func start() {
        guard config.enabled else {
            Log.info("语音输入已禁用")
            return
        }
        keyTap.onModifier = { [weak self] _, isDown in
            self?.handleModifierKey(isDown: isDown)
        }
        // 首次启动异步触发麦克风授权框，不阻塞事件线程；授权与否键盘监听都常驻
        Task { _ = checkMicPermission() }
    }

    func stop() {
        stateQueue.sync {
            levelTask?.cancel()
            levelTask = nil
        }
        Task { @MainActor in overlay.dismiss() }
    }

    /// 键盘监听是否真正在运行；等待权限时为 false
    var isMonitoring: Bool { keyTap.isMonitoring }

    // MARK: - Key handling

    private func handleModifierKey(isDown: Bool) {
        if isDown {
            // 按下 right ⌘/⌃：检查状态，只有 idle 才能开始录音
            let shouldStart: Bool = stateQueue.sync {
                if case .idle = state { return true } else { return false }
            }
            guard shouldStart else { return }
            // 麦克风仅录音时才需要；未授权只提示，不影响键盘监听
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                Log.warn("语音输入: 麦克风未授权，跳过录音（键盘控制不受影响）")
                showOverlayThenDismiss(.error("麦克风未授权"), after: 1.5)
                return
            }

            Log.debug("语音输入: right ⌘/⌃ 按下 → 暂停音乐 → 取消 TTS → 开始录音")
            // cancelAll 只管打断、不碰音乐；这里串行 cancelAll → pause，确保先打断、后暂停，
            // 音乐稳稳停在暂停态（松开后 resumeIfIdle 才恢复）。不写成两个独立 Task 并发，
            // 免得音乐暂停与打断谁先谁后不定。
            Task {
                await queue.cancelAll(origin: .speech)
                await media.pause()
            }

            // 建目录 + 建 AVAudioRecorder 是同步 IO，而这里跑在 GlobalKeyTap 的事件线程上
            // （它监听的是**全系统**键盘）——必须挪出去，否则按键瞬间整机输入都会卡顿。
            Task { self.beginRecording() }
        } else {
            // 松开 right ⌘/⌃：检查状态，只有 recording 才能结束
            let job = stateQueue.sync { () -> (AVAudioRecorder, URL)? in
                guard case .recording(let recorder, let audioURL) = state else { return nil }
                state = .idle
                return (recorder, audioURL)
            }
            guard let (recorder, audioURL) = job else { return }

            stopLevelMetering()
            Log.debug("语音输入: right ⌘/⌃ 松开 → 结束录音")
            playCue("Pop")   // 「收工」：录音已停，接下来是识别（浮窗会转"识别中…"）
            Task {
                await queue.resumeIfIdle()
                self.finishRecording(recorder: recorder, audioURL: audioURL)
            }
        }
    }

    // MARK: - Recording

    /// 在后台真正开始录音（从事件线程 offload 出来）。挂起期间状态可能已变，再确认一次。
    private func beginRecording() {
        let canStart: Bool = stateQueue.sync {
            if case .idle = state { return true } else { return false }
        }
        guard canStart, let (recorder, url) = startRecording() else { return }
        stateQueue.sync { state = .recording(recorder: recorder, audioURL: url) }
        showOverlay(.listening)
        // 「可以说了」——**录音确实起来之后**才响（此刻说才录得到）。
        // 取舍：它会紧接着被麦克风拾到一点点，但 Tink 极短、ASR 不会把音效转成文字；
        // 反过来"先等音效响完再开录"会丢掉你开头的字，不划算。
        playCue("Tink")
        startLevelMetering()
    }

    private func startRecording() -> (AVAudioRecorder, URL)? {
        try? FileManager.default.createDirectory(at: recordDir, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "MMdd-HHmmss"
        let url = recordDir.appendingPathComponent("\(fmt.string(from: Date())).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        guard let recorder = try? AVAudioRecorder(url: url, settings: settings) else {
            Log.error("语音输入: 录音器创建失败")
            return nil
        }
        recorder.isMeteringEnabled = true
        guard recorder.record(forDuration: config.maxRecordingSeconds) else {
            Log.error("语音输入: 录音启动失败")
            return nil
        }
        return (recorder, url)
    }

    private func finishRecording(recorder: AVAudioRecorder, audioURL: URL) {
        recorder.stop()

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: audioURL.path),
              let size = attrs[.size] as? Int, size > 1024 else {
            Log.debug("语音输入: 录音太短，已忽略")
            dismissOverlay()
            return
        }

        let wavData: Data
        do { wavData = try Data(contentsOf: audioURL) }
        catch { dismissOverlay(); return }

        Log.info("语音输入: ASR 请求 \(audioURL.lastPathComponent) \(wavData.count) bytes")
        showOverlay(.transcribing)
        Task {
            defer { Self.cleanupRecordings(recordDir: self.recordDir) }
            do {
                let text = try await asrEngine.transcribe(audioData: wavData, language: config.language)
                guard !text.isEmpty else {
                    Log.info("语音输入: 识别结果为空")
                    showOverlayThenDismiss(.error("结果为空"), after: 1.5)
                    return
                }
                Log.info("语音输入: 识别结果 [\(text.prefix(60))]")
                pasteText(text)
                showOverlayThenDismiss(.done, after: 0.6)
            } catch {
                Log.error("语音输入: ASR 失败 \(error)")
                showOverlayThenDismiss(.error("识别失败"), after: 1.5)
            }
        }
    }

    // MARK: - Overlay

    private func showOverlay(_ state: OverlayState) {
        Task { @MainActor in overlay.show(state: state) }
    }

    private func showOverlayThenDismiss(_ state: OverlayState, after seconds: TimeInterval) {
        Task { @MainActor in
            overlay.show(state: state)
            try? await Task.sleep(for: .seconds(seconds))
            overlay.dismiss()
        }
    }

    private func dismissOverlay() {
        Task { @MainActor in overlay.dismiss() }
    }

    /// 开始 / 结束录音的提示音（"可以说了" / "收工"）——用系统音效，不自带资源。
    /// 为什么不能只靠浮窗：按快捷键时眼睛往往不在屏幕下方，**声音才是即时的反馈**。
    /// NSSound 在主线程播放更稳（本服务不是 MainActor），故 hop 过去。
    private func playCue(_ name: String) {
        Task { @MainActor in NSSound(named: NSSound.Name(name))?.play() }
    }

    private func startLevelMetering() {
        let task = Task { @MainActor in
            while !Task.isCancelled {
                let recorder: AVAudioRecorder? = stateQueue.sync {
                    guard case .recording(let recorder, _) = state else { return nil }
                    return recorder
                }
                guard let recorder else { return }
                recorder.updateMeters()
                let db = recorder.averagePower(forChannel: 0)
                overlay.updateAudioLevel(pow(10, db / 20))
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        stateQueue.sync { levelTask = task }
    }

    private func stopLevelMetering() {
        stateQueue.sync {
            levelTask?.cancel()
            levelTask = nil
        }
    }

    // MARK: - Cleanup

    private static let maxRecordings = 2

    private static func cleanupRecordings(recordDir: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: recordDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let wavs = files.filter { $0.pathExtension == "wav" }
            .compactMap { url -> (URL, Date)? in
                guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }
        if wavs.count <= maxRecordings { return }
        for (url, _) in wavs.dropFirst(maxRecordings) {
            try? fm.removeItem(at: url)
        }
    }

    // MARK: - Paste

    private func pasteText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        let source = CGEventSource(stateID: .combinedSessionState)
        guard let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            Log.error("语音输入: 模拟 ⌘V 事件创建失败")
            return
        }
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        // 等待剪贴板就绪，不阻塞事件回调线程
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            vDown.post(tap: .cgAnnotatedSessionEventTap)
            vUp.post(tap: .cgAnnotatedSessionEventTap)

            if self.config.autoEnter {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                    guard let enterDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true),
                          let enterUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false) else {
                        Log.error("语音输入: 模拟回车事件创建失败")
                        return
                    }
                    enterDown.post(tap: .cgAnnotatedSessionEventTap)
                    enterUp.post(tap: .cgAnnotatedSessionEventTap)
                }
            }
        }
    }

    // MARK: - Media

    // MARK: - Permissions

    /// 检查麦克风权限，notDetermined 时阻塞等待用户选择
    private func checkMicPermission() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            Log.debug("语音输入: 麦克风已授权")
            return true
        case .restricted:
            Log.error("语音输入: 麦克风受限，当前设备不支持")
            return false
        case .denied:
            Log.error("语音输入: 麦克风未授权，请前往 系统设置 → 隐私与安全性 → 麦克风 启用")
            return false
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            final class PermissionBox: @unchecked Sendable { var value = false }
            let box = PermissionBox()
            AVCaptureDevice.requestAccess(for: .audio) { g in
                box.value = g
                semaphore.signal()
            }
            semaphore.wait()
            let granted = box.value
            if granted {
                Log.info("语音输入: 麦克风已授权")
                return true
            }
            Log.error("语音输入: 麦克风未授权，请前往 系统设置 → 隐私与安全性 → 麦克风 启用")
            return false
        @unknown default:
            return false
        }
    }

}
