import Foundation
import Markdown

/// Markdown → 纯文本：遍历 AST 提取 Text 节点，块级元素间加空格分隔，TTS 自行处理停顿。
public func cleanText(_ text: String) -> String {
    guard !text.isEmpty else { return "" }
    let doc = Document(parsing: text)
    var visitor = TextCollector()
    visitor.visit(doc)
    return visitor.output
}

private struct TextCollector: MarkupWalker {
    var output = ""
    private var lastWasSpace = true

    mutating func visitText(_ node: Text) {
        let t = node.string.trimmingCharacters(in: .whitespacesAndNewlines).removingEmoji
        if t.isEmpty { return }
        appendSpace()
        output += t
        lastWasSpace = false
    }

    mutating func visitSoftBreak(_: SoftBreak) { appendSpace() }
    mutating func visitLineBreak(_: LineBreak) { appendSpace() }

    mutating func visitParagraph(_ node: Paragraph)    { appendSpace(); descendInto(node); appendSpace() }
    mutating func visitHeading(_ node: Heading)         { appendSpace(); descendInto(node); appendSpace() }
    mutating func visitListItem(_ node: ListItem)       { appendSpace(); descendInto(node); appendSpace() }
    mutating func visitBlockQuote(_ node: BlockQuote)   { appendSpace(); descendInto(node); appendSpace() }

    mutating func visitLink(_ node: Link)           { descendInto(node) }
    mutating func visitEmphasis(_ node: Emphasis)   { descendInto(node) }
    mutating func visitStrong(_ node: Strong)       { descendInto(node) }

    mutating func visitInlineCode(_ node: InlineCode) { appendSpace(); output += node.code.removingEmoji; appendSpace() }

    mutating func visitCodeBlock(_ node: CodeBlock) {
        let code = node.code.trimmingCharacters(in: .whitespacesAndNewlines).removingEmoji
        if !code.isEmpty { appendSpace(); output += code; appendSpace() }
    }

    mutating func visitImage(_: Image) {}
    mutating func visitTable(_: Table) {}
    mutating func visitHTMLBlock(_: HTMLBlock) {}
    mutating func visitInlineHTML(_: InlineHTML) {}
    mutating func visitThematicBreak(_: ThematicBreak) {}

    private mutating func appendSpace() {
        if !lastWasSpace { output += " "; lastWasSpace = true }
    }
}

private extension String {
    var removingEmoji: String {
        unicodeScalars.filter { s in s.value <= 127 || !s.properties.isEmoji }.map(String.init).joined()
    }
}
