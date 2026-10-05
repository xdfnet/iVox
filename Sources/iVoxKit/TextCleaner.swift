import Foundation
import Markdown

// MARK: - 公开 API

/// Markdown → 纯文本：遍历 AST 提取 Text 节点，块级元素间加空格分隔，TTS 自行处理停顿。
///
/// 取舍标准是「耳朵能不能用」：屏幕可以略读，耳朵只能线性听完。
/// 因此源码、路径、hash/UUID、JSON、ANSI、传输进度这类「看得见听不出」的内容一律剔除，
/// 而语义信息（散文、版本号、百分比、函数名）保留。
public func cleanText(_ text: String) -> String {
    guard !text.isEmpty else { return "" }
    // 短文本且无 Markdown 特殊字符时跳过 AST 解析
    if text.count < 80 {
        let markdownChars: Set<Character> = ["#", "*", "_", "`", "[", "]", "(", ")", "{", "}", ">", "|", "-"]
        if !text.contains(where: { markdownChars.contains($0) }) {
            return text.normalizedNewlinesForTTS.cleanedForTTS
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    let doc = Document(parsing: text)
    var visitor = TextCollector()
    visitor.visit(doc)
    return visitor.output.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - AST 文本提取

private struct TextCollector: MarkupWalker {
    // 预分配 StringBuilder，避免反复 += 造成的 O(n²) 复制
    fileprivate var output = ""
    fileprivate var lastWasSpace = true

    init() {
        output.reserveCapacity(512)
    }

    mutating func visitText(_ node: Text) {
        let t = node.string.trimmingCharacters(in: .whitespacesAndNewlines).cleanedForTTS
        if t.isEmpty { return }
        appendSeparator(nextFirst: t.first)
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
        let code = node.code.cleanedForTTS
        if code.isEmpty { return }
        appendSeparator(nextFirst: code.first)
        output.append(code)
        lastWasSpace = false
    }

    /// 代码块整段跳过：源码逐 token 念出来对听众没有信息量，且一段代码能占掉几分钟
    mutating func visitCodeBlock(_: CodeBlock) {}

    mutating func visitImage(_ node: Image) { descendInto(node) }  // 保留 alt 文字（通常是一句人话描述）
    mutating func visitTable(_ node: Table) { descendInto(node); endBlock() }
    mutating func visitTableRow(_ node: Table.Row) { descendInto(node); endBlock() }  // 行间补句号停顿
    /// 单元格之间强制分隔：中文单元格否则会连读成「名称版本状态」
    mutating func visitTableCell(_ node: Table.Cell) { appendSpace(); descendInto(node) }
    mutating func visitHTMLBlock(_: HTMLBlock) {}   // HTML 对 TTS 无意义，跳过
    mutating func visitInlineHTML(_: InlineHTML) {} // 同上
    mutating func visitThematicBreak(_: ThematicBreak) {}

    /// 句末标点：命中则不再补「。」（含英文句号/分号、省略号，避免 "finished.。" 双结尾）
    private static let sentenceEnds = Set<Character>("。！？!?….;；\n")

    private mutating func endBlock() {
        // 取最后一个非空白字符判断：嵌套块（ListItem 内含 Paragraph）下，若不跳过空白
        // 会把 endBlock 自己补的空格当成「未结束」，从而补出「。 。」
        if let last = output.last(where: { !$0.isWhitespace }), !Self.sentenceEnds.contains(last) {
            output.append("。")
        }
        appendSpace()
    }

    /// 按需补分词空格：只有一侧是拉丁字母/数字时才补。
    /// 中日韩文本天然分词，硬插空格会产生伪停顿（如「加粗 普通」、行内代码后的空档）。
    private mutating func appendSeparator(nextFirst: Character?) {
        guard !lastWasSpace else { return }
        guard let prev = output.last(where: { !$0.isWhitespace }), let next = nextFirst else {
            appendSpace()
            return
        }
        if Self.isLatinWordChar(prev) || Self.isLatinWordChar(next) { appendSpace() }
    }

    private static func isLatinWordChar(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber)
    }

    private mutating func appendSpace() {
        if !lastWasSpace { output.append(" "); lastWasSpace = true }
    }
}

// MARK: - 行内清洗

private extension String {
    /// 播报前的完整行内清洗：URL → 噪音 → emoji。
    ///
    /// 顺序不可调换：
    /// - **URL 必须在噪音之前** —— 否则 URL 会被路径规则当成路径砍成 `https:b` 这类残片；
    /// - **噪音必须在 removingEmoji 之前** —— 符号清理会把 `:` `/` `[` 换成空格，正则就匹配不到了。
    var cleanedForTTS: String {
        removingURLs.removingNoise.removingEmoji
    }

    /// 剔除「眼睛能看、耳朵听不出」的噪音
    var removingNoise: String {
        removingANSI
            .removingUUIDs
            .removingHexHashes
            .removingJSONObjects
            .removingPaths
            .removingProgressNoise
            .replacingArrows
    }

    // MARK: URL

    private static let urlDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    // NSDataDetector 常把 scheme 的 https: 剩在匹配外，先整体剥掉带 scheme 的 URL
    private static let schemeURL = try? NSRegularExpression(pattern: "https?://\\S+")

    var removingURLs: String {
        var stripped = self
        if let re = Self.schemeURL {
            let ns = stripped as NSString
            stripped = re.stringByReplacingMatches(
                in: stripped, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        }
        let ns = stripped as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let urlDetector = Self.urlDetector else { return stripped }
        let matches = urlDetector.matches(in: stripped, range: range)
        guard !matches.isEmpty else { return stripped }
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

    // MARK: 噪音

    private static let ansiEscape = try? NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[A-Za-z]")

    var removingANSI: String {
        guard let re = Self.ansiEscape else { return self }
        return re.stringByReplacingMatches(
            in: self, range: NSRange(location: 0, length: (self as NSString).length), withTemplate: "")
    }

    /// UUID：必须在 hex hash 之前执行，否则末段 12 位十六进制会先被 hash 规则吃掉，留下残片
    private static let uuid = try? NSRegularExpression(
        pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

    var removingUUIDs: String {
        guard let re = Self.uuid else { return self }
        return re.stringByReplacingMatches(
            in: self, range: NSRange(location: 0, length: (self as NSString).length), withTemplate: "")
    }

    /// 12 位以上、且至少含一个字母的十六进制串（commit hash / 长 ID）。
    /// 要求含字母是为了不误删纯数字长串——订单号、时间戳仍可能是有效信息。
    private static let hexHash = try? NSRegularExpression(
        pattern: "\\b(?=[0-9a-fA-F]*[a-fA-F])[0-9a-fA-F]{12,}\\b")

    var removingHexHashes: String {
        guard let re = Self.hexHash else { return self }
        return re.stringByReplacingMatches(
            in: self, range: NSRange(location: 0, length: (self as NSString).length), withTemplate: "")
    }

    var removingJSONObjects: String {
        guard contains("{") else { return self }
        var result = ""
        result.reserveCapacity(count)
        var i = startIndex
        while i < endIndex {
            if self[i] == "{", let close = matchingBrace(from: i),
               looksLikeJSON(self[index(after: i)..<close]) {
                i = index(after: close)   // 整个对象丢弃
                continue
            }
            result.append(self[i])
            i = index(after: i)
        }
        return result
    }

    /// 从 `{` 起找配对的 `}`（含嵌套），不闭合返回 nil
    private func matchingBrace(from open: Index) -> Index? {
        var depth = 0
        var i = open
        while i < endIndex {
            switch self[i] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return i }
            default: break
            }
            i = index(after: i)
        }
        return nil
    }

    /// 同时出现「冒号 + 引号」才认定 JSON，避免误删「{待办}」这类正常文本
    private func looksLikeJSON(_ inner: Substring) -> Bool {
        let hasColon = inner.contains(":") || inner.contains("：")
        let hasQuote = inner.contains("\"") || inner.contains("“") || inner.contains("”")
        return hasColon && hasQuote
    }

    /// 绝对/家目录路径（`/a/b`、`~/a/b`）或多段相对路径（`Sources/iVox/TextCleaner.swift`）。
    /// 替换成文件名而不是整体删除：念「TextCleaner.swift」有用，念「/Users/admin/…」没用。
    private static let path = try? NSRegularExpression(pattern:
        "(?:~|/)(?:[A-Za-z0-9._-]+/)+[A-Za-z0-9._-]*"
        + "|[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)+\\.[A-Za-z][A-Za-z0-9]{0,7}")

    var removingPaths: String {
        guard let re = Self.path else { return self }
        let ns = self as NSString
        let matches = re.matches(in: self, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return self }
        // 倒序替换：前面的 range 才不会被后续替换的长度变化弄失效
        var result = self
        for m in matches.reversed() {
            guard let r = Range(m.range, in: result) else { continue }
            result.replaceSubrange(r, with: (String(result[r]) as NSString).lastPathComponent)
        }
        return result
    }

    private static let transferRate = try? NSRegularExpression(pattern: "\\d+(?:\\.\\d+)?\\s*[KMGT]?B/s")
    // 用「前一个字符不是字母」代替 \b：中文不是 ICU 的 word 字符，\b 在中文前不成立
    private static let eta = try? NSRegularExpression(
        pattern: "(?<![A-Za-z])(?:预计剩余|预计还需|剩余时间|ETA)[^，。；！？,;\\n]*",
        options: [.caseInsensitive])

    /// 传输进度类噪音：播报时早已过期，且数字连读没有信息量
    var removingProgressNoise: String {
        var s = self
        for re in [Self.transferRate, Self.eta].compactMap({ $0 }) {
            s = re.stringByReplacingMatches(
                in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "")
        }
        return s
    }

    /// 「→」念成「到」，否则 TTS 会把箭头符号跳过，导致前后词莫名连读
    var replacingArrows: String {
        replacingOccurrences(of: "→", with: "到")
    }

    // MARK: 换行归一化

    /// 纯文本换行归一化：换行是段落/折行边界，TTS 需要停顿信号。
    /// 行末无句末标点时补「。」，换行换成空格（兼容英文单词分隔，中文空格无害）。
    var normalizedNewlinesForTTS: String {
        // 行末已有停顿标点时不补句号（冒号/逗号/分号本身带停顿）
        let pauseMarks = Set<Character>("。！？!?：:，,；;…—")
        var result = ""
        result.reserveCapacity(count)
        var pendingNewline = false
        for ch in self {
            if ch == "\n" || ch == "\r" {
                pendingNewline = true
                continue
            }
            if pendingNewline {
                // 行末参考最后一个非空白、非 emoji 字符（emoji 后续才会被移除）
                if let anchor = result.last(where: { $0 != " " && !$0.isEmojiLike }),
                   !pauseMarks.contains(anchor) {
                    result.append(anchor.isASCII ? "." : "。")
                }
                if let last = result.last, last != " " { result.append(" ") }
                pendingNewline = false
            }
            result.append(ch)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 符号过滤

    /// 过滤 emoji + 非文字符号，只保留文字（字母/数字/中文）+ 语气标点。
    /// 各类空白（Tab / NBSP / 全角空格 / 连续半角空格）统一折叠成一个空格；emoji 修饰符直接砍。
    var removingEmoji: String {
        // . / ! % ? , - : ; " ' + 中文句末/语气标点。冒号分号是停顿标记，保留给 TTS 断句
        let allowedPunct: Set<UInt32> = [46, 47, 33, 37, 63, 44, 45, 58, 59, 34, 39, 12290, 65281, 65311, 8212]
        // 各类 Unicode 空白：NBSP、各宽空格、零宽空白（部分）
        let unicodeSpaces: Set<UInt32> = [0x00A0, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x202F, 0x205F, 0x3000, 0xFEFF]
        var result = ""
        var lastWasSpace = false
        for s in unicodeScalars {
            let v = s.value
            // 空白先折叠：半角空格若走下面的白名单分支会被原样追加，连续空格就漏出去了
            if v == 32 || unicodeSpaces.contains(v) {
                lastWasSpace = true
                continue
            }
            if v <= 127 {
                if (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || (v >= 48 && v <= 57) || allowedPunct.contains(v) {
                    if lastWasSpace { result.append(" ") }
                    result.append(Character(s))
                    lastWasSpace = false
                } else {
                    // 其余 ASCII 符号（含 \r \n 及 _ = @ & < > 等）→ 转空格，避免前后词粘连
                    lastWasSpace = true
                }
            } else {
                let p = s.properties
                if p.isEmoji || p.isEmojiModifier || p.isEmojiModifierBase || p.isEmojiPresentation {
                    continue  // emoji 主字 + 修饰符 + 肤色 + 展示序列
                }
                if lastWasSpace { result.append(" ") }
                result.append(Character(s))
                lastWasSpace = false
            }
        }
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

private extension Character {
    var isEmojiLike: Bool { unicodeScalars.contains { $0.properties.isEmoji } }
}
