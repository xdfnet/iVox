import AppKit
import Foundation
import iVoxKit

// 汽水音乐音量让路：iVox 占用注意力时（正在播报，或浮窗在屏上）把它的应用内音量降几格，
// 闲下来再升回去。谁在占用由浮窗服务判断（见 `OverlayService`），这里只管调音量。
//
// 为什么走 ESP32 真 HID 而不在本机合成按键：汽水音乐**丢弃 CGEvent 合成键**（实测：
// 合成音量键毫无反应），只有真硬件事件才被它当成用户操作。通道见 `HidInjector`。
//
// 为什么只调音量、不暂停：旧做法「借还背景音乐」（pause/resume）会抖——Claude 分批送来，
// 批间停顿一超时就误判「说完了」还音乐，下一批到又借走。改数值不切播放状态，抖不起来。
//
// 为什么相对调节、不读当前值：汽水音乐那 20 格是**应用内**音量（不是系统输出音量），
// 本机读不到它。只能「降几格 / 升几格」——音量本来就低时会触底，播完升回去不等于原值，
// 这是「不读当前格数」的已知代价。

/// iVox 占用注意力期间给汽水音乐让路的音量调节器。
///
/// 只在汽水音乐**正在运行**时才动手：这些是真实硬件按键，会同时送到前台 App，
/// 汽水音乐没开时按下去只会误伤当前窗口。
actor SodaVolumeDucker {
    /// 调几格：汽水音乐音量共 20 格，降 5 格约等于压到四分之一。
    private static let steps = 5

    /// 每格之间隔多久：汽水音乐反应慢，500ms 一步（再密它跟不上）。
    private static let stepInterval: Duration = .milliseconds(500)

    /// 汽水音乐自己的全局音量键：⌘⌥+↓ 降一格、⌘⌥+↑ 升一格。
    /// 键名按固件的表（`app_http.c` 的 `named_mods`/`named_keys`）：是 `down` 不是 `arrowdown`。
    private static let volumeDownKeys = ["cmd", "option", "down"]
    private static let volumeUpKeys = ["cmd", "option", "up"]

    /// 已经让过路了吗（降了但还没升回去）。
    private var ducked = false

    /// 让路：降几格。**已经让过就不再让**——浮层反复显隐会连着调，
    /// 降两次就成 10 格（真降到更靠后，越听越小声）。
    func duck() async {
        guard !ducked else { return }
        guard Self.isSodaRunning() else {
            Log.info("汽水音乐音量: 未运行，不动音量（这些键会打到前台 App）")
            return
        }
        ducked = true
        Log.info("汽水音乐音量: 让路，降 \(Self.steps) 格")
        await send(keys: Self.volumeDownKeys)
    }

    /// 恢复：升回去。没让过就不动（免得多升几格）。
    func restore() async {
        guard ducked else { return }
        ducked = false
        Log.info("汽水音乐音量: 恢复，升 \(Self.steps) 格")
        await send(keys: Self.volumeUpKeys)
    }

    /// 发一批按键：连按 `steps` 次，每次间隔 `stepInterval`。
    /// **不 await**——按键在后台发出去，播报主流程不等它。
    /// 发送链是串行的（见 `HidInjector`），所以「降的几击」一定先于「升的几击」。
    private func send(keys: [String]) async {
        let task = await HidInjector.shared.press(keys, times: Self.steps, interval: Self.stepInterval)
        Task {
            if case .failure(let error) = await task.value {
                Log.warn("汽水音乐音量: 按键没发出去（\(error.errorDescription ?? "未知原因")）")
            }
        }
    }

    /// 汽水音乐在运行吗（只认汽水音乐一个 App）。
    private static func isSodaRunning() -> Bool {
        let bundleID = AudioAppRegistry.bundleID(for: "汽水音乐")
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}
