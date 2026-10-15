import AppKit
import CoreGraphics
import Foundation
import iVoxKit

// 快速操作：Finder 与终端的组合键。

/// QuickActions —— 从 Finder 当前目录出发做一件事：开终端、拉起编码工具、复制路径。
///
/// 对应五个热键：
/// - `Opt+Z` 在 Finder 当前目录打开终端
/// - `Opt+A` / `Opt+X` / `Opt+Q` 打开终端并分别执行 `claude` / `codex` / `pi`
/// - `Opt+C` 把 Finder 选中项的路径写进剪贴板
///
/// 它和划词翻译同为「用户按了组合键」的入口，但**是两个能力域**：`Translation/` 管文本工具，
/// `QuickActions/` 管这类系统快捷，`Daemon` 只按归属分派。
///
/// 开终端走 **Ghostty**：它的 `--working-directory` + `-e` 是原生 CLI 参数，一条
/// LaunchServices 调用就够了，不需要临时文件、也不需要 Terminal 的 Automation 授权。
/// （用 Terminal.app 时这两样总得沾一样：AppleScript `do script` 要多一份 Automation 授权
/// 且 iDict 时代有双窗问题；写临时 `.command` 则要额外做回收和 mtime 竞态处理。Ghostty
/// 把这条路直接打通了。）
/// 取 Finder 路径仍走 AppleScript——这是唯一需要 Automation 的地方，面积很小。
@MainActor
final class QuickActionsService {
    private static let ghosttyApp = URL(fileURLWithPath: "/Applications/Ghostty.app")

    func handle(_ hotKey: GlobalKeyTap.HotKey, at location: CGPoint) async {
        switch hotKey {
        case .translate:
            break   // 不属于本域；Daemon 分派时已排除，这里只是穷举
        case .openTerminal:
            await openTerminal(running: nil)
        case .openTerminalClaude:
            await openTerminal(running: "claude")
        case .openTerminalCodex:
            await openTerminal(running: "codex")
        case .openTerminalPi:
            await openTerminal(running: "pi")
        case .copyPath:
            copySelectedPath()
        case .escInterrupt:
            break   // 不属于本域；Daemon 分派时已处理打断，这里只是穷举
        }
    }

    // MARK: - 开终端

    private func openTerminal(running command: String?) async {
        guard let dir = finderPath(preferContainer: true), !dir.isEmpty else {
            Log.warn("QuickActions: 取不到 Finder 目录")
            return
        }
        // 参数经 `NSWorkspace.OpenConfiguration` 下发（等价于 `open -na Ghostty.app --args …`，
        // macOS 上官方就这一条路——Ghostty 不支持直接从 CLI 启动终端）。
        // **必须配 createsNewApplicationInstance**：复用已运行的 Ghostty 实例时参数会被
        // 静默忽略（实测：带 -n 生效、不带则命令根本不跑），只有新实例收得到。
        var args = ["--working-directory=\(dir)"]
        if let command {
            // 经 login shell 跑：Ghostty 的 `-e` 是直接 exec，继承不到用户 PATH
            // （/opt/homebrew/bin、~/.local/bin 都不在 launchd 给 GUI 的最小 PATH 里）。
            args += ["-e", "/bin/zsh", "-lc", command]
        }
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = args
        config.createsNewApplicationInstance = true
        do {
            try await NSWorkspace.shared.openApplication(at: Self.ghosttyApp, configuration: config)
            if let command {
                Log.info("QuickActions: 在 \(dir) 执行 \(command)")
            } else {
                Log.info("QuickActions: 在 \(dir) 打开终端")
            }
        } catch {
            Log.warn("QuickActions: 打开 Ghostty 失败（装了没？brew install --cask ghostty）: \(error.localizedDescription)")
        }
    }

    // MARK: - 复制路径

    private func copySelectedPath() {
        guard let path = finderPath(preferContainer: false), !path.isEmpty else {
            Log.warn("QuickActions: 取不到 Finder 选中项")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        Log.info("QuickActions: 已复制路径 \(path)")
    }

    // MARK: - Finder 取路径

    /// - Parameter preferContainer: 选中项是文件时，是否取其所在目录（开终端用 true，复制路径用 false）
    private func finderPath(preferContainer: Bool) -> String? {
        let inner: String
        if preferContainer {
            inner = """
            set sel to selection
            if sel ≠ {} then
                set theItem to item 1 of sel
                if class of theItem is folder then
                    return POSIX path of (theItem as alias)
                else
                    return POSIX path of (container of theItem as alias)
                end if
            else
                try
                    return POSIX path of (target of front Finder window as alias)
                on error
                    return POSIX path of (path to desktop folder)
                end try
            end if
            """
        } else {
            inner = """
            set sel to selection
            if sel = {} then
                try
                    set sel to {target of front Finder window as alias}
                on error
                    set sel to {path to desktop folder}
                end try
            end if
            return POSIX path of (item 1 of sel as alias)
            """
        }

        let source = "tell application \"Finder\"\n\(inner)\nend tell"
        guard let script = NSAppleScript(source: source) else {
            Log.warn("QuickActions: AppleScript 构造失败")
            return nil
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            Log.warn("QuickActions: 读取 Finder 失败（可能未授予自动化权限）\(error)")
            return nil
        }
        return result.stringValue
    }
}
