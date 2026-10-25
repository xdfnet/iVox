import ArgumentParser
import Foundation
import iVoxKit

// CLI 子命令 ivox skip：手动打断三档的命令行对应（读下一页 / 跳整摞 / 全场闭嘴）。

/// 手动打断三档的命令行入口，与三个热键落到完全相同的那几个方法（热键只多一层按键识别）。
/// 存在的理由：不按热键也能验证与压测打断，也给排查留一个"从外面喊停"的开关。
/// 三个参数与三个快捷键一一对应；一个都不给按「轻」那档，即与 Ctrl+1 同义。
struct SkipCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skip",
        abstract: "手动打断三档：--page 读下一页（Ctrl+1）/ --stack 跳整摞（Ctrl+2）/ --all 全场闭嘴（Ctrl+3）"
    )

    /// 读下一页，对应 Ctrl+1
    @Flag(name: .long, help: "读下一页：丢掉当前页剩下的块（Ctrl+1；缺省档）")
    var page = false

    /// 跳整摞，对应 Ctrl+2
    @Flag(name: .long, help: "跳整摞：丢掉正在播的这一摞（含其后各页）（Ctrl+2）")
    var stack = false

    /// 全场闭嘴，对应 Ctrl+3
    @Flag(name: .long, help: "全场闭嘴：停当前 + 清空排队（Ctrl+3）")
    var all = false

    func validate() throws {
        if [page, stack, all].filter({ $0 }).count > 1 {
            throw ValidationError("--page / --stack / --all 只能给一个")
        }
    }

    func run() {
        let mode = all ? "all" : (stack ? "stack" : "page")
        let socketPath = AppPaths.socketPath
        // daemon 没在跑就无事发生：打断是锦上添花，不因它失败而报错
        guard SocketClient.isRunning(path: socketPath) else { return }
        // 尾随 \n 是必需的路由依据：handle 先按首行换行切出 header，
        // 缺了它整条请求会被当成传统整段播报体送进 handleTTS（会被原样念出来）
        try? SocketClient.send("{type:skip,mode:\(mode)}\n", to: socketPath)
    }
}
