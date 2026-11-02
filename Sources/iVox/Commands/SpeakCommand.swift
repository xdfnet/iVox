import ArgumentParser
import Foundation
import iVoxKit

// CLI 子命令 ivox speak：播报一段文本。

struct SpeakCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "speak",
        abstract: "朗读一段文本"
    )

    @Option(name: .shortAndLong, help: "来源（claude/pi/wechat…）——谁在说话")
    var source: String

    @Option(name: .shortAndLong, help: "音色 ID（用 ivox voice list 查看）")
    var voice: String

    @Flag(name: .customLong("now"), help: "现在就念（插队）：播报只暂停（队列一条不删），这句从独立播放节点出声，念完从原处接着播")
    var isNow: Bool = false

    @Argument(help: "要朗读的文本")
    var text: String

    func run() async throws {
        let socketPath = AppPaths.socketPath
        var parts: [String] = ["source:\(source)", "voice:\(voice)"]
        if isNow { parts.append("now:1") }
        let prefix = "{\(parts.joined(separator: ","))}"
        try SocketClient.send(prefix + text, to: socketPath)
        // 给 hook 用：stdout 只能出干净的 JSON，任何诊断输出都不能混进去
        fputs("已发送播报请求\n", stderr)
    }
}
