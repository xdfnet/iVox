import Darwin
import Foundation
import iVoxKit

// 进程退出时留证：**把退出的调用栈写进日志**。
//
// 为什么要有它：2026-10-26 实测，守护进程一天退了好几次，launchd 只留下一句
// 「exited due to exit(0)」（自己调用 exit(0) 退的，不是崩、不是被杀），
// 而守护进程自己的日志里**一个字都没有**——退出路径明明写了日志、还刷了盘，
// 那些行就是不在。于是「谁让退的」永远查不出（今天手工发一次停止指令验证过：
// 那行日志老老实实落了盘，说明刷盘是好的，所以线上的退出**不是走那两条路**）。
//
// 这个钩子在 `atexit` 里把退出的调用栈**同步**写进 daemon.log：
// 不管从哪条路退的，下一次就能当场看出是哪条路。

enum ExitTrace {
    /// 装钩子（进程起来时调一次）。
    static func install() {
        atexit { ExitTrace.recordExit() }
    }

    /// atexit 回调：不能带上下文，所以走一个静态方法。
    private static func recordExit() {
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 32)
        let count = Int(backtrace(&frames, Int32(frames.count)))
        var lines = ["[退出] 进程退出（atexit），退出时的调用栈："]
        if count > 0, let symbols = backtrace_symbols(&frames, Int32(count)) {
            for i in 0..<count {
                guard let symbol = symbols[i] else { continue }
                lines.append("  " + String(cString: symbol))
            }
            free(symbols)
        }
        appendToLog(lines.joined(separator: "\n") + "\n")
    }

    /// 同步写：atexit 里不能再排队（进程马上就退，队列里的写会丢）。
    private static func appendToLog(_ text: String) {
        let path = AppPaths.daemonLogPath
        let data = Data(text.utf8)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: data)
            return
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
