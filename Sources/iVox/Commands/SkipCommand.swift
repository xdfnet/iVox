import ArgumentParser
import Foundation
import iVoxKit

// CLI 子命令 ivox skip：跳过当前这一页 / 这一摞（Ctrl+2 / Ctrl+1 的命令行对应）。

/// 读下一页 / 跳过整摞，语义与两个热键完全一致——只是为了在不按热键的场合
/// （自检脚本、压测、远程排查）也能手动切页，热键路径本身不经过这里。
struct SkipCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skip",
        abstract: "读下一页（默认）或跳过整摞——Ctrl+2 / Ctrl+1 的命令行对应"
    )

    /// 跳整摞而不是下一页（对应 Ctrl+1）
    @Flag(name: .long, help: "跳过整摞（Ctrl+1），而不是读下一页（Ctrl+2）")
    var stack = false

    func run() {
        let socketPath = AppPaths.socketPath
        // daemon 没在跑就无事发生：跳过是锦上添花，不因它失败而报错
        guard SocketClient.isRunning(path: socketPath) else { return }
        // 尾随 \n 是必需的路由依据：handle 先按首行换行切出 header，
        // 缺了它整条请求会被当成传统整段播报体送进 handleTTS（`ivox quiet` 就踩在这条边界上）
        let message = "{type:skip,mode:\(stack ? "stack" : "page")}\n"
        try? SocketClient.send(message, to: socketPath)
    }
}
