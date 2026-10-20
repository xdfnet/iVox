import ApplicationServices
import CoreGraphics
import Foundation

// 模拟按键（Cmd+C）。

/// 模拟 Cmd+C（取当前选中文本）。
/// 搬自 iDict `KeyboardSimulator.swift`，差异：时间常量内联、错误类型精简、
/// 不再自带权限检查（由调用方 `ClipboardReader` 统一判断与提示）。
enum KeyboardSimulator {
    private static let keyC: CGKeyCode = 0x08
    private static let keyCommand: CGKeyCode = 0x37
    /// 两次按键之间的间隔，模拟真人节奏，确保目标 app 能正确处理
    private static let keyPressInterval: UInt64 = 2_000_000   // 2ms

    enum SimulatorError: LocalizedError {
        case eventCreationFailed

        var errorDescription: String? {
            switch self {
            case .eventCreationFailed: return "创建键盘事件失败（需要「输入监控」权限）"
            }
        }
    }

    /// 依次投递 Cmd↓ → C↓ → C↑ → Cmd↑ 到 HID 层。
    static func simulateCopy() async throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw SimulatorError.eventCreationFailed
        }
        let sequence: [(keyCode: CGKeyCode, isDown: Bool)] = [
            (keyCommand, true),
            (keyC, true),
            (keyC, false),
            (keyCommand, false),
        ]
        for (index, step) in sequence.enumerated() {
            guard let event = CGEvent(
                keyboardEventSource: source, virtualKey: step.keyCode, keyDown: step.isDown
            ) else {
                throw SimulatorError.eventCreationFailed
            }
            // 除「Cmd 抬起」外都带 Command 修饰符
            if step.keyCode != keyCommand || step.isDown {
                event.flags = .maskCommand
            }
            event.post(tap: .cghidEventTap)
            if index < sequence.count - 1 {
                try await Task.sleep(nanoseconds: keyPressInterval)
            }
        }
    }
}
