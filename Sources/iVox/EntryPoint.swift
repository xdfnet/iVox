import ArgumentParser
import Foundation

@main
struct iVox: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ivox",
        abstract: "macOS 本地语音播报守护进程",
        subcommands: [
            ServeCommand.self,
            SpeakCommand.self,
            SayCommand.self,
            VoiceCommand.self,
            StopCommand.self,
            StatusCommand.self,
            VersionCommand.self,
            RestartCommand.self,
        ],
        defaultSubcommand: ServeCommand.self
    )
}
