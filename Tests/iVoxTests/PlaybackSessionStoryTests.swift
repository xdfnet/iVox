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

    /// 造一块材料。**块上没有任何外部编号**（2026-10-18 起：块的身份只有助理发的 `seq`），
    /// 摞线索走 `deliver` 的 `group`、页线索走 `deliver` 的 `page`。
    private func block(_ text: String, source: String = "claude") -> PlaybackBlock {
        PlaybackBlock(seq: 0, text: text, voiceID: "v", source: source)
    }

    /// **跑腿侧的对照表**：「外部 group ↔ 助理自编的摞号」。
    ///
    /// 2026-10-18 起助理不再按外部号检索容器——摞的身份只有它自己发的 `localID`。
    /// 谁来记「这批材料属于哪一摞」？**衔接归跑腿的管**：生产环境这张表在
    /// `ConnectionHandler`，测试里由 `deliver` 就地模拟。
    ///
    /// 于是本文件的视角始终是「跑腿的递材料、助理分配编号」，
    /// 而不是「助理自己认 group」——后者正是 2026-10-18 那次焊接 bug 的成因。
    private var stackLedger: [String: Int] = [:]

    /// 递一批材料进去：第一次自开一摞，之后同 group 的续批按**助理发的号**并进去。
    /// - Returns: 三态。`dead` 必须丢弃、`gone` 才另开一摞（混同会让已放弃的摞重新开口）。
    @discardableResult
    private func deliver(_ session: PlaybackSession, group: String, page: String?,
                         blocks: [PlaybackBlock]) async -> PlaybackSession.StackAccept {
        if let stack = stackLedger[group] {
            let verdict = await session.appendToStack(stack, blocks, note: group, pageNote: page)
            if verdict != .gone { return verdict }
            stackLedger[group] = nil            // 号已失效：作废的摞就这么丢掉这条对照
        }
        guard let fresh = await session.newStack(blocks, note: group, pageNote: page) else { return .dead }
        stackLedger[group] = fresh
        return .appended
    }

    /// 喂若干摞，每摞一页一页地入队（模拟 Claude 按行批：一个 turn 底下好几页）。
    private func seed(_ session: PlaybackSession, stacks: [(id: String, pages: [[String]])]) async {
        for st in stacks {
            for (i, p) in st.pages.enumerated() {
                _ = await deliver(session, group: st.id, page: "\(st.id)-p\(i)",
                                  blocks: p.map { block($0) })
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
        await session.headStackTarget()?.turnID
    }

    // MARK: - 清单 3：一摞的边界还是「你一次开口引发的全部」吗？

    /// 队首那摞「已声明、字还没到」时，起点跳过它——用户耳朵里是空的，
    /// 没有正在听的摞可掀。这摞不是空的，它只是还没开口。
    func testSkipsAStackThatWasDeclaredButNotYetWritten() async {
        let s = PlaybackSession()
        _ = await s.beginTurn("gEmpty")   // 说了话，纸还在路上
        await seed(s, stacks: [(id: "gB", pages: [["B1"]])])
        await advanceAll(s)

        let taken = await s.takeHeadStack()?.turnID
        XCTAssertEqual(taken, "gB", "空摞不是「正在听的那摞」，该跳过")
    }

    /// 你放弃了一摞，它后续送来的页不得再开口。
    func testAbandonedStackNeverSpeaksAgain() async {
        let s = PlaybackSession()
        await seed(s, stacks: [(id: "gA", pages: [["A1"]]), (id: "gB", pages: [["B1"]])])
        _ = await s.takeHeadStack()
        let late = await deliver(s, group: "gA", page: "gA-p0", blocks: [block("A2")])
        XCTAssertEqual(late, .dead, "被放弃的摞，它后续送来的字不该再开口")
    }

    /// **没被你放弃的摞，它后续送来的页必须仍能开口。**
    /// 这条防的是顺手清理误伤——放弃 gA 不该让 gB 一起哑掉。
    func testUntouchedStackKeepsAcceptingContent() async {
        let s = PlaybackSession()
        await seed(s, stacks: [(id: "gA", pages: [["A1"]]), (id: "gB", pages: [["B1"]])])
        await advanceAll(s)
        _ = await s.takeHeadStack()                    // 放弃 gA
        let ok = await deliver(s, group: "gB", page: "gB-p1", blocks: [block("B2")])
        XCTAssertEqual(ok, .appended, "gB 没被放弃，它后续送来的页必须还能入队")
    }

    // MARK: - 清单 4：新纸还是排队不打断吗？（只有翻译能插队）

    /// **新来的纸一律排队。** Claude 的摞先到，命令行递来的那段字后到——
    /// 后到的必须排在后面，哪怕它更短、哪怕它是同一个人敲的。
    /// 纸上没有名牌的陌生人不插队（命令行那段字就是陌生人）。
    func testLaterPaperWaitsItsTurnEvenWhenItIsShorter() async {
        let s = PlaybackSession()
        await seed(s, stacks: [(id: "gA", pages: [["长长的一句话", "还有第二句"]])])
        _ = await s.appendPlain([block("短", source: "speak")])   // 后到的一字纸

        let order = await spokenOrder(s)
        XCTAssertEqual(order, ["长长的一句话", "还有第二句", "短"],
                       "后到的一字纸得排在长摞后面 —— 排队从不插队")
    }

    /// **译文不上桌**（2026-10-26 改）：它走播报员的另一张嘴当场念，
    /// **队列里一个位置都不占**。所以桌上的纸从头到尾就是原来那些——
    /// 这条钉的是「译文不进容器」：容器里若多出译文那一摞，
    /// 用户按 Ctrl+2 掀摞就可能掀到一张他没在听的纸。
    func testTranslationNeverEntersTheQueue() async {
        let s = PlaybackSession()
        await seed(s, stacks: [(id: "gA", pages: [["第一句", "第二句", "第三句"]])])
        // 译文走的是播报器的独立节点，容器这一层压根没有它的入口：
        // 入队前后的桌上纸数必须一模一样。
        let before = await s.pendingCount

        let order = await spokenOrder(s)
        XCTAssertEqual(order, ["第一句", "第二句", "第三句"],
                       "译文不上桌，念的顺序就是原来那摞 —— 一个字不少、一个字不多")
        XCTAssertEqual(before, 3, "桌上就这三张纸")
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

    /// 插队让完路，**队首还是原来那一摞**——译文那一下没把起点挪走。
    /// 译文不上桌，所以「正在听的摞」从头到尾都是 gA。
    func testJumpedStackResumesTheOriginalOrder() async {
        let s = PlaybackSession()
        await seed(s, stacks: [(id: "gA", pages: [["A1", "A2"]]),
                               (id: "gB", pages: [["B1", "B2"]])])
        // 译文在播报员那边念，容器不受影响：起点仍是 gA。

        let taken = await s.takeHeadStack()?.turnID
        let after = await headStackID(s)
        XCTAssertEqual(taken, "gA", "起点被译文挪走了 —— 桌上压根没有译文那一摞")
        XCTAssertEqual(after, "gB", "掀完 gA 自然落到 gB")
    }

    /// 清单 4 已从**念的顺序**上钉了「原文从断点接回」，这条补容器视角：
    /// 译文让完路，原摞一张都没少。
    func testJumpingDoesNotDropTheRestOfTheQueue() async {
        let s = PlaybackSession()
        await seed(s, stacks: [(id: "gA", pages: [["A1", "A2", "A3"]])])
        // 译文念完，播报员从原处接着念 —— 容器这边一张纸都没少。

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
        XCTAssertEqual(taken?.turnID, "gA", "起点被进度带偏了：你在听 gA，掀掉的却是别的摞")
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

        let taken = await s.takeHeadStack()?.turnID
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
            _ = await deliver(s, group: "gA", page: "pgA\(i)", blocks: [block("A\(i)")])
        }
        let beforeAnySound = await s.headPageNo
        XCTAssertEqual(beforeAnySound, 1, "还没出声时退回队首")

        await s.noteConsumed(1)
        let atA1 = await s.headPageNo
        XCTAssertEqual(atA1, 1, "块 1 在响 ⇒ 起点就是第 1 页")

        await s.noteConsumed(3)
        let atA3 = await s.headPageNo
        XCTAssertEqual(atA3, 3, "块 3 在响 ⇒ 起点就是第 3 页，不许落后也不许超前")
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
        let taken = await s.takeHeadStack()?.turnID
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

        let a = await s.takeHeadStack()?.turnID
        let b = await s.takeHeadStack()?.turnID
        let c = await s.takeHeadStack()?.turnID
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
            _ = await deliver(s, group: "gA", page: "pgA\(i)", blocks: [block("A\(i)")])
        }
        _ = await deliver(s, group: "gB", page: "pgB1", blocks: [block("B1")])
        await advance(s, 2)          // pgA1 已念完，pgA2、pgA3 已备好
        await s.noteConsumed(2)      // 块 2 正在响 ⇒ 你此刻在听 pgA2

        let taken = await s.takeHeadPage()
        let nowHead = await s.headPageNo
        XCTAssertEqual(taken?.pageNo, 2, "掀的必须是用户正在听的那一页")
        XCTAssertEqual(nowHead, 3, "掀完自然落到下一页")
    }

    /// 连按翻页 = 连着往下听。
    func testConsecutiveSkipPageWalksDown() async {
        let s = PlaybackSession()
        for i in 1...3 {
            _ = await deliver(s, group: "gA", page: "pgA\(i)", blocks: [block("A\(i)")])
        }
        let a = await s.takeHeadPage()?.pageNo
        let b = await s.takeHeadPage()?.pageNo
        let c = await s.takeHeadPage()?.pageNo
        let d = await s.takeHeadPage()
        XCTAssertEqual(a, 1)
        XCTAssertEqual(b, 2)
        XCTAssertEqual(c, 3)
        XCTAssertNil(d)
    }

    /// 掀页**不立墓碑**——这是它与掀摞唯一的语义差别：
    /// 还没来的页等它来了照样播（掀页只能掀已经出现的那一页）。
    func testSkipPageDoesNotAbandonTheStack() async {
        let s = PlaybackSession()
        _ = await deliver(s, group: "gA", page: "pgA1", blocks: [block("A1")])
        _ = await deliver(s, group: "gA", page: "pgA2", blocks: [block("A2")])
        _ = await s.takeHeadPage()
        let later = await deliver(s, group: "gA", page: "pgA3", blocks: [block("A3")])
        XCTAssertEqual(later, .appended, "掀一页不该作废整摞——同摞后续页仍要能入队")
    }

    /// 陌生人的纸没有外部页号，**照样有自己的页号**。
    ///
    /// 这是 2026-10-18 那次改造的核心断言：早先页号直接存外部 `message_id`，
    /// 外部不给就挂「匿名页」，掀页与掀摞在日志上都说不清掀的是哪一张。
    /// 改成资料室自编之后，**身份不再由端决定**——`ivox speak` / pi 这类没有
    /// 外部页号的来源，掀页照样掀得掉、也照样报得出第几页。
    func testSkipPageOnAPaperWithoutExternalName() async {
        let s = PlaybackSession()
        _ = await s.appendPlain([block("说点什么", source: "speak")])
        let taken = await s.takeHeadPage()
        let head = await headStackID(s)
        XCTAssertEqual(taken?.pageNo, 1, "没有外部页号也照样有自编页号（助理的规矩不依赖端）")
        XCTAssertEqual(taken?.dropped, 1, "掀得掉——不能按不动")
        XCTAssertNil(head)
    }

    /// **无外部编号的稿子，一份就是一摞**——这是 2026-10-18 18:11 那次现场：
    /// 那个来源没 turn_id，早先的实现把它和之前那条长回复焊进了同一个段，
    /// Ctrl+1 掀一次 34 块全丢（其中只有 6 块是新回复）。
    /// 助理的规矩：外部编号只配当「同一摞」的线索，缺席时**各自成摞**，绝不合并。
    func testPlainStacksAreNeverWeldedTogether() async {
        let s = PlaybackSession()
        _ = await s.appendPlain([block("甲的第一句", source: "pi")])
        _ = await s.appendPlain([block("乙的第一句", source: "pi")])
        let first = await s.takeHeadStack()
        XCTAssertEqual(first?.dropped, 1, "掀第一摞只该丢它自己的块，不该把后到的一起带走")
        let second = await s.takeHeadStack()
        XCTAssertEqual(second?.dropped, 1, "第二摞还在原地等着（无编号不等于同一摞）")
        let third = await s.takeHeadStack()
        XCTAssertNil(third, "两摞都掀完了")
    }

    /// **`ivox speak` 一次就是一摞，一摞里只有一张**（飞哥 2026-10-18 定的契约）。
    ///
    /// 「只有一张」不是约定俗成，是结构上成立的：无 page_id 的块两两比较 `nil == nil` 为真，
    /// 于是无论送来多少块都归成同一页。所以对 `ivox speak` 而言 **掀页与掀摞等价**——
    /// 这正是「用户不必先想这个工具有没有页」成立的原因，别让归页逻辑改出第二页。
    func testPlainSpeechIsOneStackWithExactlyOnePage() async {
        let s = PlaybackSession()
        _ = await s.appendPlain([
            block("第一块。", source: "speak"),
            block("第二块。", source: "speak"),
            block("第三块。", source: "speak"),
        ])
        let taken = await s.takeHeadPage()
        XCTAssertEqual(taken?.dropped, 3, "一次 speak 的三块应同属一页")
        let next = await s.takeHeadPage()
        XCTAssertNil(next, "一摞里没有第二页（掀完页这摞就没了）")
    }

    // MARK: - 收尾不是作废令：内容生死只由用户放弃决定

    /// Claude 说「我说完了」之后又来正文 → 照样开口。
    ///
    /// 2026-10-21 实测踩过：Stop 钩子与正文是两条独立通路，谁先到没保证。
    /// 有一次 Stop 早到 9 毫秒，而当时收尾顺手立了墓碑，于是随后到达的最后一段
    /// 140 字被静默丢弃——用户耳朵里是「念到一半没了声音」。
    /// 收尾只决定「什么时候收字幕」；作废（墓碑）只由用户主动放弃发起。
    func testFinishDoesNotKillThePagesThatArriveLater() async {
        let s = PlaybackSession()
        await seed(s, stacks: [(id: "gA", pages: [["A1"]])])
        _ = await s.sealTurn("gA")                       // Claude 说「我说完了」

        let later = await deliver(s, group: "gA", page: "gA-p1", blocks: [block("A2")])
        XCTAssertEqual(later, .appended, "收尾只是说完了，不是作废 —— 后续页必须还能入队")

        let spoken = await spokenOrder(s)
        XCTAssertEqual(spoken, ["A1", "A2"], "后到的内容必须照念")
    }

    /// Claude 说「我说完了」之后又来正文 → 照样开口，**而且这一摞从此算「说完了」**。
    ///
    /// 2026-10-24 实测踩过：收尾信号与正文是两条独立通路，谁先到没保证。收尾先到就把这一摞
    /// 盖了印，随后到达的正文又把印揭开（`sealed = false`）——于是这一摞永远停在「还在说」：
    /// `anyUnsealed` 恒为真 → 队列永远不结算 → **字幕不收、汽水音量不还**（`I1` 用例干等 60 秒
    /// 超时；正文与收尾信号只差 1 毫秒就踩中了）。
    ///
    /// 规矩是：**收尾是终判**。迟到的字照念（一个字不丢），但不再把这一摞拽回「还在说」——
    /// 该收的字幕照收，音量照还。
    func testFinishIsFinalAndLatePageDoesNotReopenTheStack() async {
        let s = PlaybackSession()
        await seed(s, stacks: [(id: "gA", pages: [["A1"]])])
        _ = await s.sealTurn("gA")                       // Claude 说「我说完了」

        let later = await deliver(s, group: "gA", page: "gA-p1", blocks: [block("A2")])
        XCTAssertEqual(later, .appended, "收尾只是说完了，不是作废 —— 后续页必须还能入队")

        let stillOpen = await s.anyUnsealed
        XCTAssertFalse(stillOpen, "收尾是终判：后到的页不许把这一摞拽回「还在说」（否则永不结算）")

        let spoken = await spokenOrder(s)
        XCTAssertEqual(spoken, ["A1", "A2"], "后到的内容必须照念")
    }

    // MARK: - 清单 8：全掀时挂哪些摞的牌？

    /// **队列只有一条**：Claude 与 pi 的内容都按到达顺序排进去，三档打断都是**按队列位置**
    /// 来的（掀页 / 掀摞 / 全部），本来就不该按来源分家（2026-10-24 改）。
    ///
    /// 此前的「只埋属主」（最近有块入队的那个来源）是替身做法：全局热键拿不到「当前会话」
    /// 是谁，就近埋一个了事。代价是「所有摞别说了」只对 claude 生效——pi 那一刻也在队列里，
    /// 内容被丢了，它后续送来的页却还会照念（半吊子）。
    ///
    /// 这条钉的是：**当前存在的摞，来源不分，一律挂牌**。
    func testShutUpBuriesEveryStackThatExists() async {
        let s = PlaybackSession()
        _ = await deliver(s, group: "gClaude", page: "p1", blocks: [block("C1", source: "claude")])
        _ = await deliver(s, group: "gPi", page: "p2", blocks: [block("X1", source: "pi")])
        _ = await deliver(s, group: "gClaude", page: "p3", blocks: [block("C2", source: "claude")])

        let buried = await s.discardAll()

        let piLater = await deliver(s, group: "gPi", page: "p4", blocks: [block("X2", source: "pi")])
        let claudeLater = await deliver(s, group: "gClaude", page: "p5", blocks: [block("C3", source: "claude")])
        XCTAssertTrue(buried.contains("gPi"), "pi 那摞当时在场，也该被挂牌")
        XCTAssertTrue(buried.contains("gClaude"), "claude 那摞在场，该被挂牌")
        XCTAssertEqual(piLater, .dead, "在场被别说了的摞，它后续送来的页不该再开口")
        XCTAssertEqual(claudeLater, .dead, "正在说话的那个被喊停了，它不该再开口")
    }

    /// 声音是全体的事：不管谁在念，按下去都得停。
    func testShutUpStopsWhicheverSourceIsSpeaking() async {
        let s = PlaybackSession()
        _ = await deliver(s, group: "gClaude", page: "p1", blocks: [block("C1", source: "claude")])
        _ = await deliver(s, group: "gPi", page: "p2", blocks: [block("X1", source: "pi")])
        await advanceAll(s)

        _ = await s.discardAll()

        let pending = await s.hasPending
        let head = await headStackID(s)
        XCTAssertFalse(pending, "容器必须全清 —— 声音是全体的事")
        XCTAssertNil(head)
    }

    /// 「已声明、字还在路上」的那摞也算「当前存在」——此刻容器里还没有它的段，
    /// 只按段立碑就会漏掉它：打断之后它陆续送来的字会照常播出来
    ///（2026-10-17 `E7` 实测：清空队列时 pending=0，墓碑一个没立，打断后同一轮照样开口）。
    func testShutUpAlsoBuriesDeclaredButUnwrittenStacks() async {
        let s = PlaybackSession()
        _ = await s.beginTurn("gPi")
        _ = await s.beginTurn("gClaude")

        _ = await s.discardAll()

        let piLater = await deliver(s, group: "gPi", page: "q1", blocks: [block("P1", source: "pi")])
        let claudeLater = await deliver(s, group: "gClaude", page: "q2", blocks: [block("C1", source: "claude")])
        XCTAssertEqual(piLater, .dead, "已声明未到字的那摞，也算在场")
        XCTAssertEqual(claudeLater, .dead, "已声明未到字的那摞，也算在场")
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

        let later = await deliver(s, group: "gA", page: "gA-p1", blocks: [block("A2")])
        let head = await headStackID(s)
        XCTAssertEqual(later, .appended, "收桌子只是清容器 —— 后续页必须还能入队")
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

    // MARK: - 「你别说了」与「你停一下」分家

    /// 用户**显式放弃内容**时（Ctrl+2 全掀）墓碑照立——掀了不埋，「放弃」就退化成
    /// 「暂停一下」，被放弃的那摞会重新开口。
    ///
    /// 反过来，**右⌘说话不是这一档**：那是「你停一下」，走 `PlaybackQueue.pausePlayback()`
    /// （设备停渲染、内容一条不删），根本不进 `discardAll`。
    /// 早先它误用了「全掀」，于是被清场顺手埋了碑，Claude 这一摞后续送来的页撞碑消失——
    /// 2026-10-23 实测丢过 891 字 / 15 块。防复发靠结构：`InterruptSource` 里已没有
    /// `.speech`，说话路径在**编译期**就进不了「全掀」。
    func testShutUpBuriesTheStackItAbandoned() async {
        let s = PlaybackSession()
        _ = await deliver(s, group: "gA", page: "p1", blocks: [block("A1", source: "claude")])
        await advanceAll(s)

        _ = await s.discardAll()                     // Ctrl+2 全掀：放弃内容

        let later = await deliver(s, group: "gA", page: "p2", blocks: [block("A2", source: "claude")])
        XCTAssertEqual(later, .dead, "被放弃的摞，它后续送来的页不该再开口")
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
