import ArgumentParser
import Foundation
import iVoxKit

struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "启动守护进程，监听 Unix Socket 播报请求"
    )

    func run() async throws {
        let socketPath = AppPaths.socketPath
        if SocketClient.isRunning(path: socketPath) {
            print("[✗] 守护进程已在运行，使用 'ivox off' 停止后再启动前台进程")
            throw ExitCode.failure
        }

        let config: Config
        do {
            config = try loadConfig()
        } catch {
            print("[✗] 配置加载失败: \(error)")
            print("请先运行: make")
            throw ExitCode.failure
        }

        let daemon = Daemon(config: config)
        try await daemon.run()
    }
}
