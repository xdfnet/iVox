import Darwin
import Foundation

enum ASRClient {
    struct Response {
        let text: String
    }

    static func transcribe(audio: Data, language: String, baseURL: String, model: String) throws -> String {
        let endpoint = try Endpoint(baseURL)
        let fd = try connect(host: endpoint.host, port: endpoint.port)
        defer { close(fd) }

        let request: [String: Any] = [
            "op": "asr",
            "language": language,
            "model": model,
            "audio_bytes": audio.count,
        ]
        let json = try JSONSerialization.data(withJSONObject: request)
        try writeAll(lengthPrefixed(json), to: fd)
        try writeAll(audio, to: fd)

        while true {
            let frame = try readFrame(from: fd)
            switch frame.type {
            case 2:
                if let obj = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any],
                   let text = obj["text"] as? String {
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return (String(data: frame.payload, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            case 3:
                let msg = String(data: frame.payload, encoding: .utf8) ?? "ASR server error"
                throw ASRError.serverError(msg)
            case 4:
                return ""
            default:
                continue
            }
        }
    }
}

enum ASRError: Error {
    case serverError(String)
    case invalidEndpoint
}

// MARK: - TCP helpers

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

private func connect(host: String, port: Int) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(.ENOTSOCK) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = UInt16(port).bigEndian
    guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
        close(fd)
        throw ASRError.invalidEndpoint
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

private struct Frame {
    var type: UInt8
    var payload: Data
}

private func lengthPrefixed(_ data: Data) -> Data {
    var out = Data()
    appendUInt32BE(UInt32(data.count), to: &out)
    out.append(data)
    return out
}

private func readFrame(from fd: Int32) throws -> Frame {
    let header = try readExactly(5, from: fd)
    let length = Int(readUInt32BE(header, at: 1))
    return Frame(type: header[0], payload: length > 0 ? try readExactly(length, from: fd) : Data())
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
