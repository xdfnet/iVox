import Darwin
import Foundation
import iVoxKit

// 远程 TTS 引擎：主进程不再自己跑 MLX，而是找誊清员进程要音频。
//
// 它同时是那个子进程的**监督者**：誊清员崩了（MLX 会崩，这是已知的），
// 这里重新拉起它，并把断掉的那一句**重发给新进程**接着誊——调用方（PlaybackQueue
// 的 producer 循环）全程无感，它只看见 PCM 流还在出。
//
// 这么做的前提是「进度存在主进程」：这里只知道自己发到第几句、收到第几帧，
// 「合到第几块」这个数从不落在子进程里。子进程是无状态的，崩了不带走任何东西。

actor TSPRemote {
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

    var isLoaded: Bool { _isLoaded }
    private var _isLoaded = false

    /// 主进程自己不加载模型，模型在誊清员那边。问它好了没。
    var state: TTSLoadState {
        get async {
            guard await ensureChildRunning() else { return .failed("誊清员拉起失败") }
            guard let s = await Self.queryState(socketPath: socketPath) else {
                return .failed("誊清员无响应")
            }
            if s == .ready { _isLoaded = true }
            return s
        }
    }

    func loadModel() async throws {
        guard await ensureChildRunning() else {
            throw TTSRemoteError.unavailable
        }
        await waitUntilReady()
        guard _isLoaded else { throw TTSRemoteError.unavailable }
    }

    /// 预热在子进程侧自己做了（它加载完就跑一次），主进程这边无事可做。
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

    func synthesizeStream(text: String, voiceID: String, trace: TTSTrace? = nil)
        -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                // 最多重试一次：连接失败说明誊清员刚崩（或还没起来），
                // 拉起它之后把**同一句**重发过去，调用方那侧无需回退进度。
                for attempt in 0..<2 {
                    do {
                        try await Self.pump(
                            text: text, voiceID: voiceID, trace: trace,
                            socketPath: self.socketPath, token: self.cancelToken,
                            onFrame: { continuation.yield($0) }
                        )
                        continuation.finish()
                        return
                    } catch {
                        guard attempt == 0, await self.recoverIfChildGone(error) else {
                            continuation.finish(throwing: error)
                            return
                        }
                        Log.warn("誊清员断线（\(error)），已重启，重发这一句接着誊\(trace?.logSuffix ?? "")")
                    }
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
    private func ensureChildRunning() async -> Bool {
        if let child, child.isRunning {
            if SocketClient.isRunning(path: socketPath) { return true }
            // 进程在但 socket 没起来：刚起或还没绑，等一下
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

    private func waitForSocket(seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if SocketClient.isRunning(path: socketPath) { return true }
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    /// 只有「连接类」故障才值得重启子进程。合成本身的错（模型没就绪等）重试没有意义。
    private func recoverIfChildGone(_ error: Error) async -> Bool {
        guard let posix = error as? POSIXError,
              posix.code == .ECONNREFUSED || posix.code == .ECONNRESET || posix.code == .ENOENT
        else { return false }
        Log.warn("誊清员不可达，重启它")
        startChild()
        return await waitForSocket(seconds: 90)
    }

    // MARK: - 传输

    /// 发一句、等它的 PCM 逐帧回来。阻塞读跑在全局队列上，不占 actor。
    private static func pump(
        text: String, voiceID: String, trace: TTSTrace?,
        socketPath: String, token: CancelToken,
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

        let myEpoch = token.epoch
        var remaining: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { break }
            // 已被打断：不再往调用方送帧，但仍要把 socket 读完，让子进程那边收口
            guard token.epoch == myEpoch else { continue }
            for frame in StreamFrame.parseChunks(from: Data(buf[0..<n]), into: &remaining) {
                onFrame(frame)
            }
        }
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
}
