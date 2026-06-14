import ArgumentParser
import Foundation

struct VersionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "显示 iVox 版本",
        version: iVoxVersion
    )

    func run() throws {
        print("iVox v\(iVoxVersion)")
        print("macOS 本地语音播报守护进程")
        print("纯 Swift · iLLM TTS · AVAudioEngine")
    }
}
