import Foundation
import iVoxKit

// 播报身份层：只管「谁在说话、说到哪、哪层被作废」，不管怎么播。
// 容器是 段 → 页 → 块，**当前播到哪里由游标表达，游标不把块从容器里取走**——
// 这样「正在播的那块」永远在容器内，掀页时它落在被删范围内，
// 不必像旧实现那样在容器外另记一份 `playingPageID`（那份会陈旧，
// 2026-10-17 的 bug 就是第二次按压拿旧页号删掉了后到的内容）。
// 四层文档见 docs/playback-purpose.md（目的）→ sources → requirements → queue。

/// 一块待播文本（服务拿去播报的单位，不是给用户看的）。
/// `seq` 由 Session 在入队时分配、单调递增，游标就靠它定位。
struct PlaybackBlock: Sendable {
    let seq: UInt
    let text: String
    let voiceID: String
    let source: String
    /// 所属页（Claude 的 `message_id`）；nil = 非 Claude 路径（pi / hook / ivox speak），
    /// 那时掀页退化成「只掐在播」。
    let pageID: String?
}

/// 一页 = 一条 assistant 消息（一次回复）。
struct PlaybackPage: Sendable {
    let id: String?
    var blocks: [PlaybackBlock]
}

/// 一段 = 一摞（一次回复引发的全部内容，`turn_id` 为 nil = 无分组的普通播报）。
struct PlaybackSegment: Sendable {
    let id: String?
    var sealed: Bool
    var pages: [PlaybackPage]

    var blockCount: Int { pages.reduce(0) { $0 + $1.blocks.count } }
    var isEmpty: Bool { blockCount == 0 }
}

/// 游标指向的块及其容器坐标。「当前在播」= 游标之后的第一块。
struct PlaybackCursor: Sendable {
    let seq: UInt
    let block: PlaybackBlock
    /// 这一块是否属于加急段（Cmd+D 译文）——两条队列各有一套游标，`commit` 据此推进对的那条。
    let isFront: Bool
}

actor PlaybackSession {
    /// 空闲宽限期（秒）：**声音停下之后**再等这么久没新内容，就判「说完了」。
    /// 取值理由：一轮里页与页之间夹工具调用，间隔是秒级；太长会让字幕迟迟不收。2 秒是飞哥定的手感。
    static let idleGraceSeconds: Double = 2
    /// 墓碑容量上限：只用来拦「被用户显式作废的摞的后续增量」，用完丢最老的。
    private static let tombstoneCapacity = 32

    private var segments: [PlaybackSegment] = []
    /// 加急段（只有 Cmd+D 译文这一种）：**插到队首**，先于常规段播。
    /// 单独一只列表而不是往 `segments` 头部插——序号单调递增，插在游标前面它就永远轮不到播；
    /// 加急段自带一套游标（`frontCursor`），两段各走各的，语义清楚。
    private var front: [PlaybackSegment] = []
    private var frontCursor: UInt = 0
    /// 每块一个单调递增的号。游标记「已播到哪一号」——删除容器内容时游标**无需修正**：
    /// 块只会往后加、序号单调，游标前方的块要么已播完要么被掀掉，两种情况都不该重播。
    private var nextSeq: UInt = 1
    private var cursorSeq: UInt = 0

    /// pi 双流认证用：认领过、尚未出栈的轮。
    private var turnStack: [String] = []
    /// 墓碑：被用户显式作废（跳整摞 / 掀桌 / 取消轮次）的摞，后续增量一律丢弃。
    private var deadTurns: [String] = []

    /// 「等新内容」的等待者。入队 / 收尾 / 打断唤醒（返回 true）；宽限到点（返回 false）。
    /// 用引用类型让「唤醒」与「超时」互斥：两边都在本 actor 上串行地从 `waiters` 摘除，
    /// 先摘到的 resume、后到的发现已不在数组里即放弃——`CheckedContinuation` 双重 resume 会 fatal crash。
    private final class Waiter: @unchecked Sendable {
        let continuation: CheckedContinuation<Bool, Never>
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    }
    /// 掀页靶心的占位（见 `claimCurrentPage`）：`claimed` 表示「某次按压已领走靶心、还没删完」。
    /// `page` 单独存是因为「领到了、但那页没有页号（非 Claude 路径）」也是一种领到，
    /// 不能和「没领」混成同一个 nil。
    private var pageClaim: (claimed: Bool, page: String?) = (false, nil)
    private var waiters: [Waiter] = []
    /// 已排定宽限计时的等待者（防止重复计时器把同一个 waiter 摘两次）。
    private var timedOut: Set<ObjectIdentifier> = []

    // MARK: - 容器查询

    /// 还有没有没播的块。
    var hasPending: Bool { nextCursor() != nil }
    /// 未播块总数（诊断用；深队列上是 O(n)，别放进热路径）。
    var pendingCount: Int { count(in: front, after: frontCursor) + count(in: segments, after: cursorSeq) }

    private func count(in list: [PlaybackSegment], after cursor: UInt) -> Int {
        var n = 0
        for s in list { for p in s.pages { n += p.blocks.filter { $0.seq > cursor }.count } }
        return n
    }
    /// 是否还有没收尾的摞（还在生成、没说「说完了」）。宽限到点就是给它们盖印的。
    var anyUnsealed: Bool { segments.contains { !$0.sealed } || front.contains { !$0.sealed } }
    /// 未收尾的摞号（诊断日志用）。
    var unsealedIDs: [String] {
        segments.filter { !$0.sealed }.compactMap(\.id) + front.filter { !$0.sealed }.compactMap(\.id)
    }

    /// 游标之后的第一块——下一个该播的。**不把它从容器里取走**。
    func nextCursor() -> PlaybackCursor? {
        if let c = first(in: front, after: frontCursor, isFront: true) { return c }
        return first(in: segments, after: cursorSeq, isFront: false)
    }

    private func first(in list: [PlaybackSegment], after cursor: UInt, isFront: Bool) -> PlaybackCursor? {
        for s in list {
            for p in s.pages {
                for b in p.blocks where b.seq > cursor {
                    return PlaybackCursor(seq: b.seq, block: b, isFront: isFront)
                }
            }
        }
        return nil
    }

    /// 播完（或作废）这一块：游标前移。块可能已被掀掉——照样前移，序号单调不会倒退。
    func commit(_ cursor: PlaybackCursor) {
        if cursor.isFront {
            if cursor.seq > frontCursor { frontCursor = cursor.seq }
        } else if cursor.seq > cursorSeq {
            cursorSeq = cursor.seq
        }
    }

    /// 当前正在播的那一页（掀页的语义：「用户感知到的当前页」）。
    /// 游标之后第一块所在的页——正是他听到的那一页。
    var currentPageID: String? { nextCursor()?.block.pageID }



    // MARK: - 入队

    /// 有分组的入队（Claude 的一摞、pi 的一轮）：同摞的各页并进同一段。
    /// - Returns: false = 该摞已被作废，这次增量静默丢弃。
    @discardableResult
    func appendGrouped(_ jobs: [PlaybackBlock], group: String) -> Bool {
        // ① 先看自己死没死。这一步必须在任何「盖上别的摞」之前——实测踩过：
        // 已死摞的迟到页会先盖掉当前活跃的那一摞、再把自己丢掉，顺手把活的也打死。
        if deadTurns.contains(group) {
            Log.debug("丢弃：turn=\(group) 那一摞已被盖上")
            return false
        }
        guard !jobs.isEmpty else { return true }
        if let idx = segments.firstIndex(where: { $0.id == group }) {
            segments[idx].pages.append(contentsOf: pages(from: jobs))
            // 又来货了：揭掉空闲宽限封的印（宽限只是猜「说完了」，不是判死）
            segments[idx].sealed = false
        } else {
            segments.append(PlaybackSegment(id: group, sealed: false, pages: pages(from: jobs)))
        }
        signal()
        return true
    }

    /// 无分组的普通播报（`ivox speak` / hook 终稿 / Cmd+D 译文）：并入队尾的无分组段。
    /// 无分组段天生收尾（没有「还在生成」这回事），因此 `sealed: true`。
    @discardableResult
    func appendPlain(_ jobs: [PlaybackBlock]) -> Bool {
        guard !jobs.isEmpty else { return false }
        if let last = segments.last, last.id == nil {
            segments[segments.count - 1].pages.append(contentsOf: pages(from: jobs))
        } else {
            segments.append(PlaybackSegment(id: nil, sealed: true, pages: pages(from: jobs)))
        }
        signal()
        return true
    }

    /// 同一次入队里的块按页归拢——同页的块挨在一起，掀页才能整页删干净。
    /// 同时按到达序盖上单调递增的 `seq`，游标靠它定位。
    private func pages(from jobs: [PlaybackBlock]) -> [PlaybackPage] {
        var out: [PlaybackPage] = []
        for j in jobs {
            let stamped = PlaybackBlock(seq: nextSeq, text: j.text, voiceID: j.voiceID,
                                        source: j.source, pageID: j.pageID)
            nextSeq += 1
            if var last = out.last, last.id == j.pageID {
                last.blocks.append(stamped)
                out[out.count - 1] = last
            } else {
                out.append(PlaybackPage(id: j.pageID, blocks: [stamped]))
            }
        }
        return out
    }

    // MARK: - 收尾与作废

    /// 流式轮开始（pi 首帧）：登记属主。已作废的旧轮忽略。
    @discardableResult
    func beginTurn(_ id: String) -> Bool {
        guard !deadTurns.contains(id) else { return false }
        if !turnStack.contains(id) { turnStack.append(id) }
        signal()
        return true
    }

    /// 这一摞说完了（Stop 钩子 / `{end}`）：盖印，**不立墓碑**——
    /// 「说完了」不等于「该轮已死」，同一摞的页可能还在路上。
    @discardableResult
    func sealTurn(_ id: String) -> Bool {
        var hit = false
        for i in segments.indices where segments[i].id == id {
            segments[i].sealed = true; hit = true
        }
        for i in front.indices where front[i].id == id {
            front[i].sealed = true; hit = true
        }
        if hit { signal() }
        return hit
    }

    /// 用户取消这一轮（pi 空流 `{cancel}`）：丢掉该轮内容并立墓碑，其后续增量一律不开口。
    @discardableResult
    func cancelTurn(_ id: String) -> Bool {
        pageClaim = (false, nil)
        let dropped = sweepSegments(matching: id, in: &segments) + sweepSegments(matching: id, in: &front)
        bury(id)
        if turnStack.last == id { turnStack.removeLast() }
        signal()
        return dropped > 0
    }

    /// 掀页的靶心：**领走**「当前正在播的那一页」并占住它。
    ///
    /// 为什么不能只读一次就完事：掀页的顺序是「领靶心 → 掐在播（要 await 播放器退净）→ 删这一页」，
    /// 中间那几个挂起点给 actor **重入**了机会——用户第二次按压会插进来，容器里这一页还没删，
    /// 于是又领到同一个页号，两次都去删同一页（2026-10-17 `P2` 实测：两下都报 Q2，随后 daemon 崩）。
    /// 领走即焚是另一半保险；**占位**才是治重入的那一半：领过之后返回 nil，第二次按压退化成
    /// 「只掐在播」，不误删、也不会重复删同一页。
    func claimCurrentPage() -> String? {
        guard !pageClaim.claimed else { return nil }
        pageClaim = (true, nextCursor()?.block.pageID)
        return pageClaim.page
    }

    /// 删掉领走的那一页并清占位。领到的页号为 nil（非 Claude 路径）时什么都不做。
    @discardableResult
    func discardClaimedPage() -> Int {
        let page = pageClaim.page
        pageClaim = (false, nil)
        return discardPage(page)
    }

    /// 掀页：丢掉所有属于该页的块（页号为 nil 的那批不算——非 Claude 路径没有页的语义）。
    /// 游标**不用修正**：它是「已播到哪一号」，被删的块要么已播完、要么正是被用户掀掉的，
    /// 两种情况都不该重播；而游标之后的第一块会自动变成新的下一块。
    /// - Returns: 被丢掉的块数。
    @discardableResult
    func discardPage(_ pageID: String?) -> Int {
        guard let pageID else { return 0 }
        // **删除不 signal**：signal 的含义是「有新内容来了，宽限不必再等」。
        // 掀页是在**删**内容——发了 signal 会把宽限计时器唤醒，让它误判「来新货了、别盖印」，
        // 宽限就此作废而没有接班人，这一摞永远收不掉（2026-10-17 `P3` 实测，同一毫秒内自唤醒）。
        return sweepPages(matching: pageID, in: &front) + sweepPages(matching: pageID, in: &segments)
    }

    /// 把符合条件的页整页删掉，返回删掉的块数。
    private func sweepPages(matching pageID: String, in list: inout [PlaybackSegment]) -> Int {
        var dropped = 0
        for i in list.indices {
            // **不能用 remove(at:) 配 indices 遍历**（2026-10-17 实测崩在这：删完索引整体前移，
            // 下一轮越界 → Index out of range → daemon 崩、LaunchAgent 拉起、自检假红一片）。
            // 要删的先算出来，再用 removeAll 一次性删。
            let hit = list[i].pages.filter { $0.id == pageID }
            dropped += hit.reduce(0) { $0 + $1.blocks.count }
            list[i].pages.removeAll { $0.id == pageID }
        }
        return dropped
    }

    /// 把符合条件的段整段删掉，返回删掉的块数。
    private func sweepSegments(matching id: String, in list: inout [PlaybackSegment]) -> Int {
        let dropped = list.filter { $0.id == id }.reduce(0) { $0 + $1.blockCount }
        list.removeAll { $0.id == id }
        return dropped
    }

    /// 游标之后那一块所在的段号（掀摞的靶心）。没有块在播、或那段没有摞号 → nil。
    private var currentSegmentID: String? {
        guard let c = nextCursor() else { return nil }
        let list = c.isFront ? front : segments
        for seg in list where seg.pages.contains(where: { $0.blocks.contains { $0.seq == c.seq } }) {
            return seg.id
        }
        return nil
    }

    /// 掀**当前**那一摞：靶心取「游标之后第一块所在的段」——正是他听到的那一摞，
    /// 取完即焚（第二次按压重新取，不会拿旧摞号删后到的内容）。容器里没有当前块就什么都不做。
    /// - Returns: 被丢掉的块数（0 = 当时没有块在播）。
    @discardableResult
    func discardCurrentSegment() -> Int {
        pageClaim = (false, nil)
        guard let cursor = nextCursor() else { return 0 }
        guard let id = currentSegmentID else {
            // 队首那段没有摞号（普通播报）：掀掉它，就是 Ctrl+1 在无分组的队首上的语义。
            if cursor.isFront {
                guard !front.isEmpty, front[0].id == nil else { return 0 }
                return front.removeFirst().blockCount
            }
            guard !segments.isEmpty, segments[0].id == nil else { return 0 }
            return segments.removeFirst().blockCount
        }
        return discardSegment(id)
    }

    /// 掀段：丢掉整摞并立墓碑，它的后续增量（含关连接后 EOF 兜底补出的残尾）不再开口。
    @discardableResult
    func discardSegment(_ id: String?) -> Int {
        guard let id else {
            // 无分组普通播报：只丢最靠前的那一段（Ctrl+1 在无分组的队首上就这个语义）。
            if !front.isEmpty, front[0].id == nil { return front.removeFirst().blockCount }
            guard !segments.isEmpty, segments[0].id == nil else { return 0 }
            return segments.removeFirst().blockCount
        }
        let dropped = sweepSegments(matching: id, in: &segments) + sweepSegments(matching: id, in: &front)
        if dropped > 0 { bury(id) }   // 同上：删除不 signal
        return dropped
    }

    /// 全掀：清空容器，所有摞立墓碑。
    @discardableResult
    func discardAll() -> [String] {
        pageClaim = (false, nil)
        // **turnStack 里的轮也要立墓碑**：它们是「已声明、块还没到」的轮，此刻容器里还没有对应的段，
        // 只按段立碑就会漏掉它们——打断之后它们陆续送来的字会照常播出来
        //（2026-10-17 `E7` 实测：清空队列时 pending=0，墓碑一个没立，打断后同一轮照样开口）。
        var ids = turnStack
        ids += segments.compactMap(\.id) + front.compactMap(\.id)
        turnStack.removeAll()
        segments.removeAll()
        front.removeAll()
        ids.forEach { bury($0) }
        signal()
        return ids
    }

    /// 加急入队（Cmd+D 译文）：插到队首，**只掐在播、其余排队内容一律保留**。
    /// 无分组天生收尾（它不是「还在生成」的摞）。
    @discardableResult
    func appendFirst(_ jobs: [PlaybackBlock]) -> Bool {
        guard !jobs.isEmpty else { return false }
        front.insert(PlaybackSegment(id: nil, sealed: true, pages: pages(from: jobs)), at: 0)
        signal()
        return true
    }

    private func bury(_ id: String) {
        deadTurns.removeAll { $0 == id }
        deadTurns.append(id)
        if deadTurns.count > Self.tombstoneCapacity { deadTurns.removeFirst() }
    }

    // MARK: - 等新内容（空闲宽限归这里，不归播放管道）

    /// 挂起直到有新内容入队 / 有摞收尾 / 被打断，返回 true；宽限到点返回 false。
    ///
    /// **为什么这个计时器必须住在身份层**：旧实现把它挂在播放管道的循环里，
    /// 于是「没有块可播但还有摞没收尾」时管道不起、计时器也就没人跑——
    /// 那一摞永远悬着，字幕收不掉、新内容不来就永远不判完（2026-10-17 `P3` 用例实测挂死 47 秒）。
    /// 等待是「还有话没说完」这件事本身，跟当前有没有管道在播无关。
    /// - Parameter afterQuiet: 先等声音真停下（宽限的起点）再起算——最后一块被取走去合成时
    ///   它还在响，立刻起算会在尾音还没念完时就判「说完」、把字幕收掉。
    ///   传的是**轮询到静音**的实现（自带上限，设备卡死也不会把宽限的起点带死）。
    func waitForContent(afterQuiet: @Sendable () async -> Void) async -> Bool {
        await afterQuiet()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let waiter = Waiter(continuation)
            waiters.append(waiter)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.idleGraceSeconds))
                await self?.expire(waiter: waiter)
            }
        }
    }

    /// 有新货 / 收尾 / 打断：唤醒所有等待者（宽限作废——它只是猜「说完了」）。
    func signal() {
        let pending = waiters
        waiters.removeAll()
        for w in pending { w.continuation.resume(returning: true) }
    }

    /// 宽限到点：把等待者摘走并唤醒 false。已被 `signal` 摘过则什么都不做。
    private func expire(waiter: Waiter) {
        guard let idx = waiters.firstIndex(where: { $0 === waiter }) else { return }
        waiters.remove(at: idx)
        waiter.continuation.resume(returning: false)
    }

    /// 宽限到点：给所有还开着的摞盖印（= 视为「说完了」）。**不立墓碑**——
    /// 它之后若又来页，`appendGrouped` 会把 `sealed` 揭回 false 继续播。
    /// - Returns: 被盖上的摞号（空 = 没有可盖的，调用方可据此判定不必收字幕）。
    @discardableResult
    func sealIdle() -> [String] {
        let ids = unsealedIDs
        guard !ids.isEmpty else { return [] }
        for i in segments.indices { segments[i].sealed = true }
        for i in front.indices { front[i].sealed = true }
        Log.info("空闲 \(Int(Self.idleGraceSeconds))秒无新内容，判定说完了：盖上 \(ids.joined(separator: ","))")
        signal()
        return ids
    }

    /// pi 双流认证：这一轮是否仍是合法属主（未被别的流顶掉）。
    func owns(_ id: String) -> Bool { turnStack.last == id }
}
