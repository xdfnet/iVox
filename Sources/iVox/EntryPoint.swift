import ArgumentParser
import Foundation

@main
struct iVox: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ivox",
        abstract: "本地语音播报守护进程，朗读 AI 编程工具的回复",
        subcommands: [
            StartCommand.self,
            StopCommand.self,
            RestartCommand.self,
            StatusCommand.self,
            SpeakCommand.self,
            ASRCommand.self,
            VoiceCommand.self,
            WeChatCommand.self,
            VersionCommand.self,
            ServeCommand.self,
        ],
        defaultSubcommand: ServeCommand.self
    )
}
