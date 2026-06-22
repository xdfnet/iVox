@preconcurrency import Cocoa
import Foundation
import AVFoundation
import iVoxKit

final class SpeechInputService: @unchecked Sendable {
    private let config: SpeechInputConfig
    private let media: MediaController
    private let recordDir: URL
    private var thread: Thread?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let asrEngine: ASREngine

    private enum State {
        case idle
        case recording(recorder: AVAudioRecorder, audioURL: URL)
    }
    private var state: State = .idle
    private let stateQueue = DispatchQueue(label: "com.user.ivox.speechinput.state")

    init(config: SpeechInputConfig, mediaController: MediaController, asrEngine: ASREngine) {
        self.config = config
        self.media = mediaController
        self.asrEngine = asrEngine
        self.recordDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ivox/recordings")
    }

    // MARK: - Lifecycle

    func start() {
        guard config.enabled else {
            Log.info("语音输入已禁用")
            return
        }
        let t = Thread { [weak self] in
            self?.run()
        }
        t.name = "com.user.ivox.speechinput"
        t.start()
        thread = t
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        eventTap = nil
        runLoopSource = nil
        thread?.cancel()
        thread = nil
    }

    // MARK: - Event loop

    private func run() {
        // 检查两类权限
        let hasMic = checkMicPermission()
        let hasAccessibility: Bool
        if let tap = createEventTap() {
            eventTap = tap
            hasAccessibility = true
        } else {
            hasAccessibility = checkAccessibilityPermission()
        }

        // 缺权限则轮询等待，到手后自动重启
        let needMic = !hasMic
        let needAccessibility = !hasAccessibility
        if needMic || needAccessibility {
            if let tap = eventTap { CFMachPortInvalidate(tap); eventTap = nil }
            waitForPermissions(needMic: needMic, needAccessibility: needAccessibility)
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap!, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        Log.info("语音输入已启动 (⌘→说话→松开→粘贴)")

        CFRunLoopRun()
    }

    // MARK: - Event tap

    private func createEventTap() -> CFMachPort? {
        let mask = 1 << CGEventType.flagsChanged.rawValue

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }
            guard event.getIntegerValueField(.keyboardEventKeycode) == 0x36 else {
                return Unmanaged.passUnretained(event)
            }

            let isDown = event.flags.contains(.maskCommand)
            let service = Unmanaged<SpeechInputService>.fromOpaque(refcon!).takeUnretainedValue()
            service.handleKey(isDown: isDown)

            return Unmanaged.passUnretained(event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        return CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: CGEventTapOptions(rawValue: 0)!,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: selfPtr
        )
    }

    // MARK: - Key handling

    private func handleKey(isDown: Bool) {
        if isDown {
            // 按下 ⌘：检查状态，只有 idle 才能开始录音
            let shouldStart: Bool = stateQueue.sync {
                if case .idle = state { return true } else { return false }
            }
            guard shouldStart else { return }

            Task { await media.pause() }
            Log.debug("语音输入: ⌘ 按下 → 暂停音乐 → 开始录音")

            guard let (recorder, url) = startRecording() else { return }
            stateQueue.sync { state = .recording(recorder: recorder, audioURL: url) }
        } else {
            // 松开 ⌘：检查状态，只有 recording 才能结束
            let job = stateQueue.sync { () -> (AVAudioRecorder, URL)? in
                guard case .recording(let recorder, let audioURL) = state else { return nil }
                state = .idle
                return (recorder, audioURL)
            }
            guard let (recorder, audioURL) = job else { return }

            Log.debug("语音输入: ⌘ 松开 → 结束录音")
            Task { await media.resume() }
            DispatchQueue.global().async {
                self.finishRecording(recorder: recorder, audioURL: audioURL)
            }
        }
    }

    // MARK: - Recording

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
            return
        }

        let wavData: Data
        do { wavData = try Data(contentsOf: audioURL) }
        catch { return }

        Log.info("语音输入: ASR 请求 \(audioURL.lastPathComponent) \(wavData.count) bytes")
        Task {
            defer { Self.cleanupRecordings(recordDir: self.recordDir) }
            do {
                let text = try await asrEngine.transcribe(audioData: wavData, language: config.language)
                guard !text.isEmpty else {
                    Log.info("语音输入: 识别结果为空")
                    return
                }
                Log.info("语音输入: 识别结果 [\(text.prefix(60))]")
                pasteText(text)
            } catch {
                Log.error("语音输入: ASR 失败 \(error)")
            }
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
        Thread.sleep(forTimeInterval: 0.15)

        let source = CGEventSource(stateID: .combinedSessionState)
        guard let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            Log.error("语音输入: 模拟 ⌘V 事件创建失败")
            return
        }
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        vDown.post(tap: .cgAnnotatedSessionEventTap)
        vUp.post(tap: .cgAnnotatedSessionEventTap)

        if config.autoEnter {
            Thread.sleep(forTimeInterval: 0.05)
            guard let enterDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true),
                  let enterUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false) else {
                Log.error("语音输入: 模拟回车事件创建失败")
                return
            }
            enterDown.post(tap: .cgAnnotatedSessionEventTap)
            enterUp.post(tap: .cgAnnotatedSessionEventTap)
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
            final class _Box: @unchecked Sendable { var value = false }
            let box = _Box()
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

    /// 检查辅助功能权限，notDetermined 时弹系统对话框
    private func checkAccessibilityPermission() -> Bool {
        let noPrompt = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): false] as CFDictionary
        if AXIsProcessTrustedWithOptions(noPrompt) { return true }
        // 弹一次系统对话框
        let prompt = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(prompt)
        Log.error("语音输入: 缺少辅助功能权限，请前往 系统设置 → 隐私与安全性 → 辅助功能 启用 iVox")
        return false
    }

    /// 轮询等待两类权限就绪，然后自动重启
    private func waitForPermissions(needMic: Bool, needAccessibility: Bool) {
        var needMic = needMic
        var needAccessibility = needAccessibility
        while needMic || needAccessibility {
            Thread.sleep(forTimeInterval: 5)
            if needMic, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                Log.info("语音输入: 麦克风已授权")
                needMic = false
            }
            if needAccessibility {
                let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
                if AXIsProcessTrustedWithOptions(options) {
                    Log.info("语音输入: 辅助功能已授权")
                    needAccessibility = false
                }
            }
        }
        Log.info("语音输入: 权限已就绪，重新启动")
        start()
    }
}
