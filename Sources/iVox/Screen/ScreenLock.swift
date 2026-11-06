import CoreGraphics
import Foundation
import iVoxKit

// 屏幕锁状态：**「屏上没人看」的判据**，也是浮层停摆的唯一依据。
//
// 判据：`CGSessionCopyCurrentDictionary()` 里的 `CGSSessionScreenIsLocked`。
// 实测（2026-11-06）：锁屏时该键 = 1，解锁后键消失。
//
// **为什么不用别的**（都实测过）：
// · 「前台 App 是不是 com.apple.loginwindow」→ 不准：2026-11-06 12:37:08 那次锁屏，
//   前台一直是 VSCode，判不出来。
// · `NSWorkspace.sessionDidResignActive/BecomeActive` → **锁屏解锁全程一个都不发**，
//   拿它当触发器等于永远收不到。
// · Darwin 通知 `com.apple.screenIsLocked` → 同样不发。
// 所以只能**轮询**（一次 88µs，1 秒一轮，代价可忽略）。

/// 屏幕锁判据（无状态、随手可问）。
enum ScreenLock {
    /// 现在屏幕锁着吗。
    ///
    /// 直接查系统会话字典——**不缓存**，调用方自己决定要不要缓存。
    static func isLocked() -> Bool {
        isLocked(session: CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:])
    }

    /// 纯逻辑：会话字典 → 锁着没（便于单测，不碰系统）。
    ///
    /// 键不存在 = 没锁（实测：解锁后键消失，不是变成 0）。
    static func isLocked(session: [String: Any]) -> Bool {
        (session["CGSSessionScreenIsLocked"] as? NSNumber)?.intValue == 1
    }
}

/// 屏幕锁监视器：轮询判据，变了就通知。
///
/// **为什么是轮询不是通知**：见文件头——系统在这件事上不发任何通知（2026-11-06 实测）。
@MainActor
final class ScreenLockMonitor {
    /// 变化时叫（`true` = 刚锁上）
    var onChange: ((Bool) -> Void)?

    private var timer: Timer?
    /// 当前状态（**构造时的初值也算**——daemon 可能一启动屏幕就锁着，
    /// 那时没有「变化」，订阅者得自己来问一句当前值）
    private(set) var locked: Bool

    /// 轮询间隔（秒）。锁屏是用户动作，1 秒足够快。
    private static let interval: TimeInterval = 1

    init() {
        locked = ScreenLock.isLocked()
        Log.info("屏幕锁监视器: 启动，当前\(locked ? "已锁" : "未锁")")
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    /// 拆掉定时器（`isolated deinit`：定时器挂在主线程，清理也得在主线程）。
    isolated deinit {
        timer?.invalidate()
    }

    /// 查一次，变了就通知。
    private func poll() {
        let now = ScreenLock.isLocked()
        guard now != locked else { return }
        locked = now
        Log.info("屏幕锁: \(now ? "已锁" : "已解锁")")
        onChange?(now)
    }
}
