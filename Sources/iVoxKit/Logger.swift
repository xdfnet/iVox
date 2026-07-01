import Foundation
import os.log

private let maxLogSize: UInt64 = 5 * 1024 * 1024

public enum Log {
    private static let subsystem = "com.user.ivox"
    private static let log = OSLog(subsystem: subsystem, category: "daemon")
    private static let fileQueue = DispatchQueue(label: "com.user.ivox.filelog")
    private static let filePath = NSString(string: "~/.config/ivox/daemon.log").expandingTildeInPath

    public static func info(_ message: String) {
        os_log("%{public}s", log: log, type: .info, message)
        writeFile("INFO", message)
    }

    public static func error(_ message: String) {
        os_log("%{public}s", log: log, type: .error, message)
        writeFile("ERROR", message)
    }

    public static func warn(_ message: String) {
        os_log("%{public}s", log: log, type: .info, message)
        writeFile("WARN", message)
    }

    public static func debug(_ message: String) {
        os_log("%{public}s", log: log, type: .debug, message)
        writeFile("DEBUG", message)
    }

    /// 确保所有挂起的写操作完成（CLI 进程退出前调用）
    public static func flush() {
        fileQueue.sync(flags: .barrier) {}
    }

    private static func writeFile(_ level: String, _ message: String) {
        fileQueue.async {
            let line = "\(timestamp()) [\(level)] \(message)\n"
            let data = Data(line.utf8)
            let dir = (filePath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)

            rotateIfNeeded()
            if !FileManager.default.fileExists(atPath: filePath) {
                FileManager.default.createFile(atPath: filePath, contents: data)
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
