import XCTest
@testable import iVox
@testable import iVoxKit

/// 队列落盘：**daemon 挂了，排队的东西还在**。
///
/// 2026-10-26 实测：daemon 在播放途中死掉，队列随之蒸发，用户只听到两个字。
/// 这组用例钉住「入队 → 进程没了 → 新进程接着念」这条链。
///
/// **两张表**：`pages`（队列的单位：一页 = 一条 assistant 消息）与
/// `sentences`（合成单位，播完即删）。不存 turn_id / session_id——它们不进队列。
final class PlaybackStoreTests: XCTestCase {
    private func tempDB() -> String {
        NSTemporaryDirectory() + "ivox-queue-test-\(UUID().uuidString).db"
    }

    /// 存进去读得回来。
    func testStoreRoundTrip() throws {
        let store = try PlaybackStore(path: tempDB())
        store.savePage(StoredPage(page: 7, source: "claude", voiceID: "taozi", text: "整页原文"))
        store.insertSentence(StoredSentence(seq: 1, page: 7, text: "第一句"))
        store.insertSentence(StoredSentence(seq: 2, page: 7, text: "第二句"))

        let pages = store.loadPages()
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages.first?.page, 7)
        XCTAssertEqual(pages.first?.source, "claude")
        XCTAssertEqual(pages.first?.voiceID, "taozi")
        XCTAssertEqual(pages.first?.text, "整页原文")

        let sentences = store.loadSentences()
        XCTAssertEqual(sentences.map(\.seq), [1, 2], "句按句号排 = 队列顺序")
        XCTAssertEqual(sentences.map(\.text), ["第一句", "第二句"])
        XCTAssertEqual(sentences.map(\.page), [7, 7], "每句记着自己属于哪一页")
    }

    /// 同一页再存一次 = 覆盖（不留旧原文）。
    func testSavePageOverwrites() throws {
        let store = try PlaybackStore(path: tempDB())
        store.savePage(StoredPage(page: 1, source: "claude", voiceID: "taozi", text: "旧原文"))
        store.savePage(StoredPage(page: 1, source: "claude", voiceID: "taozi", text: "新原文"))
        let loaded = store.loadPages()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.text, "新原文")
    }

    /// 删：按句号上限、按页、按整页、全清。
    func testDeletes() throws {
        let store = try PlaybackStore(path: tempDB())
        for page in 1...2 {
            store.savePage(StoredPage(page: page, source: "claude", voiceID: "v", text: "第\(page)页"))
            store.insertSentence(StoredSentence(seq: UInt(page), page: page, text: "第\(page)句"))
        }
        store.savePage(StoredPage(page: 3, source: "claude", voiceID: "v", text: "第3页"))
        store.insertSentence(StoredSentence(seq: 3, page: 3, text: "第3句"))

        // 按句号上限删：已交给合成的句不再留
        store.deleteSentences(upTo: 1)
        XCTAssertEqual(store.loadSentences().map(\.text), ["第2句", "第3句"])

        // 按页删句：掀页用
        store.deleteSentences(page: 2)
        XCTAssertEqual(store.loadSentences().map(\.text), ["第3句"])

        // 整页删：页与它的句一起清（别的页不动）
        store.deletePage(3)
        XCTAssertTrue(store.loadSentences().isEmpty, "第 3 页的句随页一起没了")
        XCTAssertEqual(store.loadPages().map(\.page), [1, 2], "别的页还在")

        // 全清
        store.savePage(StoredPage(page: 9, source: "claude", voiceID: "v", text: "x"))
        store.insertSentence(StoredSentence(seq: 9, page: 9, text: "y"))
        store.deleteAll()
        XCTAssertTrue(store.loadSentences().isEmpty)
        XCTAssertTrue(store.loadPages().isEmpty)
    }

    /// **daemon 挂掉 → 新进程接着念**：入队后另起一个 session（同一个库），内容还在。
    @MainActor
    func testSessionSurvivesRestart() async throws {
        let path = tempDB()
        let store = try PlaybackStore(path: path)
        let session = PlaybackSession(store: store)
        await session.restoreIfNeeded()
        await session.appendPage(text: "没播完的一句",
                                 sentences: ["没播完的一句"], voiceID: "taozi", source: "claude")
        let pending = await session.pendingCount
        XCTAssertEqual(pending, 1)

        // 「daemon 挂了」：老进程没了，只剩磁盘上的库
        let reborn = PlaybackSession(store: try PlaybackStore(path: path))
        await reborn.restoreIfNeeded()
        let rebornPending = await reborn.pendingCount
        XCTAssertEqual(rebornPending, 1, "重启后没播完的内容必须还在")
        let cursor = await reborn.nextCursor()
        XCTAssertEqual(cursor?.sentence.text, "没播完的一句")
    }

    /// 播完的句不留：已交给合成的句从库里删掉，重启后不会重念。
    @MainActor
    func testCommittedSentencesAreNotRestored() async throws {
        let path = tempDB()
        let store = try PlaybackStore(path: path)
        let session = PlaybackSession(store: store)
        await session.restoreIfNeeded()
        await session.appendPage(text: "念过的一句",
                                 sentences: ["念过的一句"], voiceID: "taozi", source: "claude")
        guard let cursor = await session.nextCursor() else { return XCTFail("应该有句") }
        await session.commit(cursor)

        let reborn = PlaybackSession(store: try PlaybackStore(path: path))
        await reborn.restoreIfNeeded()
        let pending = await reborn.pendingCount
        XCTAssertEqual(pending, 0, "念过的不该再念一遍")
    }
}
