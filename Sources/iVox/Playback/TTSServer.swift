import Darwin
import Foundation
import iVoxKit

// 誊清员进程的服务端：把字条变成能念的东西，原样写回给主进程。
//
// 它只做「合成 → PCM 写回」这一件事：不播放、不入队、不编号、不记进度。
// 协议与 ConnectionHandler 的 `handleTTSPCM` 完全一致（`{type:tts,voice:x}` +
// 正文 → StreamFrame 长度帧流），所以主进程侧可以直接复用现成的解码器
// `StreamFrame.parseChunks`。
//
// 为什么单独一个进程：MLX 的 Metal 命令编码器在析构时会重复释放 GPU 命令队列
// （`CommandEncoder::~CommandEncoder` → `-_MTLCommandEncoder dealloc` 断言 →
// SIGTRAP）。这个 bug 上游未修且 iVox 拿不到 encoder 引用无从拦截，所以只能把
// 会炸的这一层隔离出去 —— 它炸了，主进程里的队列与桌面上的字条安然无恙。

final class TTSServer: SocketConnectionHandler {
    /// 单帧请求的正文上限，与主 daemon 的 `ConnectionHandler.maxBodyBytes` 同量级，
    /// 防损坏/恶意流撑爆缓冲
    private static let maxBodyBytes = 64 * 1024 * 1024

    private let engine: TTSEngine
    private let config: Config

    init(engine: TTSEngine, config: Config) {
        self.engine = engine
        self.config = config
    }

    func handle(fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 65536)

        // 读首行 header 到换行。这一层不用流式（主进程与本进程一问一答），
        // 所以读满整段到 EOF 即可，不必像主 daemon 那样逐帧解析。
        var data = Data()
        var header = ""
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if let nl = data.firstIndex(of: 0x0A) {
                header = String(decoding: data[0..<nl], as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
                data = Data(data[(nl + 1)...])
                break
            }
            if data.count > Self.maxBodyBytes {
                Log.warn("誊清员: 首行超长（\(data.count) 字节），丢弃连接 fd=\(fd)")
                Darwin.close(fd)
                return
            }
        }

        let body = data
        let meta = Self.parseMetaKV(header)
        let sourceID = meta["source"] ?? "default"
        let voiceID = meta["voice"] ?? config.sourceVoices[sourceID] ?? config.defaultVoice
        let text = String(decoding: body, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 清洗走主进程已经送来的干净文本时是恒等；这里仍跑一遍以防调用方直送
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
                for try await pcm in stream {
                    if !writeAll(StreamFrame.chunk(pcm), to: fd) {
                        Log.warn("誊清员: 写入失败（主进程断开），终止本次合成")
                        break
                    }
                    total += pcm.count
                }
                _ = writeAll(StreamFrame.end, to: fd)
                Log.info("誊清: voice=\(voiceID) bytes=\(total) chars=\(cleaned.count)")
            } catch {
                Log.error("誊清失败: \(error)")
                _ = writeAll(StreamFrame.end, to: fd)
            }
        }
    }

    /// 循环写入直到全部写完，处理短写
    private func writeAll(_ data: Data, to fd: Int32) -> Bool {
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

    /// 解析 `{k:v,k:v}` 形式的 meta。与 `ConnectionHandler.parseMetaKV` 同款，
    /// 刻意不抽到 iVoxKit 共用：那边是 actor 的 nonisolated 方法，跨 target 共享
    /// 得连同整个 ConnectionHandler 一起下沉，收益不抵改动面。
    private static func parseMetaKV(_ header: String) -> [String: String] {
        var result: [String: String] = [:]
        let trimmed = header.trimmingCharacters(in: CharacterSet(charactersIn: "{} \t"))
        for pair in trimmed.split(separator: ",") {
            let parts = pair.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 { result[parts[0]] = parts[1] }
        }
        return result
    }
}
