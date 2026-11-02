import Darwin
import Foundation
import iVoxKit

// Unix socket 单连接处理：解析协议并分发。

actor ConnectionHandler: SocketConnectionHandler {
    private let queue: PlaybackQueue

    private let config: Config
    private let asrEngine: ASREngine
    private let engine: any TTSProviding
    private let statusProvider: @Sendable () async -> Data?

    init(queue: PlaybackQueue, config: Config, asrEngine: ASREngine, engine: any TTSProviding,
         statusProvider: @escaping @Sendable () async -> Data?) {
        self.queue = queue
        self.config = config
        self.asrEngine = asrEngine
        self.engine = engine
        self.statusProvider = statusProvider
    }

    /// 单连接的防御上限。socket 已 `chmod 0600` 挡住其他用户，但同一 UID 下的野脚本
    /// 仍能连上来：无上限的累积会被撑爆内存（曾有的写法里，`L` 帧长度还会整数溢出崩溃）。
    private nonisolated static let maxHeaderBytes = 64 * 1024
    private nonisolated static let maxBodyBytes = 64 * 1024 * 1024
    private nonisolated static let maxFrameBytes = 32 * 1024 * 1024

    nonisolated func handle(fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 65536)

        // 增量读到第一个换行（首行 header）。流式连接常开，绝不能等 EOF。
        var data = Data()
        var firstNL: Data.Index?
        while firstNL == nil {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if data.count > Self.maxHeaderBytes {
                Log.warn("Socket 接入: 首行超长（\(data.count) 字节），丢弃连接 fd=\(fd)")
                Darwin.close(fd)
                return
            }
            if let idx = data.firstIndex(of: 0x0A) { firstNL = idx }
        }
        Log.info("Socket 接入: fd=\(fd) bytes=\(data.count)")

        guard let nl = firstNL,
              let header = String(data: data[0..<nl], encoding: .utf8)?
                  .trimmingCharacters(in: .whitespaces),
              header.hasPrefix("{") else {
            // 无 header：读到 EOF，走传统整段播报
            guard drainToEOF(fd: fd, into: &data, buf: &buf) else {
                Darwin.close(fd)
                return
            }
            handleTTS(fd: fd, data: data)
            return
        }

        // 其余请求读完 body 到 EOF 后分发
        guard drainToEOF(fd: fd, into: &data, buf: &buf) else {
            Darwin.close(fd)
            return
        }
        guard let nl2 = data.firstIndex(of: 0x0A) else {
            handleTTS(fd: fd, data: data)
            return
        }
        let body = data[(nl2 + 1)...]
        if header.contains("type:asr") {
            Log.debug("ASR 请求: bytes=\(body.count)")
            handleASR(fd: fd, header: header, body: body)
        } else if header.contains("type:tts") {
            Log.debug("TTS PCM 请求: header=\(header) text_bytes=\(body.count)")
            handleTTSPCM(fd: fd, header: header, body: body)
        } else if header.contains("type:status") {
            Log.debug("状态查询请求")
            handleStatus(fd: fd)
        } else if header.contains("type:skip") {
            handleSkip(fd: fd, header: header)
        } else if header.contains("type:playback") {
            handlePlayback(fd: fd, header: header)
        } else if header.contains("type:quick") {
            handleQuick(fd: fd, header: header)
        } else if header.contains("type:lock") {
            handleScreen(fd: fd, unlock: false)
        } else if header.contains("type:unlock") {
            handleScreen(fd: fd, unlock: true)
        } else {
            handleTTS(fd: fd, data: data)
        }
    }

    /// 读到 EOF。超过 `maxBodyBytes` 视为异常客户端，返回 false（调用方丢弃连接）。
    private nonisolated func drainToEOF(fd: Int32, into data: inout Data, buf: inout [UInt8]) -> Bool {
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { return true }
            data.append(contentsOf: buf[0..<n])
            if data.count > Self.maxBodyBytes {
                Log.warn("Socket 接入: body 超长（>\(Self.maxBodyBytes) 字节），丢弃连接 fd=\(fd)")
                return false
            }
        }
    }

    private nonisolated func handleTTS(fd: Int32, data: Data) {
        defer { Darwin.close(fd) }
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespaces),
              !text.isEmpty else { return }
        // 停止帧 `{type:stop,source:x}`：**已无发送方**（hook.sh interrupt 摘除、ivox quiet
        // 已删除），留这一支是护栏不是死代码——它无换行、走的就是 handleTTS 的正文分支，
        // 少了它，旧脚本或存量 hook 发来的停止帧会被 cleanText 洗一遍**当正文念出来**
        //（"type:stop source claude"），比静默失效更难查。
        if text.hasPrefix("{type:stop"), let end = text.firstIndex(of: "}") {
            let inner = String(text[text.index(text.startIndex, offsetBy: 1)..<end])
            let source = inner.split(separator: ",")
                .first { $0.hasPrefix("source:") }
                .map { String($0.dropFirst("source:".count)) }
            Log.info("收到停止帧，忽略：打断权只归快捷键与 ivox skip（右⌘ 说话 / Ctrl+3 闭嘴 / Opt+Z 译文）(source=\(source ?? "未知") fd=\(fd) bytes=\(data.count))")
            return
        }

        // 曾经这里认一条魔法字符串（`__IVOX_STOP__`）就让整个守护进程 exit(0)——
        // **已删**（2026-10-26）：一句话就能弄死服务、谁都能发，一天被它弄没了三次、
        // 而且退出不留痕（那行日志是事后才补的，历史现场早没了）。
        // 现在要停 daemon 走**正经信号**：读实例锁里的 pid，发 SIGTERM →
        // 走的是信号那条退出路径（有日志、有清理、有退出栈）。
        
        let (source, voiceID, content, isNow) = parseRequest(text, config: config)
        // **服务端不管来源与音色**（2026-11-02）：客户端说是什么就是什么。
        // 缺 voice 是**正常路径**（`ivox speak --voice` 可省 → 走默认音色）；
        // 缺 source 也不拒，只按 default 记一笔，便于事后对账。
        Log.info("请求解析: source=\(source) voice=\(voiceID) raw_chars=\(content.count)")
        Log.debug("请求原始内容: source=\(source) raw=\(logPreview(content))")
        let cleaned = cleanText(content)
        if cleaned.isEmpty {
            Log.info("清洗后为空，跳过")
            return
        }
        let clen = cleaned.count
        let olen = content.count
        if olen > 0 {
            Log.info("清洗: [\(source)] \(olen)字 → \(clen)字 (减少 \((100*(olen-clen))/olen)%)")
        }
        Log.debug("清洗后内容: source=\(source) cleaned=\(logPreview(cleaned))")

        // 切句（合成单位）：整条一次合成会长时间占住播放（且要等整段合成完才出声），
        // 逐句入队才能边合成边播。切句真源只在 Swift 一份（`splitSentences`）。
        let jobs = splitSentences(cleaned).map {
            PlaybackJob(text: $0, voiceID: voiceID, source: source)
        }
        if isNow {
            // 用户自己要求现在念（Opt+Z 译文 / `ivox speak --now`）：**插队**——掐掉在播的、
            // 插到最前面立刻念，其余排队内容一个不丢，念完接着播原来的。
            // 与普通的「只排队」相反：那条是 agent 自动汇报，不该抢麦（否则两个后台会话收尾会
            // 互相掐掉对方的内容）；这条是用户按的，必须立刻响。
            Log.info("用户插队播报: source=\(source) voice=\(voiceID) chars=\(clen) 句=\(jobs.count)")
            Task { await queue.speakUserInitiated(jobs) }
        } else {
            // **一次请求 = 一页**（Claude 那边：一个 MessageDisplay 完整页 = 一次请求）。
            // 队列纯粹先来先进，不分组、不排队次。
            Log.info("队列入队: source=\(source) voice=\(voiceID) chars=\(clen) 句=\(jobs.count)")
            Task { await queue.enqueuePage(text: cleaned, jobs: jobs) }
        }
    }

    /// 跳过请求 `{type:skip,mode:page|all}`：手动打断的命令行入口（`ivox skip`
    /// 及其 `--all`），落到的就是 Ctrl+1 / Ctrl+2 分派的那几个方法。
    /// 两档都**只碰播报、不碰背景音乐**（音乐只归语音输入），故与热键逐字同路径。
    ///
    /// `by`：**请求方自报**的身份（如 "ivox-skip"），记进打断归因——
    /// 「谁打断的」要答得出来，就得有个人报名。
    /// 为什么不查内核里的对端 pid：`ivox skip` 这种发完就退的短命进程，
    /// 等我们读到帧时它早没了（实测 `getsockopt(LOCAL_PEERPID)` 返回 -1），
    /// 查出来是残值更糟。自报是唯一稳的渠道。
    private nonisolated func handleSkip(fd: Int32, header: String) {
        defer { Darwin.close(fd) }
        let kv = parseMetaKV(header)
        let mode = kv["mode"] ?? "page"
        // tag：自检脚本发打断时带上自己的 runId，好把自己的信号从"外部干扰"里择出去——
        // 否则它会被自己的检测抓成噪音，整条用例直接 skip（等于白挂）。
        let tag = kv["tag"].map { " tag=\($0)" } ?? ""
        let who = kv["by"] ?? "未署名"
        let by = kv["by"].map { " by=\($0)" } ?? ""
        Log.info("跳过请求: mode=\(mode)\(tag)\(by)")
        let trigger = InterruptTrigger.request(who)
        Task {
            switch mode {
            case "all":
                await queue.cancelAll(trigger)
            default:
                await queue.skipCurrentPage(trigger)
            }
        }
    }

    /// 播报总开关 `{type:playback,enabled:0|1}`：`ivox playback on/off` 的运行时入口。
    ///
    /// **只碰播报**：热键、划词翻译、微信、Web 控制台一律照常——这正是这个开关
    /// 与 `ivox off`（停整个守护进程）的区别。
    private nonisolated func handlePlayback(fd: Int32, header: String) {
        defer { Darwin.close(fd) }
        let kv = parseMetaKV(header)
        guard let raw = kv["enabled"] else {
            Log.warn("播报开关请求缺 enabled 字段")
            return
        }
        let flag: Bool
        switch raw.lowercased() {
        case "1", "true", "on": flag = true
        case "0", "false", "off": flag = false
        default:
            Log.warn("播报开关请求的 enabled 值看不懂：\(raw)")
            return
        }
        Log.info("播报开关请求: enabled=\(flag)")
        Task { await queue.setEnabled(flag) }
    }

    /// 快速操作的命令行入口（`ivox quick <action>`）：键盘上的 Opt+Q/A/X/S/C 由此获得第二扇门。
    ///
    /// **必须由 daemon 执行，不能在 CLI 进程里做**：这些动作要摸主线程（AppleScript 取
    /// Finder 选中项、`NSPasteboard` 写剪贴板），搬到 CLI 进程里就绕开了 daemon 的主线程，
    /// 也测不到它们与 TTS 合成并发时的行为——而那正是要查的地方。
    private nonisolated func handleQuick(fd: Int32, header: String) {
        defer { Darwin.close(fd) }
        let action = parseMetaKV(header)["action"] ?? "copy-path"
        Log.info("快速操作请求: action=\(action)")
        guard let hotKey = Self.quickHotKeys[action] else {
            Log.warn("快速操作: 未知动作 \(action)")
            return
        }
        // `QuickActionsService` 无实例状态（只有 `static let`），现造一个即可，
        // 省得为了这一个入口把 daemon 里那一份注入进来。
        Task { @MainActor in
            await QuickActionsService().handle(hotKey, at: .zero)
        }
    }

    /// 命令行动作名 → 热键动作。只认这几个，其余一律忽略（别让请求端能触发打断三档）。
    private nonisolated static let quickHotKeys: [String: HotKeyAction] = [
        "terminal": .openTerminal,
        "claude": .openTerminalClaude,
        "codex": .openTerminalCodex,
        "pi": .openTerminalPi,
        "copy-path": .copyPath,
    ]

    private nonisolated func handleASR(fd: Int32, header: String, body: Data) {
        let lang = parseMetaKV(header)["lang"] ?? "zh"

        Task {
            defer { Darwin.close(fd) }
            do {
                let text = try await asrEngine.transcribe(audioData: body, language: lang)
                let result = (text.isEmpty ? "" : text) + "\n"
                _ = result.data(using: .utf8).map { data in
                    data.withUnsafeBytes { raw in
                        Darwin.write(fd, raw.baseAddress, raw.count)
                    }
                }
                Log.info("ASR 识别完成 [\(text.prefix(60))]")
            } catch {
                Log.error("ASR 识别失败: \(error)")
            }
        }
    }

    /// 锁屏 / 解锁（请求-响应）。
    ///
    /// **要回复**：这两件事是「开门」动作，失败必须让人知道——不像 skip/quick 那样
    /// 打完就忘。回一行 JSON：`{"result":"ok"}` 或 `{"result":"failed","error":"…"}`。
    private nonisolated func handleScreen(fd: Int32, unlock: Bool) {
        Task {
            defer { Darwin.close(fd) }
            let result = unlock ? await ScreenControl.unlock() : await ScreenControl.lock()
            let payload: [String: String]
            switch result {
            case .success:
                payload = ["result": "ok"]
            case .failure(let error):
                payload = ["result": "failed", "error": error.errorDescription ?? "未知原因"]
            }
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
            _ = writeAll(data, to: fd)
        }
    }

    /// 返回守护进程状态 JSON（请求-响应）
    private nonisolated func handleStatus(fd: Int32) {
        let provider = statusProvider
        Task {
            defer { Darwin.close(fd) }
            if let json = await provider() {
                _ = writeAll(json, to: fd)
            }
        }
    }

    /// 合成 TTS 并将 PCM 分块写回客户端（请求-响应，不播放、不入队）
    private nonisolated func handleTTSPCM(fd: Int32, header: String, body: Data) {
        let meta = parseMetaKV(header)
        // 同上：服务端不管来源与音色，缺了用缺省（客户端该带全）。
        let sourceID = meta["source"] ?? VoiceSource.default
        let voiceID = meta["voice"] ?? config.defaultVoice

        let text = String(data: body, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleaned = cleanText(text)
        guard !cleaned.isEmpty else {
            _ = writeAll(StreamFrame.end, to: fd)
            Darwin.close(fd)
            return
        }

        Task {
            defer { Darwin.close(fd) }
            do {
                let stream = await engine.synthesizeStream(text: cleaned, voiceID: voiceID, trace: nil)
                var total = 0
                var ok = true
                for try await pcm in stream {
                    if !writeAll(StreamFrame.chunk(pcm), to: fd) {
                        ok = false
                        Log.warn("TTS PCM 写入失败，客户端断开，终止合成")
                        break
                    }
                    total += pcm.count
                }
                if ok {
                    _ = writeAll(StreamFrame.end, to: fd)
                    Log.info("TTS PCM 完成: source=\(sourceID) voice=\(voiceID) bytes=\(total) chars=\(cleaned.count)")
                }
            } catch {
                Log.error("TTS PCM 合成失败: \(error)")
                _ = writeAll(StreamFrame.end, to: fd)
            }
        }
    }

    /// 解析一次性播报请求：`{source:x,voice:y,now:1}` + 正文。
    ///
    /// **来源与音色是客户端的事，服务端不猜、不管**（2026-11-02）：给了就用给的，
    /// 没给就用缺省接着念。`source` 客户端必填（`ivox speak` 在命令行上把住这道），
    /// `voice` 可省——省了走默认音色。各端通常自己在配置里查好音色再带上。
    nonisolated private func parseRequest(_ text: String, config: Config) -> (source: String, voiceID: String, content: String, isNow: Bool) {
        guard text.hasPrefix("{"), let end = text.firstIndex(of: "}") else {
            return (VoiceSource.default, config.defaultVoice, text, false)
        }
        let kv = parseMetaKV(String(text[...end]))
        // now：用户自己要求现在念（Opt+Z 译文 / `ivox speak --now`）→ **插队**，不是排队。
        // 与 source 无关：Opt+Z 走这条路，自检也要能压到它，否则「唯一一条机器借道」的路径
        // 永远没有自动化回归保护。
        let source = kv["source"] ?? VoiceSource.default
        let voiceID = kv["voice"] ?? config.defaultVoice
        return (source, voiceID, String(text[text.index(after: end)...]), kv["now"] != nil)
    }
    nonisolated private func oneLine(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    /// 日志里只回显前 2000 字：TTS 仍拿全文，但超长回复不再往日志里灌几十万字符的 DEBUG 行
    nonisolated private func logPreview(_ value: String) -> String {
        let limit = 2000
        guard value.count > limit else { return oneLine(value) }
        return oneLine(String(value.prefix(limit))) + "…（共 \(value.count) 字，日志已截断）"
    }
}
