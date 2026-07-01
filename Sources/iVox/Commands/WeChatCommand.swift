import ArgumentParser
import Foundation

struct WeChatCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wechat",
        abstract: "微信消息桥接",
        subcommands: [
            WeChatTextCommand.self,
            WeChatSetupCommand.self,
            WeChatStatusCommand.self,
        ],
        defaultSubcommand: WeChatStatusCommand.self
    )
}
