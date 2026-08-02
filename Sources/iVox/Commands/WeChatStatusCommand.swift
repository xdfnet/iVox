import ArgumentParser
import Foundation
import iVoxKit

// MARK: - ivox wechat status — 微信状态

struct WeChatStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "查看微信配置状态"
    )

    func run() throws {
        guard let cfg = try? loadConfig(), let wechat = cfg.wechat else {
            print("🔴 微信未配置")
            print("运行 ivox wechat setup 进行配置")
            return
        }

        print("iVox 微信桥接")
        print()

        if wechat.enabled {
            print("🟢 微信已配置")
            print("   Token: \(wechat.token.prefix(16))…")
            print("   接口: \(wechat.baseURL)")
            if !wechat.allowFrom.isEmpty {
                print("   允许用户: \(wechat.allowFrom)")
            }
        } else {
            print("🔴 微信未配置")
        }

        print()

        // 检查 daemon 是否运行
        let socketPath = AppPaths.socketPath
        var st = stat()
        if stat(socketPath, &st) == 0 {
            print("🟢 守护进程运行中")
        } else {
            print("🔴 守护进程未运行")
        }

        if !wechat.enabled {
            print()
            print("运行 ivox wechat setup 配置微信")
        }
    }
}
