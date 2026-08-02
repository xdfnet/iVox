import ArgumentParser
import Foundation
import iVoxKit

struct SayCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "say",
        abstract: "语音输入状态"
    )

    func run() throws {
        let socketPath = AppPaths.socketPath

        guard SocketClient.isRunning(path: socketPath) else {
            print("语音输入: 守护进程未运行")
            throw ExitCode.failure
        }
        print("语音输入: 守护进程运行中")
        print("按住右侧 ⌘ 说话，松开后自动粘贴")
    }
}
