import Foundation
import os.log

// 日志：同时写 os_log 与日志文件（0600，5MB 轮转）。
// 默认落在 ~/.config/ivox/daemon.log；子进程（誊清员等）用 IVOX_LOG_FILE 改写自己的
// 文件名 —— 拆成独立进程后「谁没干好」要看哪个文件才能一眼判定，混在一个文件里
// 就又回到 2026-10-19 晚上那种翻三轮日志才定案的局面。

private let maxLogSize: UInt64 = 5 * 1024 * 1024

/// 日志级别门限，低于它的直接丢弃（os_log 也一起省掉）。
/// DEBUG 无门限——高频路径打得太密，落盘会淹掉真正要查的 INFO。
private enum LogLevel: Int, Comparable {
    case debug = 0, info = 1, warn = 2, error = 3

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum Log {
    private static let subsystem = "com.user.ivox"
    private static let log = OSLog(subsystem: subsystem, category: "daemon")
    private static let fileQueue = DispatchQueue(label: "com.user.ivox.filelog")

    private static let filePath: String = {
        if let override = ProcessInfo.processInfo.environment["IVOX_LOG_FILE"], !override.isEmpty {
            return NSString(string: override).expandingTildeInPath
        }
        return AppPaths.daemonLogPath   // 文件名只在 AppPaths 一处定义
    }()

    /// 本进程的角色（daemon / queue / tts / …）。写进每一行，是「谁犯的错」的
    /// 第一现场判据：即使哪天几个文件又合到一起，逐行看角色仍分得清。
    /// 由子进程启动时用 IVOX_ROLE 指定。
    static let role: String = {
        let r = ProcessInfo.processInfo.environment["IVOX_ROLE"] ?? ""
        return r.isEmpty ? "daemon" : r
    }()

    /// 默认只留 INFO 及以上；排查时 `IVOX_LOG_LEVEL=debug` 重启守护进程即可放出 DEBUG。
    /// 认不出 / 没设一律按 info 处理——静默降级不该让人查不了日志。
    private static let level: LogLevel = {
        switch ProcessInfo.processInfo.environment["IVOX_LOG_LEVEL"]?.lowercased() {
        case "debug": return .debug
        case "warn": return .warn
        case "error": return .error
        default: return .info
        }
    }()

    public static func info(_ message: String) {
        guard level <= .info else { return }
        os_log("%{public}s", log: log, type: .info, message)
        writeFile("INFO", message)
    }

    public static func error(_ message: String) {
        guard level <= .error else { return }
        os_log("%{public}s", log: log, type: .error, message)
        writeFile("ERROR", message)
    }

    public static func warn(_ message: String) {
        guard level <= .warn else { return }
        os_log("%{public}s", log: log, type: .info, message)
        writeFile("WARN", message)
    }

    public static func debug(_ message: String) {
        guard level <= .debug else { return }
        os_log("%{public}s", log: log, type: .debug, message)
        writeFile("DEBUG", message)
    }

    /// 确保所有挂起的写操作完成（CLI 进程退出前调用）
    public static func flush() {
        fileQueue.sync(flags: .barrier) {}
    }

    private static func writeFile(_ level: String, _ message: String) {
        fileQueue.async {
            // 行首固定四段：时间 / 级别 / 角色 / 正文。
            // 角色是给未来的归因工具（`ivox logs`，还没做）用的——它按列切这三段即可还原「哪个角色、
            // 什么时刻、干了什么」，不必依赖文件各自分开。
            let line = "\(timestamp()) [\(level)] [\(role)] \(message)\n"
            let data = Data(line.utf8)
            let dir = (filePath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)

            rotateIfNeeded()
            if !FileManager.default.fileExists(atPath: filePath) {
                FileManager.default.createFile(atPath: filePath, contents: data)
                // 日志含播报原文 / 微信消息 / ASR 转写，别让同机其他用户读到
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: filePath)
                return
            }
            guard let handle = FileHandle(forWritingAtPath: filePath) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    private static func rotateIfNeeded() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: filePath),
              let size = attrs[.size] as? UInt64,
              size > maxLogSize else { return }
        let bak = filePath + ".old"
        try? fm.removeItem(atPath: bak)
        try? fm.moveItem(atPath: filePath, toPath: bak)
    }

    private static func timestamp() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return df.string(from: Date())
    }
}
