import Darwin
import Foundation
import iVoxKit

// 远程 TTS 引擎：主进程不再自己跑 MLX，而是找誊清员进程要音频。
//
// 它同时是那个子进程的**监督者**：誊清员崩了（MLX 会崩，这是已知的），
// 这里重新拉起它，**崩溃的那一块作废**，调用方（PlaybackQueue 的 producer 循环）
// 记下错误继续念下一块。
//
// 为什么不「重发同一句接着誊」：崩之前已经送出的 PCM 帧都进了播报员，重发会得到
// 「前半截 + 从头再来一遍」——播出来是一句话中间断掉又重复，比直接作废更糟。
// 纸上写的「从没誊清的那张接着誊」说的是**还没开始合成的那一块**，正是这里做的事。
//
// 这么做的前提是「进度存在主进程」：这里只知道自己发到第几句、收到第几帧，
// 「合到第几块」这个数从不落在子进程里。子进程是无状态的，崩了不带走任何东西。

actor TSPRemote: TTSProviding {
    /// 子进程 socket 路径
    private let socketPath: String
    /// 拉起子进程用的可执行文件路径
    private let executablePath: String
    private var child: Process?
    /// 打断纪元：cancelActiveSynthesis 递增，进行中的合成比对不上就停止 yield。
    /// 独立于 actor 锁，因为读取方（阻塞读循环）跑在全局队列上。
    private let cancelToken = CancelToken()

    init(socketPath: String = AppPaths.ttsSocketPath,
         executablePath: String? = nil) {
        self.socketPath = socketPath
        self.executablePath = executablePath
            ?? ((AppPaths.binDir as NSString).appendingPathComponent("ivox") as NSString).expandingTildeInPath
    }

    // MARK: - 与本地引擎同名的接口

    /// 主进程自己不加载模型，模型在誊清员那边。问它好了没。
    var state: TTSLoadState {
        get async {
            guard await ensureChildRunning() else { return .failed("誊清员拉起失败") }
            guard let s = await Self.queryState(socketPath: socketPath) else {
                return .failed("誊清员无响应")
            }
            return s
        }
    }

    func loadModel() async throws {
        guard await ensureChildRunning() else {
            throw TTSRemoteError.unavailable
        }
        await waitUntilReady()
        guard case .ready = await state else { throw TTSRemoteError.unavailable }
    }

    /// 协议要求，实现是空操作：预热在誊清员进程内自己做了（它加载完就跑一次）。
    /// 这边只需要把「启动」这件事完成，等的就是 `state`。
    func warmup(voiceID: String) async {
        _ = await state
    }

    func waitUntilReady() async {
        while Task.isCancelled == false {
            let s = await state
            switch s {
            case .ready: return
            case .failed(let msg):
                Log.error("誊清员: 模型未就绪 — \(msg)")
                return
            case .notStarted, .loading:
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    /// 打发的纪元。读方在全局队列上跑，actor 锁够不着，故用一个自带锁的小盒子。
    private final class CancelToken: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt = 0
        var epoch: UInt { lock.withLock { value } }
        func bump() { lock.withLock { value &+= 1 } }
    }

    // MARK: - 合成

    func synthesizeStream(text: String, voiceID: String, trace: TTSTrace?)
        -> AsyncThrowingStream<Data, Error> {
        // 打断纪元在**入口**快照。若等到 pump 里连完、写完再取，这中间来的一次打断
        // 会取到推进后的值，比对恒等成立 —— 被打断的那一句照合成照送。
        let epoch = cancelToken.epoch
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Self.pump(
                        text: text, voiceID: voiceID, trace: trace,
                        socketPath: self.socketPath, token: self.cancelToken, epoch: epoch,
                        onFrame: { continuation.yield($0) }
                    )
                    continuation.finish()
                } catch {
                    // 崩了就记一笔、重启它，这一句作废。不重发（见文件头）。
                    await self.recoverIfChildGone(error)
                    Log.error("誊清中断，这一块作废：\(error)\(trace?.logSuffix ?? "")")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// 打断：递增纪元。**不 close 连接** —— 另一线程正阻塞在 read 上，close 会让它
    /// 挂死或读到复用的 fd。改由读循环自己发现纪元变了：停止 yield，但继续把 socket
    /// 读完（子进程那边还在往里写，不读会把它堵死），这与 TTSEngine 里的取消补丁同思路。
    func cancelActiveSynthesis(reason: String) {
        cancelToken.bump()
        Log.info("TTS 合成已取消（打断来源=\(reason)）")
    }

    // MARK: - 监督

    /// 确认誊清员活着；死了就拉起来并等它把 socket 挂上。
    ///
    /// **先问 socket、再问 child**：socket 上已经有人在听就复用，哪怕那个进程不是我拉起的。
    /// 反过来（只看 `child`）会在两种情况下闯祸——
    /// 调试期手工跑了 `ivox tts --serve`，主进程一起来就把它的 socket 路径 unlink 掉
    /// 抢走（`SocketServer.start` 开头就 unlink），那个手工进程变没人连的僵尸；
    /// 主进程上次崩掉留下的孤儿同理。
    private func ensureChildRunning() async -> Bool {
        if SocketClient.isRunning(path: socketPath) { return true }
        if let child, child.isRunning {
            // 进程在但 socket 还没起来：刚拉起，等它绑
            return await waitForSocket(seconds: 60)
        }
        startChild()
        return await waitForSocket(seconds: 90)
    }

    private func startChild() {
        child?.terminate()
        child = nil
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executablePath)
        p.arguments = ["tts", "--serve"]
        // 环境不显式设置：macOS 的 Process 默认继承父进程，IVOX_LOG_LEVEL 等
        // 会原样带过去（子进程内部自己再 setenv 它的日志文件路径）
        do {
            try p.run()
            Log.info("已拉起誊清员: pid=\(p.processIdentifier) socket=\(socketPath)")
            child = p
        } catch {
            Log.error("拉起誊清员失败: \(error)")
            child = nil
        }
    }

    /// 主进程退出时带走誊清员。**必须显式杀**：`_exit(0)` 不跑析构，父进程一走，
    /// 誊清员就成了孤儿——它自己不会退出（`while true` 常驻），会一路抱着 GPU
    /// 跑到下次开机，调试期反复重启就攒出一串僵尸。
    func stopChild() {
        guard let child else { return }
        child.terminate()          // SIGTERM：它自己装信号处理，走优雅退出
        child.waitUntilExit()
        Log.info("誊清员已收: pid=\(child.processIdentifier)")
        self.child = nil
        // socket 文件不删：`SocketServer.start` 开头就 unlink，下次 bind 会覆盖
    }

    private func waitForSocket(seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if SocketClient.isRunning(path: socketPath) { return true }
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    /// 只有「连接类」故障才值得重启子进程。合成本身的错（模型没就绪、半句）重试没有意义。
    private func recoverIfChildGone(_ error: Error) async {
        guard let posix = error as? POSIXError,
              posix.code == .ECONNREFUSED || posix.code == .ECONNRESET || posix.code == .ENOENT
        else { return }
        Log.warn("誊清员不可达，重启它")
        startChild()
        _ = await waitForSocket(seconds: 90)
    }

    // MARK: - 传输

    /// 发一句、等它的 PCM 逐帧回来。阻塞读跑在全局队列上，不占 actor。
    private static func pump(
        text: String, voiceID: String, trace: TTSTrace?,
        socketPath: String, token: CancelToken, epoch: UInt,
        onFrame: @escaping @Sendable (Data) -> Void
    ) async throws {
        let fd = try SocketClient.connect(to: socketPath)
        defer { Darwin.close(fd) }

        // 关联 ID 随请求头递过去：誊清员那边的每行日志都带它，这一摞才串得起来
        var request = Data()
        request.append(contentsOf: Data(
            "{type:tts,voice:\(voiceID)\(trace?.headerFields ?? "")}\n".utf8))
        request.append(contentsOf: Data(text.utf8))
        try request.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n > 0 { offset += n; continue }
                if errno == EINTR { continue }
                throw POSIXError(.EIO)
            }
        }
        // 写端关闭：子进程读完这个 socket 才知道正文结束
        Darwin.shutdown(fd, 1)

        var remaining: [UInt8] = []
        var sawEnd = false
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { break }
            let cancelled = token.epoch != epoch
            // 打断后仍要**解析**，只是不再送帧：解析顺带把缓冲消费掉，不解析的话
            // remaining 一路涨到本次合成的字节数；而且不读干净会把誊清员堵死。
            for frame in StreamFrame.parseChunks(from: Data(buf[0..<n]), into: &remaining, sawEnd: &sawEnd) {
                if !cancelled { onFrame(frame) }
            }
        }
        // 读干净了却没见过结束标志 = 誊清员崩在这一句中途。EOF 本身不能作数：
        // 正常念完也是 EOF，不带这个标志就分不出「念完了」和「半句就没了」。
        guard sawEnd else { throw TTSRemoteError.truncated }
    }

    /// 问一句「好了没」，读一行回复就走
    private static func queryState(socketPath: String) async -> TTSLoadState? {
        await withCheckedContinuation { (cont: CheckedContinuation<TTSLoadState?, Never>) in
            DispatchQueue.global().async {
                guard let fd = try? SocketClient.connect(to: socketPath) else {
                    cont.resume(returning: nil); return
                }
                defer { Darwin.close(fd) }
                let req = Data("{type:status}\n".utf8)
                _ = req.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, req.count) }
                Darwin.shutdown(fd, 1)
                var buf = [UInt8](repeating: 0, count: 512)
                let n = Darwin.read(fd, &buf, buf.count)
                guard n > 0 else { cont.resume(returning: nil); return }
                let text = String(decoding: buf[0..<n], as: UTF8.self)
                cont.resume(returning: Self.parseState(text))
            }
        }
    }

    private static func parseState(_ reply: String) -> TTSLoadState? {
        let t = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains("state:ready") { return .ready }
        if t.contains("state:failed") {
            let msg = t.components(separatedBy: "state:failed:").last ?? ""
            return .failed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if t.contains("state:loading") { return .loading }
        return nil
    }
}

enum TTSRemoteError: Error {
    case unavailable
    /// 读到了 EOF 却没见过结束标志：对面在这一句中途没了，只送出了半句
    case truncated
}
