import Foundation

/// 按句子切分文本，每段不超过 maxChars。在 。！？! ? 和换行处断开。
public func splitSentences(_ text: String, maxChars: Int = 80) -> [String] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return [] }
    if trimmed.count <= maxChars { return [trimmed] }

    let cutSet = Set<Character>("。！？!?\n")
    var sentences: [String] = []
    var current = ""
    for ch in trimmed {
        current.append(ch)
        if cutSet.contains(ch) {
            sentences.append(current)
            current = ""
        }
    }
    if !current.isEmpty { sentences.append(current) }

    // 贪心合并句子到每段 ≤ maxChars
    var segments: [String] = []
    var buf = ""
    for s in sentences {
        let sChars = s.count
        if buf.count + sChars <= maxChars {
            buf += s
        } else {
            if !buf.isEmpty { segments.append(buf) }
            buf = s
        }
    }
    if !buf.isEmpty { segments.append(buf) }

    return segments
}
