import XCTest
@testable import iVox

// 场景 15 的回归钉子：一摞播到最后一句时用户按 Ctrl+1，掀掉的必须是**这一摞**，
// 不能是队列里下一个还没出声的摞。2026-10-17 18:52 实测翻车现场——用户想听的那一摞
// 被整摞掀掉，且全程毫无察觉。
//
// 这些用例**不碰音频设备、不 sleep**：`PlaybackSession` 是纯 actor，毫秒级跑完，
// 钉的是「起点取自哪里」这个决定本身。
final class PlaybackSessionHeadTests: XCTestCase {

    // MARK: - 夹具

    private func block(_ text: String, page: String?) -> PlaybackBlock {
        PlaybackBlock(seq: 0, text: text, voiceID: "v", source: "test", pageID: page)
    }

    /// 喂若干摞，每摞一页一页地入队（模拟 Claude 按行批）。
    private func seed(_ session: PlaybackSession, stacks: [(id: String, pages: [[String]])]) async {
        for s in stacks {
            for (i, p) in s.pages.enumerated() {
                _ = await session.appendGrouped(p.map { block($0, page: "\(s.id)-p\(i)") },
                                               group: s.id)
            }
        }
    }

    /// 把队列进度向前推 `blocks` 步，模拟预取。
    ///
    /// 传**队首那一摞的块数**即可复现 2026-10-17 18:52 的现场形状：用户听的是 A 的尾音
    /// （尾音还在设备上响），而队列进度已经越过 A —— 旧实现在这一刻取起点，取到的正是 B。
    private func advance(_ session: PlaybackSession, _ blocks: Int) async {
        for _ in 0..<blocks {
            guard let c = await session.nextCursor() else { break }
            await session.commit(c)
        }
    }

    /// 把整个队列的进度推到末尾（更强的预取：后面的摞也都已排进播放器）。
    private func advanceAll(_ session: PlaybackSession) async {
        while let c = await session.nextCursor() {
            await session.commit(c)
        }
    }

    private func headStackID(_ session: PlaybackSession) async -> String? {
        await session.headStackTarget()?.id
    }

    // MARK: - 场景 15 本体

    /// 预取把队列进度送过边界之后按 Ctrl+1，掀的仍是用户正在听的那一摞。
    /// **这一条在修复前会红**——旧实现此刻取起点，取到的是 gB，正是 2026-10-17 18:52 现场。
    func testSkipStackTakesTheStackBeingHeard_NotTheNextOne() async {
        let s = PlaybackSession()
        await seed(s, stacks: [(id: "gA", pages: [["A1", "A2"]]),
                               (id: "gB", pages: [["B1"]]),
                               (id: "gC", pages: [["C1"]])])
        await advance(s, 2)   // 预取越过 gA 的两块；A 的尾音还在设备上响，B 还没被摸

        let taken = await s.takeHeadStack()
        let after = await headStackID(s)

        XCTAssertEqual(taken?.id, "gA", "起点被游标带偏了：用户听的是 gA，掀掉的却是别的摞")
        XCTAssertEqual(after, "gB", "掀完应落在下一摞")
    }

    /// 顺序不变：无论队列进度走到哪，起点恒为队首。进度动一动，答案不许变。
    func testHeadIsIndependentOfSchedulingProgress() async {
        let s = PlaybackSession()
        await seed(s, stacks: [(id: "gA", pages: [["A1", "A2"]]),
                               (id: "gB", pages: [["B1"]])])

        let before = await headStackID(s)
        XCTAssertEqual(before, "gA", "刚入队时起点就该是队首")

        await advance(s, 2)
        let afterBoundary = await headStackID(s)
        XCTAssertEqual(afterBoundary, "gA", "预取越过边界后起点变了 —— 这就是今天翻车的那一步")

        await advance(s, 5)   // 进度推到末尾，起点仍不许变
        let afterAll = await headStackID(s)
        XCTAssertEqual(afterAll, "gA", "进度推到哪都不该改变起点")

        let taken = await s.takeHeadStack()
        let next = await headStackID(s)
        XCTAssertEqual(taken?.id, "gA")
        XCTAssertEqual(next, "gB")
    }

    /// 连按 = 连着往下听：第二次按压落在下一摞上，不需要任何防重入机制。
    func testConsecutiveSkipWalksDownTheQueue() async {
        let s = PlaybackSession()
        await seed(s, stacks: [(id: "gA", pages: [["A1"]]),
                               (id: "gB", pages: [["B1"]]),
                               (id: "gC", pages: [["C1"]])])
        await advanceAll(s)

        let a = await s.takeHeadStack()?.id
        let b = await s.takeHeadStack()?.id
        let c = await s.takeHeadStack()?.id
        let d = await s.takeHeadStack()
        let head = await headStackID(s)

        XCTAssertEqual(a, "gA"); XCTAssertEqual(b, "gB"); XCTAssertEqual(c, "gC")
        XCTAssertNil(d, "全掀完了不该还有起点")
        XCTAssertNil(head)
    }

    /// 队首那摞「已声明、字还没到」（容器里一块都没有）时，起点跳过它——
    /// 用户耳朵里是空的，没有正在听的摞可掀。
    func testSkipPastAnEmptyDeclaredStack() async {
        let s = PlaybackSession()
        _ = await s.beginTurn("gEmpty")                 // 已声明，未到块
        await seed(s, stacks: [(id: "gB", pages: [["B1"]])])
        await advanceAll(s)

        let taken = await s.takeHeadStack()?.id
        XCTAssertEqual(taken, "gB", "空摞不是「正在听的那摞」，该跳过")
    }

    /// 掀摞要立墓碑：它后续送来的增量不得再开口。
    func testSkippedStackIsBuried() async {
        let s = PlaybackSession()
        await seed(s, stacks: [(id: "gA", pages: [["A1"]]), (id: "gB", pages: [["B1"]])])
        _ = await s.takeHeadStack()
        let late = await s.appendGrouped([block("A2", page: "gA-p0")], group: "gA")
        XCTAssertFalse(late, "被掀的摞，其后续增量不该再入队")
    }

    /// 没被用户放弃的摞，它的后续增量必须仍能入队（防止顺手清理时误伤）。
    func testUntouchedStackKeepsAcceptingContent() async {
        let s = PlaybackSession()
        await seed(s, stacks: [(id: "gA", pages: [["A1"]]), (id: "gB", pages: [["B1"]])])
        await advanceAll(s)
        _ = await s.takeHeadStack()                    // 掀 gA
        let ok = await s.appendGrouped([block("B2", page: "gB-p1")], group: "gB")
        XCTAssertTrue(ok, "gB 没被用户掀过，它的后续增量必须能入队")
    }

    // MARK: - 掀页：同一套设计

    /// 页级起点由**发声点**给出，段级不再够用：一页播完后它的内容仍留在容器里没人删，
    /// 所以「第一个有内容的页」永远落在**已播完**的那一页上。
    /// 这里 pgA1 已播完、pgA2 正在响（块 3 已发出声），按 Ctrl+2 必须掀 pgA2。
    ///
    /// **这一条在引入发声点之前会红**——那时的实现取到的是 pgA1。
    func testSkipPageTakesThePageBeingHeard() async {
        let s = PlaybackSession()
        for i in 1...3 {
            _ = await s.appendGrouped([block("A\(i)", page: "pgA\(i)")], group: "gA")
        }
        _ = await s.appendGrouped([block("B1", page: "pgB1")], group: "gB")
        await advance(s, 2)          // pgA1 已播完，pgA2、pgA3 已排进播放器
        await s.noteConsumed(2)      // 块 2 正在被渲染 ⇒ 用户此刻在听 pgA2

        let taken = await s.takeHeadPage()
        let nowHead = await s.headPageID

        XCTAssertEqual(taken?.pageID, "pgA2", "掀的必须是用户正在听的那一页")
        XCTAssertEqual(nowHead, .some("pgA3"), "掀完自然落到下一页")
    }

    /// 发声点对段级同样生效：进度被预取推到下一摞末尾也不改变起点。
    /// 队首方案在段级本来就成立（顺序推进 → 正在听的必是第一个有内容的段），
    /// 发声点只是把「碰巧成立」变成「有据可依」，两条路答案必须一致。
    func testAudiblePointAndQueueHeadAgreeOnStack() async {
        let s = PlaybackSession()
        await seed(s, stacks: [(id: "gA", pages: [["A1", "A2", "A3"]]),
                               (id: "gB", pages: [["B1"]])])
        await advanceAll(s)
        await s.noteConsumed(3)      // 用户在听块 2，仍在 gA

        let head = await headStackID(s)
        let taken = await s.takeHeadStack()?.id
        XCTAssertEqual(head, "gA")
        XCTAssertEqual(taken, "gA", "进度推到末尾也不能把起点带偏")
    }

    /// 发声点就是「正在响的那一块」，不落后也不超前。
    ///
    /// 这条钉的是 `dataConsumed` 的语义：它在 buffer **开始被渲染**时回调（仓库里字幕
    /// `onSentenceStarted` 早就这么用，从没被判过字幕延迟）。若实现改成落后一号，
    /// 页级就会掀错一页 —— 块与页一一对应，差一号就是差一页。
    func testAudiblePointIsTheSoundingBlockItself() async {
        let s = PlaybackSession()
        for i in 1...3 {
            _ = await s.appendGrouped([block("A\(i)", page: "pgA\(i)")], group: "gA")
        }
        let beforeAnySound = await s.headPageID
        XCTAssertEqual(beforeAnySound, .some("pgA1"), "还没出声时退回队首")

        await s.noteConsumed(1)
        let atA1 = await s.headPageID
        XCTAssertEqual(atA1, .some("pgA1"), "块 1 在响 ⇒ 起点就是 pgA1")

        await s.noteConsumed(3)
        let atA3 = await s.headPageID
        XCTAssertEqual(atA3, .some("pgA3"), "块 3 在响 ⇒ 起点就是 pgA3，不许落后也不许超前")
    }

    /// 连按翻页 = 连着往下听。
    func testConsecutiveSkipPageWalksDown() async {
        let s = PlaybackSession()
        for i in 1...3 {
            _ = await s.appendGrouped([block("A\(i)", page: "pgA\(i)")], group: "gA")
        }
        let a = await s.takeHeadPage()?.pageID
        let b = await s.takeHeadPage()?.pageID
        let c = await s.takeHeadPage()?.pageID
        let d = await s.takeHeadPage()
        XCTAssertEqual(a, "pgA1"); XCTAssertEqual(b, "pgA2"); XCTAssertEqual(c, "pgA3")
        XCTAssertNil(d)
    }

    /// 掀页**不立墓碑**——这是它与掀摞唯一的语义差别：还没来的页等它来了照样播
    /// （需求层「能力边界」：掀页只能掀已经出现的那一页）。
    func testSkipPageDoesNotBuryStack() async {
        let s = PlaybackSession()
        _ = await s.appendGrouped([block("A1", page: "pgA1")], group: "gA")
        _ = await s.appendGrouped([block("A2", page: "pgA2")], group: "gA")
        _ = await s.takeHeadPage()
        let later = await s.appendGrouped([block("A3", page: "pgA3")], group: "gA")
        XCTAssertTrue(later, "掀页不该作废整摞——同摞后续页仍要能入队")
    }

    /// 无页号来源（`ivox speak` 这类）退化成匿名页：按下去照样掀得掉东西。
    func testSkipPageOnAnonymousSource() async {
        let s = PlaybackSession()
        _ = await s.appendPlain([block("说点什么", page: nil)])
        let taken = await s.takeHeadPage()
        let head = await headStackID(s)
        XCTAssertNil(taken?.pageID, "无页来源就是匿名页")
        XCTAssertEqual(taken?.dropped, 1)
        XCTAssertNil(head)
    }

    /// 加急段（Cmd+D 译文）插在 `front`、先于常规段播，所以它是队首。
    func testFrontInsertedStackIsTheHead() async {
        let s = PlaybackSession()
        await seed(s, stacks: [(id: "gA", pages: [["A1"]])])
        _ = await s.appendFirst([block("译文", page: nil)])   // 加急段
        let taken = await s.takeHeadStack()?.id
        let after = await headStackID(s)
        XCTAssertNil(taken, "队首应是加急段（无分组）")
        XCTAssertEqual(after, "gA", "加急段掀掉后常规摞顶上")
    }

    // MARK: - 容器卫生

    /// 听完且已收尾的段要回收掉，否则打断起点会落在早已播完的摞上——
    /// 那摞往往还在继续送页（Claude 一次输入好几页），一掀就给它立了墓碑，后续页全被静默丢弃。
    /// 这条钉的是「播完之后 `/health` 不再报 audibleTurn」这个对外可见的事实。
    func testSpentAndSealedStacksAreRetired() async {
        let s = PlaybackSession()
        await seed(s, stacks: [(id: "gA", pages: [["A1"]])])
        await advanceAll(s)
        await s.noteConsumed(1)          // A 真的响过了
        _ = await s.sealIdle()           // 盖印 = 不会再有内容

        // 收尾路径已确认设备真静音：正在响的那块也已响完，连它一起清
        let retired = await s.retireSpentSegments(afterSilence: true)
        let head = await headStackID(s)
        let pending = await s.hasPending
        XCTAssertEqual(retired, 1)
        XCTAssertNil(head, "听完又收尾的摞不该还留在容器里当起点")
        XCTAssertFalse(pending)
    }

    /// **没收到尾的摞不许回收**：Claude 那一摞还可能继续送页，现在清了等于把它连内容一起吞掉。
    /// 即便已经确认静音也不清 —— 收尾不等于判死。
    func testUnsealedStackIsNotRetired() async {
        let s = PlaybackSession()
        await seed(s, stacks: [(id: "gA", pages: [["A1"]])])
        await advanceAll(s)
        await s.noteConsumed(1)

        let retired = await s.retireSpentSegments(afterSilence: true)
        let head = await headStackID(s)
        XCTAssertEqual(retired, 0, "还没收到尾，不能清")
        XCTAssertEqual(head, "gA")
    }

    /// 回收**不立墓碑** —— 用户没放弃它，只是听完了；后续页来了要照播。
    func testRetiringDoesNotBuryTheStack() async {
        let s = PlaybackSession()
        await seed(s, stacks: [(id: "gA", pages: [["A1"]])])
        await advanceAll(s)
        await s.noteConsumed(1)
        _ = await s.sealIdle()
        _ = await s.retireSpentSegments(afterSilence: true)

        let later = await s.appendGrouped([block("A2", page: "gA-p1")], group: "gA")
        let head = await headStackID(s)
        XCTAssertTrue(later, "回收只是清容器，不是判死——后续页必须还能入队")
        XCTAssertEqual(head, "gA")
    }

    /// 判据必须看**发声点**，不看队列进度：刚排进播放器、声音还没响的段不许清。
    func testRetiringWaitsForTheSoundNotForTheSchedule() async {
        let s = PlaybackSession()
        await seed(s, stacks: [(id: "gA", pages: [["A1", "A2"]]),
                               (id: "gB", pages: [["B1"]])])
        await advanceAll(s)              // 三块都排进了播放器
        await s.noteConsumed(3)          // 块 3 在响 ⇒ A 早已响完，B 正在响
        _ = await s.sealTurn("gA")
        _ = await s.sealTurn("gB")

        let retired = await s.retireSpentSegments()
        let head = await headStackID(s)
        XCTAssertEqual(retired, 1, "只该清 A")
        XCTAssertEqual(head, "gB", "B 正在响，它仍是起点")
    }

    /// **正在响的那一块不许清**：它 maxSeq 恰等于发声点，清了就等于把还在响的内容从容器里抹掉。
    func testCurrentlySoundingSegmentIsNotRetired() async {
        let s = PlaybackSession()
        await seed(s, stacks: [(id: "gA", pages: [["A1"]])])
        await advanceAll(s)
        await s.noteConsumed(1)
        _ = await s.sealTurn("gA")

        let retired = await s.retireSpentSegments()
        let head = await headStackID(s)
        XCTAssertEqual(retired, 0, "正在响的块还没响完")
        XCTAssertEqual(head, "gA")
    }

    /// 掀摞顺手清掉队首之前那些已播空的段：`segments` 只增不减，不清就永远堆着。
    func testEmptiedStacksAheadOfHeadAreCleanedUp() async {
        let s = PlaybackSession()
        await seed(s, stacks: [(id: "gA", pages: [["A1"]]),
                               (id: "gB", pages: [["B1"]])])
        await advanceAll(s)
        _ = await s.takeHeadStack()          // 掀 gA
        await seed(s, stacks: [(id: "gC", pages: [["C1"]])])
        await advanceAll(s)
        _ = await s.takeHeadStack()          // 掀 gB
        _ = await s.takeHeadStack()          // 掀 gC
        let head = await headStackID(s)
        let pending = await s.hasPending
        XCTAssertNil(head, "容器应已被清空")
        XCTAssertFalse(pending)
    }
}
