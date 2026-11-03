import Foundation
import iVoxKit

// 播报身份层：只管「队列里有哪些页、轮到哪一页、哪一页被放弃」，不管怎么播。
//
// **队列里只有页**（2026-11-02 起）：一页 = 一条 assistant 消息 = 一个 MessageDisplay 完整页。
// 页按**到达顺序**排，先来先进，播完整页接着播下一页。
//
// **不再有的概念**（连同它们整套判据一起删掉）：
//   - **摞**：一次输入引发的全部回复不再成组，页面不再分组；
//   - **turn_id / session_id**：不进队列、不落库，只在日志里出现；
//   - **墓碑**：用户放弃之后不再拦后续内容（迟到的内容照播）。
//
// 容器是 **页 → 句**两层：句是**合成单位**（≤80 字），纯实现细节，用户不感知；
// 页是**用户感知的单位**（一条 assistant 消息）。

/// 一句 = 合成单位（送去合成的一小段文本，≤80 字）。
struct PlaybackSentence: Sendable {
    /// **助理自编的句号**，全局单调，永不复用。游标、音频顺序、报备都用它。
    let seq: UInt
    let text: String
    let voiceID: String
    /// 属主来源（claude / pi / dict…）。随句走，日志与归因靠它。
    let source: String
}

/// 一页 = 队列里唯一的单位（一条 assistant 消息）。
struct PlaybackPage: Sendable {
    /// **资料室自编的页号**，永远有值，自增不复用。日志里直接打「第 N 页」。
    let localID: Int
    /// 整页原文（这一页说了什么）。
    let text: String
    /// 这一页的句子（合成单位），按念的顺序。
    var sentences: [PlaybackSentence]
    /// 属主来源（claude / pi / dict…）。
    let source: String
}

/// 游标指向的句及其所在页。
///
/// **它是队列进度，不是「用户在听哪」。** 生产者取句（消费层）用它；
/// **过程干预（掀页/全掀）不许用它**——游标记的是「已交给合成的最高号」，
/// 领先真实发声**至少 2~4 秒**（预取垫 + 引擎缓冲；实测常态 2~4 秒，队列深、
/// 合成快于播放时可到几十秒）。拿它当起点就是 2026-10-17 18:52 那场事故。
struct PlaybackCursor: Sendable {
    let seq: UInt
    let sentence: PlaybackSentence
    let pageNo: Int
}

actor PlaybackSession {
    /// 队列的落盘副本（可选）：**daemon 挂了，靠它把没播完的内容捞回来**。
    /// 为 nil 时队列只在内存里（测试与不需要持久化的场合）。
    private let store: PlaybackStore?
    /// 恢复只做一次（恢复完的内容不该被再恢复一遍）。
    private var didRestore = false

    /// 队列本体：**页的 FIFO**。索引 0 = 队首 = 下一个要播的。
    private var pages: [PlaybackPage] = []
    /// 句号发号器（助理自编，全局单调）。
    private var nextSeq: UInt = 1
    /// 页号发号器（助理自编，与句号分开——「第 7 页」一个维度，「句 42」另一个维度）。
    private var nextPageSeq: Int = 1
    /// **队列进度：已交给合成的最高句号。** 供消费层取句、判断「还有没有活」。
    ///
    /// **它不是「已播到哪」**（那句旧注释是错的：`commit` 在合成结束时就前移，此时音频
    /// 可能一行都还没响），更**不是「用户在听哪」**。删除容器内容时游标**无需修正**：
    /// 句只会往后加、序号单调，游标前方的句要么已播完要么被掀掉，两种情况都不该重播。
    private var cursorSeq: UInt = 0

    /// 设备当前正在渲染的句号。消费层报事实（`noteConsumed`），身份层存位置，
    /// **推导起点的事全在下面两个 `audible*Target` 里**——三层分工不许破。
    ///
    /// **`dataConsumed` 领先真实发声 10~21ms，裁决为接受**：误差方向是安全的
    /// （指向「正在响的」，最多差 21ms，不指向「还没响的」）；2026-10-17 18:52 那场事故
    /// 是危险方向。要对齐得挂 `AVAudioEngine` tap，新增 IO 抖动风险，与收益不成比例。
    ///
    /// **它就是「正在响的那一句」，不落后一号**：`dataConsumed` 在 buffer 开始被渲染时回调，
    /// 不是播完才回调 —— 仓库里字幕的 `onSentenceStarted` 早就这么用，且从没被判过字幕延迟，
    /// 这是同一条信号在生产里跑了很久的旁证。
    private var audibleSeq: UInt = 0

    /// - Parameter store: 落盘仓库；传了就自动把上次没播完的内容捞回队列。
    init(store: PlaybackStore? = nil) {
        self.store = store
    }

    // MARK: - 落盘（队列的耐久副本）

    /// 存一页与它的句子。**写盘失败只记警告**：落盘是副本，坏了也不该挡住播报。
    private func persist(page: PlaybackPage) {
        guard let store else { return }
        let voiceID = page.sentences.first?.voiceID ?? ""
        store.savePage(StoredPage(page: page.localID, source: page.source,
                                  voiceID: voiceID, text: page.text))
        for sentence in page.sentences {
            store.insertSentence(StoredSentence(seq: sentence.seq, page: page.localID,
                                               text: sentence.text))
        }
    }

    /// **daemon 起来时把上次没播完的内容捞回来**。
    ///
    /// 恢复出来的页顺序按页号（= 到达顺序）；句号沿用落盘里的原值（全局单调，
    /// 恢复后新句接着往后发号），不重新发号——重发会让「句 42 在恢复后变成句 1」，
    /// 事后对账时两边对不上。
    private func restoreFrom(_ store: PlaybackStore) {
        let storedPages = store.loadPages()
        guard !storedPages.isEmpty else { return }
        let storedSentences = store.loadSentences()
        var sentencesByPage: [Int: [StoredSentence]] = [:]
        for sentence in storedSentences {
            sentencesByPage[sentence.page, default: []].append(sentence)
        }
        var restored: [PlaybackPage] = []
        for stored in storedPages {
            // 一页的句子见底 = 这一页已经念完了（表里只剩原文），不必恢复。
            guard let pending = sentencesByPage[stored.page], !pending.isEmpty else {
                store.deletePage(stored.page)
                continue
            }
            let sentences = pending.map {
                PlaybackSentence(seq: $0.seq, text: $0.text,
                                 voiceID: stored.voiceID, source: stored.source)
            }
            restored.append(PlaybackPage(localID: stored.page, text: stored.text,
                                         sentences: sentences, source: stored.source))
        }
        guard !restored.isEmpty else { return }
        pages = restored
        // 恢复后的句号接着往后发
        nextSeq = max(nextSeq, (restored.flatMap(\.sentences).map(\.seq).max() ?? 0) + 1)
        // 页号接着往后发（页号与落盘里的保持一致，方便事后对账）
        nextPageSeq = max(nextPageSeq, (restored.map(\.localID).max() ?? 0) + 1)
        Log.info("队列恢复：上次没播完的 \(restored.reduce(0) { $0 + $1.sentences.count }) 句已重新排队（\(restored.count) 页）")
    }

    // MARK: - 容器查询

    /// 还有没有没播的句。
    var hasPending: Bool { nextCursor() != nil }
    /// 未播句总数（诊断用；深队列上是 O(n)，别放进热路径）。
    var pendingCount: Int {
        pages.reduce(0) { $0 + $1.sentences.filter { $0.seq > cursorSeq }.count }
    }

    /// 游标之后的第一句——下一个该播的。**不把它从容器里取走**。
    func nextCursor() -> PlaybackCursor? {
        for page in pages {
            for sentence in page.sentences where sentence.seq > cursorSeq {
                return PlaybackCursor(seq: sentence.seq, sentence: sentence, pageNo: page.localID)
            }
        }
        return nil
    }

    /// 播完（或作废）这一句：游标前移。句可能已被掀掉——照样前移，序号单调不会倒退。
    func commit(_ cursor: PlaybackCursor) {
        if cursor.seq > cursorSeq {
            cursorSeq = cursor.seq
        }
        // 已交给合成的句不再需要留着：真挂了下次也不会重念它
        store?.deleteSentences(upTo: cursor.seq)
        // 这一页的句子见底 → 这一页在落盘里也不必留
        for page in pages where page.sentences.allSatisfy({ $0.seq <= cursorSeq }) {
            store?.deletePage(page.localID)
        }
    }

    /// 歌词式字幕要的一帧：**这一页的所有句子** + **念到第几句**。
    ///
    /// 按句号找它所在的那一页（句 = 一句）。页里已经念过的句仍在（只有掀页才整页删），
    /// 所以这一页的句子就是「歌词的上下文」。
    func captionContext(forSeq seq: UInt) -> (lines: [String], index: Int)? {
        for page in pages {
            if let i = page.sentences.firstIndex(where: { $0.seq == seq }) {
                return (page.sentences.map(\.text), i)
            }
        }
        return nil
    }

    /// 消费层上报「句 `seq` 正在被设备渲染」。它只报事实，不推导起点。
    func noteConsumed(_ seq: UInt) {
        guard seq > audibleSeq else { return }
        audibleSeq = seq
    }

    // MARK: - 发声点（打断起点的唯一真源）

    /// 发声点所在的页。返回 nil = 还没出声过（冷启动）或那一页已被删除。
    private func audiblePageTarget() -> (index: Int, pageNo: Int)? {
        guard let i = locate(seq: audibleSeq) else { return nil }
        return (i, pages[i].localID)
    }

    /// 按 seq 在容器里反查页下标。seq 全局单调，至多命中一次。
    private func locate(seq: UInt) -> Int? {
        guard seq > 0 else { return nil }
        return pages.firstIndex { $0.sentences.contains { $0.seq == seq } }
    }

    /// 队首第一个**还有没出声的句**的页下标；没有则 nil。
    ///
    /// **判据是「还有没有没出声的」**——纯结构事实，不需要时间信息。
    ///
    /// **判据用发声点（`audibleSeq`），不用游标（`cursorSeq`）**：游标是**合成进度**，
    /// 合成快于播放时它能领先真实发声好几页（2026-11-03 实测领先了 7 页）。
    /// 用它挑「用户即将听到的那一页」，会把还没出声的中间页整片跳过。
    private func firstPendingPageIndex() -> Int? {
        pages.firstIndex { $0.sentences.contains { $0.seq > audibleSeq } }
    }

    /// **用户此刻正在听的页号**（诊断用，只读）。
    /// 发声点优先；发声点还没有记录时退回**队首**（用户还没听到任何声音，即将播的那页就是他要听的）。
    var headPageNo: Int? {
        if let p = audiblePageTarget() { return p.pageNo }
        guard let i = firstPendingPageIndex() else { return nil }
        return pages[i].localID
    }

    /// **用户此刻正在听的页**（掀页的靶心）。发声点优先，缺则队首。
    /// - Returns: `nil` = 容器里没有任何内容（队列真空 / 设备播空），此时过程干预退化成「只掐不掀」。
    func headPageTarget() -> (index: Int, pageNo: Int)? {
        if let a = audiblePageTarget() { return a }
        if let i = firstPendingPageIndex() { return (i, pages[i].localID) }
        return nil
    }

    // MARK: - 入队

    /// 入队一页（一条 assistant 消息）。返回自编页号。
    ///
    /// `sentences` 是这一页拆好的句子（合成单位）；拆分在**接入侧**做（那里才知道
    /// 原文该怎么切），这里只负责排队与发号。
    @discardableResult
    func appendPage(text: String, sentences: [String],
                    voiceID: String, source: String) -> Int? {
        guard !sentences.isEmpty else { return nil }
        let stamped = stamp(sentences, voiceID: voiceID, source: source)
        let page = PlaybackPage(localID: nextPageLocalID(), text: text,
                                sentences: stamped, source: source)
        pages.append(page)
        persist(page: page)
        return page.localID
    }

    /// 给一批句盖章句号。**句的身份只有这个 `seq`**——外部编号一律不进句。
    private func stamp(_ sentences: [String], voiceID: String, source: String) -> [PlaybackSentence] {
        sentences.map { text in
            defer { nextSeq += 1 }
            return PlaybackSentence(seq: nextSeq, text: text,
                                    voiceID: voiceID, source: source)
        }
    }

    /// 页号也走自己的发号器（外部 page_id 只当日志对照，不当身份）。
    private func nextPageLocalID() -> Int {
        defer { nextPageSeq += 1 }
        return nextPageSeq
    }

    // MARK: - 打断（掀）

    /// 掀页（Ctrl+1）：摘走**用户此刻正在听的那一页**，从下一页接着播。
    ///
    /// 起点取「发声点所在的那一页」——**不问消费进度**，那会差 2~4 秒（见 `PlaybackCursor`）。
    /// 同样**领取即摘走**：掐在播要 await 旧管道退净，那期间旧管道会 commit 掉正在响的
    /// 最后一句、游标一越过边界，「当前页」就从 A 变成 B，于是掀掉了用户想听的 B
    /// （2026-10-17 18:52 实测现场）。把摘走放在**掐之前**，起点从此不可能再被游标带偏；
    /// 连按也天然正确——第二次按压时队首已经是下一页。
    ///
    /// **不立墓碑**：迟到的内容照播（内容生死只由用户当下这一按决定）。
    ///
    /// - Returns: (被掀掉的页号，丢掉的句数，**被掀页之后第一句的句号**)。
    ///   `nil` = 当时没有内容在播。第三项给「掀完之后该接着念哪一句」用——
    ///   它是掀页的**续播起点**，跟合成进度无关（合成进度可能已越过好几页）。
    @discardableResult
    func takeHeadPage() -> (pageNo: Int, dropped: Int, nextSeq: UInt?)? {
        guard let head = headPageTarget() else { return nil }
        let page = pages[head.index]
        // 丢的是「这一页里还没出声的那几句」——已经念过的部分不算丢。
        let dropped = page.sentences.filter { $0.seq > audibleSeq }.count
        // 被掀页之后的**第一句**：掀完之后该从这里接着念。
        let nextSeq = pages.indices.contains(head.index + 1)
            ? pages[head.index + 1].sentences.first?.seq
            : nil
        pages.remove(at: head.index)
        store?.deletePage(page.localID)
        return (page.localID, dropped, nextSeq)
    }

    /// **把合成进度退回到 `seq` 之前**：让 `seq` 成为下一句该合成的。
    ///
    /// 管道被掐断时，**已经合成好但还没出声**的那些句子随管道一起没了
    /// （音频作废、容器里的句子却已被游标标成「过去了」→ 永远不会再被合成 →
    /// 内容凭空消失，表现为「跳页」）。退回去等于让它们回到「还没合成」，
    /// 重新排队、重新合成、照播。
    ///
    /// 2026-11-03 实测：合成跑在播放前面 7 页（合成比播放快 2.1 倍），
    /// Ctrl+1 掀掉正在听的那页时，第 11~17 页已经合成好却还没出声 ——
    /// 掐管道的瞬间音频全作废，而游标已越过它们 → 那 7 页再也没被念过。
    ///
    /// **只退不前**：游标本该单调（句号全局单调），这里开一个**朝回走**的口子，
    /// 只为掀页这一处用；别的路径谁都不许动它。
    /// `seq` 必须是**续播起点**（被掀页之后第一句的句号）——
    /// 它之前的内容要么已经念过、要么随那一页一起被掀掉，都不该回来。
    ///
    /// - Returns: 重新排队的句数（诊断用）。
    @discardableResult
    func resumeSynthesis(from seq: UInt) -> Int {
        guard seq > 0 else { return 0 }
        let newCursor = seq - 1
        guard newCursor < cursorSeq else { return 0 }
        cursorSeq = newCursor
        // 落盘：这些句子在 commit 时被删过（按合成进度删的），
        // 现在它们又要重播 → 重新写回队列库，daemon 中途挂了也不丢。
        var requeued = 0
        for page in pages {
            let pending = page.sentences.filter { $0.seq > newCursor }
            guard !pending.isEmpty else { continue }
            store?.savePage(StoredPage(page: page.localID, source: page.source,
                                       voiceID: page.sentences.first?.voiceID ?? "",
                                       text: page.text))
            for sentence in pending {
                store?.insertSentence(StoredSentence(seq: sentence.seq, page: page.localID,
                                                     text: sentence.text))
                requeued += 1
            }
        }
        return requeued
    }

    /// 全掀（Ctrl+2）：清空容器。
    ///
    /// **清全体**——谁在念都得停，这不伤人。
    ///
    /// **不留墓碑**：这一下之后再来的内容照常入队照常播（内容生死只由用户当下这一按决定）。
    @discardableResult
    func discardAll() -> Int {
        let dropped = pendingCount
        pages.removeAll()
        store?.deleteAll()
        return dropped
    }

    /// 回收念完的页（一句都不剩的页）：它们留在容器里只是历史垃圾。
    ///
    /// **为什么必须清**：容器原先只增不减，播完的页一直留着，酿成两个后果——
    /// ① `/health` 的 `audiblePage` 在播完之后还报着一个早就不响的页，等于对外撒谎；
    /// ② **更要命**——播完后用户按掀页，起点会落在那个早已播完的页上，
    /// 于是把「后来才到的那一页」给掀了。
    ///
    /// - Parameter afterSilence: 调用方已确认**设备真静音**（收尾那条路径，
    ///   它前面跑过 `waitUntilQuiet`）。这时连「正在响的」那一句也已经响完，可以连它一起清——
    ///   发声点本身永远停在最后一句上（没有下一句来推进它），不给这条后门，`/health` 就会一直撒谎。
    @discardableResult
    func retireSpentPages(afterSilence: Bool = false) -> Int {
        var n = 0
        while let first = pages.first {
            let maxSeq = first.sentences.map(\.seq).max() ?? 0
            // 严格小于：正在响的那一句（maxSeq == 发声点）还没响完，不能清。
            guard afterSilence || maxSeq < audibleSeq else { break }
            pages.removeFirst()
            store?.deletePage(first.localID)
            n += 1
        }
        return n
    }

    // MARK: - 恢复

    /// 恢复上次没播完的内容（daemon 起来时做一次，做过就跳过）。
    ///
    /// 放在 actor 的方法里而不是 init：init 是同步的、且非隔离的，
    /// 碰不了容器状态（`restoreFrom` 要发号、要建页）。
    func restoreIfNeeded() {
        guard !didRestore else { return }
        didRestore = true
        guard let store else { return }
        restoreFrom(store)
    }
}
