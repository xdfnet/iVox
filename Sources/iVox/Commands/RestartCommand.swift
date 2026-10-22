import ArgumentParser
import Foundation
import iVoxKit

// `ivox restart`：只重启守护进程。改完 config.toml（热键等）跑一次即可生效。

/// 重启守护进程（`ivox restart`）。
///
/// **只重启进程，不碰自启开关**——`ivox on` 会 enable 自启、`ivox off` 会 disable 自启，
/// 都不是「重启」该干的事。这里只做 launchd 的 `kickstart -k`（杀掉旧的、拉起新的），
/// 守护进程会重新读一遍 config.toml，所以改完配置跑它就行。
///
/// job 没加载（本来就没在跑）时明确报错，让人去 `ivox on`，不静默把它拉起来——
/// 那会顺带打开登录自启，属于「重启」不该做的副作用。
struct RestartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart",
        abstract: "重启守护进程（改完 config.toml 后跑一次即生效）"
    )

    func run() throws {
        let target = LaunchAgent.guiTarget + "/" + LaunchAgent.label
        guard LaunchAgent.isJobLoaded else {
            print("⚠️  守护进程当前没在跑（launchd job 未加载），用 `ivox on` 启动")
            throw ExitCode.failure
        }

        let status = LaunchAgent.launchctl(["kickstart", "-k", target])
        guard status == 0 else {
            print("⚠️  launchctl kickstart 失败（exit \(status)）")
            throw ExitCode.failure
        }

        let socket = AppPaths.socketPath
        // 先等旧的真的退（socket 不再应答），再等新的起来。
        // 直接等「socket 可应答」会撞上旧进程还没死的窗口，误报「已重启」。
        for _ in 0..<20 where SocketClient.isRunning(path: socket) {
            Thread.sleep(forTimeInterval: 0.25)
        }
        // 等 socket 就绪（30s：模型加载 + 键盘层权限轮询实测要十几秒）
        for _ in 0..<120 {
            if SocketClient.isRunning(path: socket) {
                print("✓  守护进程已重启（配置已重新加载）")
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        print("⚠️  daemon 30s 内未就绪，请查看 \(AppPaths.daemonLogPath)")
        throw ExitCode.failure
    }
}
