import Darwin
import Foundation
import iVoxKit

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

    nonisolated func handle(fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 65536)

        // 增量读到第一个换行（首行 header）。流式连接常开，绝不能等 EOF。
        var data = Data()
        var firstNL: Data.Index?
        while firstNL == nil {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if let idx = data.firstIndex(of: 0x0A) { firstNL = idx }
        }
        Log.info("Socket 接入: fd=\(fd) bytes=\(data.count)")

        guard let nl = firstNL,
              let header = String(data: data[0..<nl], encoding: .utf8)?
                  .trimmingCharacters(in: .whitespaces),
              header.hasPrefix("{") else {
            // 无 header：读到 EOF，走传统整段播报
            drainToEOF(fd: fd, into: &data, buf: &buf)
            handleTTS(fd: fd, data: data)
            return
        }

        if header.contains("type:stream") {
            handleStream(fd: fd, header: header, leftover: data[(nl + 1)...], buf: &buf)
            return
        }

        // 其余请求读完 body 到 EOF 后分发
        drainToEOF(fd: fd, into: &data, buf: &buf)
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

    private nonisolated func drainToEOF(fd: Int32, into data: inout Data, buf: inout [UInt8]) {
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
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
        Task { await queue.beginTurn(turn) }

        let sb = StreamBuffer()
        var acc = Data()
        var closed = false
        // 长度帧状态：读到 "<n>\n" 后，记录还差多少字节正文；非 nil 时不按行解析。
        var expectBytes: Int? = nil

        // 返回 false 表示收到结束/取消控制帧，停止读取。
        func feed(_ chunk: Data) -> Bool {
            acc.append(chunk)
            while true {
                // ── 长度帧正文消费中：按剩余字节数精确切，正文可含任意字节（含 \n/{end}）──
                if let need = expectBytes {
                    guard acc.count >= need else { return true }   // 数据不全，等更多
                    let payload = Data(acc.prefix(need))
                    acc.removeFirst(need)
                    expectBytes = nil
                    if let text = String(data: payload, encoding: .utf8), !text.isEmpty {
                        for block in sb.append(text) {
                            emitStreamBlock(block, source: source, voiceID: voiceID, turn: turn)
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
                    finishStream(sb: sb, source: source, voiceID: voiceID, turn: turn)
                    return false
                }
                if frame.hasPrefix("{cancel") {
                    Log.info("流式取消: turn=\(turn)")
                    Task { await queue.cancelTurn(turn) }
                    return false
                }
                for block in sb.append(frame + "\n") {
                    emitStreamBlock(block, source: source, voiceID: voiceID, turn: turn)
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
            finishStream(sb: sb, source: source, voiceID: voiceID, turn: turn)
        }
    }

    /// 解析长度头数字部分（调用方已确认行首为 'L'）；空/非数字返回 nil。
    private nonisolated func parseLengthPrefix(_ data: Data) -> Int? {
        guard !data.isEmpty else { return nil }
        var n = 0
        for b in data {
            guard b >= 0x30, b <= 0x39 else { return nil }
            n = n * 10 + Int(b - 0x30)
        }
        return n
    }

    private nonisolated func emitStreamBlock(_ raw: String, source: String,
                                             voiceID: String, turn: String) {
        let cleaned = cleanText(raw)
        guard !cleaned.isEmpty else { return }
        let jobs = splitSentences(cleaned).map {
            PlaybackJob(text: $0, voiceID: voiceID, source: source, turnID: turn)
        }
        Log.info("流式入队: turn=\(turn) 分块=\(jobs.count) chars=\(cleaned.count)")
        Task { await queue.enqueue(jobs, turnID: turn) }
    }

    private nonisolated func finishStream(sb: StreamBuffer, source: String,
                                          voiceID: String, turn: String) {
        if let tail = sb.finish() {
            emitStreamBlock(tail, source: source, voiceID: voiceID, turn: turn)
        }
        Task { await queue.endTurn(turn) }
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

        // 分块入队：整条一次合成会长时间占住播放，「↓ 跳过当前段」也失去意义
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
