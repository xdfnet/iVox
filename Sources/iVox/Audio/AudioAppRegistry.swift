import Foundation

/// 受支持应用的注册表（硬编码路径 + Bundle ID）
enum AudioAppRegistry {
    struct AppInfo: Sendable {
        let displayName: String
        let shortName: String
        let path: String
        let bundleID: String
    }

    private static let supported: [AppInfo] = [
        AppInfo(displayName: "抖音", shortName: "douyin", path: "/Applications/抖音.app", bundleID: "com.bytedance.douyin.desktop"),
        AppInfo(displayName: "汽水音乐", shortName: "qishui", path: "/Applications/汽水音乐.app", bundleID: "com.soda.music"),
    ]

    /// 按 displayName / shortName / bundleID 查找（大小写不敏感）
    static func find(by name: String) -> AppInfo? {
        let lower = name.lowercased()
        return supported.first {
            $0.displayName == name ||
            $0.shortName == lower ||
            $0.bundleID.lowercased() == lower
        }
    }

    static func bundleID(for name: String) -> String {
        find(by: name)?.bundleID ?? "com.unknown.\(name.lowercased())"
    }
}
