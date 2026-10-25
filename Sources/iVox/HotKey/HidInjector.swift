import Foundation
import iVoxKit

// HID 注入通道：把「像人那样按键」发给常驻的 ESP32-S3 注入设备（真硬件事件）。
//
// 为什么不用 CGEvent 合成：① 有些 App 丢弃合成键（汽水音乐实测：音量键毫无反应）；
// ② **锁屏后 macOS 根本不把合成键交给 loginwindow** —— 合成键能锁屏，醒不来。
// 设备把自己枚举成这台 Mac 的 USB HID 键盘，固件再按局域网 HTTP 指令发键。
//
// 为什么是 actor：一次只发一批。这保证「降 5 击」先于「升 5 击」、也保证解锁序列的先后；
// 调用方入队即返回，不占着 actor 等网络往返（主流程该干什么干什么）。

/// HID 注入失败的原因（分得比「发送失败」细，便于排查时看日志就知道卡在哪）。
enum HidError: LocalizedError, Sendable {
    /// 没有接口 token：设备端会回 401，先说明是自己这边的配置问题。
    /// 带**找过的路径**——仓改名/搬家后一眼看出是哪次改名害的。
    case tokenMissing(searched: [String])
    /// 设备连不上（离线 / 地址不对 / 路由不通）
    case deviceUnreachable(String)
    /// 设备回了非 200（401 token 不对、429 队列满…）
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .tokenMissing(let searched):
            return "缺少设备接口 token（找过：\(searched.joined(separator: "、"))）"
        case .deviceUnreachable(let detail): return "设备不可达（\(detail)）"
        case .httpStatus(let code): return "设备返回 HTTP \(code)"
        }
    }
}

/// HID 注入器：唯一的「往系统里发键」通道。
///
/// 单例是因为它对应**一台物理设备、一条通道**——不是谁的状态，是那条链路的状态。
actor HidInjector {
    static let shared = HidInjector()

    /// 设备地址（静态 IP，见 esp32-lab 的 README）。
    private static let host = "192.168.100.3"
    private static let port = 80

    /// 接口 token：环境变量 `HID_TOKEN` 优先，否则读 lab 仓里那一份——
    /// 那就是烧进板子里的同一个值（单一真源，不抄第二份）。
    ///
    /// **路径不写死一个**：仓改名是常事（esp32-hid-lab → esp32-lab 就发生过，
    /// 2026-10-25 因为路径失效，汽水音乐压音量全程没发出去，日志只说「缺少 token」）。
    /// 现在按候选列表找，`HID_TOKEN_FILE` 可覆盖；都找不到时报错会**列出找过的路径**。
    private static let tokenFileCandidates = [
        "/Users/admin/iCode/esp32-lab/firmware/s3-hid/main/api_token",
        "/Users/admin/iCode/esp32-hid-lab/main/api_token",
    ]

    /// 发送链：新来的排在上一批后面，保证顺序。
    private var chain: Task<Result<Void, HidError>, Never>?

    /// 上次探到设备在不在线（nil = 还没探过）。`ivox status` 要报这条能力的健康度，
    /// 不能每次查询都去等一次网络——所以探一次、记下来，发键的成败也顺手更新它。
    private var lastReachable: Bool?

    /// 上次探到的结果（nil = 还没探过）。
    var reachable: Bool? { lastReachable }

    /// 探一次设备在不在线（`GET /status`，固件那边免鉴权）。
    @discardableResult
    func probe() async -> Bool {
        let ok = await Self.probeOnce()
        lastReachable = ok
        return ok
    }

    /// 按一组键 `times` 次，每次之间隔 `interval`。
    ///
    /// 返回一个 Task：**入队即返回**，要等真的发完就 `await` 它；
    /// 不 await 就是「发出去就走」（不占主流程）。
    @discardableResult
    func press(_ keys: [String], times: Int = 1, interval: Duration = .milliseconds(0)) async -> Task<Result<Void, HidError>, Never> {
        enqueue { try await Self.sendKeys(keys, times: times, interval: interval) }
    }

    /// 打一段文本（走固件的 `/type`；固件逐字符发，密码这类短文本正合适）。
    @discardableResult
    func typeText(_ text: String) async -> Task<Result<Void, HidError>, Never> {
        enqueue { try await Self.sendText(text) }
    }

    /// 把一批动作接到发送链末尾。
    private func enqueue(_ work: @escaping @Sendable () async throws -> Void) -> Task<Result<Void, HidError>, Never> {
        let previous = chain
        let task: Task<Result<Void, HidError>, Never> = Task.detached {
            _ = await previous?.value
            do {
                try await work()
                await self.markReachable(true)
                return .success(())
            } catch let error as HidError {
                await self.markReachable(false)
                return .failure(error)
            } catch {
                await self.markReachable(false)
                return .failure(.deviceUnreachable(error.localizedDescription))
            }
        }
        chain = task
        return task
    }

    private func markReachable(_ reachable: Bool) {
        lastReachable = reachable
    }

    /// 探一次设备在不在（`GET /status` 免鉴权）。
    private static func probeOnce() async -> Bool {
        guard let url = URL(string: "http://\(host):\(port)/status") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// 逐次发按键，每次之间隔 `interval`（最后一次不隔）。
    private static func sendKeys(_ keys: [String], times: Int, interval: Duration) async throws {
        let token = try apiToken()
        let url = try keyURL()
        for index in 0..<max(times, 0) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(token, forHTTPHeaderField: "X-Auth-Token")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["keys": keys])
            try await send(request)
            if index < times - 1 {
                try await Task.sleep(for: interval)
            }
        }
    }

    /// 发一段文本。**文本内容不进日志**——密码就靠这条通道打。
    private static func sendText(_ text: String) async throws {
        let token = try apiToken()
        var request = URLRequest(url: try textURL())
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-Auth-Token")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])
        try await send(request)
    }

    private static func send(_ request: URLRequest) async throws {
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw HidError.httpStatus(status) }
        } catch let error as HidError {
            throw error
        } catch {
            throw HidError.deviceUnreachable(error.localizedDescription)
        }
    }

    private static func keyURL() throws -> URL {
        guard let url = URL(string: "http://\(host):\(port)/key") else {
            throw HidError.deviceUnreachable("设备地址拼不出来")
        }
        return url
    }

    private static func textURL() throws -> URL {
        guard let url = URL(string: "http://\(host):\(port)/type") else {
            throw HidError.deviceUnreachable("设备地址拼不出来")
        }
        return url
    }

    /// 接口 token：环境变量优先，否则读 lab 仓里那一份。
    private static func apiToken() throws -> String {
        if let token = ProcessInfo.processInfo.environment["HID_TOKEN"], !token.isEmpty {
            return token
        }
        var searched: [String] = []
        var paths: [String] = []
        if let override = ProcessInfo.processInfo.environment["HID_TOKEN_FILE"], !override.isEmpty {
            paths.append(override)
        }
        paths.append(contentsOf: tokenFileCandidates)
        for path in paths {
            searched.append(path)
            if let token = readToken(at: path) { return token }
        }
        throw HidError.tokenMissing(searched: searched)
    }

    /// 读一个 token 文件（空文件当没有）。
    private static func readToken(at path: String) -> String? {
        guard let text = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) else {
            return nil
        }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}
