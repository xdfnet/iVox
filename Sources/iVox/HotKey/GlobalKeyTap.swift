@preconcurrency import ApplicationServices
import CoreGraphics
import Foundation
import iVoxKit

// 全局键盘事件层：一个 tap，按归属路由给各消费者。

/// 全局键盘事件层。
///
/// 独占一个 CGEvent tap 与专用 run loop，按事件类型 / keyCode 把事件**路由**出去；
/// 它本身不含任何业务判断——谁关心右⌘、谁关心 Opt+Z，由订阅方决定。
///
/// 之所以单独成层：原先把 tap 埋在 `SpeechInputService` 里、只收修饰键。现在还要接
/// Opt+Z（普通键组合）、Opt+A（纯修饰键组合）… 若继续塞进语音服务，就成了
/// "一个 tap 管一堆不相干的热键"。
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
    /// 右⌘(0x36) / 右⌃(0x3E) 状态变化。在 tap 线程同步调用，**必须立刻返回**。
    var onModifier: (@Sendable (_ keyCode: UInt16, _ isDown: Bool) -> Void)?
    /// 命中的组合热键 + **实际生效的键位**（如 "ctrl+2"）+ 触发时的鼠标位置。
    /// 在 tap 线程同步调用，**必须立刻返回**。
    ///
    /// 带上键位是因为键位**可配**：打断归因要报的是「谁按的什么键」，
    /// 写死默认键位就是句假话。
    var onHotKey: (@Sendable (_ hotKey: HotKeyAction, _ chord: String, _ mouseLocation: CGPoint) -> Void)?

    private var thread: Thread?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var shouldStop = false
    private let stateQueue = DispatchQueue(label: "com.user.ivox.keytap.state")

    /// 生效的组合键表：动作 → 键位。**默认键位只写在 `HotKeySpec` 一处**，
    /// 这里是「默认 + 配置覆盖」算出来的结果，启动时算一次。
    private let bindings: [Binding]
    /// 语音键（右⌘ 0x36 / 右⌃ 0x3E）用哪几个；空集合 = 语音层不启用。
    private let voiceKeys: Set<UInt16>

    /// 建 tap。`config` 是配置里的 `hotkeys` 段（可为 nil = 全用默认）。
    ///
    /// 配错了**不静默**：解析失败、动作名不存在、两个动作抢同一个键位，
    /// 都在这里打日志说明，并退回默认键位——宁可继续用旧键位，也不能让热键无声消失。
    init(config: [String: String]? = nil) {
        let resolved = Self.resolve(config)
        self.bindings = resolved.bindings
        self.voiceKeys = resolved.voiceKeys
    }

    /// 同一组合键的冷却：窗口内只放行一次，防连点/手抖引发一串重复动作。
    /// 按键各自的冷却互不相干：Opt+Z 的连点不会连带压住 Ctrl+2。
    /// 只在 tap 线程读写（handle 独占它），无需加锁。
    ///
    /// 分档而非一刀 1 秒，因为**重复一次的意义各键不同**：
    /// - 划词翻译：抢在 `TranslationCoordinator` 的提交点之前就已后写胜出（连按是
    ///   「我换了个选区」，本就该让位给最新那次），压太久反而挡路，只留 0.2s 挡连击
    /// - 三个打断键：翻页/掀摞本来就该能连按，给 0.3s
    /// - 其余（开终端、复制路径）：一次就是一次，给足 1s
    private static func cooldown(for hotKey: HotKeyAction) -> TimeInterval {
        switch hotKey {
        case .translate: return 0.2
        case .skipAll, .skipBucket, .skipPage: return 0.3
        default: return 1.0
        }
    }
    private var lastFireAt: [HotKeyAction: TimeInterval] = [:]

    /// 右⌘/⌃ 语音的**长按阈值**：按下不足这么久就松开，判为误触（很多 App 用右⌘，
    /// 碰一下就打断播报 + 暂停音乐 + 开麦代价太大），什么都不发。
    /// 到点才按下沿发出 onModifier(true)；阈值内松开的按下沿直接丢弃。
    private static let modifierHold: TimeInterval = 0.15
    /// 正被按住的那个修饰键。fired=已过阈值、按下沿已发出。
    /// tap 线程写、主队列的延时回调也写（阈值到点要记 fired），故走 stateQueue 串一下。
    private var pendingModifier: (keyCode: UInt16, fired: Bool)?

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
            pendingModifier = nil
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
        // 缺它时表现为"右⌘ 语音照常、Opt+Z 毫无反应"，且 tap 创建明明成功，最难排查。
        if !CGPreflightListenEventAccess() {
            Log.warn("键盘事件层: 缺少「输入监控」权限，Opt+Z 等普通键热键收不到——"
                   + "请在 系统设置 → 隐私与安全性 → 输入监控 勾选 ivox，然后重启守护进程")
            _ = CGRequestListenEventAccess()   // 让它出现在系统设置的列表里，便于勾选
        }
        stateQueue.sync {
            guard !shouldStop else { return }
            eventTap = tap
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        Log.info("键盘事件层已启动（键位见上方「热键:」各行；语音键见「语音键:」）")
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
            guard voiceKeys.contains(UInt16(keyCode)) else { return false }
            let isDown = event.flags.contains(keyCode == 0x36 ? .maskCommand : .maskControl)
            handleModifier(keyCode: UInt16(keyCode), isDown: isDown)
            return false

        case .keyDown:
            // 按住不放的重复触发不要
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return false }
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            // 只看四个标准修饰键位，忽略 AlphaShift / Fn / NumericPad 等杂项，
            // 这样 Cmd+Shift+D、CapsLock 开着按 Opt+Z 都不会误触
            let flags = event.flags.intersection(Self.modifierMask)
            guard let binding = bindings.first(where: {
                $0.keyCode == keyCode && $0.modifiers == flags
            }) else { return false }
            let now = ProcessInfo.processInfo.systemUptime
            let cooldown = Self.cooldown(for: binding.action)
            if let last = lastFireAt[binding.action], now - last < cooldown {
                Log.debug("热键冷却中，忽略本次重复触发（剩余 "
                          + String(format: "%.1f", cooldown - (now - last)) + "s）")
                return true   // 冷却中：仍然吃掉，别漏给目标 app；但不重复执行
            }
            lastFireAt[binding.action] = now
            onHotKey?(binding.action, binding.display, event.location)
            return true

        default:
            return false
        }
    }

    // MARK: - 组合热键表（keyCode 用 ANSI 布局）

    /// 右⌘/⌃ 的按下沿延迟到「确实按住了」才发。跑在 tap 线程，逻辑只有两个分支。
    private func handleModifier(keyCode: UInt16, isDown: Bool) {
        guard isDown else {
            // 松开：只有按下沿已经发出去了才通知结束录音；阈值内松开的当没发生过。
            let pending = stateQueue.sync { () -> (keyCode: UInt16, fired: Bool)? in
                defer { pendingModifier = nil }
                guard let p = pendingModifier, p.keyCode == keyCode else { return nil }
                return p
            }
            guard let pending else { return }
            if pending.fired { onModifier?(keyCode, false) }
            return
        }
        // 已经在按住另一个修饰键（或重复按下沿）：不重复起计时
        let claimed = stateQueue.sync { () -> Bool in
            guard pendingModifier == nil else { return false }
            pendingModifier = (keyCode, false)
            return true
        }
        guard claimed else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.modifierHold) { [weak self] in
            guard let self else { return }
            let fire = self.stateQueue.sync { () -> Bool in
                guard let p = self.pendingModifier,
                      p.keyCode == keyCode, !p.fired else { return false }
                self.pendingModifier = (keyCode, true)
                return true
            }
            if fire { self.onModifier?(keyCode, true) }
        }
    }

    /// 精确匹配时只比较这四个标准修饰键位（`CGEventFlags` 没有 macOS 上
    /// `NSModifierFlags.deviceIndependentFlagsMask` 的对应常量，手动取值）
    private static let modifierMask: CGEventFlags = [
        .maskShift, .maskControl, .maskAlternate, .maskCommand,
    ]

    private struct Binding {
        let keyCode: Int64
        let modifiers: CGEventFlags
        let action: HotKeyAction
        /// 归一化显示名（"cmd+shift+d"），写日志用
        let display: String
    }

    /// 算出生效的键位表：默认键位（`HotKeySpec`）+ 配置覆盖。
    ///
    /// 规则说清楚，别让人猜：
    /// 1. 配的键位**优先**占位；两个配置项抢同一个键位 → 后者退回默认并说明；
    /// 2. 默认键位撞上已被占的键位 → 该动作**本轮不可用**并说明（不静默丢功能）；
    /// 3. 解析失败 / 动作名不存在 → 退回默认并说明。
    private static func resolve(_ config: [String: String]?) -> (bindings: [Binding], voiceKeys: Set<UInt16>) {
        var configChords: [HotKeyAction: KeyChord] = [:]
        for (name, value) in (config ?? [:]) {
            guard name != "voice" else { continue }
            guard let action = HotKeyAction(rawValue: name) else {
                Log.warn("热键配置: 不认识的动作「\(name)」，已忽略（可用动作："
                        + HotKeyAction.allCases.map(\.rawValue).joined(separator: "、") + "）")
                continue
            }
            do {
                let chord = try HotKeySpec.parseChord(value)
                // **Ctrl+Esc 已作废**：Esc 是别的 app 的「中断」键，撞上就误伤。
                // 掀页改用数字键（Ctrl+1/2/3），这里把老配置里的 Ctrl+Esc 直接退回默认。
                //
                // ⚠️ **当初那「连掀 4 次」的真凶不是 macOS**（当时判断是「修饰键的松键
                // 事件丢了，系统仍认为 Ctrl 按着」——2026-10-26 定案，实测推翻了）：
                // 是**测试用的 ESP32 板子把 "2" 发成了 Esc**——它的 `/key` 端点按
                // `HID_KEY_0 + (c-'0')` 算数字键，而数字键并不连续（'1'..'9' 在
                // 0x1E..0x26，'0' 在 0x27），于是 '2' 落到了 0x29 = Esc。板子端已修
                // （esp32-lab：数字键表与打字路径共用一张，见 `hid_usage_for_char`），
                // Esc 这一档**仍然作废**：它跟别的 app 的中断键撞，本来就不该当热键。
                if chord.keyName == "esc" && chord.modifiers == [.control] {
                    Log.warn("热键配置: \(action.rawValue) 的键位「\(value)」已作废"
                            + "（Ctrl+Esc 会与别的 app 的中断键撞），改用默认 "
                            + HotKeySpec.defaultChord(for: action).display)
                    continue
                }
                configChords[action] = chord
            } catch {
                Log.warn("热键配置: \(action.rawValue) 的键位「\(value)」无法解析（\(error)），"
                        + "改用默认 \(HotKeySpec.defaultChord(for: action).display)")
            }
        }

        var owner: [KeyChord: HotKeyAction] = [:]
        var final: [HotKeyAction: KeyChord] = [:]
        // 先落配置项：撞车时后来者退回默认（谁先按动作表顺序，顺序固定、可预期）
        for action in HotKeyAction.allCases {
            guard let chord = configChords[action] else { continue }
            if let other = owner[chord] {
                Log.warn("热键配置: \(action.rawValue) 与 \(other.rawValue) 都用了「\(chord.display)」，"
                        + "\(action.rawValue) 退回默认键位")
                continue
            }
            owner[chord] = action
            final[action] = chord
        }
        // 再落默认：连默认都撞上了 → 该动作本轮不可用，明确说出来
        for action in HotKeyAction.allCases where final[action] == nil {
            let chord = HotKeySpec.defaultChord(for: action)
            if owner[chord] != nil {
                Log.warn("热键: \(action.rawValue) 的默认键位「\(chord.display)」已被占用，该动作本轮不可用")
                continue
            }
            owner[chord] = action
            final[action] = chord
        }

        // 语音键：配置优先，配错退回默认（右⌘ + 右⌃）
        var voice = VoiceKeySpec.default
        if let raw = config?["voice"] {
            do {
                voice = try HotKeySpec.parseVoice(raw)
            } catch {
                Log.warn("热键配置: voice 的「\(raw)」无法解析（\(error)），改用默认 右⌘/右⌃")
            }
        }
        var voiceKeys: Set<UInt16> = []
        if voice.rightCommand { voiceKeys.insert(0x36) }
        if voice.rightControl { voiceKeys.insert(0x3E) }

        let bindings = HotKeyAction.allCases.compactMap { action -> Binding? in
            guard let chord = final[action] else { return nil }
            return Binding(keyCode: chord.keyCode, modifiers: cgFlags(chord.modifiers),
                          action: action, display: chord.display)
        }
        for binding in bindings {
            Log.info("热键: \(binding.action.rawValue) = \(binding.display)")
        }
        Log.info("语音键: " + (voiceKeys.isEmpty
                                ? "未启用"
                                : voiceKeys.sorted().map { $0 == 0x36 ? "右⌘" : "右⌃" }.joined(separator: "/")))
        return (bindings, voiceKeys)
    }

    /// `KeyModifiers` → `CGEventFlags`（只比四个标准修饰键位）。
    private static func cgFlags(_ modifiers: KeyModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        return flags
    }

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
