@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import iVoxKit

// 全局键盘事件层：一个 tap，按归属路由给各消费者。

/// 全局键盘事件层。
///
/// 独占一个 CGEvent tap 与专用 run loop，按事件类型 / keyCode 把事件**路由**出去；
/// 它本身不含任何业务判断——谁关心右⌘、谁关心 Cmd+D，由订阅方决定。
///
/// 之所以单独成层：原先把 tap 埋在 `SpeechInputService` 里、只收修饰键。现在还要接
/// Cmd+D、Opt+Z… 若继续塞进语音服务，就成了"一个 tap 管一堆不相干的热键"。
///
/// **两条铁律**：
/// 1. tap 回调跑在专用线程的 run loop 上，而它监听的是**全系统**键盘——回调里任何
///    耗时或阻塞都会拖慢整机输入。所以两个回调都只做匹配、然后由订阅方立刻 offload；
/// 2. 只匹配**精确**的修饰键组合（`deviceIndependentFlagsMask` 全等），
///    这样 Cmd+Shift+D、单独按 D、打字一律不受影响。
///
/// `keyUp` 一律透传：`keyDown` 已被吃掉，放行 `keyUp` 对目标 app 无害，
/// 反过来若按 keyCode 宽松匹配 keyUp，就会把「单独按 D」的抬起也吞掉、干扰打字。
final class GlobalKeyTap: @unchecked Sendable {
    /// 组合热键（iDict 时代沿用；Qwen 键已随 Qwen Code 支持下线，现五个）
    enum HotKey: Sendable {
        case translate            // Cmd+D
        case openTerminal         // Opt+Z
        case openTerminalClaude   // Opt+A
        case openTerminalCodex    // Opt+X
        case openTerminalPi       // Opt+Q
        case copyPath             // Opt+C
        case escInterrupt         // Ctrl+Esc 手动闭嘴（不录音）
    }

    /// 右⌘(0x36) / 右⌃(0x3E) 状态变化。在 tap 线程同步调用，**必须立刻返回**。
    var onModifier: (@Sendable (_ keyCode: UInt16, _ isDown: Bool) -> Void)?
    /// 命中的组合热键 + 触发时的鼠标位置。在 tap 线程同步调用，**必须立刻返回**。
    var onHotKey: (@Sendable (_ hotKey: HotKey, _ mouseLocation: CGPoint) -> Void)?

    private var thread: Thread?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var shouldStop = false
    private let stateQueue = DispatchQueue(label: "com.user.ivox.keytap.state")

    /// 键盘监听是否真的在跑；等待权限时为 false
    var isMonitoring: Bool { stateQueue.sync { eventTap != nil } }

    private var isStopped: Bool { stateQueue.sync { shouldStop } }

    // MARK: - Lifecycle

    func start() {
        let t = Thread { [weak self] in self?.run() }
        t.name = "com.user.ivox.keytap"
        t.start()
        stateQueue.sync {
            shouldStop = false
            thread = t
        }
    }

    func stop() {
        var loopToStop: CFRunLoop?
        stateQueue.sync {
            shouldStop = true
            if let eventTap { CFMachPortInvalidate(eventTap) }
            eventTap = nil
            runLoopSource = nil
            loopToStop = runLoop
            runLoop = nil
            thread?.cancel()
            thread = nil
        }
        // 在事件线程自己的 run loop 上唤醒，让它退出 CFRunLoopRun
        if let loopToStop { CFRunLoopStop(loopToStop) }
    }

    // MARK: - Event loop（专用线程）

    private func run() {
        stateQueue.sync { runLoop = CFRunLoopGetCurrent() }
        guard !isStopped else {
            stateQueue.sync { runLoop = nil }
            return
        }
        guard let tap = createEventTap() else {
            waitForPermissions()
            stateQueue.sync { runLoop = nil }
            return
        }
        // 辅助功能权限足够建 tap，但**普通键（keyDown）**还要「输入监控」——
        // 缺它时表现为"右⌘ 语音照常、Cmd+D 毫无反应"，且 tap 创建明明成功，最难排查。
        if !CGPreflightListenEventAccess() {
            Log.warn("键盘事件层: 缺少「输入监控」权限，Cmd+D 等普通键热键收不到——"
                   + "请在 系统设置 → 隐私与安全性 → 输入监控 勾选 ivox，然后重启守护进程")
            _ = CGRequestListenEventAccess()   // 让它出现在系统设置的列表里，便于勾选
        }
        stateQueue.sync {
            guard !shouldStop else { return }
            eventTap = tap
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        Log.info("键盘事件层已启动（右 ⌘/⌃ 语音；Cmd+D 划词翻译；Opt+Z/A/Q/X/C Finder）")
        CFRunLoopRun()
        stateQueue.sync { runLoop = nil }
    }

    // MARK: - Tap

    private func createEventTap() -> CFMachPort? {
        let mask = (1 << CGEventType.flagsChanged.rawValue)
                 | (1 << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<GlobalKeyTap>.fromOpaque(refcon).takeUnretainedValue()

            // 系统会在回调超时或输入风暴时**自动禁用** tap（并送来这两类事件）。
            // 不在这里重新启用的话，热键就永久失效——而 `isMonitoring` 查不出来
            // （被禁用的 tap 仍然非 nil，status 显示一切正常）。踩过。
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let port = tap.eventTap {
                    CGEvent.tapEnable(tap: port, enable: true)
                    Log.warn("键盘事件层: tap 被系统禁用，已重新启用（type=\(type.rawValue)）")
                }
                return Unmanaged.passUnretained(event)
            }

            guard !tap.isStopped else { return Unmanaged.passUnretained(event) }
            return tap.handle(type: type, event: event)
                ? nil                                  // 命中组合热键：吃掉
                : Unmanaged.passUnretained(event)      // 其余一律原样透传
        }

        return CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: CGEventTapOptions(rawValue: 0)!,   // defaultTap：可拦截
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
    }

    /// 返回 true 表示吃掉该事件。跑在 tap 线程上——只做整数比较，绝不干重活。
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .flagsChanged:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            guard keyCode == 0x36 || keyCode == 0x3E else { return false }
            let isDown = event.flags.contains(keyCode == 0x36 ? .maskCommand : .maskControl)
            onModifier?(UInt16(keyCode), isDown)
            return false

        case .keyDown:
            // 按住不放的重复触发不要
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return false }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            // 只看四个标准修饰键位，忽略 AlphaShift / Fn / NumericPad 等杂项，
            // 这样 Cmd+Shift+D、CapsLock 开着按 Cmd+D 都不会误触
            let flags = event.flags.intersection(Self.modifierMask)
            guard let binding = Self.bindings.first(where: {
                $0.keyCode == keyCode && $0.modifiers == flags
            }) else { return false }
            onHotKey?(binding.hotKey, event.location)
            return true

        default:
            return false
        }
    }

    // MARK: - 组合热键表（keyCode 用 ANSI 布局）

    /// 精确匹配时只比较这四个标准修饰键位（`CGEventFlags` 没有 macOS 上
    /// `NSModifierFlags.deviceIndependentFlagsMask` 的对应常量，手动取值）
    private static let modifierMask: CGEventFlags = [
        .maskShift, .maskControl, .maskAlternate, .maskCommand,
    ]

    private struct Binding {
        let keyCode: Int64
        let modifiers: CGEventFlags
        let hotKey: HotKey
    }

    private static let bindings: [Binding] = [
        Binding(keyCode: 0x02, modifiers: .maskCommand, hotKey: .translate),           // D
        Binding(keyCode: 0x06, modifiers: .maskAlternate, hotKey: .openTerminal),      // Z
        Binding(keyCode: 0x00, modifiers: .maskAlternate, hotKey: .openTerminalClaude),// A
        Binding(keyCode: 0x07, modifiers: .maskAlternate, hotKey: .openTerminalCodex), // X
        Binding(keyCode: 0x0C, modifiers: .maskAlternate, hotKey: .openTerminalPi),     // Q
        Binding(keyCode: 0x08, modifiers: .maskAlternate, hotKey: .copyPath),          // C
        Binding(keyCode: 0x35, modifiers: .maskControl, hotKey: .escInterrupt),        // Esc（Ctrl+Esc）
    ]

    // MARK: - 权限

    /// 轮询等待设备控制权限就绪，然后自动重启。
    private func waitForPermissions() {
        while !isStopped {
            Thread.sleep(forTimeInterval: 5)
            let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
            if AXIsProcessTrustedWithOptions(options) {
                Log.info("键盘事件层: 设备控制权限已授权")
                break
            }
        }
        guard !isStopped else { return }
        Log.info("键盘事件层: 权限已就绪，重新启动")
        start()
    }
}
