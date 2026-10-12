import AppKit
import iVoxKit

// 鼠标旁的翻译结果浮窗。

/// 一个非交互浮层：不抢焦点、悬于所有窗口、跨 Space、到点自隐，尺寸随译文长短变。
///
/// 范本是 `SpeechInput/OverlayPanel.swift`（已验证在无 `NSApplication` 事件循环的
/// daemon 里能正常显示）：同样的 `NSPanel` 组合 —— `nonactivatingPanel` 不抢焦点、
/// `level = .floating` 悬于所有窗口、`canJoinAllSpaces` 跨 Space。
///
/// 与范本的差异：位置固定在鼠标所在屏的**下方居中**（歌词式）、内容用
/// `NSTextField` 按文本量尺寸（不用 `NSHostingView`，避开无 NSApp 下 SwiftUI
/// 拟合尺寸的不确定）、超时自动隐藏。
///
/// **刻意不做**：拖拽移动、点击外部关闭、文本选择。这三样都要 key window / 输入焦点，
/// 当前 daemon 形态给不了；替代是「再按一次 Cmd+D 覆盖 + 到点自己消失」。
@MainActor
final class TranslationPanel {
    private static let maxTextWidth: CGFloat = 600
    /// 距屏幕可见区底部的留白（歌词式贴底，但不完全压边）
    private static let bottomInset: CGFloat = 28
    private static let padding: CGFloat = 14
    private static let cornerRadius: CGFloat = 10
    private static let fontSize: CGFloat = 14

    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    /// 在**鼠标所在那块屏**的下方居中显示译文（像歌词），`timeoutSeconds` 后自动隐藏。
    ///
    /// 位置固定、不跟随鼠标。鼠标位置在这里现取（`NSEvent.mouseLocation`，AppKit 全局
    /// 坐标）——**不能**用热键回调里的 `CGEvent.location`：那是屏幕坐标、**左上原点**，
    /// 而 `NSScreen` 与 `NSPanel` 用**左下原点**，混着算会选错屏幕（踩过）。
    func show(text: String, timeoutSeconds: Double) {
        let view = makeContentView(text: text)
        let size = view.frame.size
        let panel = ensurePanel()
        // 顺序要紧：先把面板调到内容尺寸，**再**装 contentView。
        // 反过来 `panel.contentView = view` 会按面板当时的 contentRect（初始 100×40）
        // 重设 view 的 frame，算好的尺寸就丢了（踩过：弹窗永远是那个初始小条）。
        panel.setContentSize(size)
        view.frame = NSRect(origin: .zero, size: size)
        panel.contentView = view

        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.minY + Self.bottomInset
            ))
        }
        panel.orderFrontRegardless()
        Log.debug("划词翻译: 浮窗 \(Int(size.width))×\(Int(size.height)) @ (\(Int(panel.frame.minX)),\(Int(panel.frame.minY)))")
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
    /// **尺寸交给 label 自己量**（`sizeToFit`），不要用 `NSAttributedString.boundingRect`
    /// 代算——`NSTextField` 的 cell 有几像素内边距，`boundingRect` 不含它，算出来的可用
    /// 面积偏大：实际排版会多折一行，最后一行超出容器被裁（踩过：总是差最后一个字，
    /// 加 2px 补偿也不够）。
    ///
    /// 分两步量：先量不折行的自然尺寸；只有超过上限时才按上限折行重排（否则短文本
    /// 也会被撑成固定宽条）。
    private func makeContentView(text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: Self.fontSize)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping

        let maxTextWidth = Self.maxTextWidth - Self.padding * 2
        label.sizeToFit()
        if label.frame.width > maxTextWidth {
            label.preferredMaxLayoutWidth = maxTextWidth
            label.sizeToFit()
        }
        let textSize = label.frame.size

        let size = NSSize(
            width: textSize.width + Self.padding * 2,
            height: textSize.height + Self.padding * 2
        )
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.96).cgColor
        container.layer?.cornerRadius = Self.cornerRadius

        label.setFrameOrigin(NSPoint(x: Self.padding, y: Self.padding))
        container.addSubview(label)
        return container
    }
}
