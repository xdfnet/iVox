import Foundation
import Markdown

// MARK: - 公开 API

/// 仅做 Markdown → 纯文本转换，不做额外过滤。
///
/// Qwen3 TTS 能自然处理 URL、emoji、代码等内容，
/// 只需要去掉 Markdown 格式标记，保留语义即可。
public func cleanText(_ text: String) -> String {
    guard !text.isEmpty else { return "" }

    let doc = Document(parsing: text)
    var extractor = RichTextExtractor()
    extractor.visit(doc)
    return joinBlocks(extractor.blocks)
}

// MARK: - 块拼接

private func joinBlocks(_ blocks: [String]) -> String {
    guard !blocks.isEmpty else { return "" }
    return blocks.joined(separator: "。")
}

// MARK: - Markdown 提取器

private struct RichTextExtractor: MarkupWalker {
    var blocks: [String] = []
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

    mutating func visitHTMLBlock(_ node: HTMLBlock) {}
    mutating func visitInlineHTML(_ node: InlineHTML) {}
    mutating func visitImage(_ node: Image) {}

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

    mutating func visitCodeBlock(_ node: CodeBlock) {
        let code = node.code.trimmingCharacters(in: .whitespacesAndNewlines)
        if !code.isEmpty {
            blocks.append(code)
        }
    }

    mutating func visitTable(_ node: Table) {}

    mutating func visitThematicBreak(_ node: ThematicBreak) {}

    mutating func visitLink(_ node: Link) {
        descendInto(node)
    }

    mutating func visitEmphasis(_ node: Emphasis) {
        descendInto(node)
    }

    mutating func visitStrong(_ node: Strong) {
        descendInto(node)
    }

    mutating func visitInlineCode(_ node: InlineCode) {
        current += node.code
    }

    private mutating func flush() {
        let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty {
            blocks.append(s)
        }
        current = ""
    }
}
