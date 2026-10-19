import AppKit
import CoreGraphics
import Foundation
import iVoxKit

// 划词翻译的链路编排。

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
    /// 后写胜出的世代号：每次触发 +1，在途的那一代回来发现号变了就作废、别上屏。
    /// 连按 Cmd+D 时**不再丢弃**第二次——用户换了选区就是想再译一次，旧的让位给新的。
    private var generation: UInt = 0

    init(config: Config, queue: PlaybackQueue) {
        self.appConfig = config
        self.translateConfig = config.resolvedTranslation
        self.service = TranslationService(config: translateConfig)
        self.queue = queue
    }

    var isEnabled: Bool { translateConfig.enabled }

    /// 翻译当前选中文本：浮窗显示译文，按配置决定是否朗读。
    ///
    /// **贵的动作押后**：翻译请求是网络往返、是这里唯一一步花钱的事，所以前面铺两道
    /// 便宜的闸——先弹「读取选区…」占位（拿回剪贴板、验证文本），再等一个提交点，
    /// 期间若用户又按了一次（世代推进）或手移开了，就压根不发请求。误触的代价从
    /// 「一次请求 + 一次朗读」降到「一个闪一下的空窗」。
    func translateSelection() async {
        guard translateConfig.enabled else { return }
        generation &+= 1
        let gen = generation
        Log.info("划词翻译: 触发")

        // 乐观占位：先上屏，让「按了有反应」这件事立刻成立
        panel.show(original: "", translated: "读取选区…",
                   timeoutSeconds: translateConfig.panelTimeoutSeconds)
        let raw = await ClipboardReader.copyAndRead()
        guard gen == generation else { return }   // 已被更新的触发顶掉，浮窗归新一代管
        guard let raw, let text = validateSelectionText(raw) else {
            Log.info("划词翻译: 没有取到可用文本（读到 \(raw.map { "\($0.count) 字" } ?? "nil")）")
            panel.show(original: "", translated: "没有取到选中文本",
                       timeoutSeconds: translateConfig.panelTimeoutSeconds)
            return
        }
        panel.show(original: text, translated: "翻译中…",
                   timeoutSeconds: translateConfig.panelTimeoutSeconds)

        // 提交点：占位已经上屏，稳一会儿再花钱。中途松手/改选区 → 下面这步压根不发生。
        try? await Task.sleep(for: .milliseconds(Self.commitDelayMilliseconds))
        guard gen == generation else { return }
        Log.info("划词翻译: 取到 \(text.count) 字，开始翻译")

        switch await service.translate(text) {
        case .success(let translated):
            guard gen == generation else { return }
            Log.info("划词翻译: 完成 → \(translated.prefix(40))")
            panel.show(original: text, translated: translated,
                       timeoutSeconds: translateConfig.panelTimeoutSeconds)
            if translateConfig.speechEnabled {
                await speak(translated)
            }
        case .failed(_, let error):
            guard gen == generation else { return }
            Log.warn("划词翻译: 失败 \(error)")
            panel.show(original: text, translated: error,
                       timeoutSeconds: translateConfig.panelTimeoutSeconds)
        }
    }

    func dismiss() {
        panel.dismiss()
    }

    // MARK: - 内部

    /// 占位上屏到发起翻译请求之间的等待。太短拦不住手抖连按，太长显得迟钝。
    private static let commitDelayMilliseconds = 200

    /// 朗读译文。走 `speakUserInitiated`（用户开口 → 掐在播、插队到队首立刻念），不是 hook 那条排队路径。
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
