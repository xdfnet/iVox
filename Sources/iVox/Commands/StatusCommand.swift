import ArgumentParser
import Foundation
import iVoxKit

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "查看守护进程运行状态：功能开关与权限"
    )

    func run() throws {
        let socketPath = AppPaths.socketPath

        guard SocketClient.isRunning(path: socketPath) else {
            print("未运行")
            return
        }

        let header = Data("{type:status}\n".utf8)
        let json = try SocketClient.sendWithReply(header: header, body: Data(), to: socketPath)
        guard let data = json.data(using: .utf8),
              let status = try? JSONDecoder().decode(DaemonStatus.self, from: data) else {
            print("运行中（状态解析失败）")
            return
        }
        render(status)
    }

    private func render(_ s: DaemonStatus) {
        print("iVox \(s.version)")
        print()
        print("功能")
        print("  语音输入    \(health(s.features.speechInput))")
        print("  微信桥接    \(health(s.features.wechat))")
        print("  媒体控制    \(health(s.features.mediaControl))")
        print("  Web UI      \(health(s.features.mediaHTTP))")
        print()
        print("权限")
        print("  麦克风      \(micText(s.permissions.microphone))")
        print("  设备控制    \(s.permissions.deviceControl ? "已授权" : "未授权")")
    }

    /// ok → 正常；off → 未启用；error:xxx → 异常(xxx)
    private func health(_ value: String) -> String {
        if value == "ok" { return "✓ 正常" }
        if value == "off" { return "— 未启用" }
        if value.hasPrefix("error:") { return "✗ 异常（\(value.dropFirst(6))）" }
        return value
    }

    private func micText(_ value: String) -> String {
        switch value {
        case "authorized": return "已授权"
        case "denied": return "未授权"
        case "notDetermined": return "未决定"
        case "restricted": return "受限"
        default: return value
        }
    }
}
