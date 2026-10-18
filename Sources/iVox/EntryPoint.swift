import ArgumentParser
import Foundation

// CLI 入口：注册全部子命令，默认子命令是 serve。

@main
struct iVox: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ivox",
        abstract: "本地语音播报守护进程，朗读 AI 编程工具的回复",
        subcommands: [
            OnCommand.self,
            OffCommand.self,
            StatusCommand.self,
            SpeakCommand.self,
            SkipCommand.self,
            QuickCommand.self,
            ASRCommand.self,
            VoiceCommand.self,
            WeChatCommand.self,
            TranslateCommand.self,
            VersionCommand.self,
            UpgradeCommand.self,
            ServeCommand.self,
        ],
        defaultSubcommand: ServeCommand.self
    )
}
