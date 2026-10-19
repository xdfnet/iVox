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
    /// **助理自编的块号**，全局单调，永不复用。游标、音频顺序、报备都用它。
    let seq: UInt
    let text: String
    let voiceID: String
    /// 属主来源（claude / pi / …）。**只供墓碑分范围**（`discardAll` 要按属主立墓碑），
    /// 不参与任何身份判断——块的身份只有 `seq`。
    let source: String
}

/// 一页 = 一条 assistant 消息（一次回复）。
struct PlaybackPage: Sendable {
    /// **资料室自编的页号**，永远有值。与 `PlaybackSegment.localID` 同一个道理：
    /// 身份是容器自己的事，不由外部决定（2026-10-18）。外部 page_id 只当「这两块是不是同一页」的线索。
    let localID: Int
    /// 外部页号（`message_id`）。**只用来判断「同一批里相邻的块是否属于同一页」**，
    /// 不作为页的身份，也不出现在日志里（无外部页号时照样能报「第 N 摞第 M 页」）。
    let externalID: String?
    var blocks: [PlaybackBlock]
}

/// 一段 = 一摞（一次回复引发的全部内容，`turn_id` 为 nil = 无分组的普通播报）。
struct PlaybackSegment: Sendable {
    /// **资料室自编的摞号**，永远有值，自增不复用。**这一摞的身份由它决定，与外部传没传编号无关。**
    ///
    /// 它存在的理由是「资料室有自己的规矩，不依赖外部」（2026-10-18）：
    /// 早先这里只有一个 `id: String?`，一份兼两职——有外部编号时是「turn_id」，
    /// 没有时是 nil。于是「外部没编号」被当成了「这几摞是同一摞」，
    /// `appendPlain` 顺手把无编号的稿全并进队尾那一个段，掀摞一次连后到的一起掀
    /// （18:11 实测：34 块里只有 6 块是新回复）。身份是容器自己的事，不该由外部决定。
    let localID: Int
    /// 外部编号（`turn_id`）。**只管一件事：立墓碑**——「这一摞作废，它后续来的增量别再收」。
    /// 没有就是没有（`ivox speak` 等无编号来源全走这条路），**不影响这摞的身份与掀除**。
    let turnID: String?
    /// 属主来源（claude / pi / …）。**只为 Ctrl+Esc 的墓碑分范围而存在**：
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
    /// 摞号发号器（资料室自编，见 `PlaybackSegment.localID`）。自增不复用，
    /// 日志里直接打「第 N 摞」，事后能对上「当时掀的是哪一摞」。
    private var nextLocalID: Int = 1
    /// 页号发号器（资料室自编，见 `PlaybackPage.localID`）。与摞号分开——
    /// 「第 7 摞第 3 页」两个维度各自单调。
    private var nextPageSeq: Int = 1
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
        segments.filter { !$0.sealed }.compactMap(\.turnID) + front.filter { !$0.sealed }.compactMap(\.turnID)
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
    private func audibleStackTarget() -> (isFront: Bool, index: Int, turnID: String?)? {
        guard let hit = locate(seq: audibleSeq) else { return nil }
        return (hit.isFront, hit.segIndex, (hit.isFront ? front : segments)[hit.segIndex].turnID)
    }

    /// 发声点所在的页（页号由资料室自编，永远有值）。
    private func audiblePageTarget() -> (isFront: Bool, segIndex: Int, pageIndex: Int, pageNo: Int)? {
        guard let hit = locate(seq: audibleSeq) else { return nil }
        let list = hit.isFront ? front : segments
        guard let j = list[hit.segIndex].pages.firstIndex(where: { $0.blocks.contains { $0.seq == audibleSeq } })
        else { return nil }
        return (hit.isFront, hit.segIndex, j, list[hit.segIndex].pages[j].localID)
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
    func headStackTarget() -> (isFront: Bool, index: Int, turnID: String?)? {
        if let a = audibleStackTarget() { return (a.isFront, a.index, a.turnID) }
        if let i = firstContentIndex(in: front) { return (true, i, front[i].turnID) }
        if let i = firstContentIndex(in: segments) { return (false, i, segments[i].turnID) }
        return nil
    }

    /// **用户此刻正在听的页号**（诊断用，只读）。与 `headStackTarget` 同源：发声点优先，缺则队首。
    /// 页号由资料室自编，所以永远有值——早先这里返回 `String??`，外层 nil 是「没在播」、
    /// 内层 nil 是「这页是匿名页」，后半个状态是外部不传 page_id 造成的，已随页号自编消失。
    /// - Returns: `nil` = 没有任何内容在播。
    var headPageNo: Int? {
        if let p = audiblePageTarget() { return p.pageNo }
        guard let head = headStackTarget(),
              let j = firstContentPageIndex(in: (head.isFront ? front : segments)[head.index])
        else { return nil }
        return (head.isFront ? front : segments)[head.index].pages[j].localID
    }



    // MARK: - 入队

    /// 开一摞并返回**助理自编的摞号**。这一批材料自成一页。
    ///
    /// `note` 是端给的原摞号（Claude 的 `turn_id` / pi 的 `turn`）、`pageNote` 是端给的
    /// 原页号（`message_id`），**都只作备注**：落进日志供事后对照，供墓碑回答
    /// 「这个外部号还能不能再进来」，但**不参与任何身份判断**——这一摞是谁、
    /// 这一页是谁，都由助理发的号说了算。块上更不留任何外部编号（见 `PlaybackBlock`）。
    ///
    /// 调用方（跑腿侧的衔接层）自己记住「外部号 ↔ 这个摞号」的对照，后续同摞的续批
    /// 拿摞号来调 `appendToStack`。**助理不持有「按外部号检索容器」的能力**——
    /// 那个能力一旦存在，就会被人拿来写分组判断，`appendPlain` 把无编号内容焊成一摞
    /// 就是这么来的（2026-10-18 现场：掀一次 34 块，其中只有 6 块是新回复）。
    func newStack(_ jobs: [PlaybackBlock], note: String?, pageNote: String? = nil) -> Int? {
        guard !jobs.isEmpty else { return nil }
        // 墓碑仍然按外部号拒：增量就是拿外部号来的，问的是「这个号还能不能再来」，
        // 不是「这是哪一摞」。前者按外部号查是对的，后者必须自编号。
        if let note, deadTurns.contains(note) {
            Log.debug("丢弃：turn=\(note) 那一摞已被盖上")
            return nil
        }
        let fresh = newPage(jobs, pageNote: pageNote)
        let seg = makeSegment(turnID: note, source: jobs[0].source, sealed: false, pages: fresh)
        segments.append(seg)
        lastFiling = SegmentFiling(stack: seg.localID, turnID: note, pages: fresh.map(\.localID))
        noteSource(jobs[0].source)
        signal()
        return seg.localID
    }

    /// 一次续批投递的结果。**三态不可合并**：
    /// `appended` 正常并入；`dead` 是墓碑命中（用户已放弃这一摞，增量必须丢弃）；
    /// `gone` 是摞号失效（被回收——**该另开一摞**）。
    /// 把 `dead` 当 `gone` 处理会让「Ctrl+1 掀掉的那摞，它后续的增量又播出来」，
    /// 墓碑就白立了（2026-10-18 改三态时才发现的坑）。
    enum StackAccept: Equatable {
        case appended
        case dead
        case gone
    }

    /// 把续批并进**助理自己发的**摞号 `stack`。
    ///
    /// 这一批算「同一页」还是「新一页」，看 `pageNote` 与该摞最后一页的外部号是否一致
    /// ——那是端送来时的线索，助理只照着归拢，不自己猜。**`pageNote` 为 nil 时一律新页**：
    /// 没有线索就不合并，宁可多切一页也不要把两批焊在一起（与 `appendPlain` 同一条原则）。
    @discardableResult
    func appendToStack(_ stack: Int, _ jobs: [PlaybackBlock],
                       note: String?, pageNote: String? = nil) -> StackAccept {
        guard !jobs.isEmpty else { return .appended }
        if let note, deadTurns.contains(note) {
            Log.debug("丢弃：turn=\(note) 那一摞已被盖上")
            return .dead
        }
        guard let hit = segmentIndex(localID: stack) else {
            Log.debug("第\(stack)摞已不在（被回收），外部号=\(note ?? "-")")
            return .gone
        }
        let blocks = stamp(jobs)
        let joined = (hit.isFront ? front : segments)[hit.index].pages
        let lastPage = joined.last
        // 数组元素是值类型，改完必须写回原坐标。
        if let pageNote, let lastPage, lastPage.externalID == pageNote {
            var merged = lastPage
            merged.blocks.append(contentsOf: blocks)
            if hit.isFront {
                front[hit.index].pages[front[hit.index].pages.count - 1] = merged
                front[hit.index].sealed = false
            } else {
                segments[hit.index].pages[segments[hit.index].pages.count - 1] = merged
                // 又来货了：揭掉空闲宽限封的印（宽限只是猜「说完了」，不是判死）
                segments[hit.index].sealed = false
            }
            lastFiling = SegmentFiling(stack: stack, turnID: note, pages: [merged.localID])
        } else {
            let page = PlaybackPage(localID: nextPageLocalID(), externalID: pageNote, blocks: blocks)
            if hit.isFront {
                front[hit.index].pages.append(page)
                front[hit.index].sealed = false
            } else {
                segments[hit.index].pages.append(page)
                segments[hit.index].sealed = false
            }
            lastFiling = SegmentFiling(stack: stack, turnID: note, pages: [page.localID])
        }
        noteSource(jobs[0].source)
        signal()
        return .appended
    }

    /// 按助理自编的摞号定位段——**这是助理唯一允许的段查找方式**。
    /// 加急段（Cmd+D 译文）与普通段共用同一个号空间。
    private func segmentIndex(localID: Int) -> (isFront: Bool, index: Int)? {
        if let i = front.firstIndex(where: { $0.localID == localID }) { return (true, i) }
        if let i = segments.firstIndex(where: { $0.localID == localID }) { return (false, i) }
        return nil
    }

    /// 无分组的普通播报（`ivox speak` / hook 终稿）：**每次入队自成一段**。
    ///
    /// 「自成一段」不是随手定的，是外部编号缺席时资料室自己的规矩：`appendGrouped`
    /// 靠 turn_id 把同一摞的续页并进同一段，无编号时没有那把钥匙，**就不能靠它分组**，
    /// 否则就只能把所有无编号的稿子视作一摞——Ctrl+1 的契约「掀这一摞、下一摞留着」
    /// 于是作废（2026-10-18 18:11 实测：一条长回复的 28 块与新回复的 6 块被焊成一摞，
    /// 掀一次 34 块全丢，只 6 块是你想听的）。
    ///
    /// 无分组段天生收尾（没有「还在生成」这回事），因此 `sealed: true`。
    /// 入队方每次都送完整一段（`enqueue(_:turnID: nil)` 只有一次性请求会走），不会把一句切碎。
    @discardableResult
    func appendPlain(_ jobs: [PlaybackBlock]) -> Int? {
        guard !jobs.isEmpty else { return nil }
        let src = jobs[0].source
        noteSource(src)
        let fresh = newPage(jobs, pageNote: nil)
        let seg = makeSegment(turnID: nil, source: src, sealed: true, pages: fresh)
        segments.append(seg)
        lastFiling = SegmentFiling(stack: seg.localID, turnID: nil, pages: fresh.map(\.localID))
        signal()
        return seg.localID
    }

    /// 资料室给刚收下这批稿的**报备**：摞号 + 这次落在哪几页。
    /// 播报员（`PlaybackQueue`）在入队日志里逐字打出来，于是「哪块属于哪一摞哪一页」
    /// 从收下那一刻就落进日志——掀的时候不必再推断，翻日志即可对上
    /// （2026-10-18：掀摞那行以前只能打「无分组 块=34」，事后根本看不出掀的是哪一摞）。
    struct SegmentFiling {
        let stack: Int
        let turnID: String?
        /// 本次新增的页号（闭区间说法，见 `pageRangeText`）。空 = 并进了已有段、没有新页。
        let pages: [Int]
    }

    /// 刚落下的这批稿的报备；下一次入队覆盖它。actor 隔离保证读到的就是最近一次入队的编号。
    var lastFiling: SegmentFiling?

    /// 给一批块盖章块号。**块的身份只有这个 `seq`**——外部编号一律不进块。
    private func stamp(_ jobs: [PlaybackBlock]) -> [PlaybackBlock] {
        jobs.map { job in
            defer { nextSeq += 1 }
            return PlaybackBlock(seq: nextSeq, text: job.text, voiceID: job.voiceID, source: job.source)
        }
    }

    /// 整批盖成一页（新页）。
    private func newPage(_ jobs: [PlaybackBlock], pageNote: String?) -> [PlaybackPage] {
        [PlaybackPage(localID: nextPageLocalID(), externalID: pageNote, blocks: stamp(jobs))]
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

    /// 这一摞说完了（Stop 钩子 / `{end}`）：盖印 + **立墓碑**。
    /// Stop 之后不会有新增量（Claude 已回复完毕），墓碑只拦「后续不该再来的增量」，
    /// 不丢在播的块（墓碑命中的是入口的 `appendToStack`/`appendPlain`，跟当前播放无关）。
    @discardableResult
    func sealTurn(_ id: String) -> Bool {
        var hit = false
        for i in segments.indices where segments[i].turnID == id {
            segments[i].sealed = true; hit = true
        }
        for i in front.indices where front[i].turnID == id {
            front[i].sealed = true; hit = true
        }
        if hit { bury(id) }
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
    /// - Returns: (资料室自编的摞号，外部 turn_id（仅用于日志对照，无分组为 nil）, 丢掉的块数)。`nil` = 当时没有内容在播。
    @discardableResult
    func takeHeadStack() -> (localID: Int, turnID: String?, dropped: Int)? {
        guard let head = headStackTarget() else { return nil }
        let seg = (head.isFront ? front : segments)[head.index]
        let dropped = seg.blockCount
        // **删除不 signal**：signal 的含义是「新内容来了，宽限不必再等」。掀是在**删**内容——
        // 发了 signal 会把宽限计时器唤醒，让它误判「来新货了、别盖印」，宽限就此作废而没有
        // 接班人，这一摞永远收不掉（2026-10-17 `P3` 实测，同一毫秒内自唤醒）。
        //
        // 顺手把它前面那些「已播完、一块没剩」的段一并清掉：它们从没被用户作废，
        // **不立墓碑**，纯粹是历史垃圾（`segments` 只增不减，不清就会越堆越多）。
        if head.isFront { front.removeFirst(head.index + 1) }
        else { segments.removeFirst(head.index + 1) }
        // 只给正在听的那摞立墓碑：它才是用户明确放弃的。**只有外部 turn_id 能立墓碑**——
        // 无编号的稿子一次性送完、不会再有后续增量，没东西可拦。
        if let id = head.turnID { bury(id) }
        return (seg.localID, seg.turnID, dropped)
    }

    /// 掀页（Ctrl+2）：摘走用户此刻正在听的那一页，从下一页接着播。**不立墓碑** ——
    /// 立墓碑是「掀摞才彻底」那一档的语义，两者差别就在这。
    ///
    /// 同样**领取即摘走**（理由见 `takeHeadStack`）。整摞被掀空就连空壳一起清，不留垃圾。
    /// 页号由资料室自编，所以「无外部页号的来源」（`ivox speak` 这类）照样有页可掀——
    /// 用户不必先想「这个工具有没有页」。
    /// - Returns: (被掀掉的页号，丢掉的块数)。`nil` = 当时没有内容在播。
    @discardableResult
    func takeHeadPage() -> (pageNo: Int, dropped: Int)? {
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
            return (page.localID, page.blocks.count)
        }
        let page = segments[hit.seg].pages[hit.page]
        segments[hit.seg].pages.removeFirst(hit.page + 1)
        if segments[hit.seg].isEmpty { segments.remove(at: hit.seg) }
        return (page.localID, page.blocks.count)
    }

    /// 把符合条件的段整段删掉，返回删掉的块数。
    private func sweepSegments(matching id: String, in list: inout [PlaybackSegment]) -> Int {
        let dropped = list.filter { $0.turnID == id }.reduce(0) { $0 + $1.blockCount }
        list.removeAll { $0.turnID == id }
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
        ids += segments.filter { $0.source == owner }.compactMap(\.turnID)
        ids += front.filter { $0.source == owner }.compactMap(\.turnID)
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
        let seg = makeSegment(turnID: nil, source: jobs[0].source, sealed: true,
                              pages: newPage(jobs, pageNote: nil))
        front.insert(seg, at: 0)
        lastFiling = SegmentFiling(stack: seg.localID, turnID: nil, pages: seg.pages.map(\.localID))
        signal()
        return true
    }

    /// 建一段并从资料室的发号器取号——**任何段都不许绕过它**，
    /// 否则自编号会重号，日志里的「第 N 摞」就对不上人了。
    /// 页由调用方先盖章好传进来（块号页号都是发出来的，算两遍就重了）。
    private func makeSegment(turnID: String?, source: String?, sealed: Bool,
                             pages: [PlaybackPage]) -> PlaybackSegment {
        defer { nextLocalID += 1 }
        return PlaybackSegment(localID: nextLocalID, turnID: turnID,
                               source: source, sealed: sealed, pages: pages)
    }

    /// 页号也走自己的发号器（外部 page_id 只当「同页线索」，不当身份）。
    private func nextPageLocalID() -> Int {
        defer { nextPageSeq += 1 }
        return nextPageSeq
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
