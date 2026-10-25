import AppKit
import iVoxKit

// 播报字幕：像音乐播放软件的歌词——屏上留着一段话，念到哪儿哪儿变白。

/// 播报字幕这一路的内容来源：把「这一页的句子 + 念到第几句」交给浮窗。
///
/// **歌词式**：屏上不是只有正在念的那一句，而是**这一页的句子**——
/// 正在念的那句亮着（卡拉OK式：念过的字白、没念到的半透明白），念过的整句留着，
/// 还没念到的暗着。眼睛可以跟着白字走，不用盯着被换掉的字。
///
/// **逐字进度是自己算的**：不新增音频信号——按「念了多久 × 语速」估，
/// 语速用上一句的实际用时校正（越念越准）。每 100ms 推进一步。
///
/// 浮窗（`OverlayService`）负责外观、排版、落点与去重；字幕只管**什么时候有字、什么时候没字**：
/// 有字就交给浮窗（跟播放同步，句首块被设备读出时才来报），播完或被打断就交回去。
/// 收起只由播报状态驱动，**不跟鼠标走**：字幕是「一边听一边看」，手总会动。
///
/// 与译文那一路同源的是「交出一段文字」这一件事——**屏上已经有的字不会显示两遍**
/// （译文被朗读时，字幕那句正是译文的一部分，浮窗会自动盖住它）。
@MainActor
final class CaptionPanel {
    private let service: OverlayService
    /// 当前页的句子（歌词的上下文）
    private var lines: [String] = []
    /// 正在念的是第几句
    private var index = 0
    /// 当前句开始念的时刻
    private var startedAt = Date()
    /// 语速（字/秒）：先用经验值，每句结束时用它的实际用时校正
    private var charsPerSecond: Double = 4.5
    /// 推进高亮的定时器（每 100ms 一步）
    private var ticker: Task<Void, Never>?

    /// 歌词窗口：当前句前后各带几句（多了占屏、少了没上下文）
    private static let contextBefore = 1
    private static let contextAfter = 1
    /// 高亮推进的节奏
    private static let tickInterval = Duration.milliseconds(100)

    init(service: OverlayService) {
        self.service = service
    }

    /// 更新字幕；`nil` = 收起。
    func update(_ frame: CaptionFrame?) {
        guard let frame, !frame.lines.isEmpty else {
            guard !lines.isEmpty else { return }
            lines = []
            stopTicker()
            service.hide(.caption)
            Log.debug("播报字幕: 收起")
            return
        }
        // 换页或换句 → 先给上一句结账（用它校正语速），再从新的一句开始算
        if frame.index != index || frame.lines != lines {
            settleRate()
            lines = frame.lines
            index = frame.index
            startedAt = Date()
        }
        render()
        startTicker()
    }

    // MARK: - 内部

    /// 上一句念完了：用它的实际用时校正语速（字/秒），下一句估得更准。
    private func settleRate() {
        guard !lines.isEmpty, index < lines.count else { return }
        let text = lines[index]
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed > 0.3, !text.isEmpty else { return }   // 太短的句子不参与校正
        let measured = Double(text.count) / elapsed
        // 平滑：一次异常（长停顿）不至于把语速带偏
        charsPerSecond = charsPerSecond * 0.5 + measured * 0.5
    }

    /// 画出歌词窗口：当前句逐字高亮，念过的白、没念的暗。
    private func render() {
        guard !lines.isEmpty, index < lines.count else { return }
        let lo = max(0, index - Self.contextBefore)
        let hi = min(lines.count - 1, index + Self.contextAfter)
        var out: [OverlayService.Line] = []
        for i in lo...hi {
            if i == index {
                let text = lines[i]
                let spoken = max(0, min(text.count, Int(Date().timeIntervalSince(startedAt) * charsPerSecond)))
                out.append(.init(text: text, style: .normal, highlight: 0..<spoken))
            } else {
                // 念过的整句留着（白），还没念到的暗着
                out.append(.init(text: lines[i], style: i < index ? .normal : .dim))
            }
        }
        service.show(.caption, lines: out)
    }

    /// 推进高亮的定时器：每 100ms 往前走一个字左右。
    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                guard !Task.isCancelled, let self else { return }
                guard !self.lines.isEmpty else { return }
                self.render()
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }
}
