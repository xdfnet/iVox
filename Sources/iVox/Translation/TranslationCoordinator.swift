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

    /// 热键分派入口（由 `GlobalKeyTap` 触发）。
    func handle(hotKey: GlobalKeyTap.HotKey, at location: CGPoint) async {
        switch hotKey {
        case .translate:
            await translateSelection(mouseLocation: location)
        case .openTerminal, .openTerminalClaude, .openTerminalQwen, .openTerminalCodex, .copyPath:
            Log.debug("Finder 热键尚未接入: \(hotKey)")
        }
    }

    /// 翻译当前选中文本：浮窗显示译文，按配置决定是否朗读。
    func translateSelection(mouseLocation: CGPoint) async {
        guard translateConfig.enabled, !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        Log.info("划词翻译: 触发")

        let raw = await ClipboardReader.copyAndRead()
        guard let raw, let text = validateSelectionText(raw) else {
            Log.info("划词翻译: 没有取到可用文本（读到 \(raw.map { "\($0.count) 字" } ?? "nil")）")
            panel.show(text: "没有取到选中文本", near: mouseLocation, timeoutSeconds: 3)
            return
        }
        Log.info("划词翻译: 取到 \(text.count) 字，开始翻译")

        switch await service.translate(text) {
        case .success(let translated):
            Log.info("划词翻译: 完成 → \(translated.prefix(40))")
            panel.show(text: translated, near: mouseLocation,
                       timeoutSeconds: translateConfig.panelTimeoutSeconds)
            if translateConfig.speechEnabled {
                await speak(translated)
            }
        case .failed(_, let error):
            Log.warn("划词翻译: 失败 \(error)")
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
