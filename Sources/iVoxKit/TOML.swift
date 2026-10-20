import Foundation

// TOML 读写：外部配置（`~/.config/ivox/config.toml`）的格式。
//
// 为什么换 TOML：JSON 不能写注释，配置一多就没法读——「这行是干嘛的」只能靠记忆。
// TOML 自带 `#` 注释、段（`[hotkeys]`）分得清楚，写起来像 INI，人能看。
//
// 范围：**只支持 iVox 配置用得到的子集**——段（`[a.b]`）、数组表（`[[voices]]`）、
// 字符串（基本与多行 `"""…"""`）、整数、浮点、布尔、数组、内联表、`#` 注释。
// 不支持日期时间（配置里没有这种值）。不支持的写法**明确报错**，不静默吞掉。
//
// 解析与序列化都在这里，不引外部依赖：发布二进制不因格式变动而变大，行为也可预期。

/// TOML 里的一个值。
public indirect enum TOMLValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case double(Double)
    case boolean(Bool)
    case array([TOMLValue])
    case table([String: TOMLValue])
}

/// TOML 解析/序列化出错。位置（行号）写进描述里，改配置时能直接定位。
public struct TOMLError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public let line: Int

    public init(message: String, line: Int) {
        self.message = message
        self.line = line
    }

    public var description: String { "第 \(line) 行：\(message)" }
}

/// TOML 的读写入口。
public enum TOML {
    /// 解析一段 TOML 文本，返回顶层的键值。
    public static func parse(_ text: String) throws -> [String: TOMLValue] {
        var parser = TOMLParser(text)
        let events = try parser.parse()
        return TOMLParser.assemble(events)
    }

    /// 把 TOML 树转成 JSON 兼容的字典（供 `JSONDecoder` 复用现成的解码逻辑）。
    public static func jsonObject(from root: [String: TOMLValue]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in root {
            out[key] = jsonValue(value)
        }
        return out
    }

    /// 字典 → TOML 树（`JSONSerialization` 的输出喂进来）。
    public static func value(from object: Any) -> TOMLValue {
        switch object {
        case let dict as [String: Any]:
            var table: [String: TOMLValue] = [:]
            for (key, value) in dict {
                // TOML 没有 null：老 JSON 里的 null 一律当成「没写这个键」
                if value is NSNull { continue }
                table[key] = self.value(from: value)
            }
            return .table(table)
        case let arr as [Any]:
            return .array(arr.map { self.value(from: $0) })
        case let s as String: return .string(s)
        case let b as Bool: return .boolean(b)
        case let i as Int: return .integer(i)
        case let d as Double: return .double(d)
        case is NSNull: return .string("")
        default: return .string(String(describing: object))
        }
    }

    /// 字典 → TOML 表（顶层）。
    public static func table(from object: Any) -> [String: TOMLValue] {
        if case .table(let table) = value(from: object) { return table }
        return [:]
    }

    /// TOML 树 → 文本。
    ///
    /// `order` 给出键的书写顺序（段名 → 键名数组）；没列到的键按字母序跟在后面。
    /// 顺序由各配置类型的 `CodingKeys` 派生，不另抄一份清单。
    public static func string(from root: [String: TOMLValue], order: [String: [String]] = [:]) -> String {
        var out = ""
        renderTable(root, path: [], order: order, out: &out)
        return out
    }

    // MARK: - 私有：值的转换

    private static func jsonValue(_ value: TOMLValue) -> Any {
        switch value {
        case .string(let s): return s
        case .integer(let i): return i
        case .double(let d): return d
        case .boolean(let b): return b
        case .array(let arr): return arr.map { jsonValue($0) }
        case .table(let t): return jsonObject(from: t)
        }
    }

    // MARK: - 私有：序列化

    /// 排好序的键：先按 `order` 给的顺序，其余按字母序。
    static func orderedKeys(_ table: [String: TOMLValue], order: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for key in order where table[key] != nil && !seen.contains(key) {
            result.append(key)
            seen.insert(key)
        }
        for key in table.keys.sorted() where !seen.contains(key) {
            result.append(key)
            seen.insert(key)
        }
        return result
    }

    /// 输出一个表：先标量键，再子表段，再数组表段。
    static func renderTable(_ table: [String: TOMLValue], path: [String],
                                    order: [String: [String]], out: inout String) {
        let sectionKey = path.joined(separator: ".")
        let keys = orderedKeys(table, order: order[sectionKey] ?? [])

        // 标量与标量数组：直接写在当前段里
        for key in keys {
            guard let value = table[key] else { continue }
            if case .array(let arr) = value {
                // 数组里含表 → 那是数组表（下面单独输出 [[段]]），不能写成行内数组
                guard !arr.contains(where: { isTable($0) }) else { continue }
                out += "\(key) = \(inlineValue(value))\n"
            } else if !isTable(value) {
                out += "\(key) = \(inlineValue(value))\n"
            }
        }

        // 子表：写成 [父.子] 段
        for key in keys {
            guard case .table(let child) = table[key] else { continue }
            out += "\n[\(renderPath(path + [key]))]\n"
            renderTable(child, path: path + [key], order: order, out: &out)
        }

        // 数组表：每个元素一个 [[父.子]] 段
        for key in keys {
            guard case .array(let arr) = table[key], arr.contains(where: { isTable($0) }) else { continue }
            for element in arr {
                guard case .table(let child) = element else { continue }
                out += "\n[[\(renderPath(path + [key]))]]\n"
                renderTable(child, path: path + [key], order: order, out: &out)
            }
        }
    }

    private static func isTable(_ value: TOMLValue) -> Bool {
        if case .table = value { return true }
        return false
    }

    /// 段名：含空格或特殊字符的键用引号包起来。
    private static func renderPath(_ path: [String]) -> String {
        path.map { key in
            let bare = key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
            return bare ? key : "\"\(escape(key))\""
        }.joined(separator: ".")
    }

    /// 单个值的写法（供文档编辑时替换值那一段）。
    public static func renderValue(_ value: TOMLValue) -> String {
        inlineValue(value)
    }

    /// 一个表的内容（不含段头），按键顺序写。
    public static func renderTableBody(_ value: TOMLValue, path: [String],
                                       order: [String: [String]]) -> String {
        guard case .table(let table) = value else { return inlineValue(value) }
        var out = ""
        renderTable(table, path: path, order: order, out: &out)
        return out
    }

    /// 单行值：字符串加引号，数组用方括号。
    static func inlineValue(_ value: TOMLValue) -> String {
        switch value {
        case .string(let s):
            return "\"\(escape(s))\""
        case .integer(let i): return String(i)
        case .double(let d): return String(d)
        case .boolean(let b): return b ? "true" : "false"
        case .array(let arr): return "[" + arr.map { inlineValue($0) }.joined(separator: ", ") + "]"
        case .table: return "{}"
        }
    }

    /// 双引号字符串的转义。
    static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if let ascii = ch.asciiValue, ascii < 0x20 {
                    out += String(format: "\\u%04X", ascii)
                } else {
                    out.append(ch)
                }
            }
        }
        return out
    }
}

// MARK: - 解析器

/// TOML 解析器：先把文本拆成「事件」（段头 / 键值），再组装成树。
///
/// 分两步是必要的：数组表（`[[voices]]`）里后续的键属于**最后一个**元素，
/// 只有先记住事件顺序才能在组装时放对地方。
struct TOMLParser {
    enum Event {
        case table([String])
        case arrayTable([String])
        case value(path: [String], value: TOMLValue)
    }

    private let chars: [Character]
    private var idx = 0
    private var line = 1
    private var events: [Event] = []
    /// 每个值在原文中的字符区间（写回时只替换这段，旁边的注释就保住了）
    var valueRanges: [String: Range<Int>] = [:]
    /// 每个键所在的行号
    var keyLines: [String: Int] = [:]
    /// 每个段覆盖的行区间（段头行 → 下一个段头行之前）
    var sectionSpans: [String: (start: Int, end: Int)] = [:]
    /// 每行起始的字符索引
    private var lineStarts: [Int] = [0]
    /// 当前段的路径（用于关段）
    private var openSection: (path: [String], line: Int)?
    /// 当前所处的段（普通表或数组表）的路径
    private var currentPath: [String] = []

    init(_ text: String) {
        self.chars = Array(text)
        var starts: [Int] = [0]
        for (offset, ch) in chars.enumerated() where ch == "\n" {
            starts.append(offset + 1)
        }
        self.lineStarts = starts
    }

    /// 字符索引 → 行号（1 起）。
    private func lineOf(_ index: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= index { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    // MARK: 主循环

    mutating func parse() throws -> [Event] {
        while true {
            try skipBlankAndComments()
            guard idx < chars.count else { break }
            if chars[idx] == "[" {
                try parseTableHeader()
            } else {
                try parseKeyValue()
            }
        }
        if let open = openSection {
            sectionSpans[open.path.joined(separator: ".")] = (open.line, line)
        }
        return events
    }

    /// 跳过空行、缩进与注释（换行也算）。
    private mutating func skipBlankAndComments() throws {
        while idx < chars.count {
            let ch = chars[idx]
            if ch == "\n" {
                line += 1
                idx += 1
            } else if ch == " " || ch == "\t" || ch == "\r" {
                idx += 1
            } else if ch == "#" {
                while idx < chars.count && chars[idx] != "\n" { idx += 1 }
            } else {
                return
            }
        }
    }

    /// 只跳空格与制表（值的前后）。
    private mutating func skipSpaces() {
        while idx < chars.count, chars[idx] == " " || chars[idx] == "\t" { idx += 1 }
    }

    // MARK: 段头

    private mutating func parseTableHeader() throws {
        idx += 1  // '['
        var isArrayTable = false
        if idx < chars.count && chars[idx] == "[" {
            isArrayTable = true
            idx += 1
        }
        skipSpaces()
        let path = try parseKeyPath()
        skipSpaces()
        guard idx < chars.count, chars[idx] == "]" else {
            throw TOMLError(message: "段名没闭合（缺 ]）", line: line)
        }
        idx += 1
        if isArrayTable {
            guard idx < chars.count, chars[idx] == "]" else {
                throw TOMLError(message: "数组表没闭合（缺 ]]）", line: line)
            }
            idx += 1
        }
        // 上一段到此为止
        if let open = openSection {
            sectionSpans[open.path.joined(separator: ".")] = (open.line, line - 1)
        }
        currentPath = path
        openSection = (path, line)
        events.append(isArrayTable ? .arrayTable(path) : .table(path))
        try skipTrailingLine()
    }

    /// 段头后面只允许注释。
    private mutating func skipTrailingLine() throws {
        skipSpaces()
        if idx < chars.count && chars[idx] == "#" {
            while idx < chars.count && chars[idx] != "\n" { idx += 1 }
        }
    }

    // MARK: 键值

    private mutating func parseKeyValue() throws {
        let keyPath = try parseKeyPath()
        skipSpaces()
        guard idx < chars.count, chars[idx] == "=" else {
            throw TOMLError(message: "键 \(keyPath.joined(separator: ".")) 后面缺 =", line: line)
        }
        idx += 1
        skipSpaces()
        let valueStart = idx
        let value = try parseValue()
        let fullPath = currentPath + keyPath
        let fullKey = fullPath.joined(separator: ".")
        valueRanges[fullKey] = valueStart..<idx
        keyLines[fullKey] = lineOf(valueStart)
        events.append(.value(path: fullPath, value: value))
        try skipTrailingLine()
    }

    /// 键路径：`a.b.c`，每段可以是裸键或引号键。
    private mutating func parseKeyPath() throws -> [String] {
        var parts: [String] = []
        while true {
            skipSpaces()
            let part = try parseKeyPart()
            parts.append(part)
            skipSpaces()
            if idx < chars.count && chars[idx] == "." {
                idx += 1
                continue
            }
            return parts
        }
    }

    private mutating func parseKeyPart() throws -> String {
        guard idx < chars.count else {
            throw TOMLError(message: "键名不完整", line: line)
        }
        if chars[idx] == "\"" || chars[idx] == "'" {
            let quote = chars[idx]
            idx += 1
            var out = ""
            while idx < chars.count && chars[idx] != quote {
                if quote == "\"" && chars[idx] == "\\" {
                    idx += 1
                    guard idx < chars.count else { break }
                    out.append(unescapeChar())
                    continue
                }
                out.append(chars[idx])
                idx += 1
            }
            guard idx < chars.count else {
                throw TOMLError(message: "引号没闭合", line: line)
            }
            idx += 1
            return out
        }
        var out = ""
        while idx < chars.count {
            let ch = chars[idx]
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" {
                out.append(ch)
                idx += 1
            } else {
                break
            }
        }
        guard !out.isEmpty else {
            throw TOMLError(message: "键名不合法", line: line)
        }
        return out
    }

    // MARK: 值

    private mutating func parseValue() throws -> TOMLValue {
        guard idx < chars.count else {
            throw TOMLError(message: "缺值", line: line)
        }
        switch chars[idx] {
        case "\"":
            if hasPrefix("\"\"\"") { return .string(try parseMultilineString(delim: "\"\"\"")) }
            return .string(try parseBasicString())
        case "'":
            if hasPrefix("'''") { return .string(try parseMultilineString(delim: "'''")) }
            return .string(try parseLiteralString())
        case "[":
            return try parseArray()
        case "{":
            return try parseInlineTable()
        default:
            return try parseScalar()
        }
    }

    private func hasPrefix(_ s: String) -> Bool {
        let target = Array(s)
        guard idx + target.count <= chars.count else { return false }
        for (offset, ch) in target.enumerated() where chars[idx + offset] != ch {
            return false
        }
        return true
    }

    /// 基本字符串 `"…"`：支持转义。
    private mutating func parseBasicString() throws -> String {
        idx += 1  // 开引号
        var out = ""
        while idx < chars.count {
            let ch = chars[idx]
            if ch == "\\" {
                idx += 1
                guard idx < chars.count else { break }
                out.append(unescapeChar())
                continue
            }
            if ch == "\"" {
                idx += 1
                return out
            }
            if ch == "\n" {
                throw TOMLError(message: "字符串里不能直接换行（要用多行字符串 \"\"\"…\"\"\"）", line: line)
            }
            out.append(ch)
            idx += 1
        }
        throw TOMLError(message: "字符串没闭合", line: line)
    }

    /// 字面串 `'…'`：不转义。
    private mutating func parseLiteralString() throws -> String {
        idx += 1
        var out = ""
        while idx < chars.count {
            let ch = chars[idx]
            if ch == "'" {
                idx += 1
                return out
            }
            if ch == "\n" {
                throw TOMLError(message: "字符串里不能直接换行（要用多行字符串 '''…'''）", line: line)
            }
            out.append(ch)
            idx += 1
        }
        throw TOMLError(message: "字符串没闭合", line: line)
    }

    /// 多行字符串 `"""…"""`：原样保留（首行换行按规范裁掉）。
    private mutating func parseMultilineString(delim: String) throws -> String {
        idx += 3
        // 规范：紧跟开头的第一个换行会被裁掉
        if idx < chars.count && chars[idx] == "\n" {
            line += 1
            idx += 1
        }
        var out = ""
        while idx < chars.count {
            if hasPrefix(delim) {
                idx += 3
                return out
            }
            if chars[idx] == "\n" { line += 1 }
            out.append(chars[idx])
            idx += 1
        }
        throw TOMLError(message: "多行字符串没闭合", line: line)
    }

    /// 数组 `[…]`：元素之间可跨行、可带注释。
    private mutating func parseArray() throws -> TOMLValue {
        idx += 1
        var items: [TOMLValue] = []
        while true {
            try skipArrayWhitespace()
            guard idx < chars.count else {
                throw TOMLError(message: "数组没闭合", line: line)
            }
            if chars[idx] == "]" {
                idx += 1
                return .array(items)
            }
            items.append(try parseValue())
            try skipArrayWhitespace()
            if idx < chars.count && chars[idx] == "," {
                idx += 1
                continue
            }
        }
    }

    /// 内联表 `{a = 1, b = 2}`。
    private mutating func parseInlineTable() throws -> TOMLValue {
        idx += 1
        var table: [String: TOMLValue] = [:]
        while true {
            try skipArrayWhitespace()
            guard idx < chars.count else {
                throw TOMLError(message: "内联表没闭合", line: line)
            }
            if chars[idx] == "}" {
                idx += 1
                return .table(table)
            }
            let keyPath = try parseKeyPath()
            skipSpaces()
            guard idx < chars.count, chars[idx] == "=" else {
                throw TOMLError(message: "内联表里缺 =", line: line)
            }
            idx += 1
            skipSpaces()
            let value = try parseValue()
            TOMLParser.setValue(path: keyPath, value: value, in: &table)
            try skipArrayWhitespace()
            if idx < chars.count && chars[idx] == "," {
                idx += 1
                continue
            }
        }
    }

    /// 数组/内联表里的空白：可含换行与注释。
    private mutating func skipArrayWhitespace() throws {
        while idx < chars.count {
            let ch = chars[idx]
            if ch == "\n" {
                line += 1
                idx += 1
            } else if ch == " " || ch == "\t" || ch == "\r" {
                idx += 1
            } else if ch == "#" {
                while idx < chars.count && chars[idx] != "\n" { idx += 1 }
            } else {
                return
            }
        }
    }

    /// 布尔 / 整数 / 浮点。
    private mutating func parseScalar() throws -> TOMLValue {
        var raw = ""
        while idx < chars.count {
            let ch = chars[idx]
            if ch == "\n" || ch == "," || ch == "]" || ch == "}" || ch == "#" { break }
            raw.append(ch)
            idx += 1
        }
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text == "true" { return .boolean(true) }
        if text == "false" { return .boolean(false) }
        let cleaned = text.replacingOccurrences(of: "_", with: "")
        if let i = Int(cleaned) { return .integer(i) }
        if let d = Double(cleaned) { return .double(d) }
        throw TOMLError(message: "看不懂的值「\(text)」", line: line)
    }

    /// 读一个转义字符（已跳过反斜杠）。
    private mutating func unescapeChar() -> Character {
        let ch = chars[idx]
        idx += 1
        switch ch {
        case "n": return "\n"
        case "t": return "\t"
        case "r": return "\r"
        case "b": return "\u{08}"
        case "f": return "\u{0C}"
        case "\"": return "\""
        case "\\": return "\\"
        case "u":
            var hex = ""
            for _ in 0..<4 where idx < chars.count {
                hex.append(chars[idx])
                idx += 1
            }
            if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                return Character(scalar)
            }
            return "u"
        default:
            return ch
        }
    }

    // MARK: 组装

    /// 把事件序列组装成 TOML 树。
    static func assemble(_ events: [Event]) -> [String: TOMLValue] {
        var root: [String: TOMLValue] = [:]
        for event in events {
            switch event {
            case .table(let path):
                ensureTable(path, in: &root)
            case .arrayTable(let path):
                ensureArrayTable(path, in: &root)
            case .value(let path, let value):
                setValue(path: path, value: value, in: &root)
            }
        }
        return root
    }

    /// 在路径上确保存在一张表；穿过数组表时落在**最后一个**元素里。
    private static func ensureTable(_ path: [String], in root: inout [String: TOMLValue]) {
        guard let head = path.first else { return }
        if path.count == 1 {
            if case .table? = root[head] { return }
            if case .array? = root[head] { return }
            root[head] = .table([:])
            return
        }
        var child = childTable(root[head])
        ensureTable(Array(path.dropFirst()), in: &child)
        storeChild(child, at: head, in: &root)
    }

    /// 数组表：在路径上追加一个新元素。
    private static func ensureArrayTable(_ path: [String], in root: inout [String: TOMLValue]) {
        guard let head = path.first else { return }
        if path.count == 1 {
            var arr: [TOMLValue]
            if case .array(let existing) = root[head] {
                arr = existing
            } else {
                arr = []
            }
            arr.append(.table([:]))
            root[head] = .array(arr)
            return
        }
        var child = childTable(root[head])
        ensureArrayTable(Array(path.dropFirst()), in: &child)
        storeChild(child, at: head, in: &root)
    }

    /// 写值：路径穿过数组表时写进最后一个元素。
    static func setValue(path: [String], value: TOMLValue, in root: inout [String: TOMLValue]) {
        guard let head = path.first else { return }
        if path.count == 1 {
            root[head] = value
            return
        }
        var child = childTable(root[head])
        setValue(path: Array(path.dropFirst()), value: value, in: &child)
        storeChild(child, at: head, in: &root)
    }

    /// 取下一层的表；数组表取最后一个元素。
    private static func childTable(_ value: TOMLValue?) -> [String: TOMLValue] {
        switch value {
        case .table(let t): return t
        case .array(let arr):
            if case .table(let t)? = arr.last { return t }
            return [:]
        default: return [:]
        }
    }

    /// 把改过的下一层写回去（数组表要写回最后一个元素）。
    private static func storeChild(_ child: [String: TOMLValue], at key: String,
                                   in root: inout [String: TOMLValue]) {
        if case .array(var arr) = root[key] {
            if arr.isEmpty {
                arr = [.table(child)]
            } else {
                arr[arr.count - 1] = .table(child)
            }
            root[key] = .array(arr)
        } else {
            root[key] = .table(child)
        }
    }
}
