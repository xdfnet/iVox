import Foundation

// /health 端点的运行态快照。

/// /health 端点的运行态快照（跨 actor 传递，全部为 Sendable 标量）
struct HealthSnapshot: Sendable {
    let version: String
    let model: String
    let engine: String       // notStarted | loading | ready | failed
    let queued: Int
    let playing: Bool
    /// 播报总开关当前是开是关（关着时队列恒为空）。
    let playbackEnabled: Bool
    /// 用户此刻正在听的摞 / 页（打断起点）；nil = 还没出声或设备已播空。
    /// `audibleTurn` 是**外部** turn_id（无分组来源为 null——它们没有这个号）；
    /// `audiblePage` 是**资料室自编**的页号，所以任何来源都报得出第几页（2026-10-18 起为数字）。
    let audibleTurn: String?
    let audiblePage: Int?
}
