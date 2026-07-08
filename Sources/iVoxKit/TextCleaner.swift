import Foundation
import Markdown

/// Markdown → 纯文本：遍历 AST 提取 Text 节点，块级元素间加空格分隔，TTS 自行处理停顿。
public func cleanText(_ text: String) -> String {
    guard !text.isEmpty else { return "" }
    let doc = Document(parsing: text)
    var visitor = TextCollector()
    visitor.visit(doc)
    return visitor.output.trimmingCharacters(in: .whitespacesAndNewlines)
}

private struct TextCollector: MarkupWalker {
    var output = ""
    private var lastWasSpace = true

    mutating func visitText(_ node: Text) {
        let t = node.string.trimmingCharacters(in: .whitespacesAndNewlines).removingEmoji.removingURLs
        if t.isEmpty { return }
        appendSpace()
        output += t
        lastWasSpace = false
    }

    mutating func visitSoftBreak(_: SoftBreak) { appendSpace() }
    mutating func visitLineBreak(_: LineBreak) { appendSpace() }

    mutating func visitParagraph(_ node: Paragraph)    { descendInto(node); endBlock() }
    mutating func visitHeading(_ node: Heading)         { descendInto(node); endBlock() }
    mutating func visitListItem(_ node: ListItem)       { descendInto(node); endBlock() }
    mutating func visitBlockQuote(_ node: BlockQuote)   { descendInto(node); endBlock() }

    mutating func visitLink(_ node: Link)           { descendInto(node) }
    mutating func visitEmphasis(_ node: Emphasis)   { descendInto(node) }
    mutating func visitStrong(_ node: Strong)       { descendInto(node) }

    mutating func visitInlineCode(_ node: InlineCode) { appendSpace(); output += node.code.removingEmoji; appendSpace() }

    mutating func visitCodeBlock(_ node: CodeBlock) {
        let code = node.code.trimmingCharacters(in: .whitespacesAndNewlines).removingEmoji
        if !code.isEmpty { appendSpace(); output += code; endBlock() }
    }

    mutating func visitImage(_ node: Image) { descendInto(node) }  // 提取 alt 文字
    mutating func visitTable(_ node: Table) { descendInto(node); endBlock() }  // 提取单元格文字
    mutating func visitHTMLBlock(_: HTMLBlock) {}   // HTML 对 TTS 无意义，跳过
    mutating func visitInlineHTML(_: InlineHTML) {} // 同上
    mutating func visitThematicBreak(_: ThematicBreak) {}

    private static let sentenceEnds = Set<Character>("。！？!?\n")

    private mutating func endBlock() {
        if let last = output.last, !Self.sentenceEnds.contains(last) {
            output += "。"
        }
        appendSpace()
    }

    private mutating func appendSpace() {
        if !lastWasSpace { output += " "; lastWasSpace = true }
    }
}

private extension String {
    private static let urlDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// 过滤 emoji + 非文字符号，只保留 ASCII 可打印字符
    /// 只保留文字（字母/数字/中文）+ 语气标点，过滤其余所有符号
    var removingEmoji: String {
        let allowedPunct: Set<UInt32> = [46, 47, 33, 37, 63, 12290, 65281, 65311, 8212]
        var result = ""
        for s in unicodeScalars {
            let v = s.value
            if v <= 127 {
                // ASCII：字母、数字、空格保留，语气标点保留，其余过滤
                if (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || (v >= 48 && v <= 57) || v == 32 || allowedPunct.contains(v) {
                    result.append(Character(s))
                }
            } else if !s.properties.isEmoji {
                result.append(Character(s))
            }
        }
        return result.replacingOccurrences(of: " +", with: " ", options: .regularExpression)
    }

    var removingURLs: String {
        let ns = self as NSString
        let range = NSRange(location: 0, length: ns.length)
        let matches = Self.urlDetector.matches(in: self, range: range)
        guard !matches.isEmpty else { return self }
        var result = ""
        var pos = 0
        for m in matches {
            result += ns.substring(with: NSRange(location: pos, length: m.range.location - pos))
            pos = m.range.location + m.range.length
        }
        result += ns.substring(with: NSRange(location: pos, length: ns.length - pos))
        return result.replacingOccurrences(of: " +", with: " ", options: .regularExpression)
    }
}
