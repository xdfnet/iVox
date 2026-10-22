import Foundation
import Markdown

// 文本降噪：Markdown AST 去代码块 + 行内噪音 / emoji（喂给 TTS）。
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
        // 行内代码只走删除线：`a && b` 不该被翻成「a 和 b」，那是给听众添噪音
        let code = node.code.cleanedCodeForTTS
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

    /// 句末标点：命中则不再补「。」（含英文句号/分号、省略号，避免 "finished.。" 双结尾）。
    /// 冒号也算：冒号是「引出下文」（如下：），块末补句号会产生「如下：。」的伪句号。
    private static let sentenceEnds = Set<Character>("。！？!?….;；：:\n")

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
    /// 播报前的完整行内清洗：**删除线 → 改写线**，两条线职责不交叉。
    ///
    /// 备菜只有两个动作，所以清洗也只有两类规则（2026-10-22 重新设计）：
    /// - **删除线（只删不改）**：`removingUnhearable`。删「眼睛能看、耳朵听不出」的——URL、ANSI、
    ///   UUID、hash、JSON、路径、传输进度。这一线一个字都不新增，删掉的换不来新词。
    /// - **改写线（把符号变成念法）**：`normalizingForSpeech`。保留「念得出来」的，
    ///   把「念不出来」的落地成汉字或清掉——符号读法表、emoji 口语表、兜底删符号。
    ///   emoji 之所以在这条线（而不是删除线）：它一体两面，**命中的改写、未命中的删**，
    ///   拆开就会漏。兜底删符号同理——它问的是「这字符念得出来吗」，是念法问题。
    ///
    /// 顺序只在这一处有意义：**删除线必须在改写线之前**——URL/路径正则要在符号还认得出来时匹配，
    /// 否则 `https://x` 会先被 `/` 规则改写，URL 规则就匹配不到了。
    var cleanedForTTS: String {
        let afterDelete = removingUnhearable
        let afterRewrite = afterDelete.normalizingForSpeech
        var trace: [String] = []
        if afterDelete != self { trace.append("删噪音") }
        if afterRewrite != afterDelete { trace.append("念稿改写") }
        if !trace.isEmpty {
            Log.debug("清洗命中: \(trace.joined(separator: "→")) （\(count)字 → \(afterRewrite.count)字）")
        }
        return afterRewrite
    }

    /// 行内代码专用：只删噪音、**跳过改写线**。
    ///
    /// 源码没有「念法」可言，`a && b` 翻成「a 和 b」纯属给听众添噪音（2026-10-22 实测）。
    /// 代码块是整段跳过（见 visitCodeBlock）；行内代码只占几个词、压缩后仍值得念出来，
    /// 但不该参与符号改写。
    var cleanedCodeForTTS: String {
        removingUnhearable
    }

    /// 删除线：只删「眼睛能看、耳朵听不出」的东西，**一个字都不新增**。
    ///
    /// 这条链里曾经混过一个 `replacingArrows`（`→` → `到」）——那是**翻译**，不是删除，
    /// 混进来会让「删」和「改」两类规则散在两处，将来加符号不知道该跟谁排。
    /// 它已搬去改写线 normalizingForSpeech（2026-10-22 重新设计）。
    var removingUnhearable: String {
        removingURLs
            .removingANSI
            .removingUUIDs
            .removingHexHashes
            .removingJSONObjects
            .removingPaths
            .removingProgressNoise
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

    // MARK: emoji 口语化

    /// 常见 emoji → 中文口语词（保留情绪，避免直接删成沉默）；未命中的留给 removingEmoji 剔除。
    private static let emojiSpeech: [Character: String] = Dictionary(
        uniqueKeysWithValues: [
            "👌": "好的", "🆗": "好的", "👍": "赞", "👎": "不行",
            "✅": "没问题", "❌": "不对", "⚠️": "注意", "❗": "注意", "⁉️": "等等",
            "🎉": "太棒了", "🎊": "太棒了", "🥳": "太棒了",
            "😂": "哈哈", "🤣": "哈哈", "😄": "哈哈", "😆": "哈哈",
            "😊": "开心", "🙂": "嗯", "😅": "汗", "😉": "眨眼",
            "🤔": "思考", "😭": "哭", "😱": "惊讶", "😴": "困",
            "🙏": "谢谢", "❤️": "比心", "🔥": "火热", "💡": "提示",
            "🚀": "起飞", "✨": "闪亮", "⭐": "星星", "🎯": "搞定了",
            "📝": "记录", "🔊": "声音", "📌": "重点", "🧠": "思考", "📦": "打包",
        ].map { (Character($0.key), $0.value) })

    /// 以 grapheme cluster 为粒度替换常见 emoji；肤色修饰（U+1F3FB–F3FF）与变体选择符 VS16 先剥离再查表，
    /// 因此 `👌🏽`/`👍🏻` 等任意肤色变体也能命中基础 emoji。
    var replacingEmojiSpeech: String {
        map { ch -> String in
            guard ch.isEmojiLike, let base = ch.emojiSpeechBase else { return String(ch) }
            return Self.emojiSpeech[base] ?? String(ch)
        }.joined()
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

    /// 改写线：**符号读法 + emoji 口语 + 兜底删符号**，三步都在这儿，位置唯一。
    ///
    /// 三步同属一线，因为问的都是同一个问题——「这字符，嘴念得出来吗」：
    /// 符号有读法的落地成汉字（symbolRules）；emoji 命中的换口语词
    /// （replacingEmojiSpeech）；剩下没有读法的符号兜底清掉（removingEmoji）。
    /// emoji 与兜底删除都**含删**，但它们不是「删除线」——它们问的是读法，不是取舍。
    ///
    /// 顺序：符号与 emoji 先落地成汉字，兜底删除最后——否则兜底会把还没翻译的
    /// `+` `=` 之类先当成噪音删掉（2026-10-22 实测 `+75%` 只剩「百分之七十五」）。
    var normalizingForSpeech: String {
        // 整段没有实质内容（只有符号与空白，如 `*** ### +++ &&&`）时直接清空：
        // 这类文本是分隔线/占位符，念出来纯是噪音。必须在改写之前判——
        // 否则 `+++` 会先被翻成「加加加」，段落就伪装成有内容，混不进噪音里（2026-10-22，
        // F-pcm-duration 用例抓到的真实回归：原来被清成 0 PCM，改写后反而出声了）。
        guard containsSubstance else { return "" }
        return applyingSymbolRules.replacingEmojiSpeech.removingEmoji
    }

    /// 去掉符号与空白后还剩东西，才算「有实质内容」。
    ///
    /// emoji 的判据是**「口语表里查得到」**而不是 Unicode 的 isEmoji 属性——
    /// `*` 和 `#` 本身带 Emoji 属性（键盘键名 📱*、#️⃣），
    /// 按属性判会把 `*** ###` 这种分隔线当成实质内容（2026-10-22 F-pcm-duration 实测）。
    /// 按口语表判才对：`🚀` 查得到「起飞」算实质，翻不出词的才是死符号。
    private var containsSubstance: Bool {
        self.contains { ch in
            if ch.isLetter || ch.isNumber { return true }
            guard ch.isEmojiLike, let base = ch.emojiSpeechBase else { return false }
            return Self.emojiSpeech[base] != nil
        }
    }

    /// 把「眼睛用的写法」翻成「嘴巴用的写法」，**不删任何东西**。
    ///
    /// 存在的理由：合成引擎是个神经网络 TTS，只认汉字与常见中文标点，
    /// 碰上没读法的符号（`/`、`①`、`+`）就只能自由发挥或直接吞掉——
    /// `59/79` 每次念法都不一样、`①` 念成「括号一」、`+75%` 只剩「百分之七十五」。
    /// 所以规则一律在这里落地成汉字，引擎不需要猜。
    ///
    /// 同形异义的判据（`<` `>` 尤其明显）：这里看到 `>` 就一定是「大于」，
    /// 因为 Markdown 引用块 `> ` 与内联 HTML `<b>` 都被上游吃掉了——
    /// `cleanText` 短文本捷径的 `markdownChars` 里有 `>` 和 `<`，
    /// 凡带它们的文本必定走 AST 解析，标记到不了这一层（2026-10-22 查证）。
    var applyingSymbolRules: String {
        var result = ""
        var cursor = startIndex
        var skipNext = false
        while cursor < endIndex {
            let ch = self[cursor]
            let next = index(after: cursor)
            // 前面紧邻的字符（跳过空白）——判「数字前缀的增减号」要用
            let prevSignificant = result.last(where: { !$0.isWhitespace })
            let prevIsWordChar = prevSignificant.map {
                $0.isLetter || $0.isNumber || $0 == "." || $0 == "/" || $0 == "-"
            } ?? false
            let followedByDigit = next < endIndex && self[next].isNumber
            switch ch {
            case "+", "-":
                // 只有「前面不是字母数字、后面紧跟数字」才是增减号：
                // `x86-64` / `2026-10-22` / `a-b` 的连字符用法原样保留。
                if !prevIsWordChar, followedByDigit {
                    result += (ch == "+" ? "增加" : "减少")
                } else if ch == "+" {
                    // 其余 `+` 念「加」：C++ 念成 C 加加、a+b 念成 a 加 b。
                    // 以前这里直接把 `+` 留给 removingEmoji 删成空格，`C++` 只剩「C」（实测）。
                    result += "加"
                } else {
                    result.append(ch)
                }
            case "=":
                // `x = 5` 以前念成「x 5」，等号连同两侧语义一起没了
                result += "等于"
            case "<":
                result += "小于"
            case ">":
                result += "大于"
            case "&":
                // `a && b` 念「a 和 b」；连续的 `&&` 只念一次，免得「和和」
                if next < endIndex, self[next] == "&" {
                    skipNext = true
                }
                result += "和"
            case "@":
                // `@param` 念「at param」。`at` 是拉丁字母，前后必须留空格——
                // 否则拼成 `atparam` 会被引擎当成一个词念（2026-10-22 实测）。
                // 中文替换词（加、等于、和）不需要，中文贴字母天然断开。
                result += " at "
            case "\u{2192}":
                // 箭头念「到」，否则 TTS 跳过它导致前后词莫名连读（从删除线搬来，2026-10-22）
                result += "到"
            case "/":
                // 斜杠统一当分隔：换成引擎认识的顿号，读作停顿。
                // 念稿层无从判断 `59/79` 是列表还是比值，猜错代价比读含糊更大（2026-10-22 裁决）。
                result += "、"
            default:
                // 带圈编号 ①(2460) – ⑳(2473)：不是 emoji，过得了 removingEmoji，
                // 但引擎没读法，映射成「第几项」。
                if let ordinal = Self.circledOrdinals[ch] {
                    result += ordinal
                } else {
                    result.append(ch)
                }
            }
            cursor = skipNext ? self.index(after: next) : next
            skipNext = false
        }
        return result
    }

    /// ①-⑳ → 第一项 … 第二十项
    private static let circledOrdinals: [Character: String] = {
        let numerals = ["一", "二", "三", "四", "五", "六", "七", "八", "九"]
        var table: [Character: String] = [:]
        for n in 1...20 {
            let value: String
            if n < 10 {
                value = numerals[n - 1]
            } else if n == 10 {
                value = "十"
            } else {
                value = numerals[n / 10 - 1] + "十" + (n % 10 == 0 ? "" : numerals[n % 10 - 1])
            }
            table[UnicodeScalar(0x2460 + n - 1).map(Character.init) as! Character] = "第\(value)项"
        }
        return table
    }()

    /// 过滤 emoji + 非文字符号，只保留文字（字母/数字/中文）+ 语气标点。
    /// 各类空白（Tab / NBSP / 全角空格 / 连续半角空格）统一折叠成一个空格；emoji 修饰符直接砍。
    /// 半角 `~` 与全角 `～` 统一转空格（语气号不发声，避免前后词粘连）。
    var removingEmoji: String {
        // . ! % ? , - : ; " ' + 中文句末/语气标点。冒号分号是停顿标记，保留给 TTS 断句。
        // 刻意不含 `/`(47)：斜杠的读法归 normalizingForSpeech，这里再留一条只是冗余，
        // 却是「将来谁动了念稿改写、裸 / 悄悄漏进 TTS」的定时炸弹（2026-10-22 删）。
        let allowedPunct: Set<UInt32> = [46, 33, 37, 63, 44, 45, 58, 59, 34, 39, 12290, 65281, 65311, 8212]
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
                // 全角波浪号 ～ 与半角 ~ 统一转空格（语气号不发声、避免前后词粘连）
                if v == 0xFF5E {
                    lastWasSpace = true
                    continue
                }
                // swift-markdown 会把 -- 智能替换成排版 en-dash（–），无听感收益且引入非 ASCII 符，
                // 归一为单个半角连字符（与单词内单个 - 行为一致，如 --verbose → -verbose）
                if v == 0x2013 {
                    if lastWasSpace { result.append(" ") }
                    result.append("-")
                    lastWasSpace = false
                    continue
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

    /// 剥掉肤色修饰（U+1F3FB–U+1F3FF）、变体选择符 VS16（U+FE0F）与 ZWJ（U+200D）后，
    /// 用剩余标量重建字符，作为 emoji 口语表的查表键；剥光了（纯修饰符）则返回 nil。
    var emojiSpeechBase: Character? {
        let scalars = unicodeScalars.filter {
            !(0x1F3FB...0x1F3FF ~= $0.value || $0.value == 0xFE0F || $0.value == 0x200D)
        }
        var s = String.UnicodeScalarView()
        s.append(contentsOf: scalars)
        return s.isEmpty ? nil : Character(String(s))
    }
}
