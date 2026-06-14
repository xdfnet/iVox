import Darwin
import Foundation

actor SocketServer {
    private var socketFD: Int32 = -1
    private var source: DispatchSourceRead?
    private var handler: ConnectionHandler?
    private var socketPath: String?

    func start(path: String, handler: ConnectionHandler) throws {
        self.handler = handler
        self.socketPath = path
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
            Darwin.close(socketFD); throw SocketError.bindFailed(String(cString: strerror(errno)))
        }
        guard Darwin.listen(socketFD, 5) == 0 else {
            Darwin.close(socketFD); throw SocketError.listenFailed(String(cString: strerror(errno)))
        }

        chmod(path, 0o600)
        Log.info("Socket 监听: \(path)")

        let fd = socketFD
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        source?.setEventHandler { [weak self] in
            Task { [weak self] in
                await self?.accept()
            }
        }
        source?.setCancelHandler { Darwin.close(fd) }
        source?.activate()
    }

    private func accept() async {
        var clientAddr = sockaddr_un()
        var len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.accept(socketFD, $0, &len)
            }
        }
        if clientFD >= 0 {
            Log.info("Socket 接入: fd=\(clientFD)")
            // handle() 内含同步阻塞 read，放到专用队列避免占用 Swift 并发线程池
            DispatchQueue.global().async { [handler] in
                handler?.handle(fd: clientFD)
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
