import Foundation

/// 流式播报的增量缓冲与「安全 flush 前缀」抽取（第二层流式，与第一层切分严格匹配）。
///
/// 扩展侧只转发增量原文，**不在客户端切句**。本类型在服务端累积**原文**并按字符索引
/// 推进一个「已确认安全」的前缀边界：只在**句末标点/换行**处前进，半句始终保留；
/// 未闭合的代码围栏内不前进。被确认的原文块各自走既有的 `cleanText → splitSentences`。
///
/// 为什么不会破坏第一层清洗：flush 只发生在句末/段落边界，吐出的每个前缀都是
/// 「完整句子 + 完整段落」，Markdown AST 的块末补句号、跨行正则都能拿到完整结构；
/// 末尾没写完的半句不带块边界，原样留到下一帧。`finish()` 时把剩余原文一次性清洗，
/// 与非流式 `ivox speak` 完全相同。
public final class StreamBuffer: @unchecked Sendable {
    /// 句末/段落边界（与 TextSplitter 的 sentenceTerminators 对齐）。
    /// 含分号：分号隔开的是相对完整的并列小分句，播报场景提前切可降低首句延迟。
    private static let boundaryMarks: Set<Character> = ["。", "！", "？", "!", "?", "…", "；", ";", "\n"]

    /// 最小 flush 颗粒（字符）。过短的句块（「好的。」「明白。」）单独合成会反复起停
    /// MLX，听感一个字一个字蹦；攒到该长度才在最近边界吐出。残尾由 finish() 兜底。
    private let minFlushChars: Int

    private let lock = NSLock()
    private var pending = ""   // 尚未确认成「完整句」的原文（含已确认句的尾巴）

    public init(minFlushChars: Int = StreamBuffer.defaultMinFlushChars) {
        self.minFlushChars = max(1, minFlushChars)
    }

    /// 默认最小颗粒：约 2~3 个短句，兼顾「快开口」与「不起停过碎」
    public static let defaultMinFlushChars = 24

    /// 追加一段增量原文，返回本次新确认、可播报的原文块（可能为空、可能多块）。
    public func append(_ chunk: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending.append(chunk)
        // 整段围栏未配平：安全前缀最多取到「进入未闭合围栏之前」，由 flushBoundary 决定。
        return advance()
    }

    /// 流结束：剩余原文（哪怕没有句末标点）一次性返回，交由调用方整段清洗。
    public func finish() -> String? {
        lock.lock(); defer { lock.unlock() }
        let rest = pending
        pending = ""
        let trimmed = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : rest
    }

    /// 在「代码区外、且前缀长度 ≥ minFlushChars」的最后一个句末边界切一刀。
    /// 吐出的前缀自身围栏必须配平，否则只含开围栏不含闭围栏，cleanText 会把代码念出来。
    /// 边界之后的尾巴（半句/未闭合围栏/攒不够长的短句）保留到下一帧。
    private func advance() -> [String] {
        guard let boundary = flushBoundary(in: pending) else { return [] }
        let ready = String(pending[pending.startIndex...boundary])
        pending = String(pending[pending.index(after: boundary)...])
        // ready 可能含多个句子，但作为「一个完整前缀」交给调用方一次 cleanText+split，
        // 由 splitSentences 决定 80 字合并/切分，保持与整段路径同一套规则。
        return ready.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [ready]
    }

    private func flushBoundary(in s: String) -> String.Index? {
        var outside = true
        var idx = s.startIndex
        var count = 0
        var chosen: String.Index?
        while idx < s.endIndex {
            if s[idx] == "`" || s[idx] == "~" {
                // 识别三连同字符围栏（``` 或 ~~~）
                let n = fenceRunLength(s, at: idx)
                if n >= 3 {
                    outside.toggle()
                    idx = s.index(idx, offsetBy: n)
                    count += n
                    continue
                }
            }
            if outside, Self.boundaryMarks.contains(s[idx]), count + 1 >= minFlushChars {
                chosen = idx
            }
            idx = s.index(after: idx)
            count += 1
        }
        // 仍在围栏内（未闭合）时 chosen 只可能落在进围栏之前，天然安全。
        return chosen
    }

    /// 返回 idx 处连续相同的 ` 或 ~ 的个数。
    private func fenceRunLength(_ s: String, at start: String.Index) -> Int {
        let target = s[start]
        var n = 0
        var idx = start
        while idx < s.endIndex, s[idx] == target {
            n += 1
            idx = s.index(after: idx)
        }
        return n
    }
}
