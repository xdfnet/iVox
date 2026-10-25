import AppKit
import iVoxKit

// 播报字幕：念到哪句，就在浮窗里显示哪句。

/// 浮窗里的**字幕那一层**的使用方：只管「长什么样」，不管浮窗落在哪儿。
///
/// 落点、选屏、跟译文叠在一起时的上下次序，都归 `IvoxOverlay`（浮窗宿主）管——
/// 这一层只交出一个画好的视图。收起只由播报状态驱动（`update(nil)`），
/// **不跟鼠标走**：字幕是「一边听一边看」，手总会动。
///
/// 与译文层的不同是**刻意**的：译文跟鼠标走、到点自隐；字幕跟播放状态。
/// 两者同源的是「造一个视图交给宿主」这一件事。
///
/// 同步口径：跟**播放**——文本随音频块流到播放器，**句首块被设备读出**时才来报
/// （`AudioPlayer` 的 `.dataConsumed` 回调），与声音对齐（误差约一个 IO 缓冲）。
/// 曾短暂用「跟合成」，实测字幕比声音早一两句，已改。
@MainActor
final class CaptionPanel {
    /// 字幕的外观：**全部由配置给**（`[captions]` 段），代码里不写死
    /// ——默认值真源在 `CaptionsConfig.default`（iVoxKit），此处不另抄一份。
    private let config: CaptionsConfig
    /// 浮窗里的字幕槽位
    private let slot: IvoxOverlay.Slot
    /// 正在显示的文本（去重：同一句重复广播不重排，免得闪）
    private var current = ""

    /// - Parameters:
    ///   - config: 字幕配置（开关与外观）。
    ///   - slot: 浮窗里的字幕槽位。
    init(config: CaptionsConfig, slot: IvoxOverlay.Slot) {
        self.config = config
        self.slot = slot
    }

    /// 更新字幕；`nil` / 空串 = 收起。
    func update(_ text: String?) {
        let text = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            guard !current.isEmpty else { return }
            current = ""
            slot.set(nil)
            Log.debug("播报字幕: 收起")
            return
        }
        guard text != current else { return }
        current = text
        slot.set(makeView(text))
    }

    // MARK: - 内部

    /// 造出这一句字幕的视图（自绘背景与圆角；宿主只管把它摆到位置上）。
    private func makeView(_ text: String) -> NSView {
        let visible = slot.visibleFrame
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
        let container = makeContainer(size: size, label: label)
        Log.debug("播报字幕: \(Int(size.width))×\(Int(size.height))")
        return container
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

    /// 深色圆角容器 + 自己的阴影。
    ///
    /// 阴影挂在**这一层**上而不是浮窗上：浮窗本身是透明的，panel 的阴影会画成一个方框。
    private func makeContainer(size: NSSize, label: NSTextField) -> NSView {
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.96).cgColor
        container.layer?.cornerRadius = CGFloat(config.cornerRadius)
        container.layer?.shadowColor = NSColor.black.cgColor
        container.layer?.shadowOpacity = 0.35
        container.layer?.shadowRadius = 10
        container.layer?.shadowOffset = .zero
        container.addSubview(label)
        label.setFrameOrigin(NSPoint(x: CGFloat(config.padding), y: CGFloat(config.padding)))
        return container
    }
}
