import Darwin
import Foundation
import iVoxKit

actor Daemon {
    private let config: Config
    private let engine: TTSEngine
    private let asrEngine: ASREngine
    private let queue: PlaybackQueue
    private let server = SocketServer()
    private let speechInput: SpeechInputService?
    private let mediaController: MediaController
    private var wechat: WeChatPlatform?
    private var mediaHTTPServer: MediaHTTPServer?
    private var shutdownContinuation: CheckedContinuation<Void, Never>?
    private var isShuttingDown = false

    init(config: Config) {
        self.config = config
        let asrPath = config.models?.asrPath ?? NSHomeDirectory() + "/.config/ivox/model/Qwen3-ASR-1.7B-4bit"

        let ttsEngine = TTSEngine(config: config)
        self.engine = ttsEngine
        self.asrEngine = ASREngine(modelPath: asrPath)
        self.mediaController = MediaController(config: config.resolvedMediaControl)
        self.queue = PlaybackQueue(
            engine: ttsEngine,
            config: config.resolvedPlayback,
            mediaController: mediaController
        )

        let siConfig = config.speechInput ?? .default
        self.speechInput = SpeechInputService(
            config: siConfig,
            mediaController: mediaController,
            asrEngine: asrEngine
        )

        if let wc = config.wechat, wc.enabled {
            self.wechat = WeChatPlatform(config: wc)
            Log.info("微信平台: 已初始化")
        }
    }

    func run() async throws {
        Log.info("iVox 守护进程启动")
        installSignalSource(SIGINT)
        installSignalSource(SIGTERM)

        let socketPath = NSString(string: "~/.config/ivox/ivox.sock").expandingTildeInPath
        let dir = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)

        let handler = ConnectionHandler(queue: queue, config: config, asrEngine: asrEngine)
        try await server.start(path: socketPath, handler: handler)

        Log.info("iVox 已启动，监听 \(socketPath)")
        if config.resolvedMediaControl.resolvedHTTPServerEnabled {
            startMediaHTTPServer()
        }
        startModelLoading()

        // 启动微信轮询
        if let wechat {
            await wechat.start(handler: handleWeChatMessage)
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.shutdownContinuation = continuation
        }

        await cleanup()
    }

    private func installSignalSource(_ sig: Int32) {
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Log.info("收到信号 \(sig)，开始退出")
            Task { await self.initiateShutdown() }
        }
        signal(sig, SIG_IGN)
        source.activate()
    }

    private func initiateShutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        shutdownContinuation?.resume()
        shutdownContinuation = nil
    }

    private func startModelLoading() {
        Task { [engine, asrEngine, config, speechInput] in
            do {
                try await engine.loadModel()
                await engine.warmup(voiceID: config.defaultVoice)
            } catch {
                Log.error("TTS 模型加载失败: \(error)")
            }

            if !(await asrEngine.isLoaded) {
            do { try await asrEngine.load() }
            catch { Log.error("ASR 模型加载失败: \(error)") }
        }

        if config.speechInput?.enabled ?? SpeechInputConfig.default.enabled {
            speechInput?.start()
        }
        }
    }

    private func startMediaHTTPServer() {
        let port = UInt16(config.resolvedMediaControl.resolvedHTTPServerPort)
        let httpServer = MediaHTTPServer(port: port)
        self.mediaHTTPServer = httpServer
        switch httpServer.start() {
        case .success:
            Log.info("媒体控制 Web UI: http://127.0.0.1:\(port)")
        case .failure(let error):
            Log.error("媒体控制 HTTP 服务器启动失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 微信消息处理

    private nonisolated func handleWeChatMessage(_ msg: IncomingMessage) async {
        Log.info("📩 收到微信消息 [来自: \(msg.fromUserID.prefix(20))…]: \(msg.content.prefix(50))")

        // 写 pending_user
        let pendingFile = NSString(string: "~/.config/ivox/pending_user").expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: NSString(string: "~/.config/ivox").expandingTildeInPath,
                                                  withIntermediateDirectories: true)
        try? msg.fromUserID.write(toFile: pendingFile, atomically: true, encoding: .utf8)

        // 剪贴板注入
        do {
            try ClipboardInjector.inject(msg.content)
            let shortID = msg.fromUserID.prefix(20)
            Log.info("📋 已注入 Claude Code [来自: \(shortID)] (\(msg.content.count) 字符)")
        } catch {
            // fallback 到 osascript
            if case InjectError.clipboardFailed = error {
                try? ClipboardInjector.injectViaAppleScript(msg.content)
                Log.info("📋 已通过 AppleScript 注入")
            } else {
                Log.error("❌ 注入失败: \(error)")
            }
        }
    }

    private func cleanup() async {
        Log.info("守护进程退出清理")
        await wechat?.stop()
        speechInput?.stop()
        mediaHTTPServer?.stop()
        await server.stop()
        await queue.shutdown()
        Log.info("守护进程已退出")
        exit(0)
    }
}
