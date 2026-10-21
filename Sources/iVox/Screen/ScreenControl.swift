import CryptoKit
import Foundation
import iVoxKit

// 屏幕锁：锁屏与解锁两件事，都走 HID 真键。
//
// 为什么不合成按键：macOS 锁屏后**不把 CGEvent 合成键交给 loginwindow**——
// 合成键能锁屏，**醒不来**（仓库自己的 Web 控制台 lock 动作早就写明了这一点：
// 「屏幕已锁定，无法通过软件唤醒」）。解锁只能靠真硬件事件。
//
// 覆盖范围：**只做「锁屏」这一种**。重启后的解锁不在范围内——重启后要先进系统
// 才有 daemon，daemon 没起来就发不出解锁键。

/// 屏幕控制失败的原因。
enum ScreenError: LocalizedError, Sendable {
    /// 按键没发出去（设备离线、token 不对…）
    case hid(HidError)
    /// 密码取不出来
    case secretUnavailable

    var errorDescription: String? {
        switch self {
        case .hid(let error): return error.errorDescription ?? "按键没发出去"
        case .secretUnavailable: return "取不出登录密码"
        }
    }
}

/// 锁屏 / 解锁的执行者。
///
/// 静态方法就够：它没有自己的状态（要发的键、密码、时序都是固定的），
/// 真正的通道是 `HidInjector.shared` 那一个。用静态省掉「谁持有实例」这件事——
/// 命令行、Web 控制台、daemon 都调同一处。
actor ScreenControl {
    /// 锁屏键：Ctrl+Cmd+Q。
    private static let lockKeys = ["ctrl", "cmd", "q"]
    /// 唤醒键：只按一下 Ctrl（固件允许「只发修饰键」，见 `app_hid.c` 的 `hid_send_combo`）。
    private static let wakeKeys = ["ctrl"]
    /// 唤醒后等锁屏界面出来。
    private static let wakeDelay: Duration = .seconds(2)
    /// 打完密码等一下再回车。
    private static let beforeEnterDelay: Duration = .milliseconds(500)

    /// 锁屏。
    static func lock() async -> Result<Void, ScreenError> {
        let task = await HidInjector.shared.press(lockKeys)
        switch await task.value {
        case .success:
            Log.info("屏幕: 已锁屏")
            return .success(())
        case .failure(let error):
            Log.warn("屏幕: 锁屏失败（\(error.errorDescription ?? "未知原因")）")
            return .failure(.hid(error))
        }
    }

    /// 解锁：按一下 Ctrl 唤醒 → 等锁屏界面 → 输密码 → 等一下 → 回车。
    ///
    /// 锁屏界面输字符即跳到密码框，所以「输密码」这一步顺带就把密码框唤出来了。
    static func unlock() async -> Result<Void, ScreenError> {
        guard let password = loginPassword else {
            Log.error("屏幕: 取不出登录密码")
            return .failure(.secretUnavailable)
        }
        // 1. 按一下 Ctrl 唤醒屏幕
        let wake = await HidInjector.shared.press(wakeKeys)
        if case .failure(let error) = await wake.value {
            Log.warn("屏幕: 唤醒失败（\(error.errorDescription ?? "未知原因")）")
            return .failure(.hid(error))
        }
        // 2. 等锁屏界面出来
        try? await Task.sleep(for: wakeDelay)
        // 3. 输密码（**内容不进日志**——密码就走这条通道打）
        let typed = await HidInjector.shared.typeText(password)
        if case .failure(let error) = await typed.value {
            Log.warn("屏幕: 输密码失败（\(error.errorDescription ?? "未知原因")）")
            return .failure(.hid(error))
        }
        // 4. 等一下
        try? await Task.sleep(for: beforeEnterDelay)
        // 5. 回车
        let enter = await HidInjector.shared.press(["enter"])
        switch await enter.value {
        case .success:
            Log.info("屏幕: 已解锁")
            return .success(())
        case .failure(let error):
            Log.warn("屏幕: 解锁失败（\(error.errorDescription ?? "未知原因")）")
            return .failure(.hid(error))
        }
    }

    /// 这一项的健康度：注入设备在不在线（它是这条能力唯一的依赖）。
    static func health() async -> String {
        switch await HidInjector.shared.reachable {
        case .some(true): return "ok"
        case .some(false): return "error:注入设备不可达"
        case .none: return "loading"
        }
    }

    // MARK: - 密码

    /// 登录密码（AES-GCM 密文 + nonce，密钥见下）。
    ///
    /// **安全边界**：密文与密钥都在二进制里 → 挡住的是「明文出现在源码 / 日志 / 命令行」，
    /// **挡不住逆向**（拿到二进制就能解开）。要更强就把密钥挪进钥匙串，改这一处即可。
    private static let secretKeyBase64 = "LFDGJOdWDhBLw6FdqnjP0P87Mcd3ozqONTlmC/rbUeg="
    private static let secretNonceBase64 = "uHo0YRpuE19uUB5c"
    private static let secretCipherBase64 = "KeMIU7xGgYjPYYiQkUY5g3XSyWIe"

    /// 解出登录密码；解不开就返回 nil（**不猜、不回退成明文**）。
    private static var loginPassword: String? {
        guard let keyData = Data(base64Encoded: secretKeyBase64),
              let nonceData = Data(base64Encoded: secretNonceBase64),
              let cipherData = Data(base64Encoded: secretCipherBase64) else { return nil }
        let nonce = try? AES.GCM.Nonce(data: nonceData)
        guard let nonce else { return nil }
        let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: cipherData.dropLast(16), tag: cipherData.suffix(16))
        guard let box else { return nil }
        guard let plain = try? AES.GCM.open(box, using: SymmetricKey(data: keyData)) else { return nil }
        return String(data: plain, encoding: .utf8)
    }
}
