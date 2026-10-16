import AppKit
import iVoxKit

// 播报字幕浮窗：念到哪句，就在屏幕下方显示哪句。

/// 一个常驻浮层：播报期间显示「正在念的这一句」，播完或被打断即收。
///
/// 与 `TranslationPanel` / `OverlayPanel` 是**各自独立**的三份实现 —— 刻意不抽公共件：
/// 三者的消失策略、生命周期、内容排布各不相同，硬抽成一个组件要开一堆口子，独立后改一个
/// 不牵连另外两个。三者同源的都是那一套 `NSPanel` 组合：不抢焦点、悬于所有窗口、跨 Space。
///
/// 与翻译浮窗的两处**刻意不同**：
/// - **不跟鼠标收**：字幕是「一边听一边看」，手总会动；收起只由播报状态驱动（`update(nil)`）
/// - **不跟鼠标、也不跟焦点所在屏**：常驻若跟着鼠标会来回跳；而 `NSScreen.main` 是**键盘焦点所在屏**，
///   多屏下焦点一动字幕就跑到别的屏去（人看不见）。固定钉在主屏（`screens.first`，含菜单栏那块）
///
/// 同步口径：跟**播放**——文本随音频块流到播放器，**句首块被设备读出**时才来报
/// （`AudioPlayer` 的 `.dataConsumed` 回调），与声音对齐（误差约一个 IO 缓冲）。
/// 曾短暂用「跟合成」，实测字幕比声音早一两句，已改。
///
/// 本类即 `@MainActor`——与 `OverlayPanel` 的取舍**不同**：那个刻意不标（它的持有者不是
/// MainActor 类，标了会把整条调用链拖成 async），代价是一批 actor-isolated 警告；本面板的
/// 调用点本来就在 `Task { @MainActor in ... }` 里（队列回调驱动），标注零成本，还省掉那批警告。
@MainActor
final class CaptionPanel {
    /// 内容区宽度上限（超过折行）
    private static let maxContentWidth: CGFloat = 600
    /// 距屏幕可见区底部：**贴底的字幕位**（与语音浮窗同高）。翻译浮窗被抬到它上方（96pt），
    /// 两者不重叠——分工是「字幕在下、翻译在上」，起初做反过（字幕在上、翻译在下）。
    private static let bottomInset: CGFloat = 24
    private static let padding: CGFloat = 14
    private static let cornerRadius: CGFloat = 10
    private static let fontSize: CGFloat = 16
    /// 内容高度上限占可见高的比例（超出截尾）
    private static let maxHeightRatio: CGFloat = 0.3

    private var panel: NSPanel?
    /// 正在显示的文本（去重：同一句重复广播不重排，免得闪）
    private var current = ""

    /// 更新字幕；`nil` / 空串 = 收起。
    func update(_ text: String?) {
        let text = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            guard !current.isEmpty else { return }
            current = ""
            panel?.orderOut(nil)
            Log.debug("播报字幕: 收起")
            return
        }
        guard text != current else { return }
        current = text
        show(text)
    }

    // MARK: - 内部

    private func show(_ text: String) {
        // 固定主屏（含菜单栏那块）：`NSScreen.main` 是**键盘焦点所在屏**、不是主屏——多屏下焦点一动，
        // 字幕就跟着跑到别的屏去，人在自己那块屏上反而看不见（实测日志里出现过别块屏的负 y 坐标）。
        // `screens.first` 才是主屏。
        let screen = NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let label = baseLabel()
        label.stringValue = text
        // 尺寸交给 label 自己量（`sizeToFit`），不用 `boundingRect` 代算——cell 的内边距它不含，
        // 算出来偏大 → 会多折一行、最后一行被裁（`TranslationPanel` 踩过，此处沿用同一口径）
        let widthLimit = min(Self.maxContentWidth, visible.width - 80) - Self.padding * 2
        label.sizeToFit()
        if label.frame.width > widthLimit {
            label.preferredMaxLayoutWidth = widthLimit
            label.sizeToFit()
        }
        let heightLimit = visible.height * Self.maxHeightRatio - Self.padding * 2
        if label.frame.height > heightLimit {
            let font = label.font!
            let lineHeight = font.ascender - font.descender + font.leading
            label.maximumNumberOfLines = max(1, Int(heightLimit / lineHeight))
            label.lineBreakMode = .byTruncatingTail
            label.sizeToFit()
        }

        let size = NSSize(width: label.frame.width + Self.padding * 2,
                          height: label.frame.height + Self.padding * 2)
        let panel = ensurePanel()
        // 顺序要紧：**先**把面板调到内容尺寸、**再**装 contentView；反过来会按面板当时的
        // contentRect（初始 100×40）重设 view 的 frame，算好的尺寸就丢了（`TranslationPanel` 踩过）
        panel.setContentSize(size)
        label.setFrameOrigin(NSPoint(x: Self.padding, y: Self.padding))
        panel.contentView = makeContainer(size: size, label: label)
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                     y: visible.minY + Self.bottomInset))
        panel.orderFrontRegardless()
        Log.debug("播报字幕: \(Int(size.width))×\(Int(size.height)) @ (\(Int(panel.frame.minX)),\(Int(panel.frame.minY)))")
    }

    private func baseLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: Self.fontSize)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }

    private func makeContainer(size: NSSize, label: NSTextField) -> NSView {
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.96).cgColor
        container.layer?.cornerRadius = Self.cornerRadius
        container.addSubview(label)
        return container
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
}
