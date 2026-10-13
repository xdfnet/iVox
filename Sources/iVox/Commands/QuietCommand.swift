import ArgumentParser
import Foundation
import iVoxKit

// CLI 子命令 ivox quiet：打断当前播报。

/// 停止当前及排队中的播报（不退出守护进程）。
/// 挂在 UserPromptSubmit：用户一提交新 prompt 就立刻打断上一轮播报，
/// 对齐真人对话「你一开口，对方就停」；新回复完成后由 Stop hook 正常播报。
struct QuietCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quiet",
        abstract: "停止当前及排队播报（守护进程继续运行）"
    )

    /// 声明打断来源（如 claude/codex/qwen），daemon 会记进日志；缺省发无来源的裸哨兵
    @Option(name: .long, help: "声明打断来源（可选，如 claude）")
    var source: String?

    func run() {
        let socketPath = AppPaths.socketPath
        // hook 场景：daemon 没在跑就当无事发生，绝不因打断失败影响用户提交
        guard SocketClient.isRunning(path: socketPath) else { return }
        let message: String
        if let source, !source.isEmpty {
            message = "{type:stop,source:\(source)}"
        } else {
            message = "{type:stop}"
        }
        try? SocketClient.send(message, to: socketPath)
    }
}
