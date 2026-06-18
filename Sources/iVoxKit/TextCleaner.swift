import Foundation
import Markdown

// MARK: - 行内噪声过滤

private let urlRe = try! NSRegularExpression(pattern: #"https?://[^\s　，,。；;）"》）』」】]+"#)
private let pathRe = try! NSRegularExpression(pattern: #"(?:~|/(?:Users|private|tmp|var|opt|usr|bin|sbin|etc|Library|Applications))/[^\s　，,。；;）"》』」】]+"#)
private let uuidRe = try! NSRegularExpression(pattern: #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#)
private let commitHashRe = try! NSRegularExpression(pattern: #"(?i)\b[0-9a-f]{16,40}\b"#) // 只删 16+ 位完整 SHA，保留短引用
private let ansiEscapeRe = try! NSRegularExpression(pattern: #"\x1b\[[0-9;]*[A-Za-z]"#)
private let speedNoiseRe = try! NSRegularExpression(pattern: #"(?i)\b\d+(?:\.\d+)?\s*(?:kb|mb|gb)/s\b"#)
private let multiSpaceRe = try! NSRegularExpression(pattern: #"\s+"#)

/// 短代码块阈值：≤ 3 行且 ≤ 80 字符转为 inline 保留
private let maxCodeBlockLines = 3
private let maxCodeBlockChars = 80

// MARK: - 块类型

private enum BlockType: Equatable {
    case paragraph
    case heading(level: Int)
    case listItem
    case blockQuote
    case codeBlock
}

private struct Block {
    let type: BlockType
    let text: String
}

// MARK: - 公开 API

public func cleanText(_ text: String) -> String {
    guard !text.isEmpty else { return "" }

    let doc = Document(parsing: text)
    var extractor = RichTextExtractor()
    extractor.visit(doc)
    return joinBlocks(extractor.blocks)
}

// MARK: - 块拼接

private func joinBlocks(_ blocks: [Block]) -> String {
    guard !blocks.isEmpty else { return "" }

    var result = ""

    for block in blocks {
        var text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { continue }

        // 确保块以句尾标点结尾，让 Qwen3 获得完整的停顿信号
        if let last = text.last, !"。？！".contains(last) {
            // 以冒号/分号/逗号结尾的，加句号形成完整句子
            // 否则也补句号闭合
            text.append("。")
        }

        if result.isEmpty {
            result = text
        } else {
            result += " "
            result += text
        }
    }

    return result
}

// MARK: - Markdown 提取器

private struct RichTextExtractor: MarkupWalker {
    var blocks: [Block] = []
    private var current = ""
    private var currentType: BlockType = .paragraph

    mutating func visitText(_ node: Text) {
        current += node.string
    }

    mutating func visitSoftBreak(_ node: SoftBreak) {
        current += " "
    }

    mutating func visitLineBreak(_ node: LineBreak) {
        current += " "
    }

    // MARK: 跳过的元素

    mutating func visitHTMLBlock(_ node: HTMLBlock) {}
    mutating func visitInlineHTML(_ node: InlineHTML) {}
    mutating func visitImage(_ node: Image) {}
    mutating func visitTable(_ node: Table) {}
    mutating func visitThematicBreak(_ node: ThematicBreak) {}

    // MARK: 代码块 — 短块保留，长块跳过

    mutating func visitCodeBlock(_ node: CodeBlock) {
        let code = node.code
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false).count
        if lines <= maxCodeBlockLines, code.count <= maxCodeBlockChars {
            // 短代码块转为 inline，保留信息
            let cleaned = cleanInlineNoise(code.trimmingCharacters(in: .whitespacesAndNewlines))
            if !cleaned.isEmpty {
                let text = "代码：\(cleaned)"
                blocks.append(Block(type: .codeBlock, text: text))
            }
        }
        // 长代码块 → 跳过
    }

    // MARK: 内联代码

    mutating func visitInlineCode(_ node: InlineCode) {
        current += node.code
    }

    // MARK: 块级元素

    mutating func visitParagraph(_ node: Paragraph) {
        currentType = .paragraph
        descendInto(node)
        flush()
    }

    mutating func visitHeading(_ node: Heading) {
        currentType = .heading(level: node.level)
        descendInto(node)
        flush()
    }

    mutating func visitListItem(_ node: ListItem) {
        currentType = .listItem
        descendInto(node)
        flush()
    }

    mutating func visitBlockQuote(_ node: BlockQuote) {
        currentType = .blockQuote
        descendInto(node)
        flush()
    }

    // MARK: 内联容器 — 仅下钻

    mutating func visitLink(_ node: Link) {
        descendInto(node)
    }

    mutating func visitEmphasis(_ node: Emphasis) {
        descendInto(node)
    }

    mutating func visitStrong(_ node: Strong) {
        descendInto(node)
    }

    // MARK: Helpers

    private mutating func flush() {
        let s = cleanInlineNoise(current)
        if !s.isEmpty {
            blocks.append(Block(type: currentType, text: s))
        }
        current = ""
        currentType = .paragraph
    }
}

// MARK: - 行内噪声

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
