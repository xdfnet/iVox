import ArgumentParser
import Foundation

/// `ivox wechat`：微信桥的子命令组（`setup` 扫码登录 / `status` 查状态）。
struct WeChatCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wechat",
        abstract: "管理微信桥接",
        subcommands: [
            WeChatSetupCommand.self,
            WeChatStatusCommand.self,
        ],
        defaultSubcommand: WeChatStatusCommand.self
    )
}
