import Foundation

// /health 端点的运行态快照。

/// /health 端点的运行态快照（跨 actor 传递，全部为 Sendable 标量）
struct HealthSnapshot: Sendable {
    let version: String
    let model: String
    let engine: String       // notStarted | loading | ready | failed
    let queued: Int
    let playing: Bool
    /// 用户此刻正在听的摞 / 页（打断起点）；nil = 还没出声或设备已播空。
    /// 黑盒断言靠它量出「按压前后是不是从正在听的那一摞换到了下一摞」。
    let audibleTurn: String?
    let audiblePage: String?
}
