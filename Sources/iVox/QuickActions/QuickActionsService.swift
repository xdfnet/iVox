import CoreGraphics
import Foundation
import iVoxKit

/// QuickActions —— 从 Finder 当前目录出发做一件事：开终端、拉起编码工具、复制路径。
///
/// 对应五个热键：
/// - `Opt+Z` 在 Finder 当前目录打开终端
/// - `Opt+A` / `Opt+Q` / `Opt+W` 打开终端并分别执行 `claude` / `qwen` / `codex`
/// - `Opt+C` 把 Finder 选中项（文件/文件夹）的路径写进剪贴板
///
/// 它和划词翻译同为「用户按了组合键」的入口，但**是两个能力域**，所以独立成目录：
/// `Translation/` 管文本工具，`QuickActions/` 管这类系统快捷。`Daemon` 只按归属分派。
///
/// TODO（Phase 4）：接 Finder 取路径 + 开终端。控 Terminal 计划用 `open -a Terminal <dir>`
/// 与临时 `.command` 文件——这样免掉对 Terminal 的 Automation 授权，也避开 iDict 原有的双窗问题
///（其记录见 `iDict/Docs/AppleScript-Terminal-Launch-vs-Activate.md`）。
@MainActor
final class QuickActionsService {
    func handle(_ hotKey: GlobalKeyTap.HotKey, at location: CGPoint) async {
        Log.info("QuickActions 尚未接入: \(hotKey)")
    }
}
