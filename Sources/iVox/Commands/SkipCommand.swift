import ArgumentParser
import Foundation
import iVoxKit

// CLI 子命令 ivox skip：手动打断两档的命令行对应（掀页 / 全掀）。

/// 手动打断两档的命令行入口，与两个热键落到完全相同的那几个方法（热键只多一层按键识别）。
/// 存在的理由：不按热键也能验证与压测打断，也给排查留一个"从外面喊停"的开关。
/// 两个参数与两个快捷键一一对应；一个都不给按「掀页」那档，即与 Ctrl+1 同义。
struct SkipCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skip",
        abstract: "手动打断两档：--page 掀页（Ctrl+1）/ --all 全掀（Ctrl+2）"
    )

    /// 掀页，对应 Ctrl+1
    @Flag(name: .long, help: "掀页：丢掉正在听的那一页剩下的内容（Ctrl+1；缺省档）")
    var page = false

    /// 全掀，对应 Ctrl+2
    @Flag(name: .long, help: "全掀：停当前 + 清空排队（Ctrl+2）")
    var all = false

    func validate() throws {
        if [page, all].filter({ $0 }).count > 1 {
            throw ValidationError("--page / --all 只能给一个")
        }
    }

    func run() {
        let mode = all ? "all" : "page"
        let socketPath = AppPaths.socketPath
        // daemon 没在跑就无事发生：打断是锦上添花，不因它失败而报错
        guard SocketClient.isRunning(path: socketPath) else { return }
        // 尾随 \n 是必需的路由依据：handle 先按首行换行切出 header，
        // 缺了它整条请求会被当成传统整段播报体送进 handleTTS（会被原样念出来）
        // by：自报身份，让 daemon 的打断归因能答出「谁打断的」（见 ConnectionHandler.handleSkip）
        try? SocketClient.send("{type:skip,mode:\(mode),by:ivox-skip}\n", to: socketPath)
    }
}
