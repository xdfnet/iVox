import ArgumentParser
import Foundation
import iVoxKit

/// 快速操作的命令行入口：键盘上的 Opt+Q/A/X/S/C 五个，在这里都有对应的第二扇门。
///
/// 动作**由 daemon 执行**，不在本进程里做——它们要摸主线程（AppleScript 取 Finder 选中项、
/// `NSPasteboard` 写剪贴板）。这条命令还有一个实际用处：`copy-path` 会调 AppleScript，
/// 与 TTS 合成并发时曾把 MLX 撞崩过（2026-10-18 实测两次 `mutex lock failed`），
/// 而崩溃在 daemon 里、外面只表现为「一摞没念完」。有这条命令就能自动复现，不必手按热键。
struct QuickCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quick",
        abstract: "快速操作：terminal 开终端 / claude codex pi 开对应会话的终端 / copy-path 复制 Finder 选中路径（对应 Opt+Q/A/X/S/C）"
    )

    @Argument(help: ArgumentHelp(
        "copy-path",
        discussion: """
        terminal        开一个终端（Opt+Q）
        claude          开终端并跑 claude（Opt+A）
        codex           开终端并跑 codex（Opt+X）
        pi              开终端并跑 pi（Opt+S）
        copy-path       把 Finder 选中项的路径复制到剪贴板（Opt+C）
        """))
    var action: String

    static let validActions = ["terminal", "claude", "codex", "pi", "copy-path"]

    func validate() throws {
        guard Self.validActions.contains(action) else {
            throw ValidationError("未知动作「\(action)」。可选：\(Self.validActions.joined(separator: " / "))")
        }
    }

    func run() {
        let socketPath = AppPaths.socketPath
        // daemon 没在跑就无事发生：这些动作本来就是随手按的快捷键，不该因为服务不在而报错
        guard SocketClient.isRunning(path: socketPath) else { return }
        // 尾随 \n 是必需的路由依据：handle 先按首行换行切出 header，缺了它整条请求会被
        // 当成传统整段播报体送进 handleTTS（会被原样念出来）。
        try? SocketClient.send("{type:quick,action:\(action)}\n", to: socketPath)
    }
}
