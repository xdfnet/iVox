import ApplicationServices
import CoreGraphics
import Foundation

// 模拟按键（Cmd+C / Cmd+V）。
//
// 放 iVoxKit：翻译（取剪贴板）和快速操作（粘贴）两个能力域都要用同一套，
// 散成两份迟早漂——尤其这里的**事件序列形状**很挑（见 send 的说明）。

/// 模拟 Cmd+C（取当前选中文本）。
/// 搬自 iDict `KeyboardSimulator.swift`，差异：时间常量内联、错误类型精简、
/// 不再自带权限检查（由调用方 `ClipboardReader` 统一判断与提示）。
public enum KeyboardSimulator {
    private static let keyC: CGKeyCode = 0x08
    private static let keyV: CGKeyCode = 0x2B
    private static let keyCommand: CGKeyCode = 0x37
    /// 两次按键之间的间隔，模拟真人节奏，确保目标 app 能正确处理
    private static let keyPressInterval: UInt64 = 2_000_000   // 2ms

    /// **自己合成出去的按键**带这个标记，键盘事件层据此放过它们。
    /// 粘贴要发一个 Cmd+V，它也会经过那个 tap——不标一下，用户把某动作绑成
    /// Cmd+V 时，粘贴会连锁触发它。
    public static let syntheticEventMarker: Int64 = 0x156E

    enum SimulatorError: LocalizedError {
        case eventCreationFailed

        var errorDescription: String? {
            switch self {
            case .eventCreationFailed: return "创建键盘事件失败（需要「输入监控」权限）"
            }
        }
    }

    /// 依次投递 Cmd↓ → C↓ → C↑ → Cmd↑ 到 HID 层。
    public static func simulateCopy() async throws {
        try await send([(keyCommand, true), (keyC, true), (keyC, false), (keyCommand, false)])
    }

    /// 依次投递 Cmd↓ → V↓ → V↑ → Cmd↑ 到 HID 层（把剪贴板贴到当前光标处）。
    public static func simulatePaste() async throws {
        try await send([(keyCommand, true), (keyV, true), (keyV, false), (keyCommand, false)])
    }

    /// **序列形状很挑**：必须是「Command 键真的按下 → 字母键按下 → 字母键抬起 → Command 抬起」四步。
    /// 只发字母键、把 Command 挂在 flag 上，目标 app **收不到**（TextEdit / Terminal 实测：
    /// 粘贴成了空操作）。Command 的按下/抬起必须是独立事件——app 是靠它更新修饰键状态的。
    private static func send(_ sequence: [(keyCode: CGKeyCode, isDown: Bool)]) async throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw SimulatorError.eventCreationFailed
        }
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
            event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
            event.post(tap: .cghidEventTap)
            if index < sequence.count - 1 {
                try await Task.sleep(nanoseconds: keyPressInterval)
            }
        }
    }
}
