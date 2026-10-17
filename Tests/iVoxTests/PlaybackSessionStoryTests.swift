import XCTest
@testable import iVox

// 播报故事（`docs/playback/paper.md`）的验收钉子。**每个 MARK 对应验收清单里的一条问句**，
// 每条用例的注释第一行是那句问句本身——故事是基线，用例照着基线写，不是照着实现写。
//
// 本文件只钉**容器**这一层：起点取自哪里、纸按什么顺序被念、谁有资格插队、
// 喊闭嘴时埋谁的牌、听完了收不收桌。`PlaybackSession` 是纯 actor，毫秒级跑完，不碰音频设备。
//
// 清单里另外几条钉在别处，原因如实记在文件末尾的对照表里。
final class PlaybackSessionStoryTests: XCTestCase {

    // MARK: - 夹具

    private func block(_ text: String, page: String?, source: String = "claude") -> PlaybackBlock {
        PlaybackBlock(seq: 0, text: text, voiceID: "v", source: source, pageID: page)
    }

    /// 喂若干摞，每摞一页一页地入队（模拟 Claude 按行批：一个 turn 底下好几页）。
    private func seed(_ session: PlaybackSession, stacks: [(id: String, pages: [[String]])]) async {
        for st in stacks {
            for (i, p) in st.pages.enumerated() {
                _ = await session.appendGrouped(p.map { block($0, page: "\(st.id)-p\(i)") },
                                               group: st.id)
            }
        }
    }

    /// 把队列进度向前推 `blocks` 步，模拟播报员**提前备好**后面几条。
    ///
    /// 故事里这个「作弊」是合法的：备好不影响起点。但它会让「队首」不再等于「正在听」，
    /// 所以凡是验起点的用例都得先备好一段。
    private func advance(_ session: PlaybackSession, _ blocks: Int) async {
        for _ in 0..<blocks {
            guard let c = await session.nextCursor() else { break }
            await session.commit(c)
        }
    }

    /// 备好到队尾：连后面那些摞也都已排进播放器了。
    private func advanceAll(_ session: PlaybackSession) async {
        while let c = await session.nextCursor() { await session.commit(c) }
    }

    /// 按**实际被念的顺序**取出所有字的正文。
    ///
    /// 顺序是播报故事最要紧的那件事（「排队从不插队」），而段/页有没有编号跟顺序无关，
    /// 所以这里直接读字，不靠 id 猜。
    private func spokenOrder(_ session: PlaybackSession) async -> [String] {
        var out: [String] = []
        while let c = await session.nextCursor() {
            await session.commit(c)
            out.append(c.block.text)
        }
        return out
    }

    private func headStackID(_ session: PlaybackSession) async -> String? {
        await session.headStackTarget()?.id
    }

    // MARK: - 清单 3：一摞的边界还是「你一次开口引发的全部」吗？

    /// 队首那摞「已声明、字还没到」时，起点跳过它——用户耳朵里是空的，
    /// 没有正在听的摞可掀。这摞不是空的，它只是还没开口。
    func testSkipsAStackThatWasDeclaredButNotYetWritten() async {
        let s = PlaybackSession()
        _ = await s.beginTurn("gEmpty", source: "claude")   // 说了话，纸还在路上
        await seed(s, stacks: [(id: "gB", pages: [["B1"]])])
        await advanceAll(s)

        let taken = await s.takeHeadStack()?.id
        XCTAssertEqual(taken, "gB", "空摞不是「正在听的那摞」，该跳过")
    }

    /// 你放弃了一摞，它后续送来的页不得再开口。
    func testAbandonedStackNeverSpeaksAgain() async {
        let s = PlaybackSession()
        await seed(s, stacks: [(id: "gA", pages: [["A1"]]), (id: "gB", pages: [["B1"]])])
        _ = await s.takeHeadStack()
        let late = await s.appendGrouped([block("A2", page: "gA-p0")], group: "gA")
        XCTAssertFalse(late, "被放弃的摞，它后续送来的字不该再开口")
    }

    /// **没被你放弃的摞，它后续送来的页必须仍能开口。**
    /// 这条防的是顺手清理误伤——放弃 gA 不该让 gB 一起哑掉。
    func testUntouchedStackKeepsAcceptingContent() async {
        let s = PlaybackSession()
        await seed(s, stacks: [(id: "gA", pages: [["A1"]]), (id: "gB", pages: [["B1"]])])
        await advanceAll(s)
        _ = await s.takeHeadStack()                    // 放弃 gA
        let ok = await s.appendGrouped([block("B2", page: "gB-p1")], group: "gB")
        XCTAssertTrue(ok, "gB 没被放弃，它后续送来的页必须还能入队")
    }

    // MARK: - 清单 4：新纸还是排队不打断吗？（只有翻译能插队）

    /// **新来的纸一律排队。** Claude 的摞先到，命令行递来的那段字后到——
    /// 后到的必须排在后面，哪怕它更短、哪怕它是同一个人敲的。
    /// 纸上没有名牌的陌生人不插队（命令行那段字就是陌生人）。
    func testLaterPaperWaitsItsTurnEvenWhenItIsShorter() async {
        let s = PlaybackSession()
        await seed(s, stacks: [(id: "gA", pages: [["长长的一句话", "还有第二句"]])])
        _ = await s.appendPlain([block("短", page: nil, source: "speak")])   // 后到的一字纸

        let order = await spokenOrder(s)
        XCTAssertEqual(order, ["长长的一句话", "还有第二句", "短"],
                       "后到的一字纸得排在长摞后面 —— 排队从不插队")
    }

    /// **只有翻译能插队**，而且它插完就走，原顺序原样接回。
    /// 这是插队唯一的合法形态：让路，不是丢弃。
    func testOnlyTranslationJumpsTheQueueAndTheRestResumes() async {
        let s = PlaybackSession()
        await seed(s, stacks: [(id: "gA", pages: [["第一句", "第二句", "第三句"]])])
        _ = await s.appendFirst([block("译文", page: nil, source: "translate")])

        let order = await spokenOrder(s)
        XCTAssertEqual(order, ["译文", "第一句", "第二句", "第三句"],
                       "译文插最前，念完原文从断点接回，一个字不少")
    }

    /// 麦克风不在这场戏里：它让路，但**不递纸**——你说的那句是给 AI 的，不是给他念的。
    /// 队列层能钉的是「让路之后队列是空的，你的讲话没有变成一张要念的纸」。
    /// 至于「它压根没有递纸入口」，那是结构事实，见文件末尾对照表。
    func testSpeechNeverContributesAPaper() async {
        let s = PlaybackSession()
        await seed(s, stacks: [(id: "gA", pages: [["A1"]])])
        await advanceAll(s)

        _ = await s.discardAll()                       // 麦克风唯一做的事：全掀
        let pending = await s.hasPending
        let head = await headStackID(s)
        XCTAssertFalse(pending, "麦克风让路后不该留下任何纸")
        XCTAssertNil(head, "麦克风说完，队列是空的 —— 你的话给 AI，不给他念")
    }

    // MARK: - 清单 5：插队是「让路」还是被写成「丢弃」？

    /// 插队的那摞念完之后，**队首回到原来那一摞**，而不是被跳过。
    func testJumpedStackResumesTheOriginalOrder() async {
        let s = PlaybackSession()
        await seed(s, stacks: [(id: "gA", pages: [["A1", "A2"]]),
                               (id: "gB", pages: [["B1", "B2"]])])
        _ = await s.appendFirst([block("译文", page: nil, source: "translate")])

        let taken = await s.takeHeadStack()?.id
        let after = await headStackID(s)
        XCTAssertNil(taken, "队首应是加急段（无分组）")
        XCTAssertEqual(after, "gA", "加急段念完了，常规摞顶上")
    }

    /// 清单 4 已从**念的顺序**上钉了「原文从断点接回」，这条补容器视角：
    /// 插队那一摞被领走之后，常规摞一张都没少。
    func testJumpingDoesNotDropTheRestOfTheQueue() async {
        let s = PlaybackSession()
        await seed(s, stacks: [(id: "gA", pages: [["A1", "A2", "A3"]])])
        _ = await s.appendFirst([block("译文", page: nil, source: "translate")])

        _ = await s.takeHeadStack()                     // 领走译文
        let rest = await spokenOrder(s)
        XCTAssertEqual(rest, ["A1", "A2", "A3"], "插队只让路，原摞一个字都不许少")
    }

    // MARK: - 清单 6：他作弊提前备着的那几秒还在吗？按的时候他认的是「第几条正在响」吗？

    /// **备好不改变起点。** 这是 2026-10-17 18:52 那次翻车的正身：
    /// 播报员已经备到下一摞了，而你还在听上一摞的尾音。
    /// 你按「这摞不要了」，掀掉的必须是**你正在听的那摞**，不能是队首。
    ///
    /// **这条在改成发声点之前会红**——那时的实现取到的是 gB。
    func testSkipStackTakesTheStackBeingHeardNotTheNextOne() async {
        let s = PlaybackSession()
        await seed(s, stacks: [(id: "gA", pages: [["A1", "A2"]]),
                               (id: "gB", pages: [["B1"]]),
                               (id: "gC", pages: [["C1"]])])
        await advance(s, 2)   // 备好越过 gA 的两块；gA 的尾音还在响，gB 还没被摸

        let taken = await s.takeHeadStack()
        let after = await headStackID(s)
        XCTAssertEqual(taken?.id, "gA", "起点被进度带偏了：你在听 gA，掀掉的却是别的摞")
        XCTAssertEqual(after, "gB", "掀完自然落到下一摞")
    }

    /// 进度推到哪都不改变起点——不落后，也不超前。
    func testStartPointIsIndependentOfSchedulingProgress() async {
        let s = PlaybackSession()
        await seed(s, stacks: [(id: "gA", pages: [["A1", "A2"]]),
                               (id: "gB", pages: [["B1"]])])
        let atFirst = await headStackID(s)
        XCTAssertEqual(atFirst, "gA", "刚入队时起点就该是队首")

        await advance(s, 2)
        let atBoundary = await headStackID(s)
        XCTAssertEqual(atBoundary, "gA", "备好越过边界后起点变了 —— 这就是翻车那一步")

        await advance(s, 5)
        let atEnd = await headStackID(s)
        XCTAssertEqual(atEnd, "gA", "备好推到哪都不该改变起点")

        let taken = await s.takeHeadStack()?.id
        let next = await headStackID(s)
        XCTAssertEqual(taken, "gA")
        XCTAssertEqual(next, "gB")
    }

    /// 发声点就是「正在响的那一块」，不落后也不超前。
    ///
    /// 这条钉的是 `dataConsumed` 的语义：它在 buffer **开始被渲染**时回调
    /// （字幕 `onSentenceStarted` 早就这么用，从没被判过字幕延迟）。
    /// 若实现改成落后一号，页级就差一页——块与页一一对应。
    func testStartPointIsTheSoundingBlockItself() async {
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

    /// 发声点对摞级同样生效，而且**两条路答案必须一致**——
    /// 队首方案在摞级本来就碰巧成立，发声点只是把它变成「有据可依」。
    func testStartPointIsIndependentOfSchedulingProgress_StackLevel() async {
        let s = PlaybackSession()
        await seed(s, stacks: [(id: "gA", pages: [["A1", "A2", "A3"]]),
                               (id: "gB", pages: [["B1"]])])
        await advanceAll(s)
        await s.noteConsumed(2)      // 用户在听块 1，仍在 gA

        let head = await headStackID(s)
        let taken = await s.takeHeadStack()?.id
        XCTAssertEqual(head, "gA")
        XCTAssertEqual(taken, "gA", "备好推到末尾也不能把起点带偏")
    }

    // MARK: - 清单 7：三档丢的是「层」还是变成了「位置」？

    /// 「这摞不要了，听下一摞」——丢的是**一整摞**，落点是下一摞。
    /// 连按就是连着往下听，不需要任何防重入。
    func testSkipStackDropsAWholeStackAndLandsOnTheNext() async {
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
        XCTAssertEqual(a, "gA")
        XCTAssertEqual(b, "gB")
        XCTAssertEqual(c, "gC")
        XCTAssertNil(d, "全掀完了不该还有起点")
        XCTAssertNil(head)
    }

    /// 「这页不要了，听下一页」——丢的是**一页**，落点是下一页。
    ///
    /// 页级必须由发声点给出起点：一页念完后它的内容仍留在容器里没人删，
    /// 所以「第一个有内容的页」永远落在**已经念完**的那一页上。
    /// 这里 pgA1 已念完、pgA2 正在响，按下去必须掀 pgA2。
    ///
    /// **这条在引入发声点之前会红**——那时的实现掀掉的是 pgA1。
    func testSkipPageTakesThePageBeingHeard() async {
        let s = PlaybackSession()
        for i in 1...3 {
            _ = await s.appendGrouped([block("A\(i)", page: "pgA\(i)")], group: "gA")
        }
        _ = await s.appendGrouped([block("B1", page: "pgB1")], group: "gB")
        await advance(s, 2)          // pgA1 已念完，pgA2、pgA3 已备好
        await s.noteConsumed(2)      // 块 2 正在响 ⇒ 你此刻在听 pgA2

        let taken = await s.takeHeadPage()
        let nowHead = await s.headPageID
        XCTAssertEqual(taken?.pageID, "pgA2", "掀的必须是用户正在听的那一页")
        XCTAssertEqual(nowHead, .some("pgA3"), "掀完自然落到下一页")
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
        XCTAssertEqual(a, "pgA1")
        XCTAssertEqual(b, "pgA2")
        XCTAssertEqual(c, "pgA3")
        XCTAssertNil(d)
    }

    /// 掀页**不立墓碑**——这是它与掀摞唯一的语义差别：
    /// 还没来的页等它来了照样播（掀页只能掀已经出现的那一页）。
    func testSkipPageDoesNotAbandonTheStack() async {
        let s = PlaybackSession()
        _ = await s.appendGrouped([block("A1", page: "pgA1")], group: "gA")
        _ = await s.appendGrouped([block("A2", page: "pgA2")], group: "gA")
        _ = await s.takeHeadPage()
        let later = await s.appendGrouped([block("A3", page: "pgA3")], group: "gA")
        XCTAssertTrue(later, "掀一页不该作废整摞——同摞后续页仍要能入队")
    }

    /// 陌生人的纸没有页号，**退化成匿名页**：按下去照样掀得掉东西。
    /// 故事里叫「它没有名牌，连撕到一张纸那一层都只是勉强的」。
    func testSkipPageOnAPaperWithoutName() async {
        let s = PlaybackSession()
        _ = await s.appendPlain([block("说点什么", page: nil, source: "speak")])
        let taken = await s.takeHeadPage()
        let head = await headStackID(s)
        XCTAssertNil(taken?.pageID, "没有页号就是匿名页")
        XCTAssertEqual(taken?.dropped, 1, "但还是掀得掉——不能按不动")
        XCTAssertNil(head)
    }

    // MARK: - 清单 8：跨来源喊闭嘴，会不会挂错那摞的牌？

    /// Ctrl+Esc 是**全局热键**，拿不到「当前会话」是谁。此前一刀切埋全部，
    /// 于是你在 Claude 里喊闭嘴，把 **Codex 正在生成的那摞**也埋了——
    /// 它随后送来的字全被丢弃、从此不再开口。
    /// 这条钉的是：**容器照旧全清，墓碑只给最近有块入队的那个来源。**
    func testShutUpBuriesOnlyTheSourceThatWasTalking() async {
        let s = PlaybackSession()
        _ = await s.appendGrouped([block("C1", page: "p1", source: "claude")], group: "gClaude")
        _ = await s.appendGrouped([block("X1", page: "p2", source: "codex")], group: "gCodex")
        _ = await s.appendGrouped([block("C2", page: "p3", source: "claude")], group: "gClaude")

        let buried = await s.discardAll()

        let codexLater = await s.appendGrouped([block("X2", page: "p4", source: "codex")], group: "gCodex")
        let claudeLater = await s.appendGrouped([block("C3", page: "p5", source: "claude")], group: "gClaude")
        XCTAssertEqual(buried, ["gClaude"], "只该埋正在说话那一摞的牌")
        XCTAssertTrue(codexLater, "Codex 没被喊停，它的后续增量必须照常入队")
        XCTAssertFalse(claudeLater, "正在说话的那个被喊停了，它不该再开口")
    }

    /// 声音是全体的事：不管谁在念，按下去都得停。
    func testShutUpStopsWhicheverSourceIsSpeaking() async {
        let s = PlaybackSession()
        _ = await s.appendGrouped([block("C1", page: "p1", source: "claude")], group: "gClaude")
        _ = await s.appendGrouped([block("X1", page: "p2", source: "codex")], group: "gCodex")
        await advanceAll(s)

        _ = await s.discardAll()

        let pending = await s.hasPending
        let head = await headStackID(s)
        XCTAssertFalse(pending, "容器必须全清 —— 声音是全体的事")
        XCTAssertNil(head)
    }

    /// 「已声明、字还在路上」的那摞也要按属主埋——否则属主随后送来的字会照常开口。
    /// 但**别的来源**正声明着的轮不埋。
    func testShutUpAlsoBuriesDeclaredButUnwrittenStacksOfThatSource() async {
        let s = PlaybackSession()
        _ = await s.beginTurn("gPi", source: "pi")
        _ = await s.beginTurn("gClaude", source: "claude")

        _ = await s.discardAll()

        let piLater = await s.appendGrouped([block("P1", page: "q1", source: "pi")], group: "gPi")
        let claudeLater = await s.appendGrouped([block("C1", page: "q2", source: "claude")], group: "gClaude")
        XCTAssertTrue(piLater, "pi 那摞没被喊停")
        XCTAssertFalse(claudeLater, "正在说话那个已声明未到字的一摞，也得被埋")
    }

    // MARK: - 清单 9：念完的纸收走了吗？有没有误收「还在写」的？

    /// 念完且已收尾的摞要回收掉，否则打断起点会落在**早已念完**的那摞上——
    /// 而它往往还在继续送页，一按就给它立了牌，后续页全被静默丢弃。
    /// 这条对外可见的事实：念完之后 `/health` 不再报 `audibleTurn`。
    func testFinishedAndClosedStackIsSweptOffTheDesk() async {
        let s = PlaybackSession()
        await seed(s, stacks: [(id: "gA", pages: [["A1"]])])
        await advanceAll(s)
        await s.noteConsumed(1)          // 真的响过了
        _ = await s.sealIdle()           // 盖印 = 不会再有内容

        // 收尾路径已确认设备真静音：正在响的那块也已响完，连它一起清
        let retired = await s.retireSpentSegments(afterSilence: true)
        let head = await headStackID(s)
        let pending = await s.hasPending
        XCTAssertEqual(retired, 1)
        XCTAssertNil(head, "念完又收尾的摞不该还留在桌上当起点")
        XCTAssertFalse(pending)
    }

    /// **还在写的不许收。** Claude 那一摞还可能继续送页，现在清了等于把它连内容一起吞掉。
    /// 即便已确认静音也不清——收尾不等于判死。
    func testStackThatIsStillBeingWrittenIsNotSwept() async {
        let s = PlaybackSession()
        await seed(s, stacks: [(id: "gA", pages: [["A1"]])])
        await advanceAll(s)
        await s.noteConsumed(1)

        let retired = await s.retireSpentSegments(afterSilence: true)
        let head = await headStackID(s)
        XCTAssertEqual(retired, 0, "还没收到尾，不能收")
        XCTAssertEqual(head, "gA")
    }

    /// 收桌子**不是判死**——用户没放弃它，只是念完了；后续页来了要照播。
    func testSweepingDoesNotAbandonTheStack() async {
        let s = PlaybackSession()
        await seed(s, stacks: [(id: "gA", pages: [["A1"]])])
        await advanceAll(s)
        await s.noteConsumed(1)
        _ = await s.sealIdle()
        _ = await s.retireSpentSegments(afterSilence: true)

        let later = await s.appendGrouped([block("A2", page: "gA-p1")], group: "gA")
        let head = await headStackID(s)
        XCTAssertTrue(later, "收桌子只是清容器 —— 后续页必须还能入队")
        XCTAssertEqual(head, "gA")
    }

    /// 判据必须看**发声点**，不看备好进度：刚排进播放器、声音还没响的摞不许收。
    func testSweepingWaitsForTheSoundNotForTheSchedule() async {
        let s = PlaybackSession()
        await seed(s, stacks: [(id: "gA", pages: [["A1", "A2"]]),
                               (id: "gB", pages: [["B1"]])])
        await advanceAll(s)              // 三块都备好了
        await s.noteConsumed(3)          // 块 3 在响 ⇒ gA 早已响完，gB 正在响
        _ = await s.sealTurn("gA")
        _ = await s.sealTurn("gB")

        let retired = await s.retireSpentSegments()
        let head = await headStackID(s)
        XCTAssertEqual(retired, 1, "只该收 gA")
        XCTAssertEqual(head, "gB", "gB 正在响，它仍在桌上")
    }

    /// **正在响的那一块不许收**：它 maxSeq 恰等于发声点，
    /// 清了就等于把还在响的内容从容器里抹掉。
    func testTheSoundingBlockIsNeverSwept() async {
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

    /// 收完桌之后不该留垃圾：全掀几次，容器回到空。
    func testDeskEndsUpEmptyAfterEverythingIsDone() async {
        let s = PlaybackSession()
        await seed(s, stacks: [(id: "gA", pages: [["A1"]]),
                               (id: "gB", pages: [["B1"]])])
        await advanceAll(s)
        _ = await s.takeHeadStack()
        await seed(s, stacks: [(id: "gC", pages: [["C1"]])])
        await advanceAll(s)
        _ = await s.takeHeadStack()
        _ = await s.takeHeadStack()

        let head = await headStackID(s)
        let pending = await s.hasPending
        XCTAssertNil(head, "桌子应已被收空")
        XCTAssertFalse(pending)
    }
}

// MARK: - 验收清单对照：哪条钉在哪
//
// 清单 10 条里 7 条钉在这个文件（见各 MARK）。剩下几条钉在别处，原因如实记下，
// 免得日后误以为「清单 = 这个文件」：
//
// | 清单 | 钉在哪 | 为什么不在这里 |
// |---|---|---|
// | 1 分工（跑腿只抄不裁…） | 架构约定 | 纯约定，构造不出会失败的单测 |
// | 2 各条来源走得通 | `make check-tts` | 要真 socket、真 daemon |
// | 7 两扇门（键盘 / 命令行） | 同上 | 两条路在 `PlaybackQueue` 才汇合，那里带音频设备 |
// | 10 字幕跟声音 | 同上 | 字幕时机在 `AudioPlayer`，容器层看不见 |
//
// 麦克风「不递纸」这条最特殊：它**不是一条断言，是一个结构事实**——
// `SpeechInputService` 只调 `cancelAll`，全项目没有任何以 `speech` 入队的调用点。
// 上面的 `testSpeechNeverContributesAPaper` 只能钉住「让路后队列是空的」这半句。
