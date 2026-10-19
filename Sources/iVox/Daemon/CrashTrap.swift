import Darwin
import Foundation
import iVoxKit

// 崩溃捕获：MLX 后端崩在 C++ 层时，系统日志里只有一行
// `mutex lock failed: Invalid argument`，没有调用栈，事后无从判断是哪个路径撞上去的
// （2026-10-18 两次「整摞没念完」都查到这里就断了）。这里把崩溃信号接住，
// 往 ~/.config/ivox/crash.log 写一份带**调用栈**的记录，并在下次启动时打进 daemon.log。
//
// ⚠️ 信号处理函数里只能用异步信号安全的调用（write/fsync/backtrace），
// 不能碰 Swift 的 actor、分配、Logger——那些在信号到达时可能正好持有锁，死得更难看。
// 因此 fd 在 install() 时就打开好，handler 里只管写。

/// 崩溃日志的 fd。信号处理函数拿不到实例状态，只能靠这个全局；Swift 6 下全局可变状态
/// 要显式 `nonisolated(unsafe)` 才放行——这里安全，因为只在 install()（单线程启动期）
/// 写一次，之后全是只读。
private nonisolated(unsafe) var crashLogFD: Int32 = -1

/// 历史崩溃累计次数，跨重启累计：crash.log 每次启动就被清空，单靠它编号永远是 #1。
/// 单独落一个小文件存，只在启动期读写一次。
private nonisolated(unsafe) var crashCount: Int = 0

/// 崩溃后由系统调进来：不返回，把现场写盘再退掉，让 launchd 拉起新进程。
/// 队列是纯内存的，进程一换全丢——所以这几行是「那一摞为什么没念完」的唯一线索。
/// 必须是顶层函数：Swift 只允许把顶层 `func` 的引用转成 C 函数指针。
private func ivoxCrashHandler(_ sig: Int32) {
    guard crashLogFD >= 0 else { _exit(128 + sig) }
    var banner = "[崩溃] \(ISO8601DateFormatter().string(from: Date())) 信号 \(sig) (\(CrashTrap.signalName(sig)))\n"
    write(crashLogFD, banner, strlen(banner))
    // backtrace 第一次调用会动态链接 libgcc，严格说不是异步信号安全的；
    // 但这是拿到调用栈的唯一途径，且真出二次异常也只是栈缺一块，比完全没有强。
    var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
    let n = backtrace(&frames, 64)
    backtrace_symbols_fd(&frames, n, crashLogFD)
    write(crashLogFD, "--- 崩溃结束 ---\n", 17)
    fsync(crashLogFD)
    _exit(128 + sig)
}

enum CrashTrap {
    static func install() {
        let path = crashLogPath()
        try? FileManager.default.createDirectory(
            atPath: AppPaths.configDir, withIntermediateDirectories: true)
        // 顺序要紧：先把上次崩溃的记录报走并**原地截断**这份文件，再打开 fd。
        // 反过来做会毁掉记录——`String.write(toFile:)` 是「写临时文件 + rename」，
        // 换掉了 inode；随后 open 拿到的 fd 指向的旧 inode 已无人可见，
        // 本次崩溃的调用栈就写进了一个看不见的孤儿文件（crash.log 恒为 0 字节）。
        reportPreviousCrash()
        crashLogFD = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard crashLogFD >= 0 else {
            Log.warn("崩溃捕获：打不开 \(path)，本次崩溃将没有调用栈")
            return
        }
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE] {
            signal(sig, ivoxCrashHandler)
        }
    }

    /// 上次崩溃留下的记录在 daemon.log 里报一声（编号接着上次往后排），并把
    /// crash.log 腾空。不清空的话它会一直躺在那儿，下次真崩了日志会混在一起。
    /// 截断用 `ftruncate` 对文件本身做，不换 inode——见 install() 的注释。
    private static func reportPreviousCrash() {
        let path = crashLogPath()
        if let prev = try? String(contentsOfFile: crashCountPath(), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let n = Int(prev) {
            crashCount = n
        }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8), !text.isEmpty else {
            try? String(crashCount).write(toFile: crashCountPath(), atomically: true, encoding: .utf8)
            return
        }
        let records = text.components(separatedBy: "--- 崩溃结束 ---")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        for (i, r) in records.enumerated() {
            let head = r.split(separator: "\n").first.map(String.init) ?? "?"
            Log.warn("崩溃记录 #\(i + crashCount + 1)：\(head)｜完整栈见 \(path)")
            // 栈也进 daemon.log：只看 crash.log 容易忘，而多行日志不便 grep
            for line in r.split(separator: "\n").dropFirst().prefix(12) {
                Log.warn("  \(line)")
            }
        }
        let fd = open(path, O_WRONLY)
        if fd >= 0 { ftruncate(fd, 0); close(fd) }
        crashCount += records.count
        try? String(crashCount).write(toFile: crashCountPath(), atomically: true, encoding: .utf8)
    }

    static func signalName(_ sig: Int32) -> String {
        switch sig {
        case SIGABRT: "SIGABRT 进程中止"
        case SIGSEGV: "SIGSEGV 内存越界"
        case SIGBUS: "SIGBUS 总线错误"
        case SIGILL: "SIGILL 非法指令"
        case SIGFPE: "SIGFPE 浮点异常"
        default: "信号 \(sig)"
        }
    }

    private static func crashLogPath() -> String {
        (AppPaths.configDir as NSString).appendingPathComponent("crash.log")
    }

    private static func crashCountPath() -> String {
        (AppPaths.configDir as NSString).appendingPathComponent("crash.count")
    }
}
