import AppKit
import iVoxKit

// iVox 浮窗宿主：屏幕上那块 iVox 窗口。播报字幕、划词译文都只是「使用方」——
// 各自造自己的内容视图，往宿主的一个槽位里放或收；宿主只管几何（选屏、落点、堆叠、显隐）。

/// 浮窗里的槽位。加一个使用方 = 在这里加一个 case。
///
/// **声明顺序 = 从下往上的堆叠顺序**：字幕在下、译文在上（曾经靠一个手写死的
/// 「96 点间隙」把两块错开；合成一个窗后，间隙由容器结构保证）。
enum OverlaySlot: String, CaseIterable {
    /// 播报字幕：念到哪句显示哪句
    case caption
    /// 划词译文：原文 + 译文
    case translation
}

/// 一块屏的落点与堆叠规则。
///
/// 宿主只做几何：**位置、选屏、堆叠、什么时候显示**都在这儿；
/// 内容长什么样、什么时候收（字幕跟播报状态、译文跟鼠标移动）归各使用方。
@MainActor
final class IvoxOverlay {
    /// 一个使用方占一个槽位。
    @MainActor
    final class Slot {
        /// 槽位是哪一层（`caption` / `translation`）
        let id: OverlaySlot
        private unowned let host: IvoxOverlay
        /// 这一层当前的内容（nil = 这一层空着）
        fileprivate var content: NSView?

        init(id: OverlaySlot, host: IvoxOverlay) {
            self.id = id
            self.host = host
        }

        /// 放内容；`nil` = 收掉这一层。
        ///
        /// 内容视图**由使用方自绘**（自己的背景、圆角、排版）——宿主不碰外观，
        /// 只把它摆到该在的位置上。
        func set(_ view: NSView?) {
            guard content !== view else { return }
            content = view
            host.relayout()
        }

        /// 浮窗所在那块屏的可见区——使用方按它算自己的尺寸上限（宽度、高度）。
        var visibleFrame: NSRect { host.visibleFrame }
    }

    private var panel: NSPanel?
    private var slots: [OverlaySlot: Slot] = [:]
    /// 整窗锚定的那块屏：显示期间不换屏（跟着鼠标走会让浮窗在人动鼠标时来回跳）。
    /// nil = 还没显示。
    private var anchorScreen: NSScreen?
    /// 认不到钉的屏时只告警一次，别刷屏。
    private var didWarnMissingScreen = false
    private let config: OverlayConfig

    init(config: OverlayConfig) {
        self.config = config
    }

    /// 取（并建）一个槽位。使用方持有它，往里放/收内容。
    func slot(_ id: OverlaySlot) -> Slot {
        if let existing = slots[id] { return existing }
        let created = Slot(id: id, host: self)
        slots[id] = created
        return created
    }

    /// 浮窗所在那块屏的**可见区**——使用方按它算自己的尺寸上限（宽度、高度）。
    ///
    /// 显示期间给的是锚定那块屏（不跟鼠标跑）；还没显示时给的是「将会落在哪块屏」。
    var visibleFrame: NSRect {
        (anchorScreen ?? pickScreen())?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    // MARK: - 内部

    /// 重排：把各槽位的内容摆好、算好窗口大小、落到位。全空则收窗。
    private func relayout() {
        let contents = OverlaySlot.allCases.compactMap { slots[$0]?.content }
        guard !contents.isEmpty else {
            panel?.orderOut(nil)
            anchorScreen = nil   // 收起来之后重新选屏：下次显示落在哪儿由那一刻的现场决定
            return
        }
        if anchorScreen == nil { anchorScreen = pickScreen() }

        let gap = CGFloat(config.gap)
        let layout = Self.stackLayout(sizes: contents.map(\.frame.size), gap: gap)
        let width = layout.size.width
        let height = layout.size.height

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        // 关掉自动改子视图尺寸：下面要自己按算好的位置摆每一层
        container.autoresizesSubviews = false
        for (view, origin) in zip(contents, layout.origins) {
            container.addSubview(view)
            view.setFrameOrigin(origin)
        }

        let panel = ensurePanel()
        // 顺序要紧：**先**把面板调到内容尺寸、**再**装 contentView；反过来会按面板当时的
        // contentRect（初始 100×40）重设 view 的 frame，算好的尺寸就丢了（`TranslationPanel` 踩过）
        panel.setContentSize(NSSize(width: width, height: height))
        container.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        panel.contentView = container

        let visible = visibleFrame
        panel.setFrameOrigin(Self.origin(inset: CGFloat(config.inset),
                                         visible: visible,
                                         size: NSSize(width: width, height: height)))
        panel.orderFrontRegardless()
        Log.debug("iVox 浮窗: \(Int(width))×\(Int(height)) @ (\(Int(panel.frame.minX)),\(Int(panel.frame.minY)))")
    }

    /// 落点：水平永远居中、垂直贴底（底边距可见区底边 `inset` 点）。
    ///
    /// 纯几何，抽成 static 便于单测（渲染与几何分开测，测几何不用开窗口）。
    /// 注意用**可见区**（`visibleFrame`）而不是整块屏：菜单栏让出的那条不算可用。
    static func origin(inset: CGFloat, visible: NSRect, size: NSSize) -> NSPoint {
        NSPoint(x: visible.midX - size.width / 2, y: visible.minY + inset)
    }

    /// 堆叠几何：各层从**下往上**摆，层间留 `gap`；每层水平居中。
    ///
    /// `sizes` 按**从下到上**的顺序给（第一项贴容器底）。返回容器尺寸与每层在容器里的原点。
    static func stackLayout(sizes: [NSSize], gap: CGFloat) -> (size: NSSize, origins: [NSPoint]) {
        let width = sizes.map(\.width).max() ?? 0
        let height = sizes.reduce(0) { $0 + $1.height } + gap * CGFloat(max(0, sizes.count - 1))
        var origins = [NSPoint](repeating: .zero, count: sizes.count)
        var y: CGFloat = 0
        for index in sizes.indices {
            origins[index] = NSPoint(x: (width - sizes[index].width) / 2, y: y)
            y += sizes[index].height + gap
        }
        return (NSSize(width: width, height: height), origins)
    }

    /// 落在哪块屏：钉了 UUID 就钉那块（认不到就落回跟鼠标，并告警一次）；没钉就跟鼠标。
    ///
    /// 鼠标位置用 `NSEvent.mouseLocation`（AppKit 全局坐标，左下原点）——
    /// **不能**用热键回调里的 `CGEvent.location`：那是屏幕坐标、**左上原点**，混着算会选错屏幕（踩过）。
    private func pickScreen() -> NSScreen? {
        if let pinned = config.resolvedScreen {
            let want = ScreenIdentity.normalize(pinned)
            if let hit = NSScreen.screens.first(where: { screen in
                guard let id = ScreenIdentity.uuid(for: screen) else { return false }
                return ScreenIdentity.normalize(id) == want
            }) {
                return hit
            }
            if !didWarnMissingScreen {
                didWarnMissingScreen = true
                Log.warn("浮窗: 找不到 uuid=\(pinned) 的屏（没接上？），暂跟鼠标所在屏")
            }
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.screens.first
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
        // 阴影由各层自己的圆角容器带（窗本身是透明的，panel 的阴影会画成一个方框）
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.panel = panel
        return panel
    }
}
