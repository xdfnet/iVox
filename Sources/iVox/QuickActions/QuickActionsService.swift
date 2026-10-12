import AppKit
import CoreGraphics
import Foundation
import iVoxKit

// 快速操作：Finder 与终端的组合键。

/// QuickActions —— 从 Finder 当前目录出发做一件事：开终端、拉起编码工具、复制路径。
///
/// 对应五个热键：
/// - `Opt+Z` 在 Finder 当前目录打开终端
/// - `Opt+A` / `Opt+Q` / `Opt+W` 打开终端并分别执行 `claude` / `qwen` / `codex`
/// - `Opt+C` 把 Finder 选中项的路径写进剪贴板
///
/// 它和划词翻译同为「用户按了组合键」的入口，但**是两个能力域**：`Translation/` 管文本工具，
/// `QuickActions/` 管这类系统快捷，`Daemon` 只按归属分派。
///
/// 控 Terminal 刻意**不用** AppleScript `do script`（那要 Terminal 的 Automation 授权，
/// 且 iDict 时代有双窗问题）：开终端用 `open -a Terminal <dir>`，要跑命令则先写一个临时
/// `.command` 文件再 `open` 它。取 Finder 路径仍走 AppleScript（这是唯一需要 Automation 的地方，
/// 面积很小）。
@MainActor
final class QuickActionsService {
    private static let terminalApp = URL(
        fileURLWithPath: "/System/Applications/Utilities/Terminal.app")

    func handle(_ hotKey: GlobalKeyTap.HotKey, at location: CGPoint) async {
        switch hotKey {
        case .translate:
            break   // 不属于本域；Daemon 分派时已排除，这里只是穷举
        case .openTerminal:
            await openTerminal(running: nil)
        case .openTerminalClaude:
            await openTerminal(running: "claude")
        case .openTerminalQwen:
            await openTerminal(running: "qwen")
        case .openTerminalCodex:
            await openTerminal(running: "codex")
        case .copyPath:
            copySelectedPath()
        }
    }

    // MARK: - 开终端

    private func openTerminal(running command: String?) async {
        guard let dir = finderPath(preferContainer: true), !dir.isEmpty else {
            Log.warn("QuickActions: 取不到 Finder 目录")
            return
        }
        do {
            if let command {
                let script = try makeCommandFile(directory: dir, command: command)
                try await NSWorkspace.shared.open(
                    [script], withApplicationAt: Self.terminalApp, configuration: .init())
                Log.info("QuickActions: 在 \(dir) 执行 \(command)")
            } else {
                try await NSWorkspace.shared.open(
                    [URL(fileURLWithPath: dir)], withApplicationAt: Self.terminalApp, configuration: .init())
                Log.info("QuickActions: 在 \(dir) 打开终端")
            }
        } catch {
            Log.warn("QuickActions: 打开终端失败 \(error.localizedDescription)")
        }
    }

    /// 写一个可执行的 `.command`（Terminal 会执行它），放在缓存目录里。
    /// 不直接用 `do script` 是因为那需要 Terminal 的 Apple Events 授权。
    private func makeCommandFile(directory: String, command: String) throws -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/ivox", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cleanupOldCommandFiles(in: dir)

        let url = dir.appendingPathComponent("quickaction-\(UUID().uuidString.prefix(8)).command")
        let script = """
        #!/bin/zsh
        cd \(shellQuote(directory)) && exec \(command)
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// 回收上次留下的 `.command`：它们只是把命令喂给 Terminal 的载体，喂完就没用了。
    /// 只删**超过 1 分钟**的——刚写下的那个可能正被 Terminal 读取，删早了会执行到空文件。
    private func cleanupOldCommandFiles(in dir: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for url in items where url.lastPathComponent.hasPrefix("quickaction-") {
            guard let mtime = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate else { continue }
            if Date().timeIntervalSince(mtime) > 60 {
                try? fm.removeItem(at: url)
            }
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
