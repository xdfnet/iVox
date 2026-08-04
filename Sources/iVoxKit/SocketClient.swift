import Darwin
import Foundation

/// 常用路径（HOME 优先取环境变量，HOME 未设时退回 NSHomeDirectory，避免波浪号展开失败）
public enum AppPaths {
    public static var configDir: String { expandTilde("~/.config/ivox") }
    public static var socketPath: String { configDir + "/ivox.sock" }
    public static var binDir: String { expandTilde("~/.local/bin") }
    /// launchd LaunchAgent plist 路径（launchctl bootstrap/bootout 用）
    public static var launchdPlistPath: String { expandTilde("~/Library/LaunchAgents/com.user.ivox.plist") }

    static func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~/") else { return path }
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return home + path.dropFirst()
    }
}

/// Unix Domain Socket 客户端工具
public enum SocketClient {
    /// 连接 UNIX Socket，返回 fd（调用方负责 close）
    public static func connect(to path: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENOTSOCK) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { ptr in
            let count = min(path.utf8.count, MemoryLayout.size(ofValue: addr.sun_path) - 1)
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
        guard ret == 0 else { Darwin.close(fd); throw POSIXError(.ECONNREFUSED) }

        // 读写超时 10s，防止 daemon 异常时无限阻塞
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    /// 发送文本消息（单向，不等待回复）
    public static func send(_ message: String, to path: String) throws {
        let fd = try connect(to: path)
        defer { Darwin.close(fd) }
        let data = Data(message.utf8)
        let sent = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard sent == data.count else { throw POSIXError(.EIO) }
    }

    /// 发送二进制消息 + 读取回复
    public static func sendWithReply(header: Data, body: Data, to path: String) throws -> String {
        let fd = try connect(to: path)
        defer { Darwin.close(fd) }

        var payload = header
        payload.append(body)
        let sent = payload.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard sent == payload.count else { throw POSIXError(.EIO) }

        Darwin.shutdown(fd, 1) // 关闭写端
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = Darwin.read(fd, &buf, buf.count)
        guard n > 0 else { throw POSIXError(.ECONNRESET) }
        return String(decoding: buf[0..<n], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 检查服务是否在监听
    public static func isRunning(path: String) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0 else { return false }
        guard let fd = try? connect(to: path) else { return false }
        Darwin.close(fd)
        return true
    }
}
