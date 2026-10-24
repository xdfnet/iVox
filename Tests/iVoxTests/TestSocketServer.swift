import Darwin
import Foundation

// 测试用的最小 Unix socket server：接受连接、读一行请求、交给 handler 决定回什么。
//
// 为什么不用 mock：读超时与「对端真断了」的区别只能靠真 socket 验——把 read 换掉
// 就碰不到 SO_RCVTIMEO 触发 EAGAIN 那条路径，而那正是 2026-10-24 丢字的根因
// （合成慢到 10 秒没吐字，被当成断流，整块内容被丢弃）。

/// 往 socket 写全部数据（半写要补齐）。
func writeAllToSocket(fd: Int32, data: Data) {
    data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset < raw.count {
            let n = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
            if n > 0 { offset += n; continue }
            if errno == EINTR { continue }
            return
        }
    }
}

/// 测试用的 Unix socket server。
final class TestSocketServer: @unchecked Sendable {
    /// 连接被 accept 后，socket 与「读到的第一行请求」交给 handler 处理。
    typealias Handler = @Sendable (Int32, Data) -> Void

    let path: String
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "ivox.test.socket.server")
    private let handler: Handler

    init(handler: @escaping Handler) throws {
        self.handler = handler
        self.path = "/tmp/ivox-test-\(UUID().uuidString.prefix(8)).sock"
        unlink(path)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        listenFD = fd

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { ptr in
            let count = min(path.utf8.count, MemoryLayout.size(ofValue: addr.sun_path) - 1)
            withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                dst.copyBytes(from: UnsafeRawBufferPointer(start: ptr, count: count))
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, len)
            }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else {
            Darwin.close(fd)
            listenFD = -1
            throw POSIXError(.EIO)
        }

        queue.async { [self] in
            while listenFD >= 0 {
                let client = Darwin.accept(listenFD, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    break        // listenFD 被 stop 关掉了
                }
                // 客户端可能已经走了（超时收手），写过去会 SIGPIPE —— 别让测试进程被信号打死
                var noSigPipe: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                           socklen_t(MemoryLayout<Int32>.size))
                // 读请求最多等 2 秒：客户端可能只是「连上就探测一下」然后走人，
                // 不发任何字节。卡在这里会让 server 整条串行队列停摆。
                var readTimeout = timeval(tv_sec: 2, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &readTimeout,
                           socklen_t(MemoryLayout<timeval>.size))
                let request = readRequestLine(fd: client)
                handler(client, request)
                Darwin.close(client)
            }
        }
    }

    /// 读一行请求（到第一个换行或 4KB 为止）。请求正文可能很长，但判据总在第一行。
    private func readRequestLine(fd: Int32) -> Data {
        var buf = [UInt8](repeating: 0, count: 4096)
        var acc = Data()
        while acc.count < 4096 {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { break }
            acc.append(contentsOf: buf[0..<n])
            if acc.contains(0x0A) { break }
        }
        return acc
    }

    /// 收摊：关掉监听 fd（accept 随之返回）并删掉 socket 文件。
    func stop() {
        let fd = listenFD
        listenFD = -1
        if fd >= 0 { Darwin.close(fd) }
        unlink(path)
    }

    deinit { stop() }
}
