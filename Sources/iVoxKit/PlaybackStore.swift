import Foundation
import SQLite3

// 播报队列的落盘副本：**daemon 挂了，排队的东西还在**。
//
// 为什么要有它：队列原本只在内存里。daemon 一挂（崩、被 kill、机器睡醒），排队的内容
// 一起没了——用户听到的是「念了两个字就没声了」，而那些字他还没听到
// （2026-10-26 实测：daemon 在 15:00:33 死掉，队列随之蒸发）。
//
// 存什么：**还没播出去的块**。已播完的、已被用户掀掉的，都不留。
// 恢复时把这些块重新排进队——宁可重念一遍，不丢。
//
// 为什么用 SQLite：一次事务就是一次原子落盘（写到一半断电也不会写坏），
// 而且系统自带（libsqlite3），不引新依赖。

/// 一块待播文本的落盘形态。
public struct StoredBlock: Sendable {
    public let seq: UInt
    public let text: String
    public let voiceID: String
    public let source: String

    public init(seq: UInt, text: String, voiceID: String, source: String) {
        self.seq = seq
        self.text = text
        self.voiceID = voiceID
        self.source = source
    }
}

/// 一页的落盘形态（一页 = 一次 assistant 消息）。
///
/// `stack` / `page` 是**资料室自编的摞号与页号**：落盘要保住「谁跟谁是一伙的」，
/// 外部 turn_id 只作备注（墓碑与分组另有其人）。
public struct StoredPage: Sendable {
    public let stack: Int
    public let page: Int
    public let turnID: String?
    public let pageExternal: String?
    /// 可变：读回来往同一页里追加块时用（数组元素是值类型，改完写回原坐标）。
    public var blocks: [StoredBlock]

    public init(stack: Int, page: Int, turnID: String?, pageExternal: String?, blocks: [StoredBlock]) {
        self.stack = stack
        self.page = page
        self.turnID = turnID
        self.pageExternal = pageExternal
        self.blocks = blocks
    }
}

/// 队列的落盘仓库（SQLite）。
///
/// **它不能拖垮播报**：所有写盘失败只记一行警告，播报照走。
/// 真源仍是内存里的容器；这里是它的**耐久副本**，供 daemon 重启后恢复。
public final class PlaybackStore: @unchecked Sendable {
    public enum StoreError: Error, CustomStringConvertible {
        case openFailed(String)
        case execFailed(String)

        public var description: String {
            switch self {
            case .openFailed(let m): return "打不开队列库：\(m)"
            case .execFailed(let m): return "队列库操作失败：\(m)"
            }
        }
    }

    private var db: OpaquePointer?
    /// 一把锁：容器 actor 与队列消费层可能从不同线程碰它（SQLite 开了 FULLMUTEX，
    /// 但我们还想把「写一批」做成一次事务，不让两个写交错）。
    private let lock = NSLock()

    public init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            if let handle { sqlite3_close(handle) }
            throw StoreError.openFailed(message)
        }
        db = handle
        try exec("PRAGMA journal_mode=WAL;")
        // NORMAL：断电可能丢最后一笔事务，但不会写坏库。队列丢一笔 = 少念一句，
        // 比每次入队都 fsync 划算得多。
        try exec("PRAGMA synchronous=NORMAL;")
        try exec("""
            CREATE TABLE IF NOT EXISTS blocks(
                seq INTEGER PRIMARY KEY,
                stack INTEGER NOT NULL,
                page INTEGER NOT NULL,
                turn_id TEXT,
                page_external TEXT,
                text TEXT NOT NULL,
                voice TEXT NOT NULL,
                source TEXT NOT NULL);
            """)
    }

    deinit { close() }

    /// 开一份默认的队列库（路径跟 socket 走）。开不了就返回 nil——
    /// **这一轮队列就只在内存里**（记一行警告，不该因此起不来）。
    public static func makeDefault() -> PlaybackStore? {
        let path = AppPaths.queueStorePath
        do {
            return try PlaybackStore(path: path)
        } catch {
            Log.warn("队列落盘库开不了（\(path)）：\(error)——这一轮队列只在内存里")
            return nil
        }
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        if let db { sqlite3_close(db) }
        db = nil
    }

    // MARK: - 写

    /// 存一页（覆盖式）：先把这一页的旧块删掉，再写新块。
    ///
    /// 覆盖而不是追加：一页可能被追加新的块（同一摞的后续增量），也可能被整页替换。
    /// 覆盖让「这一页现在有哪些块」只有一处真源。
    public func savePage(_ page: StoredPage) {
        lock.lock(); defer { lock.unlock() }
        guard db != nil else { return }
        guard execLocked("DELETE FROM blocks WHERE stack = ? AND page = ?;",
                         bindings: [.int(page.stack), .int(page.page)]) else { return }
        guard execLocked("BEGIN IMMEDIATE;") else { return }
        var ok = true
        for block in page.blocks {
            ok = ok && execLocked("""
                INSERT OR REPLACE INTO blocks
                    (seq, stack, page, turn_id, page_external, text, voice, source)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """, bindings: [
                    .int(Int(block.seq)), .int(page.stack), .int(page.page),
                    .text(page.turnID), .text(page.pageExternal),
                    .text(block.text), .text(block.voiceID), .text(block.source),
                ])
        }
        _ = execLocked(ok ? "COMMIT;" : "ROLLBACK;")
    }

    /// 删掉某摞的全部块（掀摞 / 取消轮次）。
    public func deleteStack(_ stack: Int) {
        lock.lock(); defer { lock.unlock() }
        _ = execLocked("DELETE FROM blocks WHERE stack = ?;", bindings: [.int(stack)])
    }

    /// 删掉某摞里某页的块（掀页）。
    public func deletePage(stack: Int, page: Int) {
        lock.lock(); defer { lock.unlock() }
        _ = execLocked("DELETE FROM blocks WHERE stack = ? AND page = ?;",
                       bindings: [.int(stack), .int(page)])
    }

    /// 删掉某摞里**序号不大于**给定值的块（掀掉「这一摞剩下的」）。
    public func deleteStackUpTo(stack: Int, seq: UInt) {
        lock.lock(); defer { lock.unlock() }
        _ = execLocked("DELETE FROM blocks WHERE stack = ? AND seq <= ?;",
                       bindings: [.int(stack), .int(Int(seq))])
    }

    /// 全清（全掀）。
    public func deleteAll() {
        lock.lock(); defer { lock.unlock() }
        _ = execLocked("DELETE FROM blocks;")
    }

    /// 删掉已播完的块（序号不大于给定值）。
    public func deleteUpTo(seq: UInt) {
        lock.lock(); defer { lock.unlock() }
        _ = execLocked("DELETE FROM blocks WHERE seq <= ?;", bindings: [.int(Int(seq))])
    }

    // MARK: - 读

    /// 读出所有还没播的块（按序号排）。
    public func loadBlocks() -> [StoredBlock] {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return [] }
        let sql = "SELECT seq, text, voice, source FROM blocks ORDER BY seq ASC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var result: [StoredBlock] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(StoredBlock(
                seq: UInt(sqlite3_column_int64(stmt, 0)),
                text: columnText(stmt, 1),
                voiceID: columnText(stmt, 2),
                source: columnText(stmt, 3)))
        }
        return result
    }

    /// 读出所有页（按摞号、页号排；同页的块按序号排）。
    public func loadPages() -> [StoredPage] {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return [] }
        let sql = """
            SELECT seq, stack, page, turn_id, page_external, text, voice, source
            FROM blocks ORDER BY stack ASC, page ASC, seq ASC;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var pages: [StoredPage] = []
        var index: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let seq = UInt(sqlite3_column_int64(stmt, 0))
            let stack = Int(sqlite3_column_int64(stmt, 1))
            let page = Int(sqlite3_column_int64(stmt, 2))
            let turnID = optionalColumnText(stmt, 3)
            let pageExternal = optionalColumnText(stmt, 4)
            let block = StoredBlock(seq: seq, text: columnText(stmt, 5),
                                    voiceID: columnText(stmt, 6), source: columnText(stmt, 7))
            let key = "\(stack)#\(page)"
            if let i = index[key] {
                // 数组元素是值类型：改完必须写回原坐标
                var updated = pages[i]
                updated.blocks.append(block)
                pages[i] = updated
            } else {
                index[key] = pages.count
                pages.append(StoredPage(stack: stack, page: page, turnID: turnID,
                                        pageExternal: pageExternal, blocks: [block]))
            }
        }
        return pages
    }

    /// 清空（恢复后重写时用）。
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        _ = execLocked("DELETE FROM blocks;")
    }

    // MARK: - 底层

    private enum Binding {
        case int(Int)
        case text(String?)
    }

    private func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard execLocked(sql) else {
            throw StoreError.execFailed(lastError())
        }
    }

    /// 执行一条语句（调用方已持锁）。
    @discardableResult
    private func execLocked(_ sql: String, bindings: [Binding] = []) -> Bool {
        guard let db else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        for (i, binding) in bindings.enumerated() {
            let index = Int32(i + 1)
            switch binding {
            case .int(let v): sqlite3_bind_int64(stmt, index, sqlite3_int64(v))
            case .text(let v):
                if let v {
                    sqlite3_bind_text(stmt, index, v, -1, Self.transient)
                } else {
                    sqlite3_bind_null(stmt, index)
                }
            }
        }
        // PRAGMA 之类会**返回一行**（SQLITE_ROW），也算成功
        let rc = sqlite3_step(stmt)
        return rc == SQLITE_DONE || rc == SQLITE_ROW
    }

    private func lastError() -> String {
        guard let db else { return "数据库已关闭" }
        return String(cString: sqlite3_errmsg(db))
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: c)
    }

    private func optionalColumnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    /// `SQLITE_TRANSIENT`：让 SQLite 自己拷一份字符串（Swift 的 String 随时会没）。
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
