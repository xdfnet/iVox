import AppKit
import iVoxKit

// 浮层落在哪块屏：所有浮层共用这一条规则。

/// 浮层选屏：**钉了 UUID 就钉那块**（认不到就落回跟鼠标，并告警一次）；没钉就跟鼠标。
///
/// 字幕/译文浮窗与录音胶囊都走这里——**两块浮层必须在同一块屏上**：
/// 早先录音胶囊自己挑屏（用 `NSScreen.main`），实测它永远落在上层那块主屏，
/// 而字幕浮窗按配置钉在下层那块 → 两块浮层分家，人根本看不全。
@MainActor
enum OverlayScreen {
    /// 认不到钉的屏时只告警一次，别刷屏。
    private static var didWarnMissingScreen = false

    /// 挑一块屏出来。
    ///
    /// - Parameter pinned: 屏的 UUID（空 = 跟鼠标所在屏）
    static func pick(pinned: String?) -> NSScreen? {
        if let pinned {
            let want = ScreenIdentity.normalize(pinned)
            if let hit = NSScreen.screens.first(where: { screen in
                guard let id = ScreenIdentity.uuid(for: screen) else { return false }
                return ScreenIdentity.normalize(id) == want
            }) {
                return hit
            }
            if !didWarnMissingScreen {
                didWarnMissingScreen = true
                Log.warn("浮层: 找不到 uuid=\(pinned) 的屏（没接上？），暂跟鼠标所在屏")
            }
        }
        // 鼠标位置用 `NSEvent.mouseLocation`（AppKit 全局坐标，左下原点）——
        // **不能**用热键回调里的 `CGEvent.location`：那是屏幕坐标、**左上原点**，混着算会选错屏幕（踩过）。
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.screens.first
    }
}
