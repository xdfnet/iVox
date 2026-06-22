import ArgumentParser
import Darwin
import Foundation

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
        let result = try ASRSocketClient.send(header: header, body: wavData, to: socketPath)
        fputs(result + "\n", stderr)
    }
}

enum ASRSocketClient {
    static func send(header: Data, body: Data, to socketPath: String) throws -> String {
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

        // header + WAV
        var payload = header
        payload.append(body)
        let sent = payload.withUnsafeBytes { raw in
            Darwin.write(fd, raw.baseAddress, raw.count)
        }
        guard sent == payload.count else { throw POSIXError(.EIO) }

        // 关闭写端，等服务端返回
        Darwin.shutdown(fd, 1)
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = Darwin.read(fd, &buf, buf.count)
        guard n > 0 else { throw POSIXError(.ECONNRESET) }
        return String(decoding: buf[0..<n], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
