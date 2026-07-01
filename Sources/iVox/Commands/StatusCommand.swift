import ArgumentParser
import Foundation
import iVoxKit

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "查看守护进程运行状态"
    )

    func run() throws {
        let socketPath = NSString(string: "~/.config/ivox/ivox.sock").expandingTildeInPath

        guard SocketClient.isRunning(path: socketPath) else {
            print("状态: 未运行")
            return
        }
        print("状态: 运行中")
        print("Socket: \(socketPath)")
    }
}
