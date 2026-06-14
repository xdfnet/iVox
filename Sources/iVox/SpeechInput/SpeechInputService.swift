@preconcurrency import Cocoa
import Foundation
import AVFoundation
import iVoxKit

final class SpeechInputService: @unchecked Sendable {
    private let config: SpeechInputConfig
    private let recordDir: URL
    private var thread: Thread?

    private enum State {
        case idle
        case recording(recorder: AVAudioRecorder, audioURL: URL)
    }
    private var state: State = .idle
    private let stateQueue = DispatchQueue(label: "com.user.ivox.speechinput.state")

    init(config: SpeechInputConfig) {
        self.config = config
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
        thread?.cancel()
        thread = nil
    }

    // MARK: - Event loop

    private func run() {
        requestMicPermission()

        guard let tap = createEventTap() else {
            Log.error("语音输入: 需要辅助功能权限")
            waitForAccessibility()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
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
        stateQueue.sync {
            switch state {
            case .idle:
                if isDown {
                    Log.debug("语音输入: ⌘ 按下 → 开始录音")
                    if let (recorder, url) = startRecording() {
                        state = .recording(recorder: recorder, audioURL: url)
                    }
                }
            case .recording(let recorder, let audioURL):
                if !isDown {
                    Log.debug("语音输入: ⌘ 松开 → 结束录音")
                    state = .idle
                    DispatchQueue.global().async {
                        self.finishRecording(recorder: recorder, audioURL: audioURL)
                    }
                }
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

        do {
            let wavData = try Data(contentsOf: audioURL)
            Log.info("语音输入: ASR 请求 \(audioURL.lastPathComponent) \(wavData.count) bytes")

            let text = try ASRClient.transcribe(
                audio: wavData,
                language: config.language,
                baseURL: config.baseURL ?? "tcp://127.0.0.1:8150",
                model: config.model
            )

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

    // MARK: - Paste

    private func pasteText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Thread.sleep(forTimeInterval: 0.15)

        let source = CGEventSource(stateID: .combinedSessionState)
        guard let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else { return }
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        vDown.post(tap: .cgAnnotatedSessionEventTap)
        vUp.post(tap: .cgAnnotatedSessionEventTap)

        if config.autoEnter {
            Thread.sleep(forTimeInterval: 0.05)
            let enterDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true)
            let enterUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false)
            enterDown?.post(tap: .cgAnnotatedSessionEventTap)
            enterUp?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    // MARK: - Permissions

    private func requestMicPermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Log.info("语音输入: 麦克风 \(granted ? "已授权" : "被拒绝")")
            }
        case .denied, .restricted:
            Log.error("语音输入: 麦克风未授权")
        default:
            Log.debug("语音输入: 麦克风已授权")
        }
    }

    private func waitForAccessibility() {
        DispatchQueue.global().async {
            while !Thread.current.isCancelled {
                Thread.sleep(forTimeInterval: 5)
                let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
                if AXIsProcessTrustedWithOptions(options) {
                    DispatchQueue.main.async {
                        Log.info("语音输入: 辅助功能已授权，重新启动")
                        self.start()
                    }
                    return
                }
            }
        }
    }
}
