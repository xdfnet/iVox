import Foundation

// /health 端点的运行态快照。

/// /health 端点的运行态快照（跨 actor 传递，全部为 Sendable 标量）
struct HealthSnapshot: Sendable {
    let version: String
    let model: String
    let engine: String       // notStarted | loading | ready | failed
    let queued: Int
    let playing: Bool
}
