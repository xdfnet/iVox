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

        // 读**到 EOF**（主进程发完就 shutdown 写端），再从整段里切出首行 header。
        //
        // 为什么不是「读到换行就停」：那样拿到的正文只是同一次 read 里的剩余字节，
        // 正文若被拆到第二次 read 就**静默截断** —— 半句话拿去合成，主进程毫无察觉。
        // 主进程现在一次 write 发完、正文又远小于 socket 缓冲区，碰不到；
        // 但这条协议没有长度字段，唯一的保险就是读干净。
        var data = Data()
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if data.count > Self.maxBodyBytes {
                Log.warn("誊清员: 请求超长（\(data.count) 字节），丢弃连接 fd=\(fd)")
                Darwin.close(fd)
                return
            }
        }

        // 一个字节都没有 = 对端连上就走了。那是 `SocketClient.isRunning` 的探测连接，
        // 不是请求。它每次问「好了没」都会来一次，报警报就成了心跳噪音。
        guard !data.isEmpty else {
            Darwin.close(fd)
            return
        }
        guard let nl = data.firstIndex(of: 0x0A) else {
            Log.warn("誊清员: 收到 \(data.count) 字节却没 header 换行，丢弃 fd=\(fd)")
            Darwin.close(fd)
            return
        }
        let header = String(decoding: data[0..<nl], as: UTF8.self)
        let body = Data(data[(nl + 1)...])
        let meta = parseMetaKV(header)

        // 状态查询：主进程靠它判断模型好了没、还能不能派活。不碰模型，只回一行字。
        // **必须排在类型校验之前** —— 它自己就是 `type:status`。
        if meta["type"] == "status" {
            Task {
                let reply: String
                switch await engine.state {
                case .ready: reply = "{state:ready}"
                case .failed(let msg): reply = "{state:failed:\(msg)}"
                case .notStarted, .loading: reply = "{state:loading}"
                }
                _ = writeAll(Data(reply.utf8), to: fd)
                Darwin.close(fd)
            }
            return
        }

        // 认不得的请求直接丢，不往合成里送：否则一段普通文本会被当成正文，
        // 合成为一句莫名其妙的话，还算在块号头上污染归因。
        guard meta["type"] == "tts" else {
            Log.warn("誊清员: 非合成请求 type=\(meta["type"] ?? "(缺)")，丢弃 fd=\(fd)")
            Darwin.close(fd)
            return
        }

        let sourceID = meta["source"] ?? "default"
        let voiceID = meta["voice"] ?? config.sourceVoices[sourceID] ?? config.defaultVoice
        // 块号：主进程递过来的助理自编流水号，块的唯一身份。带在每行日志上，
        // 这一块在本进程的经历才能被归因工具跨文件串起来，而不是靠时间戳猜。
        let trace = TTSTrace(seq: meta["seq"].flatMap(UInt.init), source: meta["source"])
        // **不再 cleanText**：主进程送来的正文清洗过了——三个入队点
        // （`ConnectionHandler` 两处、`TranslationCoordinator` 一处）都在构造
        // `PlaybackJob` 之前跑过 `cleanText` + `splitSentences`。这里再跑一遍是恒等，
        // 而 cleanText 是 Markdown AST 解析，不便宜。
        let cleaned = String(decoding: body, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            _ = writeAll(StreamFrame.end, to: fd)
            Darwin.close(fd)
            return
        }

        Log.info("誊清开始 voice=\(voiceID) chars=\(cleaned.count)\(trace.logSuffix)")
        Task {
            defer { Darwin.close(fd) }
            do {
                let stream = await engine.synthesizeStream(text: cleaned, voiceID: voiceID, trace: trace)
                var total = 0
                for try await pcm in stream {
                    if !writeAll(StreamFrame.chunk(pcm), to: fd) {
                        Log.warn("誊清: 写入失败（主进程断开），终止本次合成\(trace.logSuffix)")
                        break
                    }
                    total += pcm.count
                }
                _ = writeAll(StreamFrame.end, to: fd)
                Log.info("誊清完成 voice=\(voiceID) bytes=\(total)\(trace.logSuffix)")
            } catch {
                Log.error("誊清失败: \(error)\(trace.logSuffix)")
                _ = writeAll(StreamFrame.end, to: fd)
            }
        }
    }

}
