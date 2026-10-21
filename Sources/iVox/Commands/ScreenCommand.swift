import ArgumentParser
import Foundation
import iVoxKit

// CLI 子命令 ivox lock / ivox unlock：锁屏与解锁（走 HID 真键，见 ScreenControl）。
//
// 这两条**要报结果**，不像 skip/quick 那样打完就忘：锁屏/解锁是「开门」动作，
// 失败（设备不可达、密码不对）必须让人知道，不然会以为已经锁上了/已经解开了。

/// 锁屏（Ctrl+Cmd+Q）。
struct LockCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lock",
        abstract: "锁屏（Ctrl+Cmd+Q，走 HID 真键）"
    )

    func run() throws {
        try ScreenRequest.run(unlock: false)
    }
}

/// 解锁：唤醒屏幕 → 输密码 → 回车。
struct UnlockCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unlock",
        abstract: "解锁：唤醒屏幕并输入登录密码（走 HID 真键）"
    )

    func run() throws {
        try ScreenRequest.run(unlock: true)
    }
}

/// 两条命令共用的请求与结果解析。
private enum ScreenRequest {
    static func run(unlock: Bool) throws {
        let socketPath = AppPaths.socketPath
        guard SocketClient.isRunning(path: socketPath) else {
            throw ValidationError("iVox 守护进程没在跑（ivox on 启动它）")
        }
        let header = unlock ? "{type:unlock}\n" : "{type:lock}\n"
        let reply = try SocketClient.sendWithReply(
            header: Data(header.utf8), body: Data(), to: socketPath)
        guard let data = reply.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw ValidationError("守护进程回了个看不懂的答复")
        }
        guard object["result"] == "ok" else {
            let reason = object["error"] ?? "未知原因"
            throw ValidationError(unlock ? "解锁失败：\(reason)" : "锁屏失败：\(reason)")
        }
        print(unlock ? "已解锁" : "已锁屏")
    }
}
