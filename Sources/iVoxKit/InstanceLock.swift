import Darwin
import Foundation

/// 实例独占锁：同一把锁同一时刻只允许一个进程持有。
///
/// **为什么 socket 挡不住**：第二个 daemon 启动时会 unlink 掉 socket 再 bind，
/// 于是先跑的那个还活着（**还占着全局热键、麦克风**），却再也收不到命令——
/// 机器上看着「就一个 daemon」，实际是两个（2026-10-26 实测：前台手起的那份
/// 和 launchd 托管的那份并存过）。锁加在**进程级**：抢不到就自己退出，
/// 宁可没服务，也不要两份并存。
///
/// 锁由内核持有：**进程一死，锁自动释放**（不用管清理，也不会留下"假占位"）。
/// 锁文件本身留着，里面记着持有者的 pid 与启动时间，`ivox status` 读它。

public enum InstanceLock {
    /// 锁的持有凭证。**fd 必须一直开着**——关掉就等于放锁。
    public struct Holder: Sendable {
        public let fd: Int32
        public let path: String
        public let pid: Int32
    }

    public enum AcquireError: Error, CustomStringConvertible {
        /// 锁已被别人拿着（pid 读不到时为 nil）
        case held(pid: Int32?, path: String)
        /// 打不开锁文件 / 加锁失败
        case failed(String)

        public var description: String {
            switch self {
            case .held(let pid, let path):
                let who = pid.map { "pid=\($0)" } ?? "持有者未知"
                return "已有一个实例在跑（\(who)，锁 \(path)）"
            case .failed(let message):
                return message
            }
        }
    }

    /// 抢到的锁**存在这里**（进程活多久，锁就持有多久）。
    /// 单独存一份是刻意的：局部变量可能被 ARC 提前回收，而锁一旦被放掉，
    /// 闸门就形同虚设（第二个 daemon 立刻能进来）。
    private nonisolated(unsafe) static var retained: Holder?

    /// 抢锁。成功返回凭证（**调用方要一直持有它**，进程退出即释放）。
    ///
    /// - Parameter path: 锁文件路径（见 `AppPaths.lockPath`：跟 socket 同名同目录）
    public static func acquire(path: String) throws -> Holder {
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            throw AcquireError.failed("打不开锁文件 \(path)：\(String(cString: strerror(errno)))")
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK {
                throw AcquireError.held(pid: readPid(path), path: path)
            }
            throw AcquireError.failed("加锁失败 \(path)：\(String(cString: strerror(code)))")
        }
        // 记下持有者：pid + 启动时刻（status 要念给人听）
        let stamp = "\(getpid()) \(Int(Date().timeIntervalSince1970))\n"
        ftruncate(fd, 0)
        lseek(fd, 0, SEEK_SET)
        stamp.withCString { _ = write(fd, $0, strlen($0)) }
        let holder = Holder(fd: fd, path: path, pid: getpid())
        retained = holder
        return holder
    }

    /// 查锁现在有没有人拿着。**不靠文件在不在**——进程死了文件还在，
    /// 拿锁试一下才知道真相（flock 试锁成功 = 没人持有）。
    ///
    /// - Returns: (持有者 pid, 是否有人持有)
    public static func holder(path: String) -> (pid: Int32?, held: Bool) {
        let fd = open(path, O_RDWR)
        guard fd >= 0 else { return (nil, false) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let pid = readPid(path)
            close(fd)
            return (pid, true)
        }
        // 试锁成功 = 没人拿着；顺手放开，别把别人的锁抢了
        flock(fd, LOCK_UN)
        close(fd)
        return (nil, false)
    }

    /// 锁文件里记的 pid（读不到就是 nil）
    private static func readPid(_ path: String) -> Int32? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let first = text.split(separator: " ").first.flatMap { Int32($0) }
        return first
    }
}
