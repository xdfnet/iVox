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
            RestartCommand.self,
            InitConfigCommand.self,
            StatusCommand.self,
            SpeakCommand.self,
            SkipCommand.self,
            QuickCommand.self,
            LockCommand.self,
            UnlockCommand.self,
            ASRCommand.self,
            VoiceCommand.self,
            WeChatCommand.self,
            TranslateCommand.self,
            VersionCommand.self,
            UpdateCommand.self,
            ServeCommand.self,
            TTSCommand.self,
        ],
        defaultSubcommand: ServeCommand.self
    )
}
