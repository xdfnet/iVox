import AppKit
import CoreGraphics
import Foundation
import iVoxKit

/// 划词翻译的编排者：把「模拟 Cmd+C → 读剪贴板 → 翻译 → 浮窗 + 朗读」串起来。
///
/// 两个入口：
/// - `translateSelection(mouseLocation:)` —— 热键（Cmd+D）与 `ivox translate --selection` 走这条
/// - `dismiss()` —— 关掉浮窗
@MainActor
final class TranslationCoordinator {
    private let appConfig: Config
    private let translateConfig: TranslationConfig
    private let service: TranslationService
    private let queue: PlaybackQueue
    private let panel = TranslationPanel()
    /// 连按 Cmd+D 只认第一次，避免堆积出一串重复请求
    private var inFlight = false

    init(config: Config, queue: PlaybackQueue) {
        self.appConfig = config
        self.translateConfig = config.resolvedTranslation
        self.service = TranslationService(config: translateConfig)
        self.queue = queue
    }

    var isEnabled: Bool { translateConfig.enabled }

    /// 翻译当前选中文本：浮窗显示译文，按配置决定是否朗读。
    func translateSelection(mouseLocation: CGPoint) async {
        guard translateConfig.enabled, !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        guard let raw = await ClipboardReader.copyAndRead(),
              let text = validateSelectionText(raw) else {
            panel.show(text: "没有取到选中文本", near: mouseLocation, timeoutSeconds: 3)
            return
        }

        switch await service.translate(text) {
        case .success(let translated):
            panel.show(text: translated, near: mouseLocation,
                       timeoutSeconds: translateConfig.panelTimeoutSeconds)
            if translateConfig.speechEnabled {
                await speak(translated)
            }
        case .failed(_, let error):
            panel.show(text: error, near: mouseLocation,
                       timeoutSeconds: translateConfig.panelTimeoutSeconds)
        }
    }

    func dismiss() {
        panel.dismiss()
    }

    // MARK: - 内部

    /// 朗读译文。走 `speakUserInitiated`（用户开口 → 打断在播），不是 hook 那条排队路径。
    private func speak(_ text: String) async {
        let cleaned = cleanText(text)
        guard !cleaned.isEmpty else { return }
        let voiceID = translateConfig.speechVoice ?? appConfig.defaultVoice
        let jobs = splitSentences(cleaned).map {
            PlaybackJob(text: $0, voiceID: voiceID, source: "dict")
        }
        await queue.speakUserInitiated(jobs)
    }
}
