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
    /// 合成流的单次读超时（秒）——只是粒度，不是整块上限
    private let readTimeout: TimeInterval
    /// 合成一整块的总时限（秒）
    private let deadline: TimeInterval
    /// 等引擎就绪的上限（秒）。引擎永远起不来时，不能把调用方一起吊死。
    private static let readyWaitSeconds: TimeInterval = 120
    private var child: Process?
    /// 连续拉起失败次数：退避间隔的来源。
    private var consecutiveLaunchFailures = 0
    /// 下一次允许拉起的时间。退避未到点就直接判失败，不再 fork。
    private var nextLaunchAllowedAt = Date.distantPast
    /// 已就位但引擎没用的那一次报错是不是已经说过。说过了就不再逐块刷——
    /// 队列在引擎坏掉时会把每块都试一遍，每块一条同款错误既刷屏又不带新信息。
    private var lastUnavailableNote: String?
    /// **模型该不该驻留**。
    ///
    /// `true`（常态）：模型在子进程里，显存占着。
    /// `false`：**人主动关了播报** → 模型连同子进程一并收回，几 G 显存还给系统。
    ///
    /// 置着 `false` 时，**问状态不会把子进程拉回来**——否则「查一下健康」就把显存请回来了，
    /// 释放白做。真正的合成请求会把它置回 `true` 并按需加载（那是明确的需求，值得占显存）。
    private var wanted = true
    /// 打断纪元：cancelActiveSynthesis 递增，进行中的合成比对不上就停止 yield。
    /// 独立于 actor 锁，因为读取方（阻塞读循环）跑在全局队列上。
    private let cancelToken = CancelToken()

    init(socketPath: String = AppPaths.ttsSocketPath,
         executablePath: String? = nil,
         readTimeout: TimeInterval = SocketTimeout.synthesisRead,
         deadline: TimeInterval = SocketTimeout.synthesisDeadline) {
        self.socketPath = socketPath
        self.executablePath = executablePath
            ?? ((AppPaths.binDir as NSString).appendingPathComponent("ivox") as NSString).expandingTildeInPath
        self.readTimeout = readTimeout
        self.deadline = deadline
    }

    // MARK: - 与本地引擎同名的接口

    /// 主进程自己不加载模型，模型在誊清员那边。问它好了没。
    var state: TTSLoadState {
        get async {
            // 模型不该驻留：不碰子进程、不拉起它（问一次状态就把几 G 显存请回来，等于白释放）。
            if !wanted { return .notStarted }
            guard await ensureChildRunning() else { return .failed("誊清员拉起失败") }
            guard let s = await Self.queryState(socketPath: socketPath) else {
                return .failed("誊清员无响应")
            }
            return s
        }
    }

    func loadModel() async throws {
        wanted = true
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
        // 不该驻留的先请回来（真有人要声音就该给，不该装作没有）。
        if !wanted { wanted = true }
        let deadline = Date().addingTimeInterval(Self.readyWaitSeconds)
        while Task.isCancelled == false {
            let s = await state
            switch s {
            case .ready: return
            case .failed(let msg):
                Log.error("誊清员: 模型未就绪 — \(msg)")
                return
            case .notStarted, .loading:
                // 等就绪也要有上限：引擎永远起不来时，调用方不能跟着一起吊死。
                if Date() >= deadline {
                    Log.error("誊清员: 等待就绪超时（\(Int(Self.readyWaitSeconds))s）")
                    return
                }
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
                    // 引擎没就绪就别浪费一次连接往返：先问状态，失败当场作废这一块。
                    // 顺带治刷屏——队列在引擎坏掉时会把每块都试一遍，每块一条
                    // 「誊清员无响应」既占屏又不带任何新信息（2026-10-19 23:32 那次
                    // 满屏都是同一句话）。这里只在状态**变了**时说一次。
                    //
                    // **只有引擎明确不就绪才等**：请求撞上「模型正在加载」会被誊清员
                    // 直接拒掉，那一块就白丢了（2026-10-24 实测：引擎重启瞬间发出的
                    // 请求全丢，自检 F 用例因此空 PCM）。等它就绪比丢内容划算；
                    // 但正常路径（引擎已就绪）不能多等、多连——每多一次探测连接，
                    // 誊清员那边就多一份要打发的活。
                    switch await self.state {
                    case .ready:
                        break
                    case .failed(let msg):
                        await self.noteFailedAndScheduleReplacement(msg)
                        throw TTSRemoteError.unavailable
                    case .notStarted, .loading:
                        await self.waitUntilReady()
                        if case .failed(let msg) = await self.state {
                            await self.noteFailedAndScheduleReplacement(msg)
                            throw TTSRemoteError.unavailable
                        }
                    }
                    if self.lastUnavailableNote != nil {
                        Log.info("誊清员恢复就绪")
                        self.lastUnavailableNote = nil
                    }
                    try await Self.pump(
                        text: text, voiceID: voiceID, trace: trace,
                        socketPath: self.socketPath, token: self.cancelToken, epoch: epoch,
                        readTimeout: self.readTimeout, deadline: self.deadline,
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

    /// 释放模型资源：把誊清员子进程收掉——模型权重在它身上，随它一起还给系统。
    ///
    /// **退避要清零**：释放是人主动关播报，不是「拉起失败」，
    /// 否则下一次要合成时会被上次留下的退避窗口挡住（那一下会判 failed、那一块白丢）。
    func releaseModel() async {
        wanted = false
        guard child != nil else { return }
        Log.info("释放合成资源：收掉誊清员（模型显存随之归还）")
        stopChild()
        consecutiveLaunchFailures = 0
        nextLaunchAllowedAt = .distantPast
    }

    /// 撤销释放：模型重新驻留。**按需**加载（不在这里等它好——
    /// 那要好几秒，不能挡着开关返回），加载在后台做。
    func resumeModel() async {
        wanted = true
        Task { [weak self] in
            do {
                try await self?.loadModel()
            } catch {
                Log.error("TTS 模型重新加载失败: \(error)")
            }
        }
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
            if await waitForSocket(seconds: 60, child: child) { return true }
        }
        return await replaceChild(reason: "socket 不可达")
    }

    /// **拉起/更换子进程的唯一入口**。退避计数只在这里动。
    ///
    /// 收敛是刻意的：三个触发点（连不上 socket、状态报 failed、崩溃后重拉）原先各自
    /// startChild 一次，退避计数就无从对齐——一处成功会把别处的失败数清零，于是退避
    /// 形同虚设。现在它们都走这里，谁成功谁把计数归零。
    private func replaceChild(reason: String) async -> Bool {
        // 模型不该驻留就不拉：**拉回来等于把刚还回去的显存又要回来**。
        // 真正要合成的人走 `synthesizeStream` 的「按需加载」，那是有明确需求才恢复。
        guard wanted else { return false }
        let now = Date()
        guard now >= nextLaunchAllowedAt else {
            let wait = Int(nextLaunchAllowedAt.timeIntervalSinceNow.rounded(.up))
            Log.debug("誊清员更换退避中（\(reason)，\(wait)s 后再试）")
            return false
        }
        // **占位必须在这一步做完，且必须在动手拉起之前**。
        // 下面 `waitForSocket` 要 await 最多 90 秒，actor 在 await 处让出——
        // 那段时间里合成、/health、启动握手都可能涌进来，各自都读到「还没到退避点」，
        // 于是各拉一个子进程。实测退避形同虚设、每秒拉一个（2026-10-20）。
        // 先把下次允许的时间推进，后来的调用就只能看着了。
        let next = min(pow(2.0, Double(consecutiveLaunchFailures + 1)), 60.0)
        nextLaunchAllowedAt = now.addingTimeInterval(next)
        Log.info("拉起誊清员（原因：\(reason)）")
        startChild()
        if await waitForSocket(seconds: 90, child: child) {
            // socket 通了只说明「有进程在监听」，**不等于模型好了**——子进程是先绑 socket
            // 再后台加载模型的。此处不必清零退避：真正判断健康的是 state，
            // 若它随后报 failed，noteFailedAndScheduleReplacement 会再换一个，
            // 那时退避计数接着往上加，连续性才对。
            consecutiveLaunchFailures = 0
            return true
        }
        consecutiveLaunchFailures += 1
        Log.warn("誊清员拉起失败（连续第 \(consecutiveLaunchFailures) 次），\(Int(next))s 后再试")
        return false
    }

    /// 状态报 failed = **当前这个实例不行，换一个**。这才是退避该挂的地方——
    /// 子进程是「先绑 socket、再后台加载模型」，所以加载失败时 socket 一直通着，
    /// 「连不上」这条路径根本不会触发；真信号只有 failed。
    /// （2026-10-20 第一版把退避挂在连不上的判断上，一次都没触发过。）
    private func noteFailedAndScheduleReplacement(_ msg: String) async {
        if lastUnavailableNote != msg {
            Log.error("誊清员未就绪，将换一个重试：\(msg)")
            lastUnavailableNote = msg
        }
        await replaceChild(reason: "状态 failed：\(msg)")
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

    private func waitForSocket(seconds: Double, child: Process? = nil) async -> Bool {
        let began = Date()
        let deadline = began.addingTimeInterval(seconds)
        while Date() < deadline {
            if SocketClient.isRunning(path: socketPath) { return true }
            // **起来即退**：子进程在 socket 挂上之前就没了（模型加载失败走的就是这条路，
            // 加载失败即退出——见 TTSCommand）。干等满 90 秒毫无意义，立刻判失败交给退避。
            // 留 0.5 秒宽限：spawn 到 exec 之间 isRunning 可能瞬时为假。
            if let child, Date().timeIntervalSince(began) > 0.5, !child.isRunning {
                Log.warn("誊清员起来即退（pid=\(child.processIdentifier)），不等了")
                return false
            }
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
        _ = await replaceChild(reason: "连接中断（疑似崩溃）")
    }

    // MARK: - 传输

    /// 发一句、等它的 PCM 逐帧回来。阻塞读跑在全局队列上，不占 actor。
    ///
    /// **一帧都没送出就重发一次**：合成慢到超时、或这一句单独崩了，重发是安全的
    /// ——没播出去过，重发不会变成重复播。引擎已经死掉时重发只会连不上，于是仍走
    /// 「这块作废」，R1 期望的正是这个（杀进程 → 作废 → 队列继续 → 监督者重拉）。
    private static func pump(
        text: String, voiceID: String, trace: TTSTrace?,
        socketPath: String, token: CancelToken, epoch: UInt,
        readTimeout: TimeInterval, deadline: TimeInterval,
        onFrame: @escaping @Sendable (Data) -> Void
    ) async throws {
        let counter = PCMCounter()
        var attempt = 0
        while true {
            let fd = try SocketClient.connect(to: socketPath, timeout: readTimeout)
            do {
                try pumpOnce(fd: fd, text: text, voiceID: voiceID, trace: trace,
                             token: token, epoch: epoch, counter: counter,
                             deadline: deadline, onFrame: onFrame)
            } catch {
                Darwin.close(fd)
                // 纪元变了 = 用户不要了，重发是添乱；已送过帧 = 播出去一半，重发会重复。
                if counter.sentAny || attempt > 0 || token.epoch != epoch { throw error }
                attempt += 1
                Log.warn("合成未出一帧，重发一次：\(error)")
                continue
            }
            Darwin.close(fd)
            return
        }
    }

    /// 一次「发请求 + 读 PCM」。断流/超时都从这里抛。
    private static func pumpOnce(
        fd: Int32, text: String, voiceID: String, trace: TTSTrace?,
        token: CancelToken, epoch: UInt, counter: PCMCounter,
        deadline: TimeInterval,
        onFrame: @escaping @Sendable (Data) -> Void
    ) throws {
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
        // **读超时不算断流**（见 SocketReader）：合成慢时这一趟 read 会空手回来，
        // 接着等就是了——判「断了」只有 EOF 一样东西，别拿「这趟没等到」当断线。
        try SocketReader.readToEnd(fd: fd,
                                    deadlineSeconds: deadline) { chunk in
            let cancelled = token.epoch != epoch
            // 打断后仍要**解析**，只是不再送帧：解析顺带把缓冲消费掉，不解析的话
            // remaining 一路涨到本次合成的字节数；而且不读干净会把誊清员堵死。
            for frame in StreamFrame.parseChunks(from: chunk, into: &remaining, sawEnd: &sawEnd) {
                if !cancelled { counter.mark(); onFrame(frame) }
            }
        }
        // 读干净了却没见过结束标志 = 誊清员崩在这一句中途。EOF 本身不能作数：
        // 正常念完也是 EOF，不带这个标志就分不出「念完了」和「半句就没了」。
        guard sawEnd else { throw TTSRemoteError.truncated }
    }

    /// 送出的 PCM 帧计数。跨 await 边界要能被并发读，故用带锁的小盒子。
    private final class PCMCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var sentAny: Bool { lock.withLock { count > 0 } }
        func mark() { lock.withLock { count += 1 } }
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
