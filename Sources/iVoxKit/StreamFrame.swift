import Foundation

// 长度帧协议（L<n> + 正文 + end）。

/// TTS「合成返回 PCM」分块帧编码。
/// 格式：`[4B 小端 UInt32 长度 N][N 字节 48kHz Int16 mono PCM]`，合成结束写 `end`（4 个 0）。
/// 放 iVoxKit 以便 iVoxTests 直接单测编解码。
public enum StreamFrame {
    /// 单帧数据上限（100MB），防止恶意/损坏流声明超大帧导致缓冲膨胀
    public static let maxFrameBytes = 100 * 1024 * 1024

    /// 编码一帧：4 字节小端长度前缀 + 数据
    public static func chunk(_ data: Data) -> Data {
        var out = Data()
        out.reserveCapacity(data.count + 4)
        var length = UInt32(clamping: data.count).littleEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(data)
        return out
    }

    /// 结束标记：4 字节 0
    public static let end: Data = Data([0, 0, 0, 0])

    /// 解码一段字节流为帧 + 剩余未完整数据。
    /// 缓冲用 `[UInt8]` 而非 `Data`：跨多次 append/removeFirst 累积的
    /// `Data` 在此工具链下访问会崩溃，数组缓冲稳定可靠。
    /// - Parameters:
    ///   - data: 新到达的字节
    ///   - remaining: 上次未消费完的剩余缓冲（inout，消费后可回写）
    /// - Returns: 完整帧列表
    public static func parseChunks(from data: Data, into remaining: inout [UInt8]) -> [Data] {
        var sawEnd = false
        return parseChunks(from: data, into: &remaining, sawEnd: &sawEnd)
    }

    /// 同上，但额外报告**是否见到了结束标志**。
    ///
    /// 为什么需要：结束标志是被「吃掉」的，调用方只看到帧列表，拿不到这一条。
    /// 而对面进程若在合成中途崩掉，读端只会拿到 EOF —— 与「正常念完」的表象**完全一样**。
    /// 没有这个标志，半句话就会被当成完整的一句交出去：用户听到半句被掐断，
    /// 而日志里一行异常都没有，正是这次拆进程要消灭的那种「静默」。
    /// - Parameter sawEnd: 一旦见到 4 字节 0 的结束标志即置 true（只置不清）
    public static func parseChunks(from data: Data, into remaining: inout [UInt8], sawEnd: inout Bool) -> [Data] {
        remaining.append(contentsOf: data)
        var frames: [Data] = []
        var offset = 0
        while remaining.count - offset >= 4 {
            let len = UInt32(remaining[offset])
                | (UInt32(remaining[offset + 1]) << 8)
                | (UInt32(remaining[offset + 2]) << 16)
                | (UInt32(remaining[offset + 3]) << 24)
            if len == 0 {
                offset += 4
                sawEnd = true
                break
            }
            guard Int(len) <= maxFrameBytes else {
                // 声明帧超出上限：丢弃缓冲，终止解析
                remaining.removeAll()
                break
            }
            let total = Int(len) + 4
            guard remaining.count - offset >= total else { break }
            frames.append(Data(remaining[offset + 4..<offset + total]))
            offset += total
        }
        if offset > 0 {
            remaining.removeFirst(offset)
        }
        return frames
    }
}
