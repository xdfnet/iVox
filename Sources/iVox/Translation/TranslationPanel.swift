import AppKit
import iVoxKit

// 屏幕下方的翻译结果浮窗（歌词式）。

/// 一个非交互浮层：不抢焦点、悬于所有窗口、跨 Space、到点自隐。
///
/// 范本是 `SpeechInput/OverlayPanel.swift`（已验证在无 `NSApplication` 事件循环的
/// daemon 里能正常显示）：同样的 `NSPanel` 组合 —— `nonactivatingPanel` 不抢焦点、
/// `level = .floating` 悬于所有窗口、`canJoinAllSpaces` 跨 Space。
///
/// 内容两种排法，按**原文是不是一个词**分：
/// - **单词**：`feature　功能、特性` —— 横排一行，原文小一号、略暗
/// - **一句**：原文在上（12pt 灰）、译文在下（16pt 白），便于回看对应
///
/// 位置固定在鼠标所在屏的下方居中，宽度随内容、高度有上限（超出截译文）。
///
/// **刻意不做**：拖拽移动、点击外部关闭、文本选择。这三样都要 key window / 输入焦点，
/// 当前 daemon 形态给不了；替代是「再按一次 Opt+Z 覆盖 + 到点自己消失」。
@MainActor
final class TranslationPanel {
    /// 内容区宽度上限（超过就折行）
    private static let maxContentWidth: CGFloat = 600
    /// 内容区高度上限占屏幕可见高的比例（超过就截译文）
    private static let maxHeightRatio: CGFloat = 0.45
    /// 距屏幕可见区底部的留白：抬到播报字幕（24pt，贴底）**之上**，两者不重叠。
    /// 曾是 28pt（与字幕同区），飞哥定了「翻译在上、字幕在下」之后上移。
    private static let bottomInset: CGFloat = 96
    private static let padding: CGFloat = 14
    private static let cornerRadius: CGFloat = 10
    private static let gap: CGFloat = 6
    /// 原文与译文**同号**，层次只靠亮度拉开（原文 55% 透明、译文纯白）——原为 12pt，飞哥定的统一 16
    private static let originalFontSize: CGFloat = 16
    private static let translatedFontSize: CGFloat = 16

    private var panel: NSPanel?
    /// 兜底定时器：鼠标一直不动时的最后保险（正常靠鼠标移动收起）
    private var hideWorkItem: DispatchWorkItem?
    /// 显示时的鼠标位置；此后鼠标一动就认为「看完了」
    private var anchorPoint: NSPoint = .zero
    private var mouseWatchTask: Task<Void, Never>?

    /// 在**鼠标所在那块屏**的下方居中显示，`timeoutSeconds` 后自动隐藏。
    ///
    /// 鼠标位置在这里现取（`NSEvent.mouseLocation`，AppKit 全局坐标）——**不能**用
    /// 热键回调里的 `CGEvent.location`：那是屏幕坐标、**左上原点**，而 `NSScreen` 与
    /// `NSPanel` 用**左下原点**，混着算会选错屏幕（踩过）。
    ///
    /// - Parameters:
    ///   - original: 选中的原文；传空串表示只显示一段（如出错提示）
    ///   - translated: 译文
    func show(original: String, translated: String, timeoutSeconds: Double) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let view = makeContentView(
            original: original,
            translated: translated,
            maxWidth: min(Self.maxContentWidth, visible.width - 80),
            maxHeight: (visible.height - Self.bottomInset * 2) * Self.maxHeightRatio
        )
        let size = view.frame.size
        let panel = ensurePanel()
        // 顺序要紧：先把面板调到内容尺寸，**再**装 contentView。
        // 反过来 `panel.contentView = view` 会按面板当时的 contentRect（初始 100×40）
        // 重设 view 的 frame，算好的尺寸就丢了（踩过：弹窗永远是那个初始小条）。
        panel.setContentSize(size)
        view.frame = NSRect(origin: .zero, size: size)
        panel.contentView = view

        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + Self.bottomInset
        ))
        panel.orderFrontRegardless()
        Log.debug("划词翻译: 浮窗 \(Int(size.width))×\(Int(size.height)) @ (\(Int(panel.frame.minX)),\(Int(panel.frame.minY)))")

        // 划完词手就停在鼠标上，眼睛看着浮窗；一旦手移开（要滚动、点别处、打字），
        // 就说明看完了。比「固定几秒」准得多——读到什么时候就留到什么时候。
        anchorPoint = mouse
        startWatchingMouse()
        scheduleHide(after: timeoutSeconds)   // 兜底：鼠标一直不动时的最后保险
    }

    func dismiss() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        mouseWatchTask?.cancel()
        mouseWatchTask = nil
        panel?.orderOut(nil)
    }

    // MARK: - 内部

    /// 轮询鼠标：相对显示时位移超过 5px 就收起。
    /// 5px 足够大，能手抖/微漂不误触；也足够小，真人一动手就跨过去了。
    private func startWatchingMouse() {
        mouseWatchTask?.cancel()
        mouseWatchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, let self else { return }
                let now = NSEvent.mouseLocation
                let dx = now.x - self.anchorPoint.x
                let dy = now.y - self.anchorPoint.y
                if dx * dx + dy * dy > 25 {
                    self.dismiss()
                    return
                }
            }
        }
    }

    private func scheduleHide(after seconds: Double) {
        hideWorkItem?.cancel()
        guard seconds > 0 else { return }
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.dismiss() }
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 40),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.panel = panel
        return panel
    }

    /// 深色圆角容器 + 按内容排好的文本。
    ///
    /// **尺寸交给 label 自己量**（`sizeToFit`），不要用 `NSAttributedString.boundingRect`
    /// 代算——`NSTextField` 的 cell 有几像素内边距，`boundingRect` 不含它，算出来的可用
    /// 面积偏大：实际排版会多折一行，最后一行超出容器被裁（踩过：总是差最后一个字）。
    private func makeContentView(
        original: String, translated: String, maxWidth: CGFloat, maxHeight: CGFloat
    ) -> NSView {
        let textWidthLimit = maxWidth - Self.padding * 2
        let textHeightLimit = maxHeight - Self.padding * 2

        // 原文不含空白 → 当成单词，横排一行；否则上下两段
        let isWord = !original.isEmpty && !original.contains { $0.isWhitespace }
        var labels: [NSTextField] = []
        if original.isEmpty {
            labels = [translatedLabel(translated)]
        } else if isWord {
            labels = [inlineLabel(original: original, translated: translated)]
        } else {
            labels = [originalLabel(original), translatedLabel(translated)]
        }

        // 逐个按宽度上限折行并量高
        for label in labels {
            label.sizeToFit()
            if label.frame.width > textWidthLimit {
                label.preferredMaxLayoutWidth = textWidthLimit
                label.sizeToFit()
            }
        }

        // 总高超出上限 → 截**最后一段**（句子时是译文；原文是你选的，通常短，留着）
        let gaps = CGFloat(max(0, labels.count - 1)) * Self.gap
        let totalHeight = labels.reduce(0) { $0 + $1.frame.height } + gaps
        if totalHeight > textHeightLimit, let last = labels.last, last.font != nil {
            let lineHeight = last.font!.ascender - last.font!.descender + last.font!.leading
            last.maximumNumberOfLines = max(1, Int((textHeightLimit - gaps) / lineHeight))
            last.lineBreakMode = .byTruncatingTail
            last.sizeToFit()
        }

        let textWidth = labels.map(\.frame.width).max() ?? 0
        let textHeight = labels.reduce(0) { $0 + $1.frame.height } + gaps
        let size = NSSize(
            width: textWidth + Self.padding * 2,
            height: textHeight + Self.padding * 2
        )

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.96).cgColor
        container.layer?.cornerRadius = Self.cornerRadius

        // 从顶部往下摆（AppKit 原点在左下，所以要倒着算 y）
        var y = size.height - Self.padding
        for label in labels {
            y -= label.frame.height
            label.setFrameOrigin(NSPoint(x: (size.width - label.frame.width) / 2, y: y))
            container.addSubview(label)
            y -= Self.gap
        }
        return container
    }

    private func baseLabel(_ font: NSFont, _ color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = font
        label.textColor = color
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }

    private func originalLabel(_ text: String) -> NSTextField {
        let label = baseLabel(.systemFont(ofSize: Self.originalFontSize), .white.withAlphaComponent(0.55))
        label.stringValue = text
        return label
    }

    private func translatedLabel(_ text: String) -> NSTextField {
        let label = baseLabel(.systemFont(ofSize: Self.translatedFontSize), .white)
        label.stringValue = text
        return label
    }

    /// 单词：原文（小、暗）与译文（大、亮）在同一行。
    private func inlineLabel(original: String, translated: String) -> NSTextField {
        let text = NSMutableAttributedString(string: original, attributes: [
            .font: NSFont.systemFont(ofSize: Self.originalFontSize),
            .foregroundColor: NSColor.white.withAlphaComponent(0.55),
        ])
        text.append(NSAttributedString(string: "  "))
        text.append(NSAttributedString(string: translated, attributes: [
            .font: NSFont.systemFont(ofSize: Self.translatedFontSize),
            .foregroundColor: NSColor.white,
        ]))

        let label = baseLabel(.systemFont(ofSize: Self.translatedFontSize), .white)
        label.attributedStringValue = text
        return label
    }
}
