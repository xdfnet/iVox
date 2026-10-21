import AppKit
import Foundation
import iVoxKit

// 汽水音乐音量让路：播报开始时把它的应用内音量降几格，播报结束再升回去。
//
// 为什么走 ESP32 真 HID 而不在本机合成按键：汽水音乐**丢弃 CGEvent 合成键**（实测：
// 合成音量键毫无反应），只有真硬件事件才被它当成用户操作。设备是常驻的 ESP32-S3，
// 通过局域网 HTTP 收注入指令（见 esp32-hid-lab）。
//
// 为什么只调音量、不暂停：旧做法「借还背景音乐」（pause/resume）会抖——Claude 分批送来，
// 批间停顿一超时就误判「说完了」还音乐，下一批到又借走。改数值不切播放状态，抖不起来。
//
// 为什么相对调节、不读当前值：汽水音乐那 20 格是**应用内**音量（不是系统输出音量），
// 本机读不到它。只能「降几格 / 升几格」——音量本来就低时会触底，播完升回去不等于原值，
// 这是「不读当前格数」的已知代价。

/// 播报期间给汽水音乐让路的音量调节器。
///
/// 只在汽水音乐**正在运行**时才动手：这些是真实硬件按键，会同时送到前台 App，
/// 汽水音乐没开时按下去只会误伤当前窗口。
actor SodaVolumeDucker {
    /// ESP32-S3 注入设备的地址（静态 IP，见 esp32-hid-lab 的 README）。
    private static let deviceHost = "192.168.100.3"
    private static let devicePort = 80

    /// 调几格：汽水音乐音量共 20 格，降 5 格约等于压到四分之一。
    private static let steps = 5

    /// 每格之间隔多久：汽水音乐反应慢，500ms 一步（再密它跟不上）。
    private static let stepInterval: Duration = .milliseconds(500)

    /// 汽水音乐自己的全局音量键：⌘⌥+↓ 降一格、⌘⌥+↑ 升一格。
    /// 键名按固件的表（`app_http.c` 的 `named_mods`/`named_keys`）：是 `down` 不是 `arrowdown`。
    private static let volumeDownKeys = ["cmd", "option", "down"]
    private static let volumeUpKeys = ["cmd", "option", "up"]

    /// 接口 token：环境变量优先，否则读 esp32-hid-lab 仓里那一份——
    /// 那就是烧进板子里的同一个值（单一真源，不抄第二份）。都没有就放弃让路。
    private static let tokenFilePath = "/Users/admin/iCode/esp32-hid-lab/main/api_token"

    /// 已经让过路了吗（降了但还没升回去）。
    private var ducked = false

    /// 按键发送链：新来的活排在上一批后面，保证「降」的几击一定先于「升」的几击发出去。
    /// 链不在本 actor 上跑（HTTP 往返别占着 actor），主流程（播报）更不受影响。
    private var keyChain: Task<Void, Never>?

    /// 播报起落 → 让路/收声。
    func handle(_ signal: PlaybackSignal) {
        switch signal {
        case .started:
            // 已经让过路了就不再让：打断后重起管道、Cmd+D 译文插队都会再发一次 .started，
            // 重复降会变成降 10 格（真降到更靠后，越听越小声）。
            guard !ducked else { return }
            guard Self.isSodaRunning() else {
                Log.info("汽水音乐音量: 未运行，不动音量（这些键会打到前台 App）")
                return
            }
            ducked = true
            Log.info("汽水音乐音量: 播报开始，降 \(Self.steps) 格")
            enqueueKeys(Self.volumeDownKeys, count: Self.steps)
        case .ended:
            guard ducked else { return }
            ducked = false
            Log.info("汽水音乐音量: 播报结束，升 \(Self.steps) 格")
            enqueueKeys(Self.volumeUpKeys, count: Self.steps)
        }
    }

    /// 把一批按键接到发送链末尾。
    /// 用 detached：任务体里是 HTTP 往返，挂在 actor 上会占着 actor（等于占着让路这一路）。
    private func enqueueKeys(_ keys: [String], count: Int) {
        let previous = keyChain
        keyChain = Task.detached {
            _ = await previous?.value
            await Self.sendKeys(keys, count: count)
        }
    }

    /// 逐次发按键，每次之间隔 `stepInterval`（最后一次不隔）。
    /// 设备离线 / token 不对 / 返回非 200：一律记日志了事，**绝不影响播报**——
    /// 宁可没压住音量，也不让播报出问题。
    private static func sendKeys(_ keys: [String], count: Int) async {
        guard let token = apiToken() else {
            Log.warn("汽水音乐音量: 没有接口 token，不动音量")
            return
        }
        guard let url = URL(string: "http://\(deviceHost):\(devicePort)/key") else { return }
        for index in 0..<count {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(token, forHTTPHeaderField: "X-Auth-Token")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["keys": keys])
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status != 200 {
                    Log.warn("汽水音乐音量: 按键被拒（HTTP \(status)）")
                }
            } catch {
                let nsError = error as NSError
                Log.warn("汽水音乐音量: 按键发送失败（code=\(nsError.code) \(nsError.localizedDescription)）")
                return   // 连不上就别按剩下几下了
            }
            if index < count - 1 {
                try? await Task.sleep(for: Self.stepInterval)
            }
        }
    }

    /// 汽水音乐在运行吗（只认汽水音乐一个 App）。
    private static func isSodaRunning() -> Bool {
        let bundleID = AudioAppRegistry.bundleID(for: "汽水音乐")
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// 接口 token：环境变量优先，否则读 esp32-hid-lab 仓里那一份。
    private static func apiToken() -> String? {
        if let token = ProcessInfo.processInfo.environment["HID_TOKEN"], !token.isEmpty {
            return token
        }
        guard let text = try? String(contentsOf: URL(fileURLWithPath: tokenFilePath), encoding: .utf8) else {
            return nil
        }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}
