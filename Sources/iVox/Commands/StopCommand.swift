import ArgumentParser
import Foundation

struct StopCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "停止运行中的守护进程"
    )

    func run() throws {
        let socketPath = NSString(string: "~/.config/ivox/ivox.sock").expandingTildeInPath
        do {
            try SocketClient.send("__IVOX_STOP__", to: socketPath)
            print("[✓] 已发送停止指令")
        } catch {
            throw CleanExit.message("无法连接守护进程: \(error)")
        }
    }
}
