import Darwin
import Foundation
import iVoxKit

// Unix domain socket 服务端：监听 / accept / 对端校验。

/// 一次 socket 连接的处理者。Server 只管监听与对端校验，收到连接之后怎么分派
/// 由实现者自己决定 —— 主 daemon 走 `ConnectionHandler`（跑腿接入），誊清员进程
/// 走 `TTSServer`（合成 PCM 写回）。两者共用同一个 Server，故抽成协议。
protocol SocketConnectionHandler: Sendable {
    /// 接管这个 fd 的生命周期（读完或写完必须自己 close）
    func handle(fd: Int32)
}

/// 两个处理者都要用的两件事：往 fd 上写干净、解析 `{k:v,k:v}` 形式的 meta。
///
/// 上提到这里而不是各写一份：主 daemon 与誊清员进程在**同一个 target**，
/// `writeAll`/`parseMetaKV` 又都是纯 POSIX 活、各 15 行，抄两遍只会各自漂移。
extension SocketConnectionHandler {
    /// 循环写入直到全部写完，处理短写
    func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    /// 解析 `{k:v,k:v}`。**值里不能有 `,` 与 `:`** —— 分不开就是坏 header，丢进字典
    /// 的值是截断过的，比没有更坏，所以调用方要 sanitize 后再拼（见 TTSTrace.headerFields）。
    func parseMetaKV(_ header: String) -> [String: String] {
        guard header.hasPrefix("{"), let end = header.firstIndex(of: "}") else { return [:] }
        var dict: [String: String] = [:]
        for pair in header[header.index(after: header.startIndex)..<end].split(separator: ",") {
            let kv = pair.split(separator: ":", maxSplits: 1)
            if kv.count == 2 { dict[String(kv[0])] = String(kv[1]) }
        }
        return dict
    }
}

actor SocketServer {
    private var socketFD: Int32 = -1
    private var source: DispatchSourceRead?
    private var socketPath: String?

    func start(path: String, handler: any SocketConnectionHandler) throws {
        unlink(path)

        socketFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw SocketError.createFailed(String(cString: strerror(errno)))
        }

        var on: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { ptr in
            let count = min(path.utf8.count, MemoryLayout.size(ofValue: addr.sun_path) - 1)
            withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                dst.copyMemory(from: UnsafeRawBufferPointer(start: ptr, count: count))
            }
        }

        let addrSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        guard withUnsafePointer(to: &addr, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socketFD, $0, addrSize) } }) == 0 else {
            Darwin.close(socketFD); unlink(path)
            throw SocketError.bindFailed(String(cString: strerror(errno)))
        }
        chmod(path, 0o600)
        guard Darwin.listen(socketFD, 5) == 0 else {
            Darwin.close(socketFD); unlink(path)
            throw SocketError.listenFailed(String(cString: strerror(errno)))
        }

        Log.info("Socket 监听: \(path)")

        let fd = socketFD
        let capturedHandler = handler
        self.socketPath = path

        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        source?.setEventHandler { [weak self] in
            self?.acceptAndHandle(fd: fd, handler: capturedHandler)
        }
        source?.setCancelHandler { Darwin.close(fd) }
        source?.activate()
    }

    /// DispatchSource 直接调用（去掉中间 Task 层），handle 放到专用队列
    private nonisolated func acceptAndHandle(fd: Int32, handler: any SocketConnectionHandler) {
        var clientAddr = sockaddr_un()
        var len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.accept(fd, $0, &len)
            }
        }
        if clientFD >= 0 {
            // 只认同一用户：socket 本身已是 0600，这道是纵深防御。
            // getpeereid 拿的是对端 uid，同 UID 的野脚本连不上另外的账户。
            var peerUID: uid_t = 0
            var peerGID: gid_t = 0
            if getpeereid(clientFD, &peerUID, &peerGID) == 0, peerUID != getuid() {
                Log.warn("Socket: 拒绝非本用户的连接（uid=\(peerUID)）")
                Darwin.close(clientFD)
                return
            }
            var on: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            // 读超时 10s：坏客户端不关闭连接时，read 循环不会无限阻塞
            var tv = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            DispatchQueue.global().async {
                handler.handle(fd: clientFD)
            }
        }
    }

    func stop() {
        source?.cancel()
        source = nil
        if let socketPath {
            unlink(socketPath)
            self.socketPath = nil
        }
    }
}

enum SocketError: Error {
    case createFailed(String)
    case bindFailed(String)
    case listenFailed(String)
}
