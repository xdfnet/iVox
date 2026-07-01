import ArgumentParser
import Foundation
import iVoxKit

struct ASRCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "listen",
        abstract: "语音识别（WAV → 文本）"
    )

    @Option(name: .shortAndLong, help: "语言 (zh/en)")
    var lang: String = "zh"

    @Option(name: .shortAndLong, help: "WAV 文件路径")
    var file: String?

    func run() async throws {
        let wavData: Data
        if let path = file {
            wavData = try Data(contentsOf: URL(fileURLWithPath: path))
        } else {
            wavData = FileHandle.standardInput.readDataToEndOfFile()
        }
        guard !wavData.isEmpty else {
            fputs("✗ 无音频数据\n", stderr)
            throw ExitCode.failure
        }

        let socketPath = NSString(string: "~/.config/ivox/ivox.sock").expandingTildeInPath
        let header = "{type:asr,lang:\(lang)}\n".data(using: .utf8)!
        let result = try SocketClient.sendWithReply(header: header, body: wavData, to: socketPath)
        fputs(result + "\n", stderr)
    }
}
