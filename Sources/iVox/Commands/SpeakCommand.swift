import ArgumentParser
import Darwin
import Foundation

struct SpeakCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "speak",
        abstract: "一次性播报文本"
    )

    @Option(name: .shortAndLong, help: "来源标识 (claude/codex/pi)")
    var source: String?

    @Option(name: .shortAndLong, help: "音色 ID")
    var voice: String?

    @Argument(help: "要播报的文本")
    var text: String

    func run() async throws {
        let socketPath = NSString(string: "~/.config/ivox/ivox.sock").expandingTildeInPath
        var parts: [String] = []
        if let source { parts.append("source:\(source)") }
        if let voice, !voice.isEmpty { parts.append("voice:\(voice)") }
        let prefix = parts.isEmpty ? "" : "{\(parts.joined(separator: ","))}"
        try SocketClient.send(prefix + text, to: socketPath)
        // Hook-compatible: stdout must be clean JSON, no diagnostic output
        fputs("[✓] 已发送播报请求\n", stderr)
    }
}

enum SocketClient {
    static func send(_ message: String, to socketPath: String) throws {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENOTSOCK) }
        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            let count = min(socketPath.utf8.count, MemoryLayout.size(ofValue: addr.sun_path) - 1)
            withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                dst.copyMemory(from: UnsafeRawBufferPointer(start: ptr, count: count))
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ret = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, size)
            }
        }
        guard ret == 0 else { throw POSIXError(.ECONNREFUSED) }

        let data = Data(message.utf8)
        let sent = data.withUnsafeBytes { raw in
            Darwin.write(fd, raw.baseAddress, raw.count)
        }
        guard sent == data.count else { throw POSIXError(.EIO) }
    }
}
