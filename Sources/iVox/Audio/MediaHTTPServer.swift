import Foundation
import Network
import os
import iVoxKit

// MARK: - HTTP 服务错误

enum MediaHTTPServerError: LocalizedError {
    case startFailed(Error)
    case invalidPort
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .startFailed(let e): return "HTTP 服务器启动失败: \(e.localizedDescription)"
        case .invalidPort: return "无效的端口号"
        case .networkError(let e): return "网络错误: \(e.localizedDescription)"
        }
    }
}

// MARK: - 媒体控制 HTTP 服务器

final class MediaHTTPServer: @unchecked Sendable {
    private var listener: NWListener?
    private let port: UInt16

    // 以下两个属性被 stateUpdateHandler（NWListener 内部队列）和 stop()（调用者线程）访问，
    // 用锁保护避免 data race。
    private let stateLock = OSAllocatedUnfairLock()
    private var _isRunning = false
    private var _serverURL: String?

    var isRunning: Bool { stateLock.withLock { _isRunning } }
    var serverURL: String? { stateLock.withLock { _serverURL } }

    private func setState(running: Bool, url: String?) {
        stateLock.withLock {
            _isRunning = running
            _serverURL = url
        }
    }

    init(port: UInt16 = 8888) {
        self.port = port
    }

    deinit { stop() }

    /// 启动服务器
    @discardableResult
    func start() -> Result<Void, MediaHTTPServerError> {
        stop()
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                return .failure(.invalidPort)
            }
            listener = try NWListener(using: params, on: nwPort)

            listener?.newConnectionHandler = { [weak self] connection in
                guard let server = self else { return }
                Task { server.handleConnection(connection) }
            }

            listener?.stateUpdateHandler = { [weak self] state in
                guard let server = self else { return }
                switch state {
                case .ready:
                    server.setState(running: true, url: "http://127.0.0.1:\(server.port)")
                    Log.info("媒体控制 HTTP 服务器已启动: http://127.0.0.1:\(server.port)")
                case .failed(let error):
                    server.setState(running: false, url: nil)
                    Log.error("HTTP 服务器启动失败: \(error.localizedDescription)")
                case .cancelled:
                    server.setState(running: false, url: nil)
                default: break
                }
            }

            listener?.start(queue: .global())
            return .success(())
        } catch {
            return .failure(.startFailed(error))
        }
    }

    /// 停止服务器
    func stop() {
        listener?.cancel()
        listener = nil
        setState(running: false, url: nil)
        Log.info("媒体控制 HTTP 服务器已停止")
    }

    // MARK: - 连接处理

    private func handleConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .failed = state { connection.cancel() }
        }
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, _ in
            if let data, !data.isEmpty {
                Task.detached { [weak self] in
                    await self?.processRequest(data: data, connection: connection)
                }
            }
            if isComplete { connection.cancel() }
        }
    }

    // MARK: - 请求处理

    private nonisolated func processRequest(data: Data, connection: NWConnection) async {
        guard let path = Self.parsePath(from: data) else {
            HTTPResponseHandler.sendBadRequest(connection, message: "Bad Request")
            return
        }

        Log.info("HTTP 请求: \(path)")

        if path == "/" || path == "/index.html" {
            HTTPResponseHandler.sendHTML(connection, Self.loadHTML())
        } else if path.hasPrefix("/api/") {
            await handleAPI(path: path, connection: connection)
        } else if path.hasPrefix("/assets/") {
            Self.serveAsset(path: path, connection: connection)
        } else {
            Log.warn("未找到路径: \(path)")
            HTTPResponseHandler.sendNotFound(connection)
        }
    }

    nonisolated static func parsePath(from data: Data) -> String? {
        guard let request = String(data: data, encoding: .utf8),
              let firstLine = request.components(separatedBy: "\r\n").first
        else { return nil }
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        return parts[1]
    }

    // MARK: - API 处理

    private func handleAPI(path: String, connection: NWConnection) {
        let action = String(path.dropFirst(5))
        Log.info("API 动作: \(action)")

        if !Self.actionsWithoutAccessibilityCheck.contains(action) && !MediaController.checkAccessibilityPermission() {
            let json = HTTPResponseHandler.buildJSONResponse(status: "failed", error: "缺少辅助功能权限")
            HTTPResponseHandler.sendJSON(connection, json)
            return
        }

        Task {
            let (result, error) = await Self.executeAction(action)
            let json = HTTPResponseHandler.buildJSONResponse(status: result, error: error)
            HTTPResponseHandler.sendJSON(connection, json)
        }
    }

    /// 不需要辅助功能权限的动作：
    /// - 状态查询类（只读）
    /// - MediaRemote 直接调用（play/pause/next/prev — 使用私有系统框架，无需 CGEvent）
    /// - 应用切换（toggle/status — 走 NSWorkspace + open，无需 CGEvent）
    private static let actionsWithoutAccessibilityCheck: Set<String> = [
        "status", "lock_status", "status_douyin", "status_qishui",
        "play", "pause", "next", "prev",
        "toggle_douyin", "toggle_qishui",
    ]

    private static func executeAction(_ action: String) async -> (result: String, error: String?) {
        switch action {
        case "status":
            return (MediaController.hasMediaAppRunning() ? "running" : "stopped", nil)
        case "play":
            if case .failure(let e) = await MediaController.play() { return ("failed", e.errorDescription) }
            return ("playing", nil)
        case "pause":
            if case .failure(let e) = await MediaController.pause() { return ("failed", e.errorDescription) }
            return ("paused", nil)
        case "playpause":
            if case .failure(let e) = await MediaController.pressSpace() { return ("failed", e.errorDescription) }
            return ("success", nil)
        case "next": _ = await MediaController.nextTrack(); return ("success", nil)
        case "prev": _ = await MediaController.previousTrack(); return ("success", nil)
        case "volumeup": _ = await MediaController.volumeUp(); return ("success", nil)
        case "volumedown": _ = await MediaController.volumeDown(); return ("success", nil)
        case "mute": _ = await MediaController.toggleMute(); return ("success", nil)
        case "arrowup": _ = await MediaController.arrowUp(); return ("success", nil)
        case "arrowdown": _ = await MediaController.arrowDown(); return ("success", nil)
        case "lock":
            if MediaController.isScreenLocked() {
                return ("failed", "屏幕已锁定，无法通过软件唤醒")
            }
            return await lockScreenAction()
        case "lock_status":
            return (MediaController.isScreenLocked() ? "locked" : "unlocked", nil)
        case "toggle_douyin":
            return await toggleAppAction("douyin", display: "抖音")
        case "toggle_qishui":
            return await toggleAppAction("qishui", display: "汽水音乐")
        case "status_douyin":
            return (MediaController.isAppRunning("douyin") ? "running" : "stopped", nil)
        case "status_qishui":
            return (MediaController.isAppRunning("qishui") ? "running" : "stopped", nil)
        default:
            Log.warn("未知 API 操作: \(action)")
            return ("unknown", "未知操作: \(action)")
        }
    }

    private static func lockScreenAction() async -> (String, String?) {
        if case .success = await MediaController.lockScreen() { return ("lock_success", nil) }
        return ("failed", "锁屏失败")
    }

    private static func toggleAppAction(_ name: String, display: String) async -> (String, String?) {
        let wasRunning = MediaController.isAppRunning(name)
        Log.info("\(display) 切换前状态: \(wasRunning ? "运行中" : "未运行")")
        if case .success = await MediaController.toggleApp(name) {
            let result = wasRunning ? "closed" : "opened"
            Log.info("\(display) 切换完成: \(result)")
            return (result, nil)
        }
        return ("failed", "操作失败")
    }

    // MARK: - 静态资源

    private nonisolated static func serveAsset(path: String, connection: NWConnection) {
        let filename = String(path.dropFirst(8))
        Log.info("请求资源: \(filename)")

        guard let data = loadAssetFile(filename) else {
            Log.error("未找到资源: \(filename)")
            HTTPResponseHandler.sendNotFound(connection, message: "Asset Not Found")
            return
        }
        let ext = (filename as NSString).pathExtension
        HTTPResponseHandler.sendDataResponse(connection, code: 200, data: data, contentType: Self.contentType(for: ext))
    }

    /// 从 Bundle 查找资源
    /// SPM 路径: Bundle.module.resourceURL/Resources/assets/<filename>
    private nonisolated static func loadAssetFile(_ filename: String) -> Data? {
        let name = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension

        // SPM 产物（release/debug 均走通）
        if let url = Bundle.module.resourceURL?
            .appendingPathComponent("Resources")
            .appendingPathComponent("assets")
            .appendingPathComponent(filename),
           let data = try? Data(contentsOf: url) {
            return data
        }
        // 回退: Bundle.module 直接路径（某些调试场景）
        if let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources/assets"),
           let data = try? Data(contentsOf: url) {
            return data
        }
        return nil
    }

    nonisolated static func contentType(for ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "svg": return "image/svg+xml"
        case "html": return "text/html"
        default: return "application/octet-stream"
        }
    }

    // MARK: - HTML

    /// 加载 index.html（优先 Bundle，回退内嵌）
    private nonisolated static func loadHTML() -> String {
        if let data = loadAssetFile("index.html"),
           let content = String(data: data, encoding: .utf8) {
            return content
        }
        Log.error("未找到 index.html")
        return Self.fallbackHTML
    }

    private nonisolated static var fallbackHTML: String {
        """
        <!DOCTYPE html>
        <html>
        <head><title>Error</title></head>
        <body>
            <h1>Error Loading Interface</h1>
            <p>Could not load index.html from bundle.</p>
        </body>
        </html>
        """
    }
}
