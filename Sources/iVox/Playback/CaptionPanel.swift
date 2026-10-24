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
///   多屏下焦点一动字幕就跑到别的屏去（人看不见）。默认钉在主屏（`screens.first`，含菜单栏那块）；
///   要钉到别的屏，在配置 `[captions]` 段的 `screen` 填那块屏的 UUID（见 `ScreenIdentity`）——
///   **钉的是「哪块屏」这个身份，不是「屏幕上第几块」**，拔插、重启、改分辨率都不漂
///
/// 落点与外观（贴底/贴顶/居中、距边点数、字号、宽度上限…）全部来自配置 `[captions]` 段，
/// 代码里不写死——默认值真源在 `CaptionsConfig.default`（iVoxKit）。
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
    private var panel: NSPanel?
    /// 正在显示的文本（去重：同一句重复广播不重排，免得闪）
    private var current = ""
    /// 字幕的外观与落点：**全部由配置给**（`[captions]` 段），代码里不写死
    /// ——默认值真源在 `CaptionsConfig.default`（iVoxKit），此处不另抄一份。
    private let config: CaptionsConfig
    /// 钉住的那块屏的 UUID（配置给的）；nil = 主屏。
    private let pinnedScreenUUID: String?
    /// 认不到钉的屏时只告警一次，别刷屏。
    private var didWarnMissingScreen = false
    /// 钉对了只报一次（让日志能确认「钉在了一块屏上」）。
    private var didLogPinnedScreen = false

    /// - Parameter config: 字幕配置（开关、钉屏、落点与尺寸外观）。
    init(config: CaptionsConfig) {
        self.config = config
        self.pinnedScreenUUID = config.resolvedScreen
    }

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
        // 默认主屏（含菜单栏那块）：`NSScreen.main` 是**键盘焦点所在屏**、不是主屏——多屏下焦点一动，
        // 字幕就跟着跑到别的屏去，人在自己那块屏上反而看不见（实测日志里出现过别块屏的负 y 坐标）。
        // `screens.first` 才是主屏。配置了 `captions.screen` 就钉到那块屏上。
        let screen = targetScreen()
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let padding = CGFloat(config.padding)

        let label = baseLabel()
        label.stringValue = text
        // 尺寸交给 label 自己量（`sizeToFit`），不用 `boundingRect` 代算——cell 的内边距它不含，
        // 算出来偏大 → 会多折一行、最后一行被裁（`TranslationPanel` 踩过，此处沿用同一口径）
        let widthLimit = min(CGFloat(config.maxWidth), visible.width - 80) - padding * 2
        label.sizeToFit()
        if label.frame.width > widthLimit {
            label.preferredMaxLayoutWidth = widthLimit
            label.sizeToFit()
        }
        let heightLimit = visible.height * CGFloat(config.maxHeightRatio) - padding * 2
        if label.frame.height > heightLimit {
            let font = label.font!
            let lineHeight = font.ascender - font.descender + font.leading
            label.maximumNumberOfLines = max(1, Int(heightLimit / lineHeight))
            label.lineBreakMode = .byTruncatingTail
            label.sizeToFit()
        }

        let size = NSSize(width: label.frame.width + padding * 2,
                          height: label.frame.height + padding * 2)
        let panel = ensurePanel()
        // 顺序要紧：**先**把面板调到内容尺寸、**再**装 contentView；反过来会按面板当时的
        // contentRect（初始 100×40）重设 view 的 frame，算好的尺寸就丢了（`TranslationPanel` 踩过）
        panel.setContentSize(size)
        label.setFrameOrigin(NSPoint(x: padding, y: padding))
        panel.contentView = makeContainer(size: size, label: label)
        panel.setFrameOrigin(Self.origin(position: config.position,
                                         inset: CGFloat(config.inset),
                                         visible: visible, size: size))
        panel.orderFrontRegardless()
        Log.debug("播报字幕: \(Int(size.width))×\(Int(size.height)) @ (\(Int(panel.frame.minX)),\(Int(panel.frame.minY)))")
    }

    /// 落点：水平永远居中；垂直由 `position` 决定（贴底 / 贴顶 / 居中），`inset` 是距那条边的点数。
    ///
    /// 纯几何，抽成 static 便于单测（渲染与几何分开测，测几何不用开窗口）。
    /// 注意用**可见区**（`visibleFrame`）而不是整块屏：菜单栏让出的那条不算可用。
    static func origin(position: CaptionPosition, inset: CGFloat,
                       visible: NSRect, size: NSSize) -> NSPoint {
        let x = visible.midX - size.width / 2
        let y: CGFloat
        switch position {
        case .bottom: y = visible.minY + inset
        case .top: y = visible.maxY - inset - size.height
        case .center: y = visible.midY - size.height / 2
        }
        return NSPoint(x: x, y: y)
    }

    /// 字幕要往哪块屏上放。
    ///
    /// 默认主屏。配置了 `captionScreen`（某块屏的 UUID）就钉那块——**每次显示时现查**，
    /// 因为屏的插拔是运行期的事：那块屏没接上时落回主屏并告警一次，接回来又会自动钉回去。
    private func targetScreen() -> NSScreen? {
        guard let pinned = pinnedScreenUUID, !pinned.isEmpty else {
            return NSScreen.screens.first
        }
        let want = ScreenIdentity.normalize(pinned)
        if let hit = NSScreen.screens.first(where: { screen in
            guard let id = ScreenIdentity.uuid(for: screen) else { return false }
            return ScreenIdentity.normalize(id) == want
        }) {
            if !didLogPinnedScreen {
                didLogPinnedScreen = true
                Log.info("字幕屏: 已钉在 \(ScreenIdentity.describe(hit))")
            }
            return hit
        }
        if !didWarnMissingScreen {
            didWarnMissingScreen = true
            Log.warn("字幕屏: 找不到 uuid=\(pinned) 的屏（没接上？），暂落主屏")
        }
        return NSScreen.screens.first
    }

    private func baseLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: CGFloat(config.fontSize))
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
        container.layer?.cornerRadius = CGFloat(config.cornerRadius)
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
