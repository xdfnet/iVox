import Darwin
import Foundation
import iVoxKit

actor ConnectionHandler {
    private let queue: PlaybackQueue
    private let config: Config

    init(queue: PlaybackQueue, config: Config) {
        self.queue = queue
        self.config = config
    }

    nonisolated func handle(fd: Int32) {
        defer { Darwin.close(fd) }

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        Log.info("连接收包: bytes=\(data.count)")
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespaces),
              !text.isEmpty else { return }
        if text == "__IAURA_STOP__" {
            Log.info("收到停止指令，守护进程退出")
            exit(0)
        }

        let (source, voiceID, content) = extractVoicePrefix(text, config: config)
        Log.info("请求解析: source=\(source) voice=\(voiceID) raw_chars=\(content.count)")
        Log.info("请求内容: source=\(source) raw=\(oneLine(content))")
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
        Log.info("清洗内容: source=\(source) cleaned=\(oneLine(cleaned))")

        let job = PlaybackJob(text: cleaned, voiceID: voiceID, source: source)
        Log.info("队列入队: source=\(source) voice=\(voiceID) chars=\(cleaned.count)")
        Task { await queue.enqueue(job) }
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
