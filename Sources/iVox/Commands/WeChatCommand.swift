import ArgumentParser
import Foundation

// CLI 子命令 ivox wechat：微信桥管理。

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
