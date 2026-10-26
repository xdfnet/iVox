import Darwin
import Foundation

// AppPaths 与 socket 客户端。

/// 常用路径（HOME 优先取环境变量，HOME 未设时退回 NSHomeDirectory，避免波浪号展开失败）
public enum AppPaths {
    public static var configDir: String { expandTilde("~/.config/ivox") }
    /// 主 daemon 的 socket。**可被 `IVOX_SOCKET` 覆盖**：调试实例用它跟正式那份
    /// 彻底分家（socket、锁、誊清员各走各的，见 `InstanceLock`），
    /// 从根上不存在「两个 daemon 抢同一个 socket」。
    public static var socketPath: String {
        if let override = ProcessInfo.processInfo.environment["IVOX_SOCKET"], !override.isEmpty {
            return expandTilde(override)
        }
        return configDir + "/ivox.sock"
    }
    /// 这是不是一份**隔离实例**（`IVOX_SOCKET` 指了别的路径）。
    ///
    /// 隔离实例**不装热键、不开语音输入**——那两样要的是全局资源：
    /// 热键 tap 会跟正式那份抢同一个右⌘/Ctrl 键，麦克风会抢录音设备；
    /// 更要紧的是 **macOS 的权限归属算在「谁启动它」名下**，从 Claude Code 或终端
    /// 手起的实例一律挂到启动者名下 → 每起一次就弹一次权限框
    /// （2026-10-26 实测：launchd 托管那份直接放行，手起的那几份弹了十几次）。
    /// 不装热键/语音，它就**一项权限都不申请**，弹框自然没有。
    public static var isIsolatedInstance: Bool {
        guard let override = ProcessInfo.processInfo.environment["IVOX_SOCKET"], !override.isEmpty else {
            return false
        }
        return true
    }
    /// 誊清员进程的 socket。独立于主 daemon —— 它跑 MLX 合成，是唯一会崩的一层，
    /// 崩了不该带走主进程里的队列与字条。
    ///
    /// **由主 socket 派生**（同目录、基名去掉 .sock 加 -tts.sock）：默认主 socket 是
    /// `ivox.sock` → 誊清员是 `ivox-tts.sock`（与从前一致）；隔离实例
    /// （`ivox-debug.sock`）则是 `ivox-debug-tts.sock`——名字随实例走，
    /// 两份实例不会抢同一个誊清员。
    public static var ttsSocketPath: String { ttsSocketPath(for: socketPath) }
    public static func ttsSocketPath(for socket: String) -> String {
        let url = URL(fileURLWithPath: socket)
        let base = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent("\(base)-tts.sock").path
    }
    /// 实例锁文件：跟主 socket 同目录同名（.sock → .lock）。
    /// **同一把 socket = 同一把锁**——第二份进程在进程级就被拦住。
    public static var lockPath: String { lockPath(for: socketPath) }
    public static func lockPath(for socket: String) -> String {
        let url = URL(fileURLWithPath: socket)
        let base = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent("\(base).lock").path
    }
    /// 日志文件名只有这一处定义。三个进程各写各的，「哪个文件里有现场就是哪个角色的错」
    /// （见 CLAUDE.md）——所以文件名与位置必须是单一真源，散开写迟早漂。
    public static var daemonLogPath: String { configDir + "/daemon.log" }
    public static var ttsLogPath: String { configDir + "/tts.log" }
    public static var binDir: String { expandTilde("~/.local/bin") }
    /// 用户自装工具所在的目录（`claude` 在 `~/.local/bin`，`codex`/`pi` 在 Homebrew 的 bin）。
    ///
    /// launchd 起的 GUI 进程拿到的 PATH 只有系统那几项，**不含这些目录**；而 Ghostty 在
    /// macOS 上经 `/usr/bin/login` + `--noprofile --norc` 启动 shell，**不读 profile**，
    /// PATH 只能由发起方显式给过去——否则 `claude` 报 `not found`。
    ///
    /// Homebrew 的 prefix 在 Intel 是 `/usr/local`、Apple Silicon 是 `/opt/homebrew`，
    /// 按实际存在的那个取；`~` 一律由 `HOME` 展开，不写死用户名。
    public static var userBinDirs: [String] {
        var dirs = [expandTilde("~/.local/bin")]
        for prefix in ["/opt/homebrew/bin", "/usr/local/bin"] where FileManager.default.fileExists(atPath: prefix) {
            dirs.append(prefix)
            break
        }
        return dirs
    }

    static func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~/") else { return path }
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return home + path.dropFirst()
    }
}

/// Unix Domain Socket 客户端工具
public enum SocketClient {
    /// 连接 UNIX Socket，返回 fd（调用方负责 close）
    ///
    /// - Parameter timeout: 读写超时（秒）。控制类 socket 用 `SocketTimeout.control`；
    ///   合成流用 `SocketTimeout.synthesisRead`——后者只是读流粒度，整块上限另有其人
    ///   （`SocketTimeout.synthesisDeadline`），别拿粒度当整块。
    public static func connect(to path: String,
                               timeout: TimeInterval = SocketTimeout.control) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENOTSOCK) }

        // daemon 中途退出时靠 EPIPE 报错，别让进程被 SIGPIPE 杀掉
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

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

        // 读写超时：防止对端异常时无限阻塞。**注意这是「每次 read 最多等多久」，
        // 不是「整个请求最多用多久」**——合成流靠它把长合成切成一趟趟等待，
        // 断流与否看 EOF，不看某一趟有没有等到（见 SocketReader）。
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    /// 发送文本消息（单向，不等待回复）
    /// 大 payload 单次 write 可能只写出一部分（超时被截断），必须循环补齐，
    /// 否则长回复会被静默丢弃。
    public static func send(_ message: String, to path: String) throws {
        let fd = try connect(to: path)
        defer { Darwin.close(fd) }
        let data = Data(message.utf8)
        var offset = 0
        while offset < data.count {
            let sent = data.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
            }
            if sent > 0 {
                offset += sent
                continue
            }
            if errno == EINTR { continue }
            throw POSIXError(.EIO)
        }
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
