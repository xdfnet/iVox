import Foundation

/// 按换行切分文本，每段不超过 maxChars。
public func splitSentences(_ text: String, maxChars: Int = 50) -> [String] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return [] }
    if trimmed.count <= maxChars { return [trimmed] }

    // 先按换行拆
    let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

    // 贪心合并行到每段 ≤ maxChars
    var segments: [String] = []
    var buf = ""
    for line in lines {
        let lineChars = line.count
        if buf.isEmpty {
            buf = line
        } else if buf.count + 1 + lineChars <= maxChars {
            buf += "\n" + line
        } else {
            segments.append(buf)
            buf = line
        }
    }
    if !buf.isEmpty { segments.append(buf) }

    return segments
}
