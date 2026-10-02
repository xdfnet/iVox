import ArgumentParser
import Foundation
import iVoxKit

struct SayCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "say",
        abstract: "查看语音输入是否可用"
    )

    func run() throws {
        let socketPath = AppPaths.socketPath

        guard SocketClient.isRunning(path: socketPath) else {
            print("错误: 守护进程未运行")
            throw ExitCode.failure
        }
        print("守护进程运行中")
        print("按住右侧 ⌘ 说话，松开后自动粘贴")
    }
}
