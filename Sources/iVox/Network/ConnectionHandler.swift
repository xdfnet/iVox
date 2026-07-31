import Darwin
import Foundation
import iVoxKit

actor ConnectionHandler {
    private let queue: PlaybackQueue
    private let config: Config
    private let asrEngine: ASREngine
    private let engine: TTSEngine

    init(queue: PlaybackQueue, config: Config, asrEngine: ASREngine, engine: TTSEngine) {
        self.queue = queue
        self.config = config
        self.asrEngine = asrEngine
        self.engine = engine
    }

    nonisolated func handle(fd: Int32) {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        Log.info("Socket 接入: fd=\(fd) bytes=\(data.count)")

        // 找第一个 \n 切分头/体
        if let nl = data.firstIndex(of: 0x0A) {
            let headerBytes = data[0..<nl]
            guard let header = String(data: headerBytes, encoding: .utf8)?.trimmingCharacters(in: .whitespaces),
                  header.hasPrefix("{") else {
                handleTTS(fd: fd, data: data)
                return
            }
            let body = data[(nl + 1)...]
            if header.contains("type:asr") {
                Log.debug("ASR 请求: bytes=\(body.count)")
                handleASR(fd: fd, header: header, body: body)
            } else if header.contains("type:tts") {
                Log.debug("TTS PCM 请求: header=\(header) text_bytes=\(body.count)")
                handleTTSPCM(fd: fd, header: header, body: body)
            } else {
                handleTTS(fd: fd, data: data)
            }
        } else {
            handleTTS(fd: fd, data: data)
        }
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
        Log.debug("请求原始内容: source=\(source) raw=\(oneLine(content))")
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
        Log.debug("清洗后内容: source=\(source) cleaned=\(oneLine(cleaned))")

        let job = PlaybackJob(text: cleaned, voiceID: voiceID, source: source)
        Log.info("队列入队: source=\(source) voice=\(voiceID) chars=\(cleaned.count)")
        Task { await queue.enqueue(job) }
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
}
