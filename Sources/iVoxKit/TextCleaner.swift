import Foundation
import Markdown

// MARK: - 行内噪音过滤

private let urlRe = try! NSRegularExpression(pattern: #"https?://[^\s　，,。；;）"》）』」】]+"#)
private let pathRe = try! NSRegularExpression(pattern: #"(?:~|/(?:Users|private|tmp|var|opt|usr|bin|sbin|etc|Library|Applications))/[^\s　，,。；;）"》』」】]+"#)
private let uuidRe = try! NSRegularExpression(pattern: #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#)
private let commitHashRe = try! NSRegularExpression(pattern: #"(?i)\b[0-9a-f]{12,20}\b"#)
private let ansiEscapeRe = try! NSRegularExpression(pattern: #"\x1b\[[0-9;]*[A-Za-z]"#)
private let speedNoiseRe = try! NSRegularExpression(pattern: #"(?i)\b\d+(?:\.\d+)?\s*(?:kb|mb|gb)/s\b"#)
private let multiSpaceRe = try! NSRegularExpression(pattern: #"\s+"#)

// MARK: - 公开 API

public func cleanText(_ text: String) -> String {
    guard !text.isEmpty else { return "" }

    let doc = Document(parsing: text)
    var extractor = CleanTextExtractor()
    extractor.visit(doc)
    return extractor.segments.joined(separator: "，")
}

// MARK: - Markdown 提取器

private struct CleanTextExtractor: MarkupWalker {
    var segments: [String] = []
    private var current = ""

    mutating func visitText(_ node: Text) {
        current += node.string
    }

    mutating func visitSoftBreak(_ node: SoftBreak) {
        current += " "
    }

    mutating func visitLineBreak(_ node: LineBreak) {
        current += " "
    }

    // 跳过的元素
    mutating func visitCodeBlock(_ node: CodeBlock) {}
    mutating func visitInlineCode(_ node: InlineCode) {
        current += node.code
    }
    mutating func visitHTMLBlock(_ node: HTMLBlock) {}
    mutating func visitInlineHTML(_ node: InlineHTML) {}
    mutating func visitImage(_ node: Image) {}
    mutating func visitTable(_ node: Table) {}
    mutating func visitThematicBreak(_ node: ThematicBreak) {}

    // 块级元素：收集文本后刷出段落
    mutating func visitParagraph(_ node: Paragraph) {
        descendInto(node)
        flush()
    }

    mutating func visitHeading(_ node: Heading) {
        descendInto(node)
        flush()
    }

    mutating func visitListItem(_ node: ListItem) {
        descendInto(node)
        flush()
    }

    mutating func visitBlockQuote(_ node: BlockQuote) {
        descendInto(node)
        flush()
    }

    // 内联容器：仅下钻
    mutating func visitLink(_ node: Link) {
        descendInto(node)
    }

    mutating func visitEmphasis(_ node: Emphasis) {
        descendInto(node)
    }

    mutating func visitStrong(_ node: Strong) {
        descendInto(node)
    }

    // MARK: - Helpers

    private mutating func flush() {
        let s = cleanInlineNoise(current)
        if !s.isEmpty {
            segments.append(s)
        }
        current = ""
    }
}

private func cleanInlineNoise(_ text: String) -> String {
    var s = text
    for re in [ansiEscapeRe, urlRe, pathRe, uuidRe, commitHashRe, speedNoiseRe] {
        s = re.stringByReplacingMatches(
            in: s,
            range: NSRange(location: 0, length: s.utf16.count),
            withTemplate: ""
        )
    }

    s = s.replacingOccurrences(of: "✅", with: "成功")
        .replacingOccurrences(of: "❌", with: "失败")
        .replacingOccurrences(of: "✓", with: "成功")
        .replacingOccurrences(of: "✗", with: "失败")
    s = s.replacingOccurrences(of: "→", with: "到")

    s = multiSpaceRe.stringByReplacingMatches(
        in: s,
        range: NSRange(location: 0, length: s.utf16.count),
        withTemplate: " "
    )
    s = s.replacingOccurrences(of: " ，", with: "，")
        .replacingOccurrences(of: " ,", with: ",")
        .replacingOccurrences(of: " 。", with: "。")
        .replacingOccurrences(of: " ；", with: "；")
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}
