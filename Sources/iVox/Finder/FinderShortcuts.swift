import CoreGraphics
import Foundation
import iVoxKit

/// Finder / 终端快捷（Opt+Z / Opt+A / Opt+Q / Opt+W / Opt+C）。
///
/// 它和划词翻译同为「用户按了组合键」的入口，但**不是翻译功能**——是独立的一层系统快捷，
/// 所以单独成文件、单独装配，不与 `Translation/` 混在一起。
///
/// TODO（Phase 4）：取 Finder 当前目录 / 选中项 → 开 Terminal 或把路径写进剪贴板。
/// 控 Terminal 计划用 `open -a Terminal <dir>` 与临时 `.command` 文件，
/// 这样不必申请 Terminal 的 Automation 权限（iDict 原做法见其 `Docs/AppleScript-Terminal-Launch-vs-Activate.md`）。
@MainActor
final class FinderShortcuts {
    func handle(_ hotKey: GlobalKeyTap.HotKey, at location: CGPoint) async {
        Log.info("Finder 快捷尚未接入: \(hotKey)")
    }
}
