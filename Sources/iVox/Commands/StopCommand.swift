import ArgumentParser
import Foundation
import iVoxKit

struct StopCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "停止运行中的守护进程"
    )

    func run() throws {
        let socketPath = AppPaths.socketPath
        guard SocketClient.isRunning(path: socketPath) else {
            print("[✗] 守护进程未运行")
            throw ExitCode.failure
        }

        do {
            try SocketClient.send("__IVOX_STOP__", to: socketPath)
        } catch {
            print("[✗] 无法连接守护进程: \(error)")
            throw ExitCode.failure
        }

        // 轮询等待 socket 消失，确认进程真正退出（最多 ~10s）
        for _ in 0..<40 {
            if !SocketClient.isRunning(path: socketPath) {
                print("[✓] 守护进程已停止")
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        print("[✗] 守护进程未在超时内退出，请手动执行: pkill -f 'ivox serve'")
        throw ExitCode.failure
    }
}
