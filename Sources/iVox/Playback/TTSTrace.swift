// 一次合成的「身份证」：顺着 IPC 带到誊清员进程，让它的每行日志都能认领自己属于哪一块。
//
// 起因：拆成多进程后各写各的日志文件，但**关联 ID 不跟着走**。于是誊清员那边只剩
// 「合成完成 bytes=…」，跟主进程那条「队列入队 turn=… 」对不上号 —— 要查「那一摞为什么
// 没念完」仍得靠时间戳在三份文件里拼，而时间戳不保证写入时刻与事件时刻一致。
//
// **只带 `seq`，不带 turn_id / message_id**：外部编号在纸的比喻里早就降级成「备注」，
// 块的身份只有助理自编的 `seq`（见 PlaybackBlock 的注释）。未来的归因工具（`ivox logs`，还没做）
// 要把一摞串起来时，走的是「主进程日志里 turn → 该摞的 seq 集合 → 誊清员日志里这些 seq」，
// 而不是把外部编号一路透传——那会让「谁的号」又开始决定「这块是谁的」。

struct TTSTrace: Sendable {
    /// 块号：助理自编的全局单调流水号，块的唯一身份
    let seq: UInt?
    /// 来源（claude / pi / speak …），仅供阅读
    let source: String?

    init(seq: UInt? = nil, source: String? = nil) {
        self.seq = seq
        self.source = source
    }

    /// 拼成 header 里的字段，值只留安全字符（与 ConnectionHandler 的 meta 同约束）
    var headerFields: String {
        var parts: [String] = []
        if let seq { parts.append("seq:\(seq)") }
        if let source, !source.isEmpty { parts.append("source:\(sanitize(source))") }
        return parts.isEmpty ? "" : "," + parts.joined(separator: ",")
    }

    /// 日志行尾的回显。**只带块号**——来源不在这一行：块号已是主键，
    /// 同一块从头到尾只有一个来源，再挂一个字段只是让人多读一遍。
    var logSuffix: String {
        guard let seq else { return "" }
        return " seq=\(seq)"
    }

    /// header 按 `,` 与 `:` 切分，脏字符会切坏 meta —— 与 ConnectionHandler 同一套约束
    private func sanitize(_ v: String) -> String {
        String(v.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" })
    }
}
