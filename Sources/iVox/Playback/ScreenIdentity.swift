import AppKit
import CoreGraphics

// 屏的身份：每块屏的持久 UUID 与可读描述——用来把「字幕钉在哪块屏」钉死。

/// 一块屏的稳定身份与描述。
///
/// **为什么是 UUID，而不是序号 / 型号 / 坐标**：macOS 给每块屏分配一个由 EDID 派生的持久 UUID。
/// 同一台机器上两块同型号、同分辨率、同序列号的屏（实测两块 Redmi 27 NU 在 vendor/model/serial
/// 上完全相同）在 UUID 上却不同；而系统自己就用这个 UUID 记屏幕摆位——拔插、重启、改分辨率、
/// 重排摆放都不变。序号会随插拔重排漂移，坐标会随摆放变，型号分不出同款的两块。
@MainActor
enum ScreenIdentity {
    /// 该屏的 UUID（大写带连字符）；取不到时返回 nil（无 EDID 的虚拟屏等）。
    static func uuid(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        let raw = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value))?.takeRetainedValue()
        guard let raw else { return nil }
        return CFUUIDCreateString(nil, raw) as String
    }

    /// 归一化：去连字符 + 大写——配置里带不带横线、大小写怎么写都认得出同一块屏。
    static func normalize(_ raw: String) -> String {
        raw.uppercased().filter { $0 != "-" }
    }

    /// 人看的描述：型号 + 尺寸 + UUID（打日志用）。
    static func describe(_ screen: NSScreen) -> String {
        let size = "\(Int(screen.frame.width))×\(Int(screen.frame.height))"
        return "\(screen.localizedName) \(size) uuid=\(uuid(for: screen) ?? "无")"
    }

    /// 当前所有屏的清单（一行，冒号分隔）——打日志让人能查到该填哪个 UUID。
    static func inventory() -> String {
        NSScreen.screens.enumerated()
            .map { "\($0.offset + 1)) \(describe($0.element))" }
            .joined(separator: " | ")
    }
}
