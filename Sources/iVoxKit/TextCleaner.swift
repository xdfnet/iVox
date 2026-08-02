import Foundation
import Markdown

/// Markdown → 纯文本：遍历 AST 提取 Text 节点，块级元素间加空格分隔，TTS 自行处理停顿。
public func cleanText(_ text: String) -> String {
    guard !text.isEmpty else { return "" }
    // 短文本且无 Markdown 特殊字符时跳过 AST 解析
    if text.count < 80 {
        let markdownChars: Set<Character> = ["#", "*", "_", "`", "[", "]", "(", ")", "{", "}", ">", "|", "-"]
        if !text.contains(where: { markdownChars.contains($0) }) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    let doc = Document(parsing: text)
    var visitor = TextCollector()
    visitor.visit(doc)
    return visitor.output.trimmingCharacters(in: .whitespacesAndNewlines)
}

private struct TextCollector: MarkupWalker {
    // 预分配 StringBuilder，避免反复 += 造成的 O(n²) 复制
    fileprivate var output = ""
    fileprivate var lastWasSpace = true

    init() {
        output.reserveCapacity(512)
    }

    mutating func visitText(_ node: Text) {
        let t = node.string.trimmingCharacters(in: .whitespacesAndNewlines).removingEmoji.removingURLs
        if t.isEmpty { return }
        appendSpace()
        output.append(t)
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

    mutating func visitInlineCode(_ node: InlineCode) {
        appendSpace()
        output.append(node.code.removingEmoji)
        appendSpace()
    }

    mutating func visitCodeBlock(_ node: CodeBlock) {
        let code = node.code.trimmingCharacters(in: .whitespacesAndNewlines).removingEmoji
        if !code.isEmpty { appendSpace(); output.append(code); endBlock() }
    }

    mutating func visitImage(_ node: Image) { descendInto(node) }  // 提取 alt 文字
    mutating func visitTable(_ node: Table) { descendInto(node); endBlock() }  // 提取单元格文字
    mutating func visitHTMLBlock(_: HTMLBlock) {}   // HTML 对 TTS 无意义，跳过
    mutating func visitInlineHTML(_: InlineHTML) {} // 同上
    mutating func visitThematicBreak(_: ThematicBreak) {}

    private static let sentenceEnds = Set<Character>("。！？!?\n")

    private mutating func endBlock() {
        if let last = output.last, !Self.sentenceEnds.contains(last) {
            output.append("。")
        }
        appendSpace()
    }

    private mutating func appendSpace() {
        if !lastWasSpace { output.append(" "); lastWasSpace = true }
    }
}

private extension String {
    private static let urlDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// 过滤 emoji + 非文字符号，只保留文字（字母/数字/中文）+ 语气标点。
    /// Tab / 不间断空格 / 全角空格 → 当空格合并；emoji 修饰符 → 砍。
    var removingEmoji: String {
        let allowedPunct: Set<UInt32> = [46, 47, 33, 37, 63, 44, 45, 12290, 65281, 65311, 8212]
        // 各类 Unicode 空白：NBSP、各宽空格、零宽空白（部分）
        let unicodeSpaces: Set<UInt32> = [0x00A0, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x202F, 0x205F, 0x3000, 0xFEFF]
        var result = ""
        var lastWasSpace = false
        for s in unicodeScalars {
            let v = s.value
            if v <= 127 {
                if (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || (v >= 48 && v <= 57) || v == 32 || allowedPunct.contains(v) {
                    if lastWasSpace { result.append(" ") }
                    result.append(Character(s))
                    lastWasSpace = false
                } else if v == 32 || v == 9 {  // 空格 + Tab 合并
                    lastWasSpace = true
                }
                // 其余 ASCII 符号（含 \r \n）丢弃
            } else {
                let p = s.properties
                if p.isEmoji || p.isEmojiModifier || p.isEmojiModifierBase || p.isEmojiPresentation {
                    continue  // emoji 主字 + 修饰符 + 肤色 + 展示序列
                }
                if unicodeSpaces.contains(v) {
                    lastWasSpace = true
                    continue
                }
                if lastWasSpace { result.append(" ") }
                result.append(Character(s))
                lastWasSpace = false
            }
        }
        return result
    }

    var removingURLs: String {
        let ns = self as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let urlDetector = Self.urlDetector else { return self }
        let matches = urlDetector.matches(in: self, range: range)
        guard !matches.isEmpty else { return self }
        var result = ""
        var pos = 0
        var lastWasSpace = false
        for m in matches {
            let segment = ns.substring(with: NSRange(location: pos, length: m.range.location - pos))
            appendNormalizingWhitespace(segment, into: &result, lastWasSpace: &lastWasSpace)
            pos = m.range.location + m.range.length
        }
        let tail = ns.substring(with: NSRange(location: pos, length: ns.length - pos))
        appendNormalizingWhitespace(tail, into: &result, lastWasSpace: &lastWasSpace)
        return result
    }

    /// 逐字符拷贝，ASCII 空格 + Tab 都合并为一个空格，其他原样保留
    private func appendNormalizingWhitespace(_ seg: String, into result: inout String, lastWasSpace: inout Bool) {
        for c in seg {
            if c == " " || c == "\t" {
                if !lastWasSpace { result.append(" ") }
                lastWasSpace = true
            } else {
                result.append(c)
                lastWasSpace = false
            }
        }
    }
}
