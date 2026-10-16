import AVFoundation
import Darwin
import Foundation
import iVoxKit

// 守护进程本体：装配全部服务并管理生命周期。

actor Daemon {
    private let config: Config
    private let engine: TTSEngine
    private let asrEngine: ASREngine
    private let queue: PlaybackQueue
    private let server = SocketServer()
    private let speechInput: SpeechInputService?
    /// 键盘事件层：一个 tap 服务多个消费者（右⌘ 语音 + 各组热键）
    private let keyTap = GlobalKeyTap()
    private var translationCoordinator: TranslationCoordinator?
    private var quickActions: QuickActionsService?
    /// 播报字幕浮窗（配置开启才创建）
    private var captionPanel: CaptionPanel?
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
            mediaController: mediaController
        )

        let siConfig = config.speechInput ?? .default
        self.speechInput = SpeechInputService(
            config: siConfig,
            mediaController: mediaController,
            playbackQueue: queue,
            asrEngine: asrEngine,
            keyTap: keyTap
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
        // 目录里躺着 config.json（含微信 token）与 daemon.log（含播报原文），只给本人
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: nil)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        // 目录权限只约束**新建**的文件；已经躺在里面的，每次启动补收一次
        for name in ["config.json", "daemon.log", "daemon.log.old"] {
            let path = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: path)
            }
        }

        let handler = ConnectionHandler(
            queue: queue, config: config, asrEngine: asrEngine, engine: engine,
            statusProvider: { [weak self] in
                guard let snapshot = await self?.makeStatusSnapshot() else { return nil }
                return try? JSONEncoder().encode(snapshot)
            }
        )
        try await server.start(path: socketPath, handler: handler)

        Log.info("iVox 已启动，监听 \(socketPath)")
        if config.resolvedMediaControl.resolvedHTTPServerEnabled {
            startMediaHTTPServer()
        }
        startModelLoading()
        await setUpHotKeys()
        await setUpCaption()

        // 启动微信轮询
        if let wechat {
            await wechat.start(handler: handleWeChatMessage)
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.shutdownContinuation = continuation
        }

        await cleanup()
    }

    /// 汇总各功能真实运行开关与两个权限状态，供 socket `{type:status}` 返回。
    func makeStatusSnapshot() async -> DaemonStatus {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let mic: String
        switch micStatus {
        case .authorized: mic = "authorized"
        case .denied: mic = "denied"
        case .restricted: mic = "restricted"
        case .notDetermined: mic = "notDetermined"
        @unknown default: mic = "unknown"
        }

        // 各功能健康结论：区分 未启用 / 正常 / 异常原因
        let siEnabled = config.speechInput?.enabled ?? SpeechInputConfig.default.enabled
        let speech: String
        if !siEnabled {
            speech = "off"
        } else if speechInput?.isMonitoring != true {
            speech = "error:键盘监听未运行"
        } else if micStatus != .authorized {
            speech = "error:麦克风未授权"
        } else {
            speech = "ok"
        }

        let wechatHealth: String
        if config.wechat?.enabled != true {
            wechatHealth = "off"
        } else if await wechat?.isPolling == true {
            wechatHealth = "ok"
        } else {
            wechatHealth = "error:长轮询未运行"
        }

        let mc = config.resolvedMediaControl
        let webUI: String
        if !mc.resolvedHTTPServerEnabled {
            webUI = "off"
        } else if mediaHTTPServer?.isRunning == true {
            webUI = "ok"
        } else {
            webUI = "error:Web 服务未监听"
        }

        // 自动播报：取决于 TTS 模型是否就绪
        let playbackHealth: String
        switch await engine.state {
        case .ready: playbackHealth = "ok"
        case .failed(let message): playbackHealth = "error:\(message)"
        case .notStarted, .loading: playbackHealth = "loading"
        }

        // 划词翻译与快速操作都与语音输入共用同一套键盘监听（依赖同一权限）
        let translationHealth: String
        if !config.resolvedTranslation.enabled {
            translationHealth = "off"
        } else if keyTap.isMonitoring != true {
            translationHealth = "error:键盘监听未运行"
        } else {
            translationHealth = "ok"
        }
        let quickActionsHealth = keyTap.isMonitoring ? "ok" : "error:键盘监听未运行"

        return DaemonStatus(
            version: iVoxVersion,
            features: .init(
                playback: playbackHealth,
                speechInput: speech,
                translation: translationHealth,
                quickActions: quickActionsHealth,
                wechat: wechatHealth,
                // 媒体控制的入口就是 Web 服务，健康度即它
                mediaControl: mc.enabled ? webUI : "off"
            ),
            permissions: .init(
                microphone: mic,
                deviceControl: MediaController.checkDeviceControlPermission()
            )
        )
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
        // 键盘事件层**不在这里**启动：等 setUpHotKeys() 把处理器装好再开 tap，
        // 否则启动瞬间到达的按键会撞上「tap 已开、handler 还是 nil」的窗口。
        }
    }

    /// /health 运行态快照：TTS 引擎状态 + 模型名 + 播放队列
    func makeHealthSnapshot() async -> HealthSnapshot {
        let ttsPath = config.models?.ttsPath ?? "~/.config/ivox/model/Qwen3-TTS-12Hz-1.7B-Base-8bit"
        let expanded = (ttsPath as NSString).expandingTildeInPath
        let modelName = expanded.split(separator: "/").last.map { String($0) } ?? ttsPath
        let engineState: String
        switch await engine.state {
        case .notStarted: engineState = "notStarted"
        case .loading: engineState = "loading"
        case .ready: engineState = "ready"
        case .failed: engineState = "failed"
        }
        return HealthSnapshot(
            version: iVoxVersion,
            model: modelName,
            engine: engineState,
            queued: await queue.pendingCount,
            playing: await queue.isProcessing
        )
    }

    /// 启动媒体控制 HTTP 服务器（提供 Web UI），端口由配置指定。
    /// 装配热键：键盘事件层收到组合键后，按**能力归属**分派给各自的服务。
    /// 划词翻译与 Finder 快捷是两个独立能力域，这里只做分发，不把逻辑揉在一起。
    private func setUpHotKeys() async {
        let coordinator = await MainActor.run {
            TranslationCoordinator(config: config, queue: queue)
        }
        let quickActionsService = await MainActor.run { QuickActionsService() }
        translationCoordinator = coordinator
        quickActions = quickActionsService

        keyTap.onHotKey = { hotKey, location in
            Task { @MainActor in
                switch hotKey {
                case .translate:
                    guard coordinator.isEnabled else { return }
                    await coordinator.translateSelection()
                case .openTerminal, .openTerminalClaude,
                     .openTerminalCodex, .openTerminalPi, .copyPath:
                    await quickActionsService.handle(hotKey, at: location)
                case .escInterrupt:
                    // 手动打断三档之「掀桌」：Ctrl+Esc 用户不想说话，只静音播报 + 恢复音乐。
                    // 语义同停止帧（不录音），不做右⌘ 那套「打断 + 暂停音乐」——
                    // 打断后立即 resume，否则用户安静聆听的背景音乐会一直卡在暂停态。
                    await self.queue.cancelAll(origin: .esc)
                    await self.queue.resumeIfIdle()
                case .skipBucket:
                    // 手动打断三档之「中」：丢正在播的这一轮（连同其后分块），从下一桶接着播。
                    await self.queue.skipCurrentBucket(.skip)
                case .skipPage:
                    // 手动打断三档之「轻」：只丢正在播的这一句，同一轮剩下的照常念。
                    await self.queue.skipCurrentPage(.skipPage)
                }
            }
        }
        // 处理器都装好了，这时才开 tap（顺序反了会让启动瞬间的按键落到 nil handler 上）
        keyTap.start()
        let speak = config.resolvedTranslation.speechEnabled ? "浮窗 + 朗读" : "仅浮窗"
        Log.info("热键已装配（Cmd+D 划词翻译，\(speak)；Opt+Z/A/Q/X/C QuickActions；手动打断三档：Ctrl+2 跳这句 / Ctrl+1 跳整轮 / Ctrl+Esc 掀桌）")
    }

    /// 播报字幕（配置开启才装）：把队列广播的「正在念的这句」显示到屏幕下方浮窗。
    /// 队列在后台 actor、AppKit 必须在主线程——跨过去由闭包里的 `Task { @MainActor in }` 承担。
    private func setUpCaption() async {
        guard config.resolvedPlayback.resolvedCaptions else {
            Log.info("播报字幕: 未开启（config 的 playback.captions）")
            return
        }
        let panel = await MainActor.run { CaptionPanel() }   // 面板是 @MainActor 类型，构造要在主线程
        captionPanel = panel
        await queue.setCaptionSink { text in
            Task { @MainActor in panel.update(text) }
        }
        Log.info("播报字幕: 已开启")
    }

    private func startMediaHTTPServer() {
        let port = UInt16(config.resolvedMediaControl.resolvedHTTPServerPort)
        let httpServer = MediaHTTPServer(port: port) { [weak self] in
            await self?.makeHealthSnapshot()
        }
        self.mediaHTTPServer = httpServer
        switch httpServer.start() {
        case .success:
            Log.info("媒体控制 Web UI: 端口 \(port)（监听所有网卡，手机同局域网可访问 http://<本机IP>:\(port)）")
        case .failure(let error):
            Log.error("媒体控制 HTTP 服务器启动失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 微信消息处理
    //
    // 流程（微信驱动，非 CLI 驱动）：
    //   1. 收到微信消息 → 发 start typing（"正在输入"）
    //   2. 调常驻 ClaudeAskService.ask() 获取回复
    //   3. 发 stop typing（"正在输入"消失）
    //   4. 发消息到微信
    //   5. claude 回复结束时触发 Stop Hook → hook.sh → ivox speak（TTS 由 Claude Code 统一处理）
    //
    // 注意：TTS 不在 daemon 这一层，daemon 只负责消息路由。

    private func handleWeChatMessage(_ msg: IncomingMessage) async {
        Log.info("📩 收到微信消息 [来自: \(msg.fromUserID.prefix(20))…]: \(msg.content.prefix(50))")

        guard let claudeAsk else {
            Log.error("ClaudeAskService 未初始化")
            return
        }

        // ① 发 start typing
        await wechat?.sendTyping(status: .start)

        do {
            // ② 走流式桥：assistant 过程段逐段发回微信（过程可见）。最后一条 assistant 即完整结尾，
            //   不再单独取 result（内容重复）。onSegment @Sendable，wechat actor 属性拷成 local let。
            let w = wechat
            try await claudeAsk.askStreaming(text: msg.content) { seg in
                // 微信 sendMessage 是 actor 方法，需异步；错误静默降级（微信偶发失败不阻塞主流程）。
                Task { @MainActor [w] in
                    do {
                        try await w?.sendMessage(text: seg)
                        Log.info("📤 已发送过程段 \(seg.count) 字符")
                    } catch {
                        Log.warn("过程段发送失败: \(error.localizedDescription)")
                    }
                }
            }

            // ③ 发 stop typing（"正在输入"先消失，再出现消息）
            await wechat?.sendTyping(status: .stop)
        } catch {
            // 异常时也要发 stop typing，避免"正在输入"一直显示
            await wechat?.sendTyping(status: .stop)
            Log.error("❌ Claude 请求失败: \(error)")
            // 失败必须回微信：只记日志的话，用户那头看到"正在输入"消失后再无下文，
            // 会误判成链路挂了（2026-10-16 实际踩过，连发三条都石沉大海）。
            let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            try? await wechat?.sendMessage(text: "⚠️ 这条没跑完：\(reason)。可以再发一次，或把任务拆小些。")
        }
    }

    /// 退出时清理：停止微信轮询、语音输入、HTTP 服务器、Socket 服务器、播放队列，然后 exit(0)。
    private func cleanup() async {
        Log.info("守护进程退出清理")
        await wechat?.stop()
        await claudeAsk?.stop()
        speechInput?.stop()
        mediaHTTPServer?.stop()
        await server.stop()
        await queue.shutdown()
        Log.info("守护进程已退出")
        exit(0)
    }
}
