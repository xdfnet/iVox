import Darwin
import Foundation
import iVoxKit

/// Unix socket 单连接处理：按首行 header 分发到 TTS / 流式 / ASR / 状态等分支。
actor ConnectionHandler {
    private let queue: PlaybackQueue
    private let config: Config
    private let asrEngine: ASREngine
    private let engine: TTSEngine
    private let statusProvider: @Sendable () async -> Data?

    init(queue: PlaybackQueue, config: Config, asrEngine: ASREngine, engine: TTSEngine,
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

        if header.contains("type:stream") {
            handleStream(fd: fd, header: header, leftover: data[(nl + 1)...], buf: &buf)
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

    /// 流式播报：首帧 `{type:stream,source:x,voice:y,turn:<id>}`，其后逐帧增量原文，
    /// `{end}` 结束（flush 残尾），`{cancel}` 取消。帧以 \n 分隔；delta 内含的 \n
    /// 被切成帧边界（补回后正好作为句末 flush 触发）。EOF 也按结束兜底。
    private nonisolated func handleStream(fd: Int32, header: String, leftover: Data,
                                          buf: inout [UInt8]) {
        defer { Darwin.close(fd) }
        let meta = parseMetaKV(header)
        let source = meta["source"] ?? "default"
        let voiceID = meta["voice"] ?? config.sourceVoices[source] ?? config.defaultVoice
        guard let turn = meta["turn"], !turn.isEmpty else {
            Log.warn("stream 缺少 turn，丢弃连接")
            return
        }
        Log.info("流式开始: source=\(source) voice=\(voiceID) turn=\(turn)")
        // 本连接的入队/结束/取消全部串到同一根链上：帧序 = 执行序（见 StreamOpChain）
        let chain = StreamOpChain()
        chain.hop { await self.queue.beginTurn(turn) }

        let sb = StreamBuffer()
        var acc = Data()
        var closed = false
        // 长度帧状态：读到 "<n>\n" 后，记录还差多少字节正文；非 nil 时不按行解析。
        var expectBytes: Int? = nil

        // 返回 false 表示收到结束/取消控制帧，停止读取。
        func feed(_ chunk: Data) -> Bool {
            acc.append(chunk)
            // 帧迟迟不完整时也不能让 acc 无限涨
            guard acc.count <= Self.maxBodyBytes else {
                Log.warn("流式连接缓冲超长（\(acc.count) 字节），停止读取")
                return false
            }
            while true {
                // ── 长度帧正文消费中：按剩余字节数精确切，正文可含任意字节（含 \n/{end}）──
                if let need = expectBytes {
                    guard acc.count >= need else { return true }   // 数据不全，等更多
                    let payload = Data(acc.prefix(need))
                    acc.removeFirst(need)
                    expectBytes = nil
                    if let text = String(data: payload, encoding: .utf8), !text.isEmpty {
                        for block in sb.append(text) {
                            emitStreamBlock(block, source: source, voiceID: voiceID, turn: turn, chain: chain)
                        }
                    }
                    continue
                }

                guard let nl = acc.firstIndex(of: 0x0A) else { return true }  // 行不完整
                let line = Data(acc[acc.startIndex..<nl])
                acc.removeSubrange(acc.startIndex...nl)

                // 长度帧头："L<n>" → 下一帧是 n 字节自描述正文。L 前缀使其不可能与
                // 正常正文行（含纯数字、{end} 等）或旧客户端裸文本混淆。
                if line.first == 0x4C, let len = parseLengthPrefix(Data(line.dropFirst())) {
                    expectBytes = len
                    continue
                }

                // 控制帧 / 旧裸文本（兼容老客户端）
                guard let frame = String(data: line, encoding: .utf8) else { continue }
                if frame == "{end}" {
                    finishStream(sb: sb, source: source, voiceID: voiceID, turn: turn, chain: chain)
                    return false
                }
                if frame.hasPrefix("{cancel") {
                    Log.info("流式取消: turn=\(turn)")
                    chain.hop { await self.queue.cancelTurn(turn) }
                    return false
                }
                for block in sb.append(frame + "\n") {
                    emitStreamBlock(block, source: source, voiceID: voiceID, turn: turn, chain: chain)
                }
            }
        }

        if !leftover.isEmpty { closed = !feed(leftover) }
        while !closed {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { break }
            if !feed(Data(buf[0..<n])) { closed = true; break }
        }
        if !closed {  // EOF 兜底：正常结束 flush 残尾
            finishStream(sb: sb, source: source, voiceID: voiceID, turn: turn, chain: chain)
        }
    }

    /// 解析长度头数字部分（调用方已确认行首为 'L'）；空 / 非数字 / 超限返回 nil。
    /// 先卡位数再算：否则 `L` 跟一长串数字会让 `n * 10` 溢出，直接 trap 崩掉整个守护进程
    /// （而守护进程没有自恢复），这是同 UID 进程最容易踩到的一脚。
    private nonisolated func parseLengthPrefix(_ data: Data) -> Int? {
        guard !data.isEmpty, data.count <= 10 else { return nil }
        var n = 0
        for b in data {
            guard b >= 0x30, b <= 0x39 else { return nil }
            n = n * 10 + Int(b - 0x30)
        }
        return n <= Self.maxFrameBytes ? n : nil
    }

    private nonisolated func emitStreamBlock(_ raw: String, source: String,
                                             voiceID: String, turn: String, chain: StreamOpChain) {
        let cleaned = cleanText(raw)
        guard !cleaned.isEmpty else { return }
        let jobs = splitSentences(cleaned).map {
            PlaybackJob(text: $0, voiceID: voiceID, source: source, turnID: turn)
        }
        Log.info("流式入队: turn=\(turn) 分块=\(jobs.count) chars=\(cleaned.count)")
        chain.hop { await self.queue.enqueue(jobs, turnID: turn) }
    }

    private nonisolated func finishStream(sb: StreamBuffer, source: String,
                                          voiceID: String, turn: String, chain: StreamOpChain) {
        if let tail = sb.finish() {
            emitStreamBlock(tail, source: source, voiceID: voiceID, turn: turn, chain: chain)
        }
        chain.hop { await self.queue.endTurn(turn) }
        Log.info("流式结束: turn=\(turn)")
    }

    private nonisolated func handleTTS(fd: Int32, data: Data) {
        defer { Darwin.close(fd) }
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespaces),
              !text.isEmpty else { return }
        if text == "__IVOX_STOP__" {
            Log.info("收到停止指令，守护进程退出")
            exit(0)
        }
        if text == "__IVOX_STOP_PLAYBACK__" {
            Log.info("收到停止播放指令，取消当前及排队播放")
            Task { await queue.cancelAll() }
            return
        }

        let (source, voiceID, content) = extractVoicePrefix(text, config: config)
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

        // 分块入队：整条一次合成会长时间占住播放（且要等整段合成完才出声），逐句入队才能边合成边播
        let chunks = splitSentences(cleaned)
        let jobs = chunks.map { PlaybackJob(text: $0, voiceID: voiceID, source: source) }
        Log.info("队列入队: source=\(source) voice=\(voiceID) chars=\(cleaned.count) 分块=\(jobs.count)")
        Task { await queue.enqueue(jobs) }
    }

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
        let sourceID = meta["source"] ?? "default"
        let voiceID = meta["voice"] ?? config.sourceVoices[sourceID] ?? config.defaultVoice

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
                let stream = await engine.synthesizeStream(text: cleaned, voiceID: voiceID)
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

    /// 循环写入直到全部写完，处理短写
    private nonisolated func writeAll(_ data: Data, to fd: Int32) -> Bool {
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

    private nonisolated func parseMetaKV(_ header: String) -> [String: String] {
        guard header.hasPrefix("{"),
              let end = header.firstIndex(of: "}") else { return [:] }
        let inner = String(header[header.index(after: header.startIndex)..<end])
        var dict: [String: String] = [:]
        for pair in inner.split(separator: ",") {
            let kv = pair.split(separator: ":", maxSplits: 1)
            if kv.count == 2 { dict[String(kv[0])] = String(kv[1]) }
        }
        return dict
    }

    nonisolated private func extractVoicePrefix(_ text: String, config: Config) -> (source: String, voiceID: String, content: String) {
        guard text.hasPrefix("{"), let end = text.firstIndex(of: "}") else {
            return ("default", config.defaultVoice, text)
        }
        let metaStr = String(text[text.index(after: text.startIndex)..<end])
        let pairs = metaStr.split(separator: ",").map { $0.split(separator: ":", maxSplits: 1).map(String.init) }
        var sourceID = "default"
        var explicitVoice: String?
        for pair in pairs where pair.count == 2 {
            switch pair[0] {
            case "source": sourceID = pair[1]
            case "voice":  explicitVoice = pair[1]
            default: break
            }
        }
        let voiceID = explicitVoice ?? config.sourceVoices[sourceID] ?? config.defaultVoice
        let content = String(text[text.index(after: end)...])
        return (sourceID, voiceID, content)
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

/// 单连接内的队列操作串行链：让首帧 / 入队 / `{end}` / `{cancel}` 严格按**帧序**落地。
/// 原先这四处各自 `Task {}`，落到 PlaybackQueue 的顺序全凭调度器——实测 `{end}` 的 Task
/// 抢在同一连接后一个入队 Task 之前执行：轮次已被 `{end}` 关闭（turnOpen=0），迟到的同轮
/// 入队又把它打开且再无人关，管道把分块播完后永久停在「等新 job」（/health 恒 playing=true、
/// queued=0，看门狗与 drain 都够不着）。黑盒 A-tail/E3 用例抓到的「未收尾」即此。
/// `hop` 只在连接自己的读取线程（`handle` → `feed`）调用，故无需同步。
private final class StreamOpChain {
    private var tail: Task<Void, Never>?

    func hop(_ op: @escaping @Sendable () async -> Void) {
        let prev = tail
        tail = Task {
            if let prev { _ = await prev.value }
            await op()
        }
    }
}
