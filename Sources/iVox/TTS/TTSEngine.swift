import Darwin
import Foundation
import iVoxKit

actor TTSEngine {
    private let config: Config
    private let maxRetries = 2
    private let chunkSamples = 5760
    private let sampleRate = 24_000

    init(config: Config) {
        self.config = config
    }

    var isLoaded: Bool { true }

    func synthesizeStream(text: String, voiceID: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await synthesizeWithRetry(text: text, voiceID: voiceID, continuation: continuation)
            }
        }
    }

    private func synthesizeWithRetry(
        text: String,
        voiceID: String,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) async {
        for attempt in 0...maxRetries {
            do {
                try await synthesizeOnce(text: text, voiceID: voiceID, continuation: continuation)
                return
            } catch {
                let isLast = attempt == maxRetries
                Log.error("TTS 合成失败 (attempt \(attempt + 1)/\(maxRetries + 1)): \(error)")
                if isLast {
                    continuation.finish(throwing: error)
                    return
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    private func synthesizeOnce(
        text: String,
        voiceID: String,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) async throws {
        let endpoint = try Endpoint(config.api.baseURL)
        let fd = try connect(host: endpoint.host, port: endpoint.port)
        defer { close(fd) }

        let request: [String: Any] = [
            "op": "tts",
            "text": text,
            "voice": voiceID,
            "streaming_interval": 0.24,
        ]
        let json = try JSONSerialization.data(withJSONObject: request)
        try writeAll(makeLengthPrefixed(json), to: fd)

        Log.info("TTS TCP 请求: voice=\(voiceID) text_chars=\(text.count) endpoint=\(endpoint.host):\(endpoint.port)")

        let prebufferSamples = prebufferSamples(forTextLength: text.count)
        var sampleBuffer: [Float] = []
        sampleBuffer.reserveCapacity(prebufferSamples + chunkSamples)
        var totalSamples = 0
        var chunkIdx = 0
        var startedStreaming = false
        let requestStartedAt = Date()

        while true {
            let frame = try readFrame(from: fd)
            switch frame.type {
            case .audio:
                let samples = extractFloatSamples(frame.payload)
                totalSamples += samples.count
                sampleBuffer.append(contentsOf: samples)

                if !startedStreaming, sampleBuffer.count >= prebufferSamples {
                    startedStreaming = true
                    Log.info("TTS 预缓冲完成: samples=\(sampleBuffer.count) latency=\(String(format: "%.2f", -requestStartedAt.timeIntervalSinceNow))s")
                }
                if startedStreaming {
                    chunkIdx += yieldReadyChunks(from: &sampleBuffer, continuation: continuation, firstChunkIndex: chunkIdx)
                }

            case .text:
                continue

            case .error:
                let message = String(data: frame.payload, encoding: .utf8) ?? "TTS server error"
                throw TTSError.serverError(message)

            case .end:
                if totalSamples == 0 { throw TTSError.noAudioData }
                while !sampleBuffer.isEmpty {
                    let end = min(chunkSamples, sampleBuffer.count)
                    let chunk = Array(sampleBuffer.prefix(end))
                    sampleBuffer.removeFirst(end)
                    let pcm = audioToPCM(chunk)
                    if chunkIdx == 0 {
                        Log.info("TTS 首块: samples=\(chunk.count) pcm_bytes=\(pcm.count)")
                    }
                    continuation.yield(pcm)
                    chunkIdx += 1
                }
                Log.info("TTS 完成: total_samples=\(totalSamples) chunks=\(chunkIdx)")
                continuation.finish()
                return
            }
        }
    }

    private func yieldReadyChunks(
        from sampleBuffer: inout [Float],
        continuation: AsyncThrowingStream<Data, Error>.Continuation,
        firstChunkIndex: Int
    ) -> Int {
        var emitted = 0
        while sampleBuffer.count >= chunkSamples {
            let chunk = Array(sampleBuffer.prefix(chunkSamples))
            sampleBuffer.removeFirst(chunkSamples)
            let pcm = audioToPCM(chunk)
            if firstChunkIndex + emitted == 0 {
                Log.info("TTS 首块: samples=\(chunk.count) pcm_bytes=\(pcm.count)")
            }
            continuation.yield(pcm)
            emitted += 1
        }
        return emitted
    }

    private func prebufferSamples(forTextLength count: Int) -> Int {
        let seconds: Double
        switch count {
        case 0...80: seconds = 0.8
        case 81...220: seconds = 2.0
        default: seconds = 6.0
        }
        return Int(Double(sampleRate) * seconds)
    }
}

private struct Endpoint {
    var host: String
    var port: Int

    init(_ value: String) throws {
        if let url = URL(string: value), let host = url.host {
            self.host = host
            self.port = url.port ?? 8150
            return
        }
        let trimmed = value
            .replacingOccurrences(of: "tcp://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "/v1", with: "")
        let parts = trimmed.split(separator: ":", maxSplits: 1).map(String.init)
        self.host = parts.first ?? "127.0.0.1"
        self.port = parts.dropFirst().first.flatMap(Int.init) ?? 8150
    }
}

private struct Frame {
    var type: FrameType
    var payload: Data
}

private enum FrameType: UInt8 {
    case audio = 1
    case text = 2
    case error = 3
    case end = 4
}

private enum TTSError: Error {
    case invalidEndpoint
    case noAudioData
    case serverError(String)
}

private func connect(host: String, port: Int) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.ENOTSOCK) }

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = UInt16(port).bigEndian
    guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
        close(fd)
        throw TTSError.invalidEndpoint
    }

    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard ok == 0 else {
        close(fd)
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
    }
    return fd
}

private func makeLengthPrefixed(_ data: Data) -> Data {
    var out = Data()
    appendUInt32BE(UInt32(data.count), to: &out)
    out.append(data)
    return out
}

private func readFrame(from fd: Int32) throws -> Frame {
    let header = try readExactly(5, from: fd)
    guard let type = FrameType(rawValue: header[0]) else { throw TTSError.serverError("Invalid frame type") }
    let length = Int(readUInt32BE(header, at: 1))
    let payload = length > 0 ? try readExactly(length, from: fd) : Data()
    return Frame(type: type, payload: payload)
}

private func readExactly(_ count: Int, from fd: Int32) throws -> Data {
    var data = Data(count: count)
    var offset = 0
    try data.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress else { throw POSIXError(.EIO) }
        while offset < count {
            let n = Darwin.read(fd, base.advanced(by: offset), count - offset)
            if n < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if n == 0 { throw POSIXError(.ECONNRESET) }
            offset += n
        }
    }
    return data
}

private func writeAll(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset < data.count {
            let n = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
            if n < 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            offset += n
        }
    }
}

private func extractFloatSamples(_ data: Data) -> [Float] {
    let count = data.count / 4
    guard count > 0 else { return [] }
    return data.withUnsafeBytes { ptr in
        guard let base = ptr.baseAddress?.assumingMemoryBound(to: Float.self) else { return [] }
        return Array(UnsafeBufferPointer(start: base, count: count))
    }
}

private func appendUInt32BE(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8(value & 0xff))
}

private func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
    (UInt32(data[offset]) << 24) |
    (UInt32(data[offset + 1]) << 16) |
    (UInt32(data[offset + 2]) << 8) |
    UInt32(data[offset + 3])
}
