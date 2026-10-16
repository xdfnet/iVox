import ArgumentParser
import Foundation
import iVoxKit

// CLI 子命令 ivox speak：播报一段文本。

struct SpeakCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "speak",
        abstract: "朗读一段文本"
    )

    @Option(name: .shortAndLong, help: "来源（claude/codex/pi），决定默认音色")
    var source: String?

    @Option(name: .shortAndLong, help: "音色 ID（用 ivox voice list 查看）")
    var voice: String?

    @Option(name: .long, help: "分组 ID：同一条回复的多批增量并进同一桶（hook 传 message_id）")
    var group: String?

    @Option(name: .long, help: "页号：这一块属于哪一页（hook 传 message_id），Ctrl+2「读下一页」按它翻页")
    var page: String?

    @Flag(name: .customLong("final"), help: "这批是该回复的最后一批（收尾该分组）")
    var isFinal: Bool = false

    @Argument(help: "要朗读的文本")
    var text: String

    func run() async throws {
        let socketPath = AppPaths.socketPath
        var parts: [String] = []
        if let source, !source.isEmpty { parts.append("source:\(source)") }
        if let voice, !voice.isEmpty { parts.append("voice:\(voice)") }
        if let group, !group.isEmpty { parts.append("group:\(group)") }
        if let page, !page.isEmpty { parts.append("page:\(page)") }
        if isFinal { parts.append("end:1") }
        let prefix = parts.isEmpty ? "" : "{\(parts.joined(separator: ","))}"
        try SocketClient.send(prefix + text, to: socketPath)
        // 给 hook 用：stdout 只能出干净的 JSON，任何诊断输出都不能混进去
        fputs("已发送播报请求\n", stderr)
    }
}
