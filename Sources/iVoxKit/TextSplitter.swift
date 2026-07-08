import Foundation

/// 按句末标点切分文本。
/// 句末标点：。！？!?
public func splitSentences(_ text: String, maxChars: Int = 50) -> [String] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return [] }

    let sentencePattern = /[。！？!?]+/
    var segments: [String] = []
    var lastEnd = trimmed.startIndex

    for match in trimmed.matches(of: sentencePattern) {
        let end = match.range.upperBound
        let sentence = String(trimmed[lastEnd..<end]).trimmingCharacters(in: .whitespaces)
        lastEnd = end
        if !sentence.isEmpty { segments.append(sentence) }
    }

    return segments.isEmpty ? [trimmed] : segments
}
