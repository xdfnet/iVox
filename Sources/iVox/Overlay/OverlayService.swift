import AppKit
import iVoxKit

// iVox 浮窗服务：屏幕上那块公共浮窗。
//
// 各能力只说「我要显示哪几行字」与「我什么时候没话说了」，别的都不管：
// 外观、排版、落点、选屏、消失的等待、以及背景音乐让路，全在这一个服务里。

/// 浮窗服务：谁在说话、显示哪几行字、什么时候消失。
///
/// 同一个来源的新内容**替换**旧内容（字幕每句换一句、译文从占位换成结果）；
/// 不同来源的内容**并存**（播报字幕 + 划词译文同屏，各占几行）。
@MainActor
final class OverlayService {
    /// 浮窗的来源（哪个能力在用）。
    enum Channel: String, CaseIterable {
        /// 播报字幕：念到哪句显示哪句
        case caption
        /// 划词译文：原文 + 译文
        case translation
    }

    /// 一行文字的样式。
    enum Style: Sendable {
        /// 正文（白）
        case normal
        /// 附注（半透明白）——原文那一行用它
        case dim
    }

    /// 一行文字。
    struct Line: Sendable {
        let text: String
        let style: Style
        /// 卡拉OK式高亮区间（**字符下标**）：区间内白色、区间外半透明白。
        /// nil = 整行一个颜色（按 `style`）。
        let highlight: Range<Int>?

        init(text: String, style: Style = .normal, highlight: Range<Int>? = nil) {
            self.text = text
            self.style = style
            self.highlight = highlight
        }
    }

    /// 屏上只有这两个颜色（翻译那双色）：主色 = 正文白，次色 = 半透明白。
    /// **字幕的卡拉OK高亮也用它们**——不另立一套颜色。
    private static let primaryColor = NSColor.white
    private static let secondaryColor = NSColor.white.withAlphaComponent(0.55)

    private var channels: [Channel: [Line]] = [:]
    private var panel: NSPanel?
    /// 整窗锚定的那块屏：显示期间不换屏（跟着鼠标走会让浮窗在人动鼠标时来回跳）。
    /// nil = 还没显示。
    private var anchorScreen: NSScreen?
    /// 认不到钉的屏时只告警一次，别刷屏。
    private var didWarnMissingScreen = false
    /// 浮层在不在屏上——**音乐让路的唯一判据**
    private var isWindowVisible = false
    /// 上一轮画出来的文字与 label：卡拉OK式字幕每 100ms 推进一步高亮，
    /// 整块重建视图会闪——文字没变就只换颜色。
    private var renderedTexts: [String] = []
    private var renderedLabels: [NSTextField] = []
    /// 音乐已经让过路了吗（降了但还没升回来）
    private var musicDucked = false
    private let ducker: SodaVolumeDucker
    private let config: OverlayConfig

    init(config: OverlayConfig, ducker: SodaVolumeDucker = SodaVolumeDucker()) {
        self.config = config
        self.ducker = ducker
    }

    /// 显示（或替换）某个来源的内容。`lines` 为空 = 收起这个来源。
    func show(_ channel: Channel, lines: [Line]) {
        guard !lines.isEmpty else {
            hide(channel)
            return
        }
        channels[channel] = lines
        relayout()
    }

    /// 收起某个来源的内容（别的来源不受影响）。
    func hide(_ channel: Channel) {
        guard channels.removeValue(forKey: channel) != nil else { return }
        relayout()
    }

    // MARK: - 内部

    /// 重排：把各来源的内容排成几行、装进**一块载体**、落到位。
    ///
    /// **内容一空就收窗**，不留残余：早先留了「等 3 秒再收」的机制（`lingerSeconds`），
    /// 想着让背景音乐别在两句之间抖——实际是**把上一个问题的形状搬了个地方**：
    /// 用户按了 Ctrl+2 掀桌，字幕还挂着最后那句 3 秒、音乐也压着 3 秒不回来，
    /// 「字幕收不干净、恢复太慢」正是这么来的。空了就收，干净。
    private func relayout() {
        render(visibleLines())
    }

    /// 背景音乐让路：**只跟浮层走**——浮层在屏上就降 5 格，浮层一消失就升回来。
    ///
    /// 早先还掺了「iVox 正在出声」这半个判据（播报起落信号），飞哥否了：
    /// 让路与否只该看**屏幕上有没有东西占着**。声音归声音、屏幕归屏幕，
    /// 两条线不搅在一起（字幕关掉时，播报也不该压着音乐）。
    ///
    /// 「停」用的是现成的音量让路（`SodaVolumeDucker`）——真暂停做不到：汽水音乐丢弃
    /// 合成键，而媒体会话可能打到别的 App。改数值不切播放状态，抖不起来。
    private func updateMusic() {
        let occupied = isWindowVisible
        guard occupied != musicDucked else { return }
        musicDucked = occupied
        Task { await (occupied ? ducker.duck() : ducker.restore()) }
    }

    /// 要显示哪几行：**同一句话不显示两遍**。
    ///
    /// 谁是那句话、谁是从它派生的：字幕那行是 iVox 正在念的一句，译文那行是用户主动要的结果。
    /// 划词译文会被朗读，念出来的那句正是译文的一部分 —— 于是字幕成了译文的**回声**，
    /// 屏幕上同一句话出现两遍（用户反馈过）。所以重叠时**去掉字幕那行、留下译文**。
    ///
    /// 排列：译文在上、字幕在下（译文是用户正在看的东西，字幕是背景的「正在念」）。
    private func visibleLines() -> [Line] {
        let contents = Channel.allCases.map { (channel: $0, lines: channels[$0] ?? []) }
        return Self.visibleLines(contents)
    }

    /// 逐行去重：**同一句话只显示一遍**。
    ///
    /// 判据：字幕那行与译文**重叠**（译文包含它 / 它包含译文 / 两者相同）→ 字幕那行是回声，去掉。
    /// 译文**永远保留**——它是用户要的结果，字幕只是它被念出来时的影子。
    ///
    /// 只拿译文的**正文那行**（非 dim）来比：dim 那行是用户选的原文（可能是个英文短词），
    /// 拿它比容易把不相干的字幕误判成回声。
    ///
    /// 归一化会去掉首尾空白与句末标点：字幕那句是从译文里切出来的，末尾标点可能对不上。
    /// 纯逻辑（不碰实例状态），便于单测。
    static func visibleLines(_ contents: [(channel: Channel, lines: [Line])]) -> [Line] {
        func lines(of channel: Channel) -> [Line] {
            contents.first { $0.channel == channel }?.lines ?? []
        }
        let translation = lines(of: .translation)
        let caption = lines(of: .caption)
        // 译文的正文行（原文那行是 dim，不参与比对）
        let translatedText = translation.filter { $0.style != .dim }.map { normalize($0.text) }

        var result: [Line] = translation
        for line in caption {
            let text = normalize(line.text)
            guard !text.isEmpty else { continue }
            let isEcho = translatedText.contains { other in
                other == text || other.contains(text) || text.contains(other)
            }
            if !isEcho { result.append(line) }
        }
        return result
    }

    /// 归一化：去首尾空白、去句末标点。
    private static func normalize(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = result.last, "。．.，,、！!？?；;：:…～~".contains(last) {
            result.removeLast()
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 画出这几行。**没有内容 = 收窗**（顺带把音乐放回来）。
    private func render(_ lines: [Line]) {
        guard !lines.isEmpty else {
            panel?.orderOut(nil)
            anchorScreen = nil
            isWindowVisible = false
            updateMusic()
            return
        }
        if anchorScreen == nil { anchorScreen = pickScreen() }

        // **文字没变就只改颜色**：卡拉OK式字幕的高亮每 100ms 推进一步，
        // 整块重建视图会闪（连着闪十几下）。只换颜色不动尺寸 → 视觉上只有字在变亮。
        if renderedTexts == lines.map(\.text), renderedLabels.count == lines.count {
            for (label, line) in zip(renderedLabels, lines) { apply(line, to: label) }
            return
        }

        let padding = CGFloat(config.padding)
        let gap = CGFloat(config.gap)
        let visible = screenVisibleFrame

        // 逐行量尺寸：宽度上限 = 浮窗宽度上限，且别超出屏宽（载体还有内边距）
        let widthLimit = min(CGFloat(config.maxWidth), visible.width - 80 - padding * 2)
        var labels: [NSTextField] = []
        for line in lines {
            let label = makeLabel(line.text, style: line.style)
            apply(line, to: label)
            label.sizeToFit()
            if label.frame.width > widthLimit {
                label.preferredMaxLayoutWidth = widthLimit
                label.sizeToFit()
            }
            labels.append(label)
        }

        // 总高超出上限 → 截**最后一行**（译文那一行；原文是你选的，通常短，留着）
        let heightLimit = visible.height * CGFloat(config.maxHeightRatio) - padding * 2
        let gaps = gap * CGFloat(max(0, labels.count - 1))
        var totalHeight = labels.reduce(0) { $0 + $1.frame.height } + gaps
        if totalHeight > heightLimit, let last = labels.last, let font = last.font {
            let lineHeight = font.ascender - font.descender + font.leading
            let room = heightLimit - gaps
            last.maximumNumberOfLines = max(1, Int(room / lineHeight))
            last.lineBreakMode = .byTruncatingTail
            last.sizeToFit()
            totalHeight = labels.reduce(0) { $0 + $1.frame.height } + gaps
        }

        let contentWidth = labels.map { $0.frame.width }.max() ?? 0
        let carrierSize = NSSize(width: contentWidth + padding * 2,
                                 height: totalHeight + padding * 2)

        // 一块载体：整个浮窗只有这一个背景、这一层圆角、这一个影子
        let carrier = NSView(frame: NSRect(origin: .zero, size: carrierSize))
        carrier.wantsLayer = true
        carrier.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.96).cgColor
        carrier.layer?.cornerRadius = CGFloat(config.cornerRadius)
        carrier.layer?.shadowColor = NSColor.black.cgColor
        carrier.layer?.shadowOpacity = 0.35
        carrier.layer?.shadowRadius = 10
        carrier.layer?.shadowOffset = .zero
        // 关掉自动改子视图尺寸：下面要自己按算好的位置摆每一行
        carrier.autoresizesSubviews = false

        var y = carrierSize.height - padding
        for label in labels {
            y -= label.frame.height
            carrier.addSubview(label)
            label.setFrameOrigin(NSPoint(x: (carrierSize.width - label.frame.width) / 2, y: y))
            y -= gap
        }

        let panel = ensurePanel()
        // 顺序要紧：**先**把面板调到内容尺寸、**再**装 contentView；反过来会按面板当时的
        // contentRect（初始 100×40）重设 view 的 frame，算好的尺寸就丢了（`TranslationPanel` 踩过）
        panel.setContentSize(carrierSize)
        carrier.frame = NSRect(origin: .zero, size: carrierSize)
        panel.contentView = carrier

        panel.setFrameOrigin(Self.origin(inset: CGFloat(config.inset),
                                         visible: visible,
                                         size: carrierSize))
        renderedTexts = lines.map(\.text)
        renderedLabels = labels

        panel.orderFrontRegardless()
        isWindowVisible = true
        updateMusic()
        Log.debug("iVox 浮窗: \(Int(carrierSize.width))×\(Int(carrierSize.height)) @ "
                  + "(\(Int(panel.frame.minX)),\(Int(panel.frame.minY)))")
    }

    private func makeLabel(_ text: String, style: Style) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: CGFloat(config.fontSize))
        label.textColor = style == .dim ? Self.secondaryColor : Self.primaryColor
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }

    /// 把一行的文字与颜色装进 label：整行一种色，或卡拉OK式（区间白、其余半透明白）。
    private func apply(_ line: Line, to label: NSTextField) {
        let font = label.font ?? .systemFont(ofSize: CGFloat(config.fontSize))
        let attributed = NSMutableAttributedString(string: line.text, attributes: [
            .font: font,
            .foregroundColor: baseColor(for: line),
        ])
        if let h = line.highlight, !h.isEmpty {
            let count = line.text.count
            let lo = max(0, min(h.lowerBound, count))
            let hi = max(lo, min(h.upperBound, count))
            if hi > lo {
                let start = line.text.index(line.text.startIndex, offsetBy: lo)
                let end = line.text.index(line.text.startIndex, offsetBy: hi)
                attributed.addAttribute(.foregroundColor, value: Self.primaryColor,
                                        range: NSRange(start..<end, in: line.text))
            }
        }
        label.attributedStringValue = attributed
    }

    /// 一行的底色：整行一种色时按 style；带高亮时底色一律次色（区间内才转主色）。
    private func baseColor(for line: Line) -> NSColor {
        if line.highlight == nil {
            return line.style == .dim ? Self.secondaryColor : Self.primaryColor
        }
        return Self.secondaryColor
    }

    /// 浮窗所在那块屏的**可见区**（菜单栏让出的那条不算可用）。
    var screenVisibleFrame: NSRect {
        (anchorScreen ?? pickScreen())?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// 落点：水平永远居中、垂直贴底（底边距可见区底边 `inset` 点）。
    ///
    /// 纯几何，抽成 static 便于单测（渲染与几何分开测，测几何不用开窗口）。
    static func origin(inset: CGFloat, visible: NSRect, size: NSSize) -> NSPoint {
        NSPoint(x: visible.midX - size.width / 2, y: visible.minY + inset)
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
        // 阴影由载体那一层带（浮窗本身是透明的，panel 的阴影会画成一个方框）
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.panel = panel
        return panel
    }
}
