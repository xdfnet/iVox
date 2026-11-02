import XCTest
@testable import iVox
@testable import iVoxKit

// 播报故事（`docs/playback/paper.md`）的验收钉子。**每个 MARK 对应验收清单里的一条问句**，
// 每条用例的注释第一行是那句问句本身——故事是基线，用例照着基线写，不是照着实现写。
//
// 本文件只钉**容器**这一层：队列里排的是什么、轮到哪一页、用户喊停时掀掉哪一页、
// 字幕取哪一页的上下文、daemon 挂了之后怎么接着念。`PlaybackSession` 是纯 actor，
// 毫秒级跑完，不碰音频设备。
//
// **模型只有一层容器**：队列 = **页的 FIFO**。一页 = 一条 assistant 消息（用户感知的单位），
// 页里再分句（合成单位，用户不感知）。没有摞、没有分组、没有墓碑——
// **页按到达顺序排，先来先进，谁都不插队**。
final class PlaybackSessionStoryTests: XCTestCase {

    // MARK: - 夹具

    /// 递一页进去：一页 = 一条 assistant 消息，`sentences` 是这一页拆好的句子。
    ///
    /// **句子只有文本**：身份（句号）与音色由容器自己发——外部编号一律不进队列。
    private func page(_ session: PlaybackSession, _ sentences: [String],
                      source: String = "claude", voiceID: String = "v") async -> Int? {
        await session.appendPage(text: sentences.joined(separator: " "),
                                 sentences: sentences, voiceID: voiceID, source: source)
    }

    /// 把队列进度向前推 `n` 步，模拟播报员**提前备好**后面几句。
    ///
    /// 备好不影响「用户在听哪」，但会让「队首」不再等于「正在听」——
    /// 所以凡是验靶心的用例都得先备好一段。
    private func advance(_ session: PlaybackSession, _ n: Int) async {
        for _ in 0..<n {
            guard let c = await session.nextCursor() else { break }
            await session.commit(c)
        }
    }

    /// 备好到队尾：连后面那些页也都已排进播放器。
    private func advanceAll(_ session: PlaybackSession) async {
        while let c = await session.nextCursor() { await session.commit(c) }
    }

    /// 按**实际被念的顺序**取出所有字的正文。
    ///
    /// 顺序是播报故事最要紧的那件事（「排队从不插队」），所以这里直接读字，不靠 id 猜。
    private func spokenOrder(_ session: PlaybackSession) async -> [String] {
        var out: [String] = []
        while let c = await session.nextCursor() {
            await session.commit(c)
            out.append(c.sentence.text)
        }
        return out
    }

    // MARK: - 队列是页的 FIFO：谁都不插队

    /// **先来先进，先到的页先念。**
    ///
    /// 三页按到达顺序进去，念出来的顺序必须与之一致——哪怕后到的那页更短、
    /// 哪怕它来自另一个接入方（pi / 命令行）。队列里没有任何东西有插队权。
    func testPagesAreSpokenInArrivalOrder() async {
        let s = PlaybackSession()
        _ = await page(s, ["甲一", "甲二"])
        _ = await page(s, ["乙"])
        _ = await page(s, ["丙"], source: "pi")

        let order = await spokenOrder(s)
        XCTAssertEqual(order, ["甲一", "甲二", "乙", "丙"],
                       "排队从不插队：谁都不许插到前头")
    }

    /// 一页里的句子连着念完才轮到下一页——**页是单位，句子不是**。
    func testAPageIsSpokenWholeBeforeTheNextPage() async {
        let s = PlaybackSession()
        _ = await page(s, ["A1", "A2", "A3"])
        _ = await page(s, ["B1"])

        let order = await spokenOrder(s)
        XCTAssertEqual(order, ["A1", "A2", "A3", "B1"],
                       "一页念完才轮到下一页")
    }

    /// **后到的短页也得排在长页后面。**
    ///
    /// 2026-10-18 那场翻车的老教训：没有外部编号的两段内容曾被焊成一段，
    /// 按一次掀掉一大片。现在没有分组，两页就是两页，谁也不合并。
    func testLaterShortPageWaitsBehindTheEarlierOne() async {
        let s = PlaybackSession()
        _ = await page(s, ["长长的一句话", "还有第二句"])
        _ = await page(s, ["短"], source: "speak")

        let order = await spokenOrder(s)
        XCTAssertEqual(order, ["长长的一句话", "还有第二句", "短"],
                       "后到的一页字短也得排队 —— 队列里没有优先权")
    }

    // MARK: - 掀页（Ctrl+1）掀掉的是哪一页？

    /// **掀掉的是用户此刻正在听的那一页**——不是队首，也不是游标走到的那一页。
    ///
    /// 游标（已交给合成的最高句号）领先真实发声 2~4 秒（预取垫 + 引擎缓冲），
    /// 拿它当起点就是 2026-10-17 18:52 那场事故。
    /// 这里备好到第 2 页，而设备仍在渲染第 1 页的尾句——掀的必须是第 1 页。
    func testSkipPageTakesThePageBeingHeardNotTheQueueHead() async {
        let s = PlaybackSession()
        _ = await page(s, ["A1", "A2"])
        _ = await page(s, ["B1"])
        _ = await page(s, ["C1"])
        await advance(s, 2)          // 甲的两句都备好了
        await s.noteConsumed(2)      // 第 2 句正在响 ⇒ 用户此刻在听第 1 页

        let taken = await s.takeHeadPage()
        XCTAssertEqual(taken?.pageNo, 1, "掀的必须是用户正在听的那一页")
        let head = await s.headPageNo
        XCTAssertEqual(head, 2, "掀完自然落到下一页")
    }

    /// 发声点还没记录时（还没出声），**靶心退回队首**——用户即将听到的那页。
    func testSkipPageFallsBackToTheQueueHeadBeforeAnySound() async {
        let s = PlaybackSession()
        _ = await page(s, ["A1"])
        _ = await page(s, ["B1"])

        let taken = await s.takeHeadPage()
        XCTAssertEqual(taken?.pageNo, 1, "还没出声时，掀的该是即将播的那一页")
    }

    /// **领取即摘走**：掀页在「掐」之前就把那一页摘走，
    /// 所以掐在播期间游标前移也不会掀错页。
    ///
    /// 2026-10-17 18:52 实测：掐要 await 旧管道退净，那期间旧管道 commit 掉
    /// 正在响的最后一句、游标一越过边界，「当前页」就从 A 变成 B，
    /// 于是掀掉了用户想听的 B。把摘走放在掐之前，起点从此不可能再被游标带偏。
    func testSkipPageTakesThePageOutBeforeTheInterruptLands() async {
        let s = PlaybackSession()
        _ = await page(s, ["A1"])
        _ = await page(s, ["B1", "B2"])
        await advance(s, 1)          // 甲已念完
        await s.noteConsumed(1)      // 甲正在响

        let taken = await s.takeHeadPage()
        XCTAssertEqual(taken?.pageNo, 1)

        // 掐在播期间：旧管道 commit 掉正在响的那一句，游标越到了第 2 页
        await advance(s, 1)

        let next = await s.takeHeadPage()
        XCTAssertEqual(next?.pageNo, 2,
                       "被掀掉的那页不该再被掀第二次 —— 领取即摘走")
    }

    /// 掀页丢掉的是**那一页剩下的内容**，别页一页不动。
    func testSkipPageDropsOnlyThatPage() async {
        let s = PlaybackSession()
        _ = await page(s, ["A1", "A2", "A3"])
        _ = await page(s, ["B1"])

        let taken = await s.takeHeadPage()
        XCTAssertEqual(taken?.dropped, 3, "掀掉的是那一页的整页内容")

        let rest = await spokenOrder(s)
        XCTAssertEqual(rest, ["B1"], "别的页一个字都不许少")
    }

    /// 连按掀页 = 连着往下听：掀完第 1 页再掀就是第 2 页。
    func testConsecutiveSkipPageWalksDownTheQueue() async {
        let s = PlaybackSession()
        _ = await page(s, ["A1"])
        _ = await page(s, ["B1"])
        _ = await page(s, ["C1"])

        let a = await s.takeHeadPage()?.pageNo
        let b = await s.takeHeadPage()?.pageNo
        let c = await s.takeHeadPage()?.pageNo
        let d = await s.takeHeadPage()
        XCTAssertEqual(a, 1)
        XCTAssertEqual(b, 2)
        XCTAssertEqual(c, 3)
        XCTAssertNil(d, "全掀完了不该还有靶心")
    }

    // MARK: - 全掀（Ctrl+2）：清空全部内容

    /// **全掀清空全部内容**——不分来源、不分页，一句不剩。
    ///
    /// 声音是全体的事：不管谁在念，按下去都得停。
    func testSkipAllClearsEverything() async {
        let s = PlaybackSession()
        _ = await page(s, ["C1"], source: "claude")
        _ = await page(s, ["X1"], source: "pi")
        _ = await page(s, ["C2"], source: "claude")

        let dropped = await s.discardAll()
        XCTAssertEqual(dropped, 3, "清全体：谁在念都得停")

        let pending = await s.hasPending
        let head = await s.headPageNo
        XCTAssertFalse(pending, "容器必须全清")
        XCTAssertNil(head, "清完就没有靶心了")
    }

    /// 全掀之后**后来的页照常入队、照常播**。
    ///
    /// **不立墓碑**：用户放弃的是「此刻队列里的内容」，不是「这个来源以后的话」。
    /// 内容生死只由用户当下这一按决定。
    func testContentArrivingAfterSkipAllStillGetsSpoken() async {
        let s = PlaybackSession()
        _ = await page(s, ["A1"])
        _ = await s.discardAll()

        _ = await page(s, ["迟到的甲"])
        let spoken = await spokenOrder(s)
        XCTAssertEqual(spoken, ["迟到的甲"], "迟到的内容照常入队照常播 —— 不立墓碑")
    }

    // MARK: - 撤回来路：只撤指定的页

    // MARK: - 不立墓碑：放弃之后迟到的内容照常入队照常播

    /// **掀页不立墓碑**——放弃的是那一页，不是这个来源以后所有的页。
    func testContentArrivingAfterSkipPageStillGetsSpoken() async {
        let s = PlaybackSession()
        _ = await page(s, ["A1"])
        _ = await s.takeHeadPage()

        _ = await page(s, ["后来的甲"])
        let spoken = await spokenOrder(s)
        XCTAssertEqual(spoken, ["后来的甲"], "掀一页不该作废这个来源后续的页")
    }

    /// **全掀同样不立墓碑**：撤的是「此刻排队的内容」，不是「来源」。
    func testContentArrivingAfterSkipAllFromTheSameSourceStillSpeaks() async {
        let s = PlaybackSession()
        _ = await page(s, ["A1"], source: "claude")
        _ = await s.discardAll()

        _ = await page(s, ["A2"], source: "claude")
        let spoken = await spokenOrder(s)
        XCTAssertEqual(spoken, ["A2"], "全掀只清此刻的内容，不封这个来源")
    }

    // MARK: - 字幕：这一页的所有句子 + 念到第几句

    /// **字幕给的是那一页的所有句子，外加念到第几句、页号。**
    ///
    /// 页里已经念过的句仍在（只有掀页才整页删），所以这一页的句子就是歌词的上下文。
    func testCaptionContextCarriesTheWholePageAndWhereWeAre() async {
        let s = PlaybackSession()
        _ = await page(s, ["A1", "A2", "A3"])
        _ = await page(s, ["B1"])

        let first = await s.nextCursor()
        guard let first else { return XCTFail("应该有句") }
        let ctx = await s.captionContext(forSeq: first.seq)
        XCTAssertEqual(ctx?.lines, ["A1", "A2", "A3"], "字幕给的是这一页的所有句子")
        XCTAssertEqual(ctx?.index, 0, "刚开口：念到第 1 句")
        XCTAssertEqual(ctx?.page, 1, "页号也得给")
    }

    /// 念到这一页中间那句时，字幕的「念到第几句」跟着走。
    func testCaptionIndexFollowsTheSoundingSentence() async {
        let s = PlaybackSession()
        _ = await page(s, ["A1", "A2", "A3"])

        guard let c = await s.nextCursor() else { return XCTFail("应该有句") }
        await s.commit(c)                       // 第 1 句念完
        guard let second = await s.nextCursor() else { return XCTFail("应该有句") }
        await s.noteConsumed(second.seq)

        let ctx = await s.captionContext(forSeq: second.seq)
        XCTAssertEqual(ctx?.index, 1, "念到第 2 句")
        XCTAssertEqual(ctx?.lines, ["A1", "A2", "A3"], "上下文仍是整页")
    }

    /// 字幕只认自己那一页：别页的句号查不到上下文（返回 nil）。
    func testCaptionContextIsScopedToItsOwnPage() async {
        let s = PlaybackSession()
        _ = await page(s, ["A1"])
        _ = await page(s, ["B1"])

        guard let c = await s.nextCursor() else { return XCTFail("应该有句") }
        let ctx = await s.captionContext(forSeq: c.seq)
        XCTAssertEqual(ctx?.lines, ["A1"], "别页的句子不在这一页的上下文里")
    }

    // MARK: - 发声点推进后，翻页靶心跟着走

    /// **发声点往前挪，靶心就跟着挪**——用户听到哪儿，掀的就是哪儿。
    func testHeadTargetFollowsTheAudiblePoint() async {
        let s = PlaybackSession()
        _ = await page(s, ["A1"])
        _ = await page(s, ["B1"])
        _ = await page(s, ["C1"])

        await s.noteConsumed(1)
        let atA = await s.headPageNo
        XCTAssertEqual(atA, 1, "第 1 句在响 ⇒ 靶心是第 1 页")

        await s.noteConsumed(2)
        let atB = await s.headPageNo
        XCTAssertEqual(atB, 2, "第 2 句在响 ⇒ 靶心跟着走到第 2 页")

        await s.noteConsumed(3)
        let atC = await s.headPageNo
        XCTAssertEqual(atC, 3, "第 3 句在响 ⇒ 靶心是第 3 页")
    }

    /// **备好进度不改变靶心**：备到队尾也不许把「正在听」带偏。
    func testSchedulingProgressDoesNotMoveTheTarget() async {
        let s = PlaybackSession()
        _ = await page(s, ["A1", "A2"])
        _ = await page(s, ["B1"])

        await advanceAll(s)          // 全备好
        await s.noteConsumed(1)      // 用户还在听 A1

        let head = await s.headPageNo
        let taken = await s.takeHeadPage()?.pageNo
        XCTAssertEqual(head, 1, "备好推到队尾也不许把靶心带偏")
        XCTAssertEqual(taken, 1, "掀的必须是用户正在听的那一页")
    }

    // MARK: - 念完的页收走了吗？

    /// **念完的页要收走**：它留在容器里只是历史垃圾，
    /// 而留着它会让掀页的靶心落在「早就念完的那一页」上，
    /// 于是把后来才到的那一页给掀了（2026-10-17 那场事故的另一面）。
    func testSpentPagesAreRetiredOnceTheyAreDone() async {
        let s = PlaybackSession()
        _ = await page(s, ["A1"])
        _ = await page(s, ["B1"])
        await advanceAll(s)
        await s.noteConsumed(2)      // 第 2 页在响 ⇒ 第 1 页已经念完

        let retired = await s.retireSpentPages()
        XCTAssertEqual(retired, 1, "念完的那一页该被收走")
        let head = await s.headPageNo
        XCTAssertEqual(head, 2, "收走之后靶心落在下一页")
    }

    /// **正在响的那一页不许收**：它还没响完。
    func testTheSoundingPageIsNeverRetired() async {
        let s = PlaybackSession()
        _ = await page(s, ["A1"])
        await advanceAll(s)
        await s.noteConsumed(1)

        let retired = await s.retireSpentPages()
        XCTAssertEqual(retired, 0, "正在响的页还没响完")
        let head = await s.headPageNo
        XCTAssertEqual(head, 1)
    }

    // MARK: - 落盘：daemon 挂了，没播完的页还在

    /// **daemon 重启后，没播完的页按原顺序回来。**
    ///
    /// `make update` 走 `launchctl kickstart -k`，那是 SIGKILL——
    /// 队列只在内存里的话，每部署一次就丢一次排队。
    func testUnfinishedPagesComeBackInOrderAfterRestart() async {
        let path = NSTemporaryDirectory() + "ivox-story-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = try? PlaybackStore(path: path)
        let s = PlaybackSession(store: store)
        await s.restoreIfNeeded()
        _ = await page(s, ["甲一", "甲二"])
        _ = await page(s, ["乙"])
        _ = await page(s, ["丙"])
        await advance(s, 1)          // 甲的第一句念完了，剩下三句没念

        // 「daemon 挂了」：老进程没了，只剩磁盘上的库
        let reborn = PlaybackSession(store: try? PlaybackStore(path: path))
        await reborn.restoreIfNeeded()

        let spoken = await spokenOrder(reborn)
        XCTAssertEqual(spoken, ["甲二", "乙", "丙"],
                       "重启后没播完的内容按原顺序回来")
    }

    /// **念过的不许重念**：已交给合成的句从库里删掉了。
    func testCommittedSentencesAreNotSpokenAgainAfterRestart() async {
        let path = NSTemporaryDirectory() + "ivox-story-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let s = PlaybackSession(store: try? PlaybackStore(path: path))
        await s.restoreIfNeeded()
        _ = await page(s, ["念过的一句"])
        guard let c = await s.nextCursor() else { return XCTFail("应该有句") }
        await s.commit(c)

        let reborn = PlaybackSession(store: try? PlaybackStore(path: path))
        await reborn.restoreIfNeeded()
        let pending = await reborn.pendingCount
        XCTAssertEqual(pending, 0, "念过的不该再念一遍")
    }
}

// MARK: - 验收清单对照：哪条钉在哪
//
// 清单里在这个文件钉的是**容器层**的各条（见各 MARK）。剩下几条钉在别处，原因如实记下，
// 免得日后误以为「清单 = 这个文件」：
//
// | 清单 | 钉在哪 | 为什么不在这里 |
// |---|---|---|
// | 分工（接入侧只抄不裁…） | 架构约定 | 纯约定，构造不出会失败的单测 |
// | 各条来源走得通 | `make check-tts` | 要真 socket、真 daemon |
// | 两扇门（键盘 / 命令行） | 同上 | 两条路在 `PlaybackQueue` 才汇合，那里带音频设备 |
// | 字幕跟声音 | 同上 | 字幕时机在 `AudioPlayer`，容器层看不见 |
//
// 麦克风「不递纸」这条最特殊：它**不是一条断言，是一个结构事实**——
// `SpeechInputService` 只调 `discardAll`，全项目没有任何以 `speech` 入队的调用点。
