import ArgumentParser
import Foundation
import iVoxKit

struct SpeakCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "speak",
        abstract: "朗读一段文本"
    )

    @Option(name: .shortAndLong, help: "来源（claude/codex/dsh/qwen/pi），决定默认音色")
    var source: String?

    @Option(name: .shortAndLong, help: "音色 ID（用 ivox voice list 查看）")
    var voice: String?

    @Argument(help: "要朗读的文本")
    var text: String

    func run() async throws {
        let socketPath = AppPaths.socketPath
        var parts: [String] = []
        if let source, !source.isEmpty { parts.append("source:\(source)") }
        if let voice, !voice.isEmpty { parts.append("voice:\(voice)") }
        let prefix = parts.isEmpty ? "" : "{\(parts.joined(separator: ","))}"
        try SocketClient.send(prefix + text, to: socketPath)
        // Hook-compatible: stdout must be clean JSON, no diagnostic output
        fputs("已发送播报请求\n", stderr)
    }
}
