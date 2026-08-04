import ArgumentParser
import Foundation
import iVoxKit

struct StopCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "停止运行中的守护进程"
    )

    func run() throws {
        let domain = "gui/\(getuid())"
        let label = "com.user.ivox"

        // launchd bootout 才能真正停止：移除 job 后 KeepAlive 不会再拉起
        if runLaunchctl(["bootout", domain + "/" + label]) {
            waitForStop(socketPath: AppPaths.socketPath)
            print("[✓] 守护进程已停止")
            return
        }

        // 未注册 launchd（如 nohup 手动运行）时，退回 socket 停止信号
        let socketPath = AppPaths.socketPath
        if SocketClient.isRunning(path: socketPath) {
            do {
                try SocketClient.send("__IVOX_STOP__", to: socketPath)
                print("[✓] 守护进程已停止")
                return
            } catch {
                print("[✗] 无法连接守护进程: \(error)")
                throw ExitCode.failure
            }
        }
        print("[✗] 守护进程未运行")
        throw ExitCode.failure
    }

    /// 轮询等待 socket 消失，确认进程真正退出（bootout 移除 job 后进程退出是异步的）
    private func waitForStop(socketPath: String) {
        for _ in 0..<20 {
            if !SocketClient.isRunning(path: socketPath) { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        // 5s 超时：job 已移除不会自动拉起，进程仍在退出中
    }

    private func runLaunchctl(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return false
        }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
