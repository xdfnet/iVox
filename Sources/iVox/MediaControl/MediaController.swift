import ApplicationServices
import AppKit
import Foundation
import iVoxKit

// 媒体控制：MediaRemote / CGEvent 控制系统媒体（Web 控制台也走它）。
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

    // 曾在这里加过 `MRMediaRemoteGetNowPlayingApplicationIsPlaying`（"现在是否有媒体在播"）——
    // 它是**回调式**私有 API，在 Swift 6 并发下连踩两坑：`@convention(block)` 参数被视作
    // sending（区域隔离报错），绕开后又是闭包逃逸（运行期 `@noescape ... has escaped`，
    // daemon 崩循环）。已整体撤掉 —— **别再往这条路走**。

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
        case .permissionDenied: return "缺少「设备控制与数据访问」权限"
        case .eventCreationFailed: return "创建媒体控制事件失败"
        case .eventPostFailed: return "发送媒体控制事件失败"
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

// MARK: - MediaController

/// 媒体控制器：通过 MediaRemote / CGEvent 直接控制系统媒体。
/// （早期还有一套「远程模式」——`baseURL` 非空时改走 HTTP 调外部服务；从未被调用，已删除。）
///
/// **只为麦克风让路**：录音要干净，音乐就让开；说完则继续 —— 不是"控制你的播放器"。
/// **播报不再经由它**（播报不碰背景音乐，见 `PlaybackQueue` 文件头）；调用方只剩语音输入与 Web 控制台。
/// 语义是**「说完继续」而非「恢复原状」**——你若本来就把音乐暂停着，录音结束会把它放起来。
/// 类需要记住"这次暂停是不是我们发的"，值类型存不住，故为 `actor`。
actor MediaController {
    private let config: MediaControlConfig
    /// 是否处于「我们发起的暂停」状态（恢复后复位）。
    private var suspendedByUs = false

    init(config: MediaControlConfig) {
        self.config = config
    }

    // MARK: - 调度

    /// 让路：暂停音乐（**开始录音时**调用；播报早已不调用它了）；说完由 `resume()` 让它继续。
    /// 语义是**「说完继续」而非「恢复原状」**：本来暂停着的音乐也会被放起来——让路预设了"对方在走"。
    /// （试过更"精确"的判据——暂停前先查是否真有媒体在播：MediaRemote 那条私有 API 在 Swift 6 下
    /// 会崩，已撤，见 `MediaRemoteBridge` 的注释。）
    func pause() async {
        Log.info("媒体控制: 暂停")
        if case .failure(let err) = await Self.pause() {
            Log.warn("媒体控制: 暂停失败 \(err.localizedDescription)")
            return
        }
        suspendedByUs = true   // 无条件记账；等有了可靠的"原本在不在播"，再收紧成"原本在播才记"
    }

    /// 继续：恢复音乐（录音结束时调用）。只对「我们发过的暂停」生效。
    func resume() async {
        guard suspendedByUs else {
            Log.debug("媒体控制: 无需恢复（这次暂停不是我们借的）")
            return
        }
        suspendedByUs = false
        Log.info("媒体控制: 恢复")
        if case .failure(let err) = await Self.play() {
            Log.warn("媒体控制: 恢复失败 \(err.localizedDescription)")
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

    /// 播放/暂停切换（通过 MediaRemote 系统媒体键，无需设备控制权限）
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [appConfig.path]
        do {
            try process.run()
        } catch {
            Log.error("应用启动失败: \(error.localizedDescription)")
            return .failure(.eventPostFailed)
        }
        // 真实回检：`open` 命令发出未必真启动（曾遇系统 LaunchServices 状态坏时 open 返回 0
        // 但进程不起来，日志却照记「已启动」让人抓瞎）。轮询 ≤5s 等 bundleID 进程真出现，
        // 没出现就判失败，让 toggle 返回 failed、不误报 opened。
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if !NSRunningApplication.runningApplications(withBundleIdentifier: appConfig.bundleID).isEmpty {
                Log.info("应用已启动: \(appConfig.displayName)")
                return .success(())
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        Log.error("应用启动超时（open 命令已发出但进程未出现）: \(appConfig.displayName)")
        return .failure(.eventPostFailed)
    }

    // MARK: - 锁屏检测

    static func isScreenLocked() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow"
    }

    // MARK: - 设备控制权限

    static func checkDeviceControlPermission() -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - 权限包装器

    private static func withPermissionCheck<T>(
        _ operation: @escaping () async -> Result<T, MediaControllerError>
    ) async -> Result<T, MediaControllerError> {
        guard checkDeviceControlPermission() else {
            Log.warn("无设备控制权限")
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
