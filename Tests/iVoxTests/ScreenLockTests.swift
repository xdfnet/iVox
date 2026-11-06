import XCTest
@testable import iVox

/// 屏幕锁判据：**会话字典里那个键怎么读**。
///
/// 判据本身是实测出来的（2026-11-06）：锁屏时 `CGSSessionScreenIsLocked` = 1，
/// 解锁后**键消失**（不是变成 0）。读法错了，锁屏就判不出来。
final class ScreenLockTests: XCTestCase {

    /// 锁屏：键 = 1 → 锁着
    func testLockedWhenKeyIsOne() {
        XCTAssertTrue(ScreenLock.isLocked(session: ["CGSSessionScreenIsLocked": 1]),
                      "键 = 1 → 屏幕锁着")
    }

    /// 解锁：键消失 → 没锁
    func testUnlockedWhenKeyAbsent() {
        XCTAssertFalse(ScreenLock.isLocked(session: [:]),
                       "键消失 → 没锁（实测解锁后就是这样，不是变成 0）")
    }

    /// 键 = 0 → 没锁
    func testUnlockedWhenKeyIsZero() {
        XCTAssertFalse(ScreenLock.isLocked(session: ["CGSSessionScreenIsLocked": 0]),
                       "键 = 0 → 没锁")
    }

    /// 系统给的是 NSNumber 也认（别只认 Swift 原生 Int）
    func testAcceptsNSNumber() {
        XCTAssertTrue(ScreenLock.isLocked(session: ["CGSSessionScreenIsLocked": NSNumber(value: 1)]),
                      "NSNumber(1) 也该判成锁着")
    }

    /// 别的键在不在，不影响判据
    func testIgnoresOtherKeys() {
        let session: [String: Any] = [
            "kCGSSessionUserNameKey": "admin",
            "kCGSSessionOnConsoleKey": 1,
        ]
        XCTAssertFalse(ScreenLock.isLocked(session: session),
                       "别的键不改变判据")
    }
}
