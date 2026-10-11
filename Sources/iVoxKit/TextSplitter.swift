import Foundation

/// 播报分块参数
public enum PlaybackChunking {
    /// 单个播报分块上限（字符）。太小会频繁起停合成，太大则首句开播延迟变大
    public static let maxChars = 80
}

/// 按句末标点切分文本，并把相邻短句合并到接近 `maxChars`。
///
/// 用于播报分块：一次 `ivox speak` 拆成多段入队，句级合成
/// 也贴合流式 turn 的「边切边播」。
public func splitSentences(_ text: String, maxChars: Int = PlaybackChunking.maxChars) -> [String] {
    let limit = max(1, maxChars)
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    let atoms = sentenceAtoms(trimmed).flatMap { hardSplit($0, limit: limit) }
    return merge(atoms, limit: limit)
}

// MARK: - 私有实现

/// 句末标点：连续出现（如「？！」）算作上一句的结尾。
/// 含分号：分号隔开相对完整的并列小分句，播报时提前切可降低首句延迟（对齐 StreamBuffer）。
private let sentenceTerminators: Set<Character> = ["。", "！", "？", "!", "?", "…", "；", ";", "\n"]
/// 超长句优先在这些位置断开
private let softBreaks: Set<Character> = ["，", "、", "：", ",", ":", " "]

/// 切出原子句；纯标点不单独成句，并回上一句
private func sentenceAtoms(_ text: String) -> [String] {
    var atoms: [String] = []
    var buf = ""
    for ch in text {
        buf.append(ch)
        guard sentenceTerminators.contains(ch) else { continue }
        let s = buf.trimmingCharacters(in: .whitespacesAndNewlines)
        buf = ""
        appendAtom(s, into: &atoms)
    }
    appendAtom(buf.trimmingCharacters(in: .whitespacesAndNewlines), into: &atoms)
    return atoms
}

private func appendAtom(_ s: String, into atoms: inout [String]) {
    guard !s.isEmpty else { return }
    // 「！」被单独切开时并回上一句，避免产出一个只念停顿的空句
    if !s.contains(where: { $0.isLetter || $0.isNumber }), !atoms.isEmpty {
        atoms[atoms.count - 1] += s
    } else {
        atoms.append(s)
    }
}

/// 单句超过上限时，在软标点处断开；完全没有标点的长串按 2×上限硬切
private func hardSplit(_ sentence: String, limit: Int) -> [String] {
    guard sentence.count > limit else { return [sentence] }
    var out: [String] = []
    var cur = ""
    for ch in sentence {
        cur.append(ch)
        if cur.count >= limit, softBreaks.contains(ch) {
            out.append(cur.trimmingCharacters(in: .whitespaces))
            cur = ""
        } else if cur.count >= limit * 2 {
            out.append(cur.trimmingCharacters(in: .whitespaces))
            cur = ""
        }
    }
    let tail = cur.trimmingCharacters(in: .whitespaces)
    if !tail.isEmpty { out.append(tail) }
    return out
}

/// 相邻短句合并到 ≤ limit；上一段以全角标点结尾时不补空格
private func merge(_ atoms: [String], limit: Int) -> [String] {
    var out: [String] = []
    var cur = ""
    for a in atoms {
        if cur.isEmpty {
            cur = a
        } else if cur.count + a.count <= limit {
            cur += (cur.last?.isASCII ?? false) ? " " + a : a
        } else {
            out.append(cur)
            cur = a
        }
    }
    if !cur.isEmpty { out.append(cur) }
    return out
}
