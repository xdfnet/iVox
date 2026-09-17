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
    private var claudeAsk: ClaudeAskService?
    private var mediaHTTPServer: MediaHTTPServer?
    private var shutdownContinuation: CheckedContinuation<Void, Never>?
    private var isShuttingDown = false

    /// 初始化：创建 TTS 引擎、ASR 引擎、播放队列、微信平台等所有子服务。
    init(config: Config) {
        self.config = config
        let asrPath = config.models?.asrPath ?? NSHomeDirectory() + "/.config/ivox/model/Qwen3-ASR-1.7B-8bit"

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
            playbackQueue: queue,
            asrEngine: asrEngine
        )

        if let wc = config.wechat, wc.enabled {
            self.wechat = WeChatPlatform(config: wc)
            self.claudeAsk = ClaudeAskService(
                dataDir: NSString(string: "~/.config/ivox/wechat").expandingTildeInPath,
                claudePath: wc.resolvedClaudePath,
                timeoutSeconds: wc.resolvedAskTimeoutSeconds
            )
            Log.info("微信平台: 已初始化")
        }
    }

    /// 入口：启动所有服务（信号处理、Unix Socket、微信轮询、TTS/ASR 模型加载），
    ///      然后住留直到收到 SIGINT/SIGTERM 调用 cleanup() 退出。
    func run() async throws {
        Log.info("iVox 守护进程启动")
        installSignalSource(SIGINT)
        installSignalSource(SIGTERM)

        let socketPath = AppPaths.socketPath
        let dir = AppPaths.configDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)

        let handler = ConnectionHandler(queue: queue, config: config, asrEngine: asrEngine, engine: engine)
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

    /// 注册 POSIX 信号（SIGINT/SIGTERM）监听，收到后触发优雅 shutdown。
    private func installSignalSource(_ sig: Int32) {
        let source = DispatchSource.makeSignalSource(signal: sig, queue: DispatchQueue(label: "com.user.ivox.signals", qos: .userInitiated))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Log.info("收到信号 \(sig)，开始退出")
            Task { await self.initiateShutdown() }
        }
        signal(sig, SIG_IGN)
        source.activate()
    }

    /// 标记 shutdown 状态，唤醒 run() 中的 continuation 以退出主循环。
    private func initiateShutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        shutdownContinuation?.resume()
        shutdownContinuation = nil
    }

    /// 后台加载 TTS 和 ASR 模型（异步），并启动语音输入服务。
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

            let lang = config.speechInput?.language ?? SpeechInputConfig.default.language
            await asrEngine.warmup(language: lang)

        if config.speechInput?.enabled ?? SpeechInputConfig.default.enabled {
            speechInput?.start()
        }
        }
    }

    /// 启动媒体控制 HTTP 服务器（提供 Web UI），端口由配置指定。
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
    //
    // 流程（微信驱动，非 CLI 驱动）：
    //   1. 收到微信消息 → 发 start typing（"正在输入"）
    //   2. 调 claude --print 获取回复
    //   3. 发 stop typing（"正在输入"消失）
    //   4. 发消息到微信
    //   5. claude --print 结束时触发 Stop Hook → hook.sh → ivox speak（TTS 由 Claude Code 统一处理）
    //
    // 注意：TTS 不在 daemon 这一层，daemon 只负责消息路由。

    private func handleWeChatMessage(_ msg: IncomingMessage) async {
        Log.info("📩 收到微信消息 [来自: \(msg.fromUserID.prefix(20))…]: \(msg.content.prefix(50))")

        guard let claudeAsk else {
            Log.error("ClaudeAskService 未初始化")
            return
        }

        // ① 发 start typing
        await wechat?.sendTyping(userID: msg.fromUserID, status: .start)

        do {
            // ② 调 Claude CLI 获取回复
            let response = try await claudeAsk.ask(userID: msg.fromUserID, text: msg.content)

            // ③ 发 stop typing（"正在输入"先消失，再出现消息）
            await wechat?.sendTyping(userID: msg.fromUserID, status: .stop)

            // ④ 发微信回复
            try await wechat?.sendMessage(to: msg.fromUserID, text: response)
            Log.info("📤 已发送 \(response.count) 字符 → \(msg.fromUserID.prefix(20))…")
            //   TTS 由 claude --print 完成后的 Stop Hook 触发，不在这里处理
        } catch {
            // 异常时也要发 stop typing，避免"正在输入"一直显示
            await wechat?.sendTyping(userID: msg.fromUserID, status: .stop)
            Log.error("❌ Claude 请求失败: \(error)")
        }
    }

    /// 退出时清理：停止微信轮询、语音输入、HTTP 服务器、Socket 服务器、播放队列，然后 exit(0)。
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
