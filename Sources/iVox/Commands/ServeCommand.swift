import ArgumentParser
import Foundation
import iVoxKit

// CLI 子命令 ivox serve：前台运行守护进程。

struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "以前台模式运行守护进程（供 LaunchAgent 拉起）"
    )

    func run() async throws {
        // 模型全部走本地目录，不依赖 Hub：设离线标志，避免任何启动期联网检查卡顿
        // （防御性：当前 Swift 依赖栈主要靠「本地目录」判据，这两个变量也惠及子进程透传）
        setenv("HF_HUB_OFFLINE", "1", 1)
        setenv("TRANSFORMERS_OFFLINE", "1", 1)

        let socketPath = AppPaths.socketPath
        if SocketClient.isRunning(path: socketPath) {
            print("错误: 守护进程已在运行，使用 ivox off 停止后再启动前台进程")
            throw ExitCode.failure
        }

        let config: Config
        do {
            config = try loadConfig()
        } catch {
            print("错误: 配置加载失败: \(error)")
            print("请先运行 make")
            throw ExitCode.failure
        }

        let daemon = Daemon(config: config)
        try await daemon.run()
    }
}
