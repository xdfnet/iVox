import AppKit
import iVoxKit

// 播报字幕：念到哪句，就在浮窗里显示哪句。

/// 播报字幕这一路的内容来源：只说「这一句」，别的都不管。
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
    /// 正在显示的文本（去重：同一句重复广播不重排，免得闪）
    private var current = ""

    init(service: OverlayService) {
        self.service = service
    }

    /// 更新字幕；`nil` / 空串 = 收起。
    func update(_ text: String?) {
        let text = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            guard !current.isEmpty else { return }
            current = ""
            service.hide(.caption)
            Log.debug("播报字幕: 收起")
            return
        }
        guard text != current else { return }
        current = text
        service.show(.caption, lines: [.init(text: text, style: .normal)])
    }
}
