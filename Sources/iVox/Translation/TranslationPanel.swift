import AppKit
import iVoxKit

// 鼠标旁的翻译结果浮窗。

/// 一个非交互浮层：不抢焦点、悬于所有窗口、跨 Space、到点自隐，尺寸随译文长短变。
///
/// 范本是 `SpeechInput/OverlayPanel.swift`（已验证在无 `NSApplication` 事件循环的
/// daemon 里能正常显示）：同样的 `NSPanel` 组合 —— `nonactivatingPanel` 不抢焦点、
/// `level = .floating` 悬于所有窗口、`canJoinAllSpaces` 跨 Space。
///
/// 与范本的差异：位置跟随鼠标（`placeNearAnchor`）、内容用 `NSTextField` 按文本量尺寸
/// （不用 `NSHostingView`，避开无 NSApp 下 SwiftUI 拟合尺寸的不确定）、超时自动隐藏。
///
/// **刻意不做**：拖拽移动、点击外部关闭、文本选择。这三样都要 key window / 输入焦点，
/// 当前 daemon 形态给不了；替代是「再按一次 Cmd+D 覆盖 + 到点自己消失」。
@MainActor
final class TranslationPanel {
    private static let maxTextWidth: CGFloat = 600
    private static let padding: CGFloat = 14
    private static let cornerRadius: CGFloat = 10
    private static let fontSize: CGFloat = 14

    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    /// 在鼠标旁边显示译文；`timeoutSeconds` 后自动隐藏。
    ///
    /// 鼠标位置在这里现取（`NSEvent.mouseLocation`，AppKit 全局坐标）。**不能**用
    /// 热键回调里的 `CGEvent.location`——那是屏幕坐标、**左上原点**，而 `NSScreen`
    /// 与 `NSPanel` 用**左下原点**；混着算弹窗会跑到屏幕另一头（踩过）。
    func show(text: String, timeoutSeconds: Double) {
        let view = makeContentView(text: text)
        let panel = ensurePanel()
        panel.contentView = view
        panel.setContentSize(view.frame.size)

        let anchor = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main {
            panel.setFrameOrigin(placeNearAnchor(
                anchor: anchor,
                visibleFrame: screen.visibleFrame,
                size: view.frame.size
            ))
        }
        panel.orderFrontRegardless()
        scheduleHide(after: timeoutSeconds)
    }

    func dismiss() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        panel?.orderOut(nil)
    }

    // MARK: - 内部

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

    /// 深色圆角容器 + 自动换行的文本，尺寸随内容量出来。
    ///
    /// 宽高都用 `boundingRect` 自己算，不依赖 `NSTextField.sizeToFit()`（多行时不按上限
    /// 折行、高度量错，长译文只显示一行）。**宽度分两步**：先量「不折行」的自然宽度，
    /// 只有它超过上限时才折行——直接拿上限当约束去量，单行短文本也会返回上限宽，
    /// 弹窗就是固定的宽条（踩过）。
    private func makeContentView(text: String) -> NSView {
        let font = NSFont.systemFont(ofSize: Self.fontSize)
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let maxTextWidth = Self.maxTextWidth - Self.padding * 2
        let width = min(ceil(attributed.size().width), maxTextWidth)
        let bounds = attributed.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let textSize = NSSize(width: width, height: ceil(bounds.height))

        let size = NSSize(
            width: textSize.width + Self.padding * 2,
            height: textSize.height + Self.padding * 2
        )
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.96).cgColor
        container.layer?.cornerRadius = Self.cornerRadius

        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = .white
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.frame = NSRect(origin: NSPoint(x: Self.padding, y: Self.padding), size: textSize)
        container.addSubview(label)
        return container
    }
}
