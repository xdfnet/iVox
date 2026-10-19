// TTS 就绪状态：本地引擎（TTSEngine）与远程引擎（TSPRemote）共用同一个类型。
//
// 单独抽出来是因为 `Daemon.statusProvider` 与 `PlaybackQueue.waitUntilEngineReady()`
// 两处都对它做 switch —— 引擎换成走 IPC 的实现之后，若各用各的枚举，这两处就得跟着
// 改一遍。类型共用则切换引擎只是构造时换个对象，调用方一行不动。

enum TTSLoadState: Sendable, Equatable {
    case notStarted
    case loading
    case ready
    case failed(String)
}
