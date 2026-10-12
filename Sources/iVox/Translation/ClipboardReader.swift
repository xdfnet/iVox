import AppKit
import Foundation
import iVoxKit

/// 「模拟 Cmd+C → 等剪贴板更新 → 读出选中文本」。
///
/// 与 iDict 的关键差异：**加了 `changeCount` 校验**。iDict 只 `sleep(50ms)` 就盲读，
/// 在 daemon 里遇到慢应用（Electron / 大型 IDE）经常来不及写入，会拿到**上一次**剪贴板内容
/// —— 表现为"翻译出来的东西跟选中文本对不上"。这里轮询到剪贴板真的变了才读。
@MainActor
enum ClipboardReader {
    /// 发一次 Cmd+C 并等剪贴板变化，返回其中的文本。
    /// - Parameter maxWaitMs: 最长等待；超时后退回直接读当前内容（可能仍是有效结果）。
    static func copyAndRead(maxWaitMs: Int = 300) async -> String? {
        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount

        do {
            try await KeyboardSimulator.simulateCopy()
        } catch {
            Log.warn("模拟 Cmd+C 失败：\(error.localizedDescription)")
            return nil
        }

        let stepMs = 10
        var waited = 0
        while waited < maxWaitMs {
            if pasteboard.changeCount != before {
                return pasteboard.string(forType: .string)
            }
            try? await Task.sleep(nanoseconds: UInt64(stepMs) * 1_000_000)
            waited += stepMs
        }

        // 超时：不回退到空，直接读当前内容（选中同一段文本时 changeCount 本就不会变）
        Log.debug("Cmd+C 后剪贴板 \(maxWaitMs)ms 未变化，直接读取当前内容")
        return pasteboard.string(forType: .string)
    }
}
