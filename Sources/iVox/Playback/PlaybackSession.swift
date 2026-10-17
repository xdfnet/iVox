import Foundation
import iVoxKit

// 播报身份层：只管「谁在说话、说到哪、哪层被作废」，不管怎么播。
// 容器是 段 → 页 → 块，**当前播到哪里由游标表达，游标不把块从容器里取走**——
// 这样「正在播的那块」永远在容器内，掀页时它落在被删范围内，
// 不必像旧实现那样在容器外另记一份 `playingPageID`（那份会陈旧，
// 2026-10-17 的 bug 就是第二次按压拿旧页号删掉了后到的内容）。
// 播报四层文档见 docs/playback/：purpose（目的/取舍）→ sources → requirements → queue。
//
// **三层各干各的，别管别人**（2026-10-17 起的分层契约）：
//   ① 插入队列：只管把 段/页/块 放进容器，不关心谁会播、谁会删。
//   ② 消费队列：只管按容器顺序取块、合成、播放，不关心插队意图与打断。
//   ③ 过程干预：只管「掐 + 删队首」，**绝不问消费进度**。
// 第 ③ 条是被一次实测事故逼出来的（2026-10-17 18:52）：干预层为了找「当前摞」
// 去问游标，而游标是**合成进度**、领先真实发声 2~4 秒（预取垫 + 引擎缓冲），
// 于是用户按下 Ctrl+1 时耳朵里是 A、代码掀的是 B——用户想听的那一摞被整摞掀掉，
// 且毫无察觉。
//
// **为什么问游标是多余的**：播放严格按容器顺序推进，所以「正在播的那一摞」
// 恒等于**容器里第一个还有未播块的段**——纯结构事实，不需要时间信息。
// 本文件里游标只用于两件事：① 判「这个段还剩不剩内容」；② producer 取块。
// 任何「用户在听什么」的判断都不许经过游标。

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
    /// 属主来源（claude / codex / pi / …）。**只为 Ctrl+Esc 的墓碑分范围而存在**：
    /// 掀容器是全体，埋墓碑只埋属主那一份（见 `discardAll`）。
    let source: String?
    var sealed: Bool
    var pages: [PlaybackPage]

    var blockCount: Int { pages.reduce(0) { $0 + $1.blocks.count } }
    var isEmpty: Bool { blockCount == 0 }
}

/// 游标指向的块及其容器坐标。
///
/// **它是队列进度，不是「用户在听哪」。** 生产者取块（消费层）用它；
/// **过程干预（Ctrl+1/2/Esc）不许用它**——游标记的是「已交给合成的最高号」，
/// 领先真实发声 2~4 秒（预取垫 + 引擎缓冲）。拿它当起点就是 2026-10-17 18:52 那场事故。
/// 干预层只许看容器结构，见 `headStackTarget()`。
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
    /// 每块一个单调递增的号。
    private var nextSeq: UInt = 1
    /// **队列进度：已交给合成的最高块号。** 供消费层取块、判「还有没有活」；
    /// 供删除操作判断「这个段还剩不剩内容」。
    ///
    /// **它不是「已播到哪」**（那句旧注释是错的：`commit` 在合成结束时就前移，此时音频
    /// 可能一行都还没响），更**不是「用户在听哪」**。删除容器内容时游标**无需修正**：
    /// 块只会往后加、序号单调，游标前方的块要么已播完要么被掀掉，两种情况都不该重播。
    private var cursorSeq: UInt = 0

    /// pi 双流认证用：认领过、尚未出栈的轮。**连属主一起记**——
    /// 「已声明、字还没到」的轮此刻容器里没有段，Ctrl+Esc 要按来源挑着埋，缺了来源就挑不出来。
    private var turnStack: [(source: String, id: String)] = []

    /// **播报员此刻在念的那份**的来源。Ctrl+Esc 的墓碑只埋它这一份——全局热键
    /// 拿不到「当前会话」是谁，拿这个当替身：你喊闭嘴时，冲的就是他手上正拿着的那摞。
    ///
    /// ⚠️ 定义是「**此刻在念谁的东西**」，不是「谁在说话」——差一个字结论会反过来：
    /// 翻译插队（`appendFirst` 也走 `noteSource`）会把属主换成 `translate`，因为那一刻
    /// 播报员手上拿的正是你刚递的那张字条，你想喊停的也是它。译文的增量不来自某个会话，
    /// Claude 那边不送新块就一直挂着；等它送新块，属主自然换回 `claude`。
    /// （曾按「谁在说话」理解，以为插队纸在抢位、打算删掉 `appendFirst` 那行 `noteSource`
    /// ——那会把「译文正响时按 Ctrl+Esc」变成不埋任何东西，正是这个字段要避免的。）
    private var lastActiveSource: String?
    /// 墓碑：被用户显式作废（跳整摞 / 掀桌 / 取消轮次）的摞，后续增量一律丢弃。
    private var deadTurns: [String] = []

    /// 「等新内容」的等待者。入队 / 收尾 / 打断唤醒（返回 true）；宽限到点（返回 false）。
    /// 用引用类型让「唤醒」与「超时」互斥：两边都在本 actor 上串行地从 `waiters` 摘除，
    /// 先摘到的 resume、后到的发现已不在数组里即放弃——`CheckedContinuation` 双重 resume 会 fatal crash。
    private final class Waiter: @unchecked Sendable {
        let continuation: CheckedContinuation<Bool, Never>
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    }
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
    // 2026-10-17 删除。这个 getter 是**拿合成进度冒充用户感知位置**的源头：
    // 掀页/掀摞的起点都取自它，而游标领先真实发声 2~4 秒。起点改由队首结构给出，
    // 见 `headStackTarget()` / `headPageTarget()`。

    // MARK: - 发声点（打断起点的唯一真源）

    /// 设备当前正在渲染的块号。消费层报事实（`noteConsumed`），身份层存位置，
    /// **推导起点的事全在下面两个 `audible*Target` 里**——三层分工不许破。
    ///
    /// **`dataConsumed` 领先真实发声 10~21ms，裁决为接受**：误差方向是安全的
    /// （指向「正在响的」，最多差 21ms，不指向「还没响的」）；2026-10-17 18:52 那场事故
    /// 是危险方向。要对齐得挂 `AVAudioEngine` tap，新增 IO 抖动风险，与收益不成比例。
    ///
    /// **它就是「正在响的那一块」，不落后一号**：`dataConsumed` 在 buffer 开始被渲染时回调，
    /// 不是播完才回调 —— 仓库里字幕的 `onSentenceStarted` 早就这么用，且从没被判过字幕延迟，
    /// 这是同一条信号在生产里跑了很久的旁证。
    private var audibleSeq: UInt = 0

    /// 消费层上报「块 `seq` 正在被设备渲染」。它只报事实，不推导起点。
    func noteConsumed(_ seq: UInt) {
        guard seq > audibleSeq else { return }
        audibleSeq = seq
    }

    /// 发声点所在的段。返回 nil = 还没出声过（冷启动）或那一摞已被删除。
    private func audibleStackTarget() -> (isFront: Bool, index: Int, id: String?)? {
        guard let hit = locate(seq: audibleSeq) else { return nil }
        return (hit.isFront, hit.segIndex, (hit.isFront ? front : segments)[hit.segIndex].id)
    }

    /// 发声点所在的页。
    private func audiblePageTarget() -> (isFront: Bool, segIndex: Int, pageIndex: Int, id: String?)? {
        guard let hit = locate(seq: audibleSeq) else { return nil }
        let list = hit.isFront ? front : segments
        guard let j = list[hit.segIndex].pages.firstIndex(where: { $0.blocks.contains { $0.seq == audibleSeq } })
        else { return nil }
        return (hit.isFront, hit.segIndex, j, list[hit.segIndex].pages[j].id)
    }

    /// 按 seq 在两个容器里反查坐标。seq 全局单调（`pages(from:)` 统一盖章），
    /// 所以一个号在两个容器里至多命中一次。
    private func locate(seq: UInt) -> (isFront: Bool, segIndex: Int)? {
        guard seq > 0 else { return nil }
        func segIndex(in list: [PlaybackSegment]) -> Int? {
            list.firstIndex { $0.pages.contains { p in p.blocks.contains { $0.seq == seq } } }
        }
        if let i = segIndex(in: front) { return (true, i) }
        if let i = segIndex(in: segments) { return (false, i) }
        return nil
    }

    // MARK: - 起点（过程干预只许看这两个 getter）

    /// 第一个**有内容**的段在容器里的下标；没有则 nil。
    ///
    /// **判据是「有没有内容」，不是「有没有未播」。** 一段的内容播完了（块都过了游标）
    /// 仍在容器里、尾音还在设备上响——那正是用户耳朵里那一摞。改用「未播」会在预取把
    /// 游标送过边界的那一刻把起点推到下一摞（2026-10-17 18:52 实测事故的形状）。
    /// 反过来，**一块内容都没有的段**（已声明、字还没到的挂起摞）不算起点，跳过它。
    private func firstContentIndex(in list: [PlaybackSegment]) -> Int? {
        list.firstIndex { !$0.isEmpty }
    }

    /// 段内第一个有内容的页下标。
    private func firstContentPageIndex(in seg: PlaybackSegment) -> Int? {
        seg.pages.firstIndex { !$0.blocks.isEmpty }
    }

    /// **用户此刻正在听的摞**。
    ///
    /// 先看发声点（准确，2026-10-17 引入）；发声点还没有记录时退回**队首**——
    /// 用户还没听到任何声音，即将播的那个就是他要听的。
    /// 加急段（Cmd+D 译文）排在 `front`、先播，所以无发声记录时它优先。
    ///
    /// - Returns: `nil` = 容器里没有任何内容（队列真空 / 设备播空），此时过程干预退化成「只掐不掀」。
    func headStackTarget() -> (isFront: Bool, index: Int, id: String?)? {
        if let a = audibleStackTarget() { return (a.isFront, a.index, a.id) }
        if let i = firstContentIndex(in: front) { return (true, i, front[i].id) }
        if let i = firstContentIndex(in: segments) { return (false, i, segments[i].id) }
        return nil
    }

    /// **用户此刻正在听的页号**（诊断用，只读）。与 `headStackTarget` 同源：发声点优先，缺则队首。
    /// - Returns: 外层 `nil` = 没有任何内容在播；内层 `nil` = 这一页没有页号（非 Claude 路径的匿名页）。
    var headPageID: String?? {
        if let p = audiblePageTarget() { return .some(p.id) }
        guard let head = headStackTarget(),
              let j = firstContentPageIndex(in: (head.isFront ? front : segments)[head.index])
        else { return nil }
        return .some((head.isFront ? front : segments)[head.index].pages[j].id)
    }



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
        let src = jobs[0].source
        noteSource(src)
        if let idx = segments.firstIndex(where: { $0.id == group }) {
            segments[idx].pages.append(contentsOf: pages(from: jobs))
            // 又来货了：揭掉空闲宽限封的印（宽限只是猜「说完了」，不是判死）
            segments[idx].sealed = false
        } else {
            segments.append(PlaybackSegment(id: group, source: src, sealed: false, pages: pages(from: jobs)))
        }
        signal()
        return true
    }

    /// 无分组的普通播报（`ivox speak` / hook 终稿 / Cmd+D 译文）：并入队尾的无分组段。
    /// 无分组段天生收尾（没有「还在生成」这回事），因此 `sealed: true`。
    @discardableResult
    func appendPlain(_ jobs: [PlaybackBlock]) -> Bool {
        guard !jobs.isEmpty else { return false }
        let src = jobs[0].source
        noteSource(src)
        if let last = segments.last, last.id == nil {
            segments[segments.count - 1].pages.append(contentsOf: pages(from: jobs))
        } else {
            segments.append(PlaybackSegment(id: nil, source: src, sealed: true, pages: pages(from: jobs)))
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
    func beginTurn(_ id: String, source: String) -> Bool {
        guard !deadTurns.contains(id) else { return false }
        if !turnStack.contains(where: { $0.id == id }) { turnStack.append((source, id)) }
        noteSource(source)
        signal()
        return true
    }

    /// 记下「谁刚说了话」。三个入队入口 + 轮登记都走它，是插入队列对外面唯一的可观测输出。
    private func noteSource(_ source: String) {
        lastActiveSource = source
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
        let dropped = sweepSegments(matching: id, in: &segments) + sweepSegments(matching: id, in: &front)
        bury(id)
        if let i = turnStack.lastIndex(where: { $0.id == id }) { turnStack.remove(at: i) }
        signal()
        return dropped > 0
    }

    /// 掀摞（Ctrl+1）：丢掉**用户此刻正在听的这一摞**，从下一摞接着播。
    ///
    /// 起点取「容器里第一个还有未播块的段」——纯结构事实，**不问消费进度**。
    /// 顺手把它前面那些「已播完、一块没剩」的段清掉：它们从没被用户作废，**不立墓碑**，
    /// 纯粹是历史垃圾（`segments` 只增不减，不清就会越堆越多）。
    ///
    /// 幂等性是这套结构自带的：按第二次时队首已经换成下一摞，天然落在「听下一摞」上。
    ///
    /// **领取即摘走，这是本方法存在的全部理由。** 旧实现把「找起点」和「删内容」合在一步、
    /// 且那一步排在 `await` 之后——掐在播要等旧管道退净，而那期间旧管道会 commit 掉
    /// 正在响的最后一块、游标一越过边界，「当前摞」就从 A 变成 B，于是掀掉了用户想听的 B
    /// （2026-10-17 18:52 实测现场：掀的是 B、A 留在容器里两秒后被宽限盖印）。
    /// 把摘走放在**掐之前**，起点从此不可能再被游标带偏；连按也天然正确——第二次按压时
    /// 队首已经是下一摞。旧实现那套「领走即焚 + 占位防重入」由此不再需要。
    ///
    /// - Returns: (被立墓碑的摞号，nil = 无分组普通播报, 丢掉的块数)。`nil` = 当时没有内容在播。
    @discardableResult
    func takeHeadStack() -> (id: String?, dropped: Int)? {
        guard let head = headStackTarget() else { return nil }
        let dropped = (head.isFront ? front : segments)[head.index].blockCount
        // **删除不 signal**：signal 的含义是「新内容来了，宽限不必再等」。掀是在**删**内容——
        // 发了 signal 会把宽限计时器唤醒，让它误判「来新货了、别盖印」，宽限就此作废而没有
        // 接班人，这一摞永远收不掉（2026-10-17 `P3` 实测，同一毫秒内自唤醒）。
        //
        // 顺手把它前面那些「已播完、一块没剩」的段一并清掉：它们从没被用户作废，
        // **不立墓碑**，纯粹是历史垃圾（`segments` 只增不减，不清就会越堆越多）。
        if head.isFront { front.removeFirst(head.index + 1) }
        else { segments.removeFirst(head.index + 1) }
        // 只给正在听的那摞立墓碑：它才是用户明确放弃的。
        if let id = head.id { bury(id) }
        return (head.id, dropped)
    }

    /// 掀页（Ctrl+2）：摘走用户此刻正在听的那一页，从下一页接着播。**不立墓碑** ——
    /// 立墓碑是「掀摞才彻底」那一档的语义，两者差别就在这。
    ///
    /// 同样**领取即摘走**（理由见 `takeHeadStack`）。整摞被掀空就连空壳一起清，不留垃圾。
    /// 无页号（`ivox speak` 这类无页来源）退化成匿名页：掀掉的那一页就是它所在的那一段，
    /// 用户不必先想「这个工具有没有页」。
    /// - Returns: (被掀掉的页号，可能为 nil = 匿名页, 丢掉的块数)。`nil` = 当时没有内容在播。
    @discardableResult
    func takeHeadPage() -> (pageID: String?, dropped: Int)? {
        // 起点先看发声点；还没出声过（冷启动）才退回队首的那一页。
        let hit: (isFront: Bool, seg: Int, page: Int)
        if let a = audiblePageTarget() {
            hit = (a.isFront, a.segIndex, a.pageIndex)
        } else if let h = headStackTarget(),
                  let j = firstContentPageIndex(in: (h.isFront ? front : segments)[h.index]) {
            hit = (h.isFront, h.index, j)
        } else {
            return nil
        }
        if hit.isFront {
            let page = front[hit.seg].pages[hit.page]
            front[hit.seg].pages.removeFirst(hit.page + 1)
            if front[hit.seg].isEmpty { front.remove(at: hit.seg) }
            return (page.id, page.blocks.count)
        }
        let page = segments[hit.seg].pages[hit.page]
        segments[hit.seg].pages.removeFirst(hit.page + 1)
        if segments[hit.seg].isEmpty { segments.remove(at: hit.seg) }
        return (page.id, page.blocks.count)
    }

    /// 把符合条件的段整段删掉，返回删掉的块数。
    private func sweepSegments(matching id: String, in list: inout [PlaybackSegment]) -> Int {
        let dropped = list.filter { $0.id == id }.reduce(0) { $0 + $1.blockCount }
        list.removeAll { $0.id == id }
        return dropped
    }

    /// 回收队首那些「已经听完、也不会再来内容」的段，返回清掉的段数。**不立墓碑** ——
    /// 用户没放弃它们，只是听完了；后续若还有页来，`appendGrouped` 会重新开段照播。
    ///
    /// **为什么必须清**（2026-10-17 引入发声点时发现）：容器原先只增不减，播完的摞一直留着，
    /// 酿成两个后果——
    /// ① `/health` 的 `audibleTurn` 在播完之后还报着一个早就不响的摞，等于对外撒谎；
    /// ② **更要命**——播完后用户按 Ctrl+1，起点会落在那个早已播完的摞上，于是给它立墓碑；
    /// 而 Claude 那一摞往往**还在继续送页**（一次输入 = 好几页），墓碑一立，后续页全被静默丢弃。
    /// 每次泵顺手清一次，`segments` 才不会既虚胖又误导起点。
    ///
    /// - Parameter afterSilence: 调用方已确认**设备真静音**（`播报收尾` 那条路径，
    ///   它前面跑过 `waitUntilQuiet`）。这时连「正在响」的块也已经响完了，可以连它一起清——
    ///   发声点本身永远停在最后一块上（没有下一块来推进它），不给这条后门，`/health` 就会一直撒谎。
    @discardableResult
    func retireSpentSegments(afterSilence: Bool = false) -> Int {
        func takeSpent(_ list: inout [PlaybackSegment]) -> Int {
            var n = 0
            while let first = list.first, first.sealed {
                let maxSeq = first.pages.flatMap({ $0.blocks }).map(\.seq).max() ?? 0
                // 严格小于：正在响的那一块（maxSeq == 发声点）还没响完，不能清。
                guard afterSilence || maxSeq < audibleSeq else { break }
                list.removeFirst(); n += 1
            }
            return n
        }
        return takeSpent(&front) + takeSpent(&segments)
    }

    /// 全掀：清空容器，所有摞立墓碑。
    @discardableResult
    /// 全掀（Ctrl+Esc）：**清容器是全体，立墓碑只给属主**。
    ///
    /// **清全体**——谁在念都得停，这不伤人。
    ///
    /// **碑只埋属主**（`lastActiveSource`，最近有块入队的那个来源）：Ctrl+Esc 是全局热键，
    /// 拿不到「当前会话」是谁；按属主埋是替身——你喊闭嘴时，刚在说话的多半就是你正在看的那个
    /// 工具。此前不分来源一刀切，你在 Claude 里喊闭嘴会把 **Codex 正在生成的那摞**一起埋掉，
    /// 它随后送来的字全被丢弃、从此不再开口（这与「两会话并行、互不误杀」的场景 8 直接冲突）。
    ///
    /// **turnStack 里的轮同样按属主挑**：它们是「已声明、块还没到」的轮，此刻容器里还没有对应的段，
    /// 只按段立碑就会漏掉它们——打断之后它们陆续送来的字会照常播出来
    ///（2026-10-17 `E7` 实测：清空队列时 pending=0，墓碑一个没立，打断后同一轮照样开口）。
    func discardAll() -> [String] {
        let owner = lastActiveSource
        var ids = turnStack.filter { $0.source == owner }.map(\.id)
        ids += segments.filter { $0.source == owner }.compactMap(\.id)
        ids += front.filter { $0.source == owner }.compactMap(\.id)
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
        noteSource(jobs[0].source)
        front.insert(PlaybackSegment(id: nil, source: jobs[0].source, sealed: true,
                                     pages: pages(from: jobs)), at: 0)
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
}
