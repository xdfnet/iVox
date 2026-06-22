import ApplicationServices
import AppKit
import Foundation
import iVoxKit

// MARK: - MediaRemote 动态桥接

/// 动态加载 MediaRemote 私有框架，实现精确的播放控制
private enum MediaRemoteBridge {
    nonisolated(unsafe) private static let handle: UnsafeMutableRawPointer? = {
        let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
        if h == nil { Log.warn("MediaRemote 框架未加载") }
        return h
    }()

    static var isAvailable: Bool { handle != nil }

    @discardableResult
    static func sendCommand(_ command: Command) -> Bool {
        guard let h = handle, let sym = dlsym(h, "MRMediaRemoteSendCommand") else { return false }
        typealias Func = @convention(c) (UInt32, UnsafeMutableRawPointer?) -> Bool
        return unsafeBitCast(sym, to: Func.self)(command.rawValue, nil)
    }

    enum Command: UInt32 {
        case play = 0, pause = 1, toggle = 2, stop = 3, nextTrack = 4, previousTrack = 5
        case skipForward = 19, skipBackward = 20
    }
}

// MARK: - 媒体控制器错误

enum MediaControllerError: LocalizedError, Sendable {
    case permissionDenied
    case eventCreationFailed
    case eventPostFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "缺少「辅助功能」权限"
        case .eventCreationFailed: return "创建媒体控制事件失败"
        case .eventPostFailed: return "发送媒体控制事件失败"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .permissionDenied:
            return "请前往「系统设置」> 「隐私与安全性」> 「辅助功能」启用权限"
        case .eventCreationFailed, .eventPostFailed:
            return "请尝试重启应用"
        }
    }
}

// MARK: - 媒体键虚拟码

private enum MediaKey: Int32 {
    case playPause = 16, nextTrack = 17, prevTrack = 18
    case volumeUp = 0, volumeDown = 1, mute = 7
    case arrowUp = 126, arrowDown = 125
    case lockScreen = 12
    case space = 49
}

// MARK: - 远程模式状态（@unchecked Sendable: 仅从 send() 串行访问）

private final class RemoteState: @unchecked Sendable {
    var lastFailureTime: Date?
    init() {}
}

// MARK: - MediaController

/// 媒体控制器，支持双模式：
/// - **本地模式**（`baseURL` 为空）：通过 MediaRemote / CGEvent 直接控制
/// - **远程模式**（`baseURL` 非空）：通过 HTTP 调用外部 API（向后兼容）
struct MediaController {
    private let config: MediaControlConfig
    private let remote = RemoteState()
    private let cooldownInterval: TimeInterval = 5.0

    init(config: MediaControlConfig) {
        self.config = config
    }

    // MARK: - 双模调度

    /// 暂停音乐 (TTS 播报前调用)
    func pause() async {
        if config.isBuiltin {
            Log.info("媒体控制(本地): 暂停")
            _ = await Self.pause()
        } else {
            Log.info("媒体控制(远程): 暂停")
            await send(config.pausePath)
        }
    }

    /// 恢复音乐 (TTS 播报完成后调用)
    func resume() async {
        if config.isBuiltin {
            Log.info("媒体控制(本地): 恢复")
            Log.info("---------------------END----------------------")
            _ = await Self.play()
        } else {
            Log.info("媒体控制(远程): 恢复")
            Log.info("---------------------END----------------------")
            await send(config.resumePath)
        }
    }

    // MARK: - 远程模式

    private func send(_ path: String) async {
        guard config.enabled else { return }
        guard let url = URL(string: config.baseURL + path) else { return }

        if let lastFail = remote.lastFailureTime,
           Date().timeIntervalSince(lastFail) < cooldownInterval {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 2

        for attempt in 0...1 {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    Log.error("媒体控制返回非 200: \(http.statusCode)")
                    if attempt == 0 {
                        Log.info("媒体控制请求失败，500ms 后重试")
                        try await Task.sleep(nanoseconds: 500_000_000)
                        continue
                    }
                }
                return
            } catch {
                remote.lastFailureTime = Date()
                Log.error("媒体控制请求失败: \(error.localizedDescription)")
                if attempt == 0 {
                    Log.info("媒体控制请求失败，500ms 后重试")
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
            }
        }
    }

    // MARK: - 原生 API

    /// 支持的媒体 App Bundle ID
    private static let mediaAppBundleIDs: Set<String> = [
        "com.bytedance.douyin.desktop",
        "com.soda.music",
    ]

    /// 是否有媒体 App 在运行
    static func hasMediaAppRunning() -> Bool {
        mediaAppBundleIDs.contains { bundleID in
            !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        }
    }

    /// 检查应用是否运行
    static func isAppRunning(_ appName: String) -> Bool {
        isAppRunning(bundleID: appBundleID(for: appName))
    }

    static func play() async -> Result<Void, MediaControllerError> {
        guard hasMediaAppRunning() else {
            Log.info("无抖音或汽水音乐运行，跳过")
            return .success(())
        }
        guard MediaRemoteBridge.isAvailable, MediaRemoteBridge.sendCommand(.play) else {
            Log.error("MediaRemote 播放失败")
            return .failure(.eventPostFailed)
        }
        Log.info("MediaRemote 精确播放")
        return .success(())
    }

    static func pause() async -> Result<Void, MediaControllerError> {
        guard hasMediaAppRunning() else {
            Log.info("无抖音或汽水音乐运行，跳过")
            return .success(())
        }
        guard MediaRemoteBridge.isAvailable, MediaRemoteBridge.sendCommand(.pause) else {
            Log.error("MediaRemote 暂停失败")
            return .failure(.eventPostFailed)
        }
        Log.info("MediaRemote 精确暂停")
        return .success(())
    }

    static func nextTrack() async -> Result<Void, MediaControllerError> {
        guard hasMediaAppRunning() else {
            Log.info("无抖音或汽水音乐运行，跳过")
            return .success(())
        }
        guard MediaRemoteBridge.isAvailable, MediaRemoteBridge.sendCommand(.nextTrack) else {
            Log.error("MediaRemote 下一曲失败")
            return .failure(.eventPostFailed)
        }
        Log.info("MediaRemote 下一曲")
        return .success(())
    }

    /// 播放/暂停切换（通过 MediaRemote 系统媒体键，无需辅助功能权限）
    static func playPause() async -> Result<Void, MediaControllerError> {
        guard hasMediaAppRunning() else {
            Log.info("无抖音或汽水音乐运行，跳过")
            return .success(())
        }
        guard MediaRemoteBridge.isAvailable, MediaRemoteBridge.sendCommand(.toggle) else {
            Log.error("MediaRemote 切换失败")
            return .failure(.eventPostFailed)
        }
        Log.info("MediaRemote 播放/暂停切换")
        return .success(())
    }

    static func previousTrack() async -> Result<Void, MediaControllerError> {
        guard hasMediaAppRunning() else {
            Log.info("无抖音或汽水音乐运行，跳过")
            return .success(())
        }
        guard MediaRemoteBridge.isAvailable, MediaRemoteBridge.sendCommand(.previousTrack) else {
            Log.error("MediaRemote 上一曲失败")
            return .failure(.eventPostFailed)
        }
        Log.info("MediaRemote 上一曲")
        return .success(())
    }

    static func volumeUp() async -> Result<Void, MediaControllerError> { await simulateMediaKey(.volumeUp) }
    static func volumeDown() async -> Result<Void, MediaControllerError> { await simulateMediaKey(.volumeDown) }
    static func toggleMute() async -> Result<Void, MediaControllerError> { await simulateMediaKey(.mute) }
    static func arrowUp() async -> Result<Void, MediaControllerError> { await simulateArrowKey(.arrowUp) }
    static func arrowDown() async -> Result<Void, MediaControllerError> { await simulateArrowKey(.arrowDown) }
    static func pressSpace() async -> Result<Void, MediaControllerError> { await simulateArrowKey(.space) }
    static func lockScreen() async -> Result<Void, MediaControllerError> { await simulateLockScreen() }

    // MARK: - 应用管理

    static func toggleApp(_ appName: String) async -> Result<Void, MediaControllerError> {
        isAppRunning(appName) ? await closeApp(appName) : await openApp(appName)
    }

    private static func closeApp(_ appName: String) async -> Result<Void, MediaControllerError> {
        let bundleID = appBundleID(for: appName)
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            app.terminate()
            app.forceTerminate()
        }
        return .success(())
    }

    static func openApp(_ name: String) async -> Result<Void, MediaControllerError> {
        Log.info("尝试打开应用: \(name)")
        guard let appConfig = AudioAppRegistry.find(by: name) else {
            Log.error("未知应用名称: \(name)")
            return .failure(.eventPostFailed)
        }
        guard FileManager.default.fileExists(atPath: appConfig.path) else {
            Log.error("应用不存在: \(appConfig.path)")
            return .failure(.eventPostFailed)
        }
        // 通过 NSWorkspace 打开应用（比 /usr/bin/open 更可靠，适用于 daemon 上下文）
        let appURL = URL(fileURLWithPath: appConfig.path)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        guard (try? await NSWorkspace.shared.openApplication(at: appURL, configuration: config)) != nil else {
            Log.error("NSWorkspace 打开应用失败: \(name)")
            return .failure(.eventPostFailed)
        }
        Log.info("应用已启动: \(appConfig.displayName)")
        return .success(())
    }

    // MARK: - 锁屏检测

    static func isScreenLocked() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow"
    }

    // MARK: - 辅助功能权限

    static func checkAccessibilityPermission() -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func requestAccessibilityPermission() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - 权限包装器

    private static func withPermissionCheck<T>(
        _ operation: @escaping () async -> Result<T, MediaControllerError>
    ) async -> Result<T, MediaControllerError> {
        guard checkAccessibilityPermission() else {
            Log.warn("无辅助功能权限")
            return .failure(.permissionDenied)
        }
        return await operation()
    }

    // MARK: - 按键模拟

    private static func simulateMediaKey(_ key: MediaKey) async -> Result<Void, MediaControllerError> {
        await withPermissionCheck {
            let data1 = Int((key.rawValue << 16) | Int32(0xa00))
            guard let ev = NSEvent.otherEvent(
                with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: 0xa00),
                timestamp: 0, windowNumber: 0, context: nil,
                subtype: 8, data1: data1, data2: -1
            ) else { return .failure(.eventCreationFailed) }
            ev.cgEvent?.post(tap: .cghidEventTap)

            let data1up = Int((key.rawValue << 16) | Int32(0xb00))
            guard let evUp = NSEvent.otherEvent(
                with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: 0xb00),
                timestamp: 0, windowNumber: 0, context: nil,
                subtype: 8, data1: data1up, data2: -1
            ) else { return .failure(.eventCreationFailed) }
            evUp.cgEvent?.post(tap: .cghidEventTap)
            return .success(())
        }
    }

    private static func simulateArrowKey(_ key: MediaKey) async -> Result<Void, MediaControllerError> {
        await withPermissionCheck {
            let source = CGEventSource(stateID: .hidSystemState)
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key.rawValue), keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key.rawValue), keyDown: false)
            else { return .failure(.eventCreationFailed) }
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            return .success(())
        }
    }

    /// 模拟锁屏（Control+Command+Q）
    private static func simulateLockScreen() async -> Result<Void, MediaControllerError> {
        await withPermissionCheck {
            let source = CGEventSource(stateID: .hidSystemState)
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(MediaKey.lockScreen.rawValue), keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(MediaKey.lockScreen.rawValue), keyDown: false)
            else { return .failure(.eventCreationFailed) }
            keyDown.flags = [.maskControl, .maskCommand]
            keyUp.flags = [.maskControl, .maskCommand]
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            return .success(())
        }
    }

    // MARK: - 辅助方法

    private static func isAppRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    // MARK: - 应用查询

    private static func appBundleID(for name: String) -> String {
        AudioAppRegistry.bundleID(for: name)
    }
}
