import ArgumentParser
import Foundation
import iVoxKit

struct SpeakCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "speak",
        abstract: "一次性播报文本"
    )

    @Option(name: .shortAndLong, help: "来源标识 (claude/codex/qwen)")
    var source: String?

    @Option(name: .shortAndLong, help: "音色 ID")
    var voice: String?

    @Argument(help: "要播报的文本")
    var text: String

    func run() async throws {
        let socketPath = AppPaths.socketPath
        var parts: [String] = []
        if let source, !source.isEmpty { parts.append("source:\(source)") }
        if let voice, !voice.isEmpty { parts.append("voice:\(voice)") }
        let prefix = parts.isEmpty ? "" : "{\(parts.joined(separator: ","))}"
        try SocketClient.send(prefix + text, to: socketPath)
        // Hook-compatible: stdout must be clean JSON, no diagnostic output
        fputs("[✓] 已发送播报请求\n", stderr)
    }
}
