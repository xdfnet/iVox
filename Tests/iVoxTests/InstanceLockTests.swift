import XCTest
@testable import iVoxKit

/// 实例独占锁的契约：同一把锁只允许一个进程；锁跟着 socket 走。
final class InstanceLockTests: XCTestCase {
    private func tempPath(_ name: String) -> String {
        NSTemporaryDirectory() + "ivox-lock-test-\(name)-\(UUID().uuidString).lock"
    }

    /// 抢到的人拿着；第二个抢不到，且报得出持有者的 pid。
    func testSecondAcquireIsRejected() throws {
        let path = tempPath("a")
        let first = try InstanceLock.acquire(path: path)
        XCTAssertEqual(first.pid, getpid())

        XCTAssertThrowsError(try InstanceLock.acquire(path: path)) { error in
            guard case InstanceLock.AcquireError.held(let pid, let file)? = error as? InstanceLock.AcquireError else {
                return XCTFail("应是「已被持有」，实际 \(error)")
            }
            XCTAssertEqual(pid, getpid())
            XCTAssertEqual(file, path)
        }
    }

    /// holder 说的是「现在有没有人拿着」，不是「文件在不在」——
    /// 进程死了锁自动释放，文件还留着（那不是占位）。
    func testStaleLockFileIsNotAHolder() throws {
        let path = tempPath("b")
        try "999999 0\n".write(toFile: path, atomically: true, encoding: .utf8)
        let (pid, held) = InstanceLock.holder(path: path)
        XCTAssertFalse(held, "没人持有的旧锁文件不该被当成有人占着")
        XCTAssertNil(pid)
    }

    /// 抢到之后 holder 要报得出来。
    func testHolderReportsOwner() throws {
        let path = tempPath("c")
        _ = try InstanceLock.acquire(path: path)
        let (pid, held) = InstanceLock.holder(path: path)
        XCTAssertTrue(held)
        XCTAssertEqual(pid, getpid())
    }

    /// 锁、誊清员 socket 都由主 socket 派生：**一个实例一套名字**，
    /// 两份实例不会抢同一个 socket、也不会抢同一把锁。
    func testPathsFollowTheSocket() {
        XCTAssertEqual(AppPaths.ttsSocketPath(for: "/tmp/ivox-debug.sock"), "/tmp/ivox-debug-tts.sock")
        XCTAssertEqual(AppPaths.lockPath(for: "/tmp/ivox-debug.sock"), "/tmp/ivox-debug.lock")
        // 默认值不能变：主 socket 是 ivox.sock，誊清员历来就叫 ivox-tts.sock
        XCTAssertEqual(AppPaths.ttsSocketPath, AppPaths.configDir + "/ivox-tts.sock")
        XCTAssertEqual(AppPaths.lockPath, AppPaths.configDir + "/ivox.lock")
    }

    /// IVOX_SOCKET 覆盖主 socket：调试实例跟正式那份彻底分家。
    func testSocketOverride() {
        let old = getenv("IVOX_SOCKET").map { String(cString: $0) }
        defer {
            if let old { setenv("IVOX_SOCKET", old, 1) } else { unsetenv("IVOX_SOCKET") }
        }
        setenv("IVOX_SOCKET", "/tmp/ivox-iso.sock", 1)
        XCTAssertEqual(AppPaths.socketPath, "/tmp/ivox-iso.sock")
        XCTAssertEqual(AppPaths.ttsSocketPath, "/tmp/ivox-iso-tts.sock")
        XCTAssertEqual(AppPaths.lockPath, "/tmp/ivox-iso.lock")
    }
}
