import ArgumentParser
import Foundation
import iVoxKit

// CLI 子命令 ivox playback：播报总开关——单独关掉播报，守护进程与其余能力照常。

/// 播报总开关的命令行入口。
///
/// 与 `ivox off` 的区别：那个停整个守护进程（热键、微信、Web 控制台一起没）；
/// 这个**只关播报**——正在念的立刻闭嘴、排队的内容清空、之后进来的内容一律丢弃，
/// 其余能力照常在跑。
///
/// 状态写在 config.toml 的 `playback.enabled` 里（**配置是真源**）：改完重启仍然生效；
/// 运行时那一下由 socket 帧 `{type:playback,enabled:0|1}` 立刻生效，不必重启。
struct PlaybackCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "playback",
        abstract: "播报总开关：单独关掉播报（守护进程与其余能力照常）"
    )

    /// on / off；省略则只看当前状态
    @Argument(help: "on 打开 / off 关闭（省略则显示当前状态）")
    var state: String?

    func validate() throws {
        guard let state else { return }
        let s = state.lowercased()
        guard s == "on" || s == "off" else {
            throw ValidationError("只认 on / off")
        }
    }

    func run() throws {
        guard let state else {
            printStatus()
            return
        }
        let enabled = state.lowercased() == "on"
        try writeConfig(enabled)
        notifyDaemon(enabled)
        print(enabled ? "播报已打开" : "播报已关闭：正在念的停了，排队的清空，之后进来的内容不念")
    }

    // MARK: - 配置（真源）

    /// 就地改 config.toml 的 `playback.enabled`——**保留用户自己写的注释**（整体重排会冲掉）。
    private func writeConfig(_ enabled: Bool) throws {
        let path = ConfigFile.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw ValidationError("找不到配置 \(path)，先跑一次 `ivox init-config`")
        }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let doc = try TOMLDocument.parse(text, order: ConfigAudit.sectionOrder)
        let updated = doc.setting(.boolean(enabled), forKey: "playback.enabled")
        try updated.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - 运行时（立刻生效）

    /// 通知守护进程马上切换。daemon 没在跑就算了——配置已经改好，下次启动自然生效。
    private func notifyDaemon(_ enabled: Bool) {
        let socketPath = AppPaths.socketPath
        guard SocketClient.isRunning(path: socketPath) else { return }
        // 尾随 \n 是必需的路由依据（见 SkipCommand 的注释）
        try? SocketClient.send("{type:playback,enabled:\(enabled ? 1 : 0)}\n", to: socketPath)
    }

    // MARK: - 状态

    private func printStatus() {
        print("播报")
        let running = SocketClient.isRunning(path: AppPaths.socketPath)
        if running {
            let runtime = runtimeState()
            print("  运行时    \(runtime ?? "未知")")
        } else {
            print("  运行时    守护进程未运行")
        }
        print("  配置      playback.enabled = \(configState())（重启后仍然照它走）")
    }

    /// 运行时状态：问守护进程的 status（`features.playback` 为 "off" 即关着）。
    private func runtimeState() -> String? {
        guard let reply = try? SocketClient.sendWithReply(header: Data("{type:status}\n".utf8),
                                                          body: Data(),
                                                          to: AppPaths.socketPath),
              let data = reply.data(using: .utf8),
              let status = try? JSONDecoder().decode(DaemonStatus.self, from: data) else { return nil }
        return status.features.playback == "off" ? "已关闭" : "已打开"
    }

    /// 配置里的值：没写就是开着（默认值在代码里，见 `PlaybackConfig.defaultEnabled`）。
    private func configState() -> String {
        guard let config = try? loadConfig() else { return "读不到" }
        return config.resolvedPlayback.resolvedEnabled ? "true" : "false"
    }
}
