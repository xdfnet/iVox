import Foundation

// 「能把字变成声音」这件事的契约，进程内引擎（`TTSEngine`）与远程引擎（`TSPRemote`）都实现。
//
// 边界：只管「字 → 声音」。归拢成摞、裁成字条、排队、发声点一概不在契约内——那些留在
// 主进程，且**永不跨 IPC**（发声点跨进程会重演 paper.md 记的那次「摘错摞」）。
//
// **协议成员一律声明成 `async`**：实现方都是 actor，跨 actor 访问本来就是 await；
// 按同步要求写，编译器会判「一致性跨越 actor 隔离」而报错——那不是并发 bug，是声明与
// 实现对不上。声明成 async，隔离自然成立，不必用 `@preconcurrency` 绕过。

protocol TTSProviding: Sendable {
    /// 模型好了没。主进程自己不加载模型，问的就是对面那个进程。
    var state: TTSLoadState { get async }

    /// 启动期握手：等到能干活（或失败）为止
    func loadModel() async throws
    func waitUntilReady() async

    /// 预热。远程引擎的预热在子进程侧自己做（它加载完就跑一次），这边只是等它。
    func warmup(voiceID: String) async

    /// 把一段字变成 PCM 帧流。`trace` 是块的身份证，带在每行日志上。
    func synthesizeStream(text: String, voiceID: String, trace: TTSTrace?) async
        -> AsyncThrowingStream<Data, Error>

    /// 打断当前这一句。协作式：正在 MLX 里跑的那一句不会中途消失，只是产出作废。
    func cancelActiveSynthesis(reason: String) async
}

/// 引擎就绪状态。进程内与远程共用同一个类型：`Daemon` 的 statusProvider 与
/// `PlaybackQueue.waitUntilEngineReady()` 两处都对它做 switch，引擎换成走 IPC 的实现后
/// 仍不必改这两处。
enum TTSLoadState: Sendable, Equatable {
    case notStarted
    case loading
    case ready
    case failed(String)
}
