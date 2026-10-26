import XCTest
@testable import iVox
@testable import iVoxKit

/// 队列落盘：**daemon 挂了，排队的东西还在**。
///
/// 2026-10-26 实测：daemon 在播放途中死掉，队列随之蒸发，用户只听到两个字。
/// 这组用例钉住「入队 → 进程没了 → 新进程接着念」这条链。
final class PlaybackStoreTests: XCTestCase {
    private func tempDB() -> String {
        NSTemporaryDirectory() + "ivox-queue-test-\(UUID().uuidString).db"
    }

    /// 存进去读得回来。
    func testStoreRoundTrip() throws {
        let store = try PlaybackStore(path: tempDB())
        let page = StoredPage(stack: 3, page: 7, turnID: "turn-1", pageExternal: "msg-1",
                              blocks: [StoredBlock(seq: 1, text: "第一块", voiceID: "taozi", source: "claude"),
                                       StoredBlock(seq: 2, text: "第二块", voiceID: "taozi", source: "claude")])
        store.savePage(page)
        let loaded = store.loadPages()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.stack, 3)
        XCTAssertEqual(loaded.first?.page, 7)
        XCTAssertEqual(loaded.first?.turnID, "turn-1")
        XCTAssertEqual(loaded.first?.blocks.map(\.text), ["第一块", "第二块"])
    }

    /// 同一页再存一次 = 覆盖（不留旧块）。
    func testSavePageOverwrites() throws {
        let store = try PlaybackStore(path: tempDB())
        store.savePage(StoredPage(stack: 1, page: 1, turnID: nil, pageExternal: nil,
                                  blocks: [StoredBlock(seq: 1, text: "旧", voiceID: "taozi", source: "claude")]))
        store.savePage(StoredPage(stack: 1, page: 1, turnID: nil, pageExternal: nil,
                                  blocks: [StoredBlock(seq: 2, text: "新", voiceID: "taozi", source: "claude")]))
        let loaded = store.loadPages()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.blocks.map(\.text), ["新"])
    }

    /// 删：按摞、按页、按序号上限。
    func testDeletes() throws {
        let store = try PlaybackStore(path: tempDB())
        store.savePage(StoredPage(stack: 1, page: 1, turnID: nil, pageExternal: nil,
                                  blocks: [StoredBlock(seq: 1, text: "a", voiceID: "v", source: "s")]))
        store.savePage(StoredPage(stack: 1, page: 2, turnID: nil, pageExternal: nil,
                                  blocks: [StoredBlock(seq: 2, text: "b", voiceID: "v", source: "s")]))
        store.savePage(StoredPage(stack: 2, page: 1, turnID: nil, pageExternal: nil,
                                  blocks: [StoredBlock(seq: 3, text: "c", voiceID: "v", source: "s")]))
        store.deletePage(stack: 1, page: 1)
        XCTAssertEqual(store.loadBlocks().map(\.text), ["b", "c"])
        store.deleteStack(1)
        XCTAssertEqual(store.loadBlocks().map(\.text), ["c"])
        store.deleteAll()
        XCTAssertTrue(store.loadBlocks().isEmpty)
    }

    /// **daemon 挂掉 → 新进程接着念**：入队后另起一个 session（同一个库），内容还在。
    @MainActor
    func testSessionSurvivesRestart() async throws {
        let path = tempDB()
        let store = try PlaybackStore(path: path)
        let session = PlaybackSession(idleGraceSeconds: 60, store: store)
        await session.restoreIfNeeded()
        await session.appendPlain([PlaybackBlock(seq: 0, text: "没播完的一句", voiceID: "taozi", source: "claude")])
        let pending = await session.pendingCount
        XCTAssertEqual(pending, 1)

        // 「daemon 挂了」：老进程没了，只剩磁盘上的库
        let reborn = PlaybackSession(idleGraceSeconds: 60, store: try PlaybackStore(path: path))
        await reborn.restoreIfNeeded()
        let rebornPending = await reborn.pendingCount
        XCTAssertEqual(rebornPending, 1, "重启后没播完的内容必须还在")
        let cursor = await reborn.nextCursor()
        XCTAssertEqual(cursor?.block.text, "没播完的一句")
    }

    /// 播完的块不留：已交给合成的块从库里删掉，重启后不会重念。
    @MainActor
    func testCommittedBlocksAreNotRestored() async throws {
        let path = tempDB()
        let store = try PlaybackStore(path: path)
        let session = PlaybackSession(idleGraceSeconds: 60, store: store)
        await session.restoreIfNeeded()
        await session.appendPlain([PlaybackBlock(seq: 0, text: "念过的一句", voiceID: "taozi", source: "claude")])
        guard let cursor = await session.nextCursor() else { return XCTFail("应该有块") }
        await session.commit(cursor)

        let reborn = PlaybackSession(idleGraceSeconds: 60, store: try PlaybackStore(path: path))
        await reborn.restoreIfNeeded()
        let pending = await reborn.pendingCount
        XCTAssertEqual(pending, 0, "念过的不该再念一遍")
    }
}
