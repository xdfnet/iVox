import ArgumentParser
import Foundation
import iVoxKit

/// 停止当前及排队中的播报（不退出守护进程）。
/// 挂在 UserPromptSubmit：用户一提交新 prompt 就立刻打断上一轮播报，
/// 对齐真人对话「你一开口，对方就停」；新回复完成后由 Stop hook 正常播报。
struct QuietCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quiet",
        abstract: "停止当前及排队播报（守护进程继续运行）"
    )

    func run() {
        let socketPath = AppPaths.socketPath
        // hook 场景：daemon 没在跑就当无事发生，绝不因打断失败影响用户提交
        guard SocketClient.isRunning(path: socketPath) else { return }
        try? SocketClient.send("__IVOX_STOP_PLAYBACK__", to: socketPath)
    }
}
