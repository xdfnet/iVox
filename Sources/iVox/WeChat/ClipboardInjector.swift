import Cocoa
import iVoxKit

// MARK: - 剪贴板注入

enum ClipboardInjector {

    /// 将文本复制到剪贴板并模拟 Cmd+V + Enter 注入到当前活动应用
    static func inject(_ text: String) throws {
        // 1. 写入剪贴板
        let pb = NSPasteboard.general
        pb.clearContents()
        guard pb.setString(text, forType: .string) else {
            throw InjectError.clipboardFailed
        }

        // 2. 小延迟等剪贴板就绪
        Thread.sleep(forTimeInterval: 0.05)

        // 3. 模拟 Cmd+V
        let source = CGEventSource(stateID: .hidSystemState)
        let vKey: CGKeyCode = 9

        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)

        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cghidEventTap)

        Thread.sleep(forTimeInterval: 0.1)

        // 4. 模拟 Enter
        let enterDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true)
        enterDown?.post(tap: .cghidEventTap)

        let enterUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false)
        enterUp?.post(tap: .cghidEventTap)
    }

    /// 使用 osascript 后备方案（需要辅助功能权限）
    static func injectViaAppleScript(_ text: String) throws {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard pb.setString(text, forType: .string) else {
            throw InjectError.clipboardFailed
        }
        Thread.sleep(forTimeInterval: 0.05)

        let script = """
        tell application "System Events" to keystroke "v" using command down
        delay 0.1
        tell application "System Events" to keystroke return
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw InjectError.osascriptFailed
        }
    }
}

enum InjectError: Error, LocalizedError {
    case clipboardFailed
    case osascriptFailed

    var errorDescription: String? {
        switch self {
        case .clipboardFailed: return "剪贴板写入失败"
        case .osascriptFailed: return "AppleScript 注入失败"
        }
    }
}
