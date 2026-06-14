import ArgumentParser
import Darwin
import Foundation

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "查看守护进程运行状态"
    )

    func run() throws {
        let socketPath = NSString(string: "~/.config/ivox/ivox.sock").expandingTildeInPath

        var st = stat()
        guard stat(socketPath, &st) == 0 else {
            print("状态: 未运行")
            return
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            print("状态: 异常")
            return
        }
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

        if ret == 0 {
            print("状态: 运行中")
            print("Socket: \(socketPath)")
        } else {
            print("状态: 未运行")
        }
    }
}
