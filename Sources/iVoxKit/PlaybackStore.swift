import Foundation
import SQLite3

// 播报队列的落盘副本：**daemon 挂了，排队的东西还在**。
//
// 为什么要有它：队列原本只在内存里。daemon 一挂（崩、被 kill、机器睡醒），排队的内容
// 一起没了——用户听到的是「念了两个字就没声了」，而那些字他还没听到
// （2026-10-26 实测：daemon 在 15:00:33 死掉，队列随之蒸发）。
//
// **两张表**（2026-11-02 起：队列里只有页）：
//   `pages`     —— 一页一条 = **队列的单位**（一条 assistant 消息）。记页号、来源、音色与整页原文。
//   `sentences` —— 一句一条 = **合成单位**（≤80 字）。纯实现细节，用户不感知；
//                  **播完即删**（消费掉），这一页的句子见底时那一页也删。
//
// **不存 turn_id / session_id**：它们只进日志，不参与排队，也不落库。
//
// 为什么用 SQLite：一次事务就是一次原子落盘（写到一半断电也不会写坏），
// 而且系统自带（libsqlite3），不引新依赖。

/// 一页的落盘形态（一页 = 队列里唯一的单位 = 一条 assistant 消息）。
///
/// `page` 是**资料室自编的页号**：身份是容器自己的事，不由外部决定。
public struct StoredPage: Sendable {
    public let page: Int
    public let source: String
    public let voiceID: String
    /// 整页原文（这一页说了什么，拆句之前的形态）。
    public let text: String

    public init(page: Int, source: String, voiceID: String, text: String) {
        self.page = page
        self.source = source
        self.voiceID = voiceID
        self.text = text
    }
}

/// 一句的落盘形态（合成单位，≤80 字）。
public struct StoredSentence: Sendable {
    public let seq: UInt
    public let page: Int
    public let text: String

    public init(seq: UInt, page: Int, text: String) {
        self.seq = seq
        self.page = page
        self.text = text
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
            var message = "未知错误"
            if let handle { message = String(cString: sqlite3_errmsg(handle)); sqlite3_close(handle) }
            throw StoreError.openFailed(message)
        }
        db = handle
        try exec("PRAGMA journal_mode=WAL;")
        // NORMAL：断电可能丢最后一笔事务，但不会写坏库。队列丢一笔 = 少念一句，
        // 比每次入队都 fsync 划算得多。
        try exec("PRAGMA synchronous=NORMAL;")
        // 老库（一张 blocks 表，装的是「摞/页/块」三层）改名留着，不删也不读。
        // 它的内容读不出来（旧结构和新结构不是一回事），留着只是备查。
        _ = execLocked("ALTER TABLE blocks RENAME TO blocks_legacy;")
        try exec("""
            CREATE TABLE IF NOT EXISTS pages(
                page   INTEGER PRIMARY KEY,
                source TEXT NOT NULL,
                voice  TEXT NOT NULL,
                text   TEXT NOT NULL);
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS sentences(
                seq  INTEGER PRIMARY KEY,
                page INTEGER NOT NULL,
                text TEXT NOT NULL);
            """)
        try exec("CREATE INDEX IF NOT EXISTS sentences_page ON sentences(page);")
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

    /// 存一页（覆盖式）。
    public func savePage(_ page: StoredPage) {
        lock.lock(); defer { lock.unlock() }
        guard db != nil else { return }
        _ = execLocked("""
            INSERT OR REPLACE INTO pages (page, source, voice, text) VALUES (?, ?, ?, ?);
            """, bindings: [.int(page.page), .text(page.source), .text(page.voiceID), .text(page.text)])
    }

    /// 插一句（从页面原文派生出的合成单位）。
    public func insertSentence(_ sentence: StoredSentence) {
        lock.lock(); defer { lock.unlock() }
        guard db != nil else { return }
        _ = execLocked("""
            INSERT OR REPLACE INTO sentences (seq, page, text) VALUES (?, ?, ?);
            """, bindings: [.int(Int(sentence.seq)), .int(sentence.page), .text(sentence.text)])
    }

    /// 删掉已播完（已交给合成）的句：序号不大于给定值的那些。
    public func deleteSentences(upTo seq: UInt) {
        lock.lock(); defer { lock.unlock() }
        _ = execLocked("DELETE FROM sentences WHERE seq <= ?;", bindings: [.int(Int(seq))])
    }

    /// 删掉某页的句（掀页）。
    public func deleteSentences(page: Int) {
        lock.lock(); defer { lock.unlock() }
        _ = execLocked("DELETE FROM sentences WHERE page = ?;", bindings: [.int(page)])
    }

    /// 删掉某页（这一页与它的句一起清掉）。
    public func deletePage(_ page: Int) {
        lock.lock(); defer { lock.unlock() }
        _ = execLocked("DELETE FROM sentences WHERE page = ?;", bindings: [.int(page)])
        _ = execLocked("DELETE FROM pages WHERE page = ?;", bindings: [.int(page)])
    }

    /// 全清（全掀）。
    public func deleteAll() {
        lock.lock(); defer { lock.unlock() }
        _ = execLocked("DELETE FROM sentences;")
        _ = execLocked("DELETE FROM pages;")
    }

    // MARK: - 读

    /// 读出所有页（按页号排 = 队列顺序）。
    public func loadPages() -> [StoredPage] {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return [] }
        let sql = "SELECT page, source, voice, text FROM pages ORDER BY page ASC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var result: [StoredPage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(StoredPage(
                page: Int(sqlite3_column_int64(stmt, 0)),
                source: columnText(stmt, 1),
                voiceID: columnText(stmt, 2),
                text: columnText(stmt, 3)))
        }
        return result
    }

    /// 读出所有还没播完的句（按句号排 = 队列顺序）。
    public func loadSentences() -> [StoredSentence] {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return [] }
        let sql = "SELECT seq, page, text FROM sentences ORDER BY seq ASC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var result: [StoredSentence] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(StoredSentence(
                seq: UInt(sqlite3_column_int64(stmt, 0)),
                page: Int(sqlite3_column_int64(stmt, 1)),
                text: columnText(stmt, 2)))
        }
        return result
    }

    /// 清空（恢复后重写时用）。
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        _ = execLocked("DELETE FROM sentences;")
        _ = execLocked("DELETE FROM pages;")
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

    /// `SQLITE_TRANSIENT`：让 SQLite 自己拷一份字符串（Swift 的 String 随时会没）。
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
