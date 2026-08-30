import ArgumentParser
import Foundation
import iVoxKit

struct StartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "启动守护进程（后台运行）"
    )

    func run() throws {
        let socketPath = AppPaths.socketPath
        if SocketClient.isRunning(path: socketPath) {
            print("[✓] 守护进程已在运行")
            return
        }

        let launcher = AppPaths.binDir + "/ivox"
        guard FileManager.default.fileExists(atPath: launcher) else {
            print("[✗] 未找到 ivox 二进制: \(launcher)，请先运行: make update")
            throw ExitCode.failure
        }

        // 清理残留 socket（进程已不在时防止误判 / bind 冲突）
        try? FileManager.default.removeItem(atPath: socketPath)

        let configDir = AppPaths.configDir
        try FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        let logPath = configDir + "/daemon.log"

        // nohup 后台拉起，脱离终端会话（关终端 / SIGHUP 不影响守护进程）
        let cmd = "nohup '\(launcher)' serve >> '\(logPath)' 2>&1 < /dev/null &"
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", cmd]
        do {
            try shell.run()
            shell.waitUntilExit()
        } catch {
            print("[✗] 启动失败: \(error)")
            throw ExitCode.failure
        }

        // 轮询等待 socket 就绪（最多 ~10s），确认进程真正启动
        for _ in 0..<40 {
            if SocketClient.isRunning(path: socketPath) {
                print("[✓] 守护进程已启动")
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        print("[✗] 启动失败，请查看日志: \(logPath)")
        throw ExitCode.failure
    }
}
