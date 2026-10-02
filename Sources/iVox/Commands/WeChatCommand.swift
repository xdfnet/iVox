import ArgumentParser
import Foundation

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
