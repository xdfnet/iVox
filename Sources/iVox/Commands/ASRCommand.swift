import ArgumentParser
import Foundation
import iVoxKit

struct ASRCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "listen",
        abstract: "语音识别（WAV → 文本）"
    )

    private static let maxAudioBytes = 100 * 1024 * 1024

    @Option(name: .shortAndLong, help: "语言 (zh/en)")
    var lang: String = "zh"

    @Option(name: .shortAndLong, help: "WAV 文件路径")
    var file: String?

    func run() async throws {
        guard !lang.isEmpty, lang.allSatisfy(\.isLetter) else {
            fputs("✗ 语言参数无效: \(lang)\n", stderr)
            throw ExitCode.failure
        }

        let wavData: Data
        if let path = file {
            wavData = try Data(contentsOf: URL(fileURLWithPath: path))
        } else {
            // 分块读 stdin，限制上限防止内存耗尽
            var buf = Data()
            while let chunk = try FileHandle.standardInput.read(upToCount: 1 << 20), !chunk.isEmpty {
                buf.append(chunk)
                if buf.count > Self.maxAudioBytes {
                    fputs("✗ 音频数据超过 100MB 上限\n", stderr)
                    throw ExitCode.failure
                }
            }
            wavData = buf
        }
        guard !wavData.isEmpty else {
            fputs("✗ 无音频数据\n", stderr)
            throw ExitCode.failure
        }

        let socketPath = AppPaths.socketPath
        let header = "{type:asr,lang:\(lang)}\n".data(using: .utf8)!
        let result = try SocketClient.sendWithReply(header: header, body: wavData, to: socketPath)
        fputs(result + "\n", stderr)
    }
}
