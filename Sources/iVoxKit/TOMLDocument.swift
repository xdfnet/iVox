import Foundation

// 解析后的 TOML 文档：**按键改值，保留原文里的注释**。
//
// 为什么需要它：配置文件是用户自己的地盘，里面写着「这行我为什么改成这样」。
// 程序写回配置时若整份重排，注释就没了——用户会骂。想避免，就得知道每个键在原文的哪个位置，
// 只动那几行，其余原样保留。
//
// 键的写法是点号路径：`hotkeys.translate`、`sourceVoices.default`、`wechat.token`。

public struct TOMLDocument {
    /// 原文
    public let text: String
    /// 解析出来的键值树
    public let root: [String: TOMLValue]

    private let ranges: [String: Range<Int>]
    private let keyLines: [String: Int]
    private let sectionSpans: [String: (start: Int, end: Int)]
    private let order: [String: [String]]

    private init(text: String, root: [String: TOMLValue], parser: TOMLParser, order: [String: [String]]) {
        self.text = text
        self.root = root
        self.ranges = parser.valueRanges
        self.keyLines = parser.keyLines
        self.sectionSpans = parser.sectionSpans
        self.order = order
    }

    /// 解析一段 TOML 文本。
    ///
    /// `order` 给出键的书写顺序（段名 → 键名数组）；不传则按键名字母序。
    public static func parse(_ text: String, order: [String: [String]] = [:]) throws -> TOMLDocument {
        var parser = TOMLParser(text)
        let events = try parser.parse()
        return TOMLDocument(text: text, root: TOMLParser.assemble(events), parser: parser, order: order)
    }

    // MARK: - 改值

    /// 设值：键已存在就只替换值那一段（行尾注释留着）；不存在就在所在段的末尾追加一行。
    public func setting(_ value: TOMLValue, forKey key: String) -> String {
        if let range = ranges[key] {
            // 解析器记的是字符偏移，转成 String 的索引再替换
            let start = text.index(text.startIndex, offsetBy: range.lowerBound)
            let end = text.index(text.startIndex, offsetBy: range.upperBound)
            var out = text
            out.replaceSubrange(start..<end, with: TOML.renderValue(value))
            return out
        }
        let parent = key.split(separator: ".").dropLast().joined(separator: ".")
        let name = String(key.split(separator: ".").last ?? "")
        let line = "\(name) = \(TOML.renderValue(value))\n"
        guard let span = sectionSpans[parent] else {
            // 段还没有 → 整段追加到文件末尾
            var out = text
            if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
            out += "\n[\(parent)]\n" + line
            return out
        }
        return inserting(line, at: span.end, in: text)
    }

    /// 删键：把那一整行删掉（连同该行自己的行尾注释）。
    public func removingValue(forKey key: String) -> String {
        guard let line = keyLines[key] else { return text }
        return removingLine(line, in: text)
    }

    /// 往数组表（`[[voices]]`）追加一个元素：接在最后一个同数组表的块后面。
    public func appendingToArrayTable(_ key: String, element: TOMLValue) -> String {
        let body = TOML.renderTableBody(element, path: [key], order: order)
        let blocks = arrayTableBlocks(key: key, in: text)
        guard let last = blocks.last else {
            var out = text
            if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
            out += "\n[[\(key)]]\n" + body
            return out
        }
        return inserting("\n[[\(key)]]\n" + body, at: last.endLine, in: text)
    }

    /// 一次删掉多个键（各自的整行）。
    public func removingValues(forKeys keys: [String]) -> String {
        let lines = keys.compactMap { keyLines[$0] }.sorted(by: >)
        guard !lines.isEmpty else { return text }
        var rows = text.components(separatedBy: "\n")
        for line in lines {
            let index = line - 1
            guard index >= 0, index < rows.count else { continue }
            rows.remove(at: index)
        }
        return rows.joined(separator: "\n")
    }

    /// 删掉数组表里的第 index 个元素（0 起）。
    public func removingFromArrayTable(_ key: String, index: Int) -> String {
        let blocks = arrayTableBlocks(key: key, in: text)
        guard index >= 0, index < blocks.count else { return text }
        let block = blocks[index]
        var lines = text.components(separatedBy: "\n")
        // 块覆盖 [startLine, endLine]（含头不含尾）
        lines.removeSubrange(block.startLine..<block.endLine)
        return lines.joined(separator: "\n")
    }

    /// 数组表里现有元素的个数。
    public func arrayTableCount(_ key: String) -> Int {
        arrayTableBlocks(key: key, in: text).count
    }

    // MARK: - 私有

    private struct Block {
        let startLine: Int
        let endLine: Int
    }

    /// 找出 `[[key]]` 的各块（行号，0 起；endLine 是块的下一行）。
    private func arrayTableBlocks(key: String, in text: String) -> [Block] {
        let lines = text.components(separatedBy: "\n")
        var starts: [Int] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "[[\(key)]]" { starts.append(index) }
        }
        var blocks: [Block] = []
        for (i, start) in starts.enumerated() {
            var end = lines.count
            var scan = start + 1
            while scan < lines.count {
                let trimmed = lines[scan].trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") { end = scan; break }
                scan += 1
            }
            _ = i
            blocks.append(Block(startLine: start, endLine: end))
        }
        return blocks
    }

    /// 在第 index 行（0 起）之前插入一段文本。
    private func inserting(_ snippet: String, at index: Int, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        lines.insert(contentsOf: snippet.components(separatedBy: "\n").dropLast(),
                     at: min(max(index, 0), lines.count))
        return lines.joined(separator: "\n")
    }

    /// 删掉第 line 行（0 起）。
    private func removingLine(_ line: Int, in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let index = line - 1
        guard index >= 0, index < lines.count else { return text }
        lines.remove(at: index)
        return lines.joined(separator: "\n")
    }
}
