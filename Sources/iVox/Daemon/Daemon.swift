import AVFoundation
import Darwin
import Foundation
import iVoxKit

// 守护进程本体：装配全部服务并管理生命周期。

actor Daemon {
    private let config: Config
    private let engine: any TTSProviding
    private let asrEngine: ASREngine
    private let queue: PlaybackQueue
    private let server = SocketServer()
    private let speechInput: SpeechInputService?
    /// 键盘事件层：一个 tap 服务多个消费者（右⌘ 语音 + 各组热键）
    /// 键位来自配置 `hotkeys` 段（没写的走默认），见 `HotKeySpec`。
    private let keyTap: GlobalKeyTap
    private var translationCoordinator: TranslationCoordinator?
    private var quickActions: QuickActionsService?
    /// 播报字幕浮窗（配置开启才创建）
    private var captionPanel: CaptionPanel?
    /// 屏幕上的那块 iVox 浮窗（公共���务）：字幕、译文都把要显示的文字交给它
    private var overlay: OverlayService?
    private let mediaController: MediaController
    private var wechat: WeChatPlatform?
    private var claudeAsk: ClaudeAskService?
    private var mediaHTTPServer: MediaHTTPServer?
    private var shutdownContinuation: CheckedContinuation<Void, Never>?
    private var isShuttingDown = false

    /// 初始化：创建 TTS 引擎、ASR 引擎、播放队列、微信平台等所有子服务。
    init(config: Config) {
        self.config = config
        let asrPath = (ModelPaths.asr as NSString).expandingTildeInPath
        self.keyTap = GlobalKeyTap(config: config.hotkeys)

        // 引擎选谁：**默认远程**——MLX 的 Metal 命令编码器析构时会重复释放 GPU 命令
        // 队列（SIGTRAP），上游未修且拿不到 encoder 引用无从拦截。把它隔离进誊清员
        // 进程，它炸了主进程的队列与字幕安然无恙，由 `TSPRemote` 监督着重拉。
        // `IVOX_TTS=local` 退回进程内合成 —— 调试期用它对照排障（同一段文本，
        // 一边走 socket 一边不过），不是给日常用的。
        let ttsEngine: any TTSProviding
        if ProcessInfo.processInfo.environment["IVOX_TTS"] == "local" {
            ttsEngine = TTSEngine(config: config)
            Log.info("TTS 引擎: 进程内合成（IVOX_TTS=local）")
        } else {
            ttsEngine = TSPRemote()
            Log.info("TTS 引擎: 远程誊清员进程")
        }
        self.engine = ttsEngine
        self.asrEngine = ASREngine(modelPath: asrPath)
        self.mediaController = MediaController()
        self.queue = PlaybackQueue(
            engine: ttsEngine,
            mediaController: mediaController,
            idleGraceSeconds: config.resolvedPlayback.resolvedIdleGraceSeconds,
            enabled: config.resolvedPlayback.resolvedEnabled
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
        CrashTrap.install()
        installSignalSource(SIGINT)
        installSignalSource(SIGTERM)

        let socketPath = AppPaths.socketPath
        let dir = AppPaths.configDir
        // 目录里躺着 config.toml（含微信 token）与 daemon.log（含播报原文），只给本人
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: nil)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        // 目录权限只约束**新建**的文件；已经躺在里面的，每次启动补收一次
        for name in ["config.toml", "config.json", "daemon.log", "daemon.log.old"] {
            let path = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: path)
            }
        }

        // 先把上次没播完的内容捞回来（daemon 挂了不丢排队的东西）——
        // 必须在开始接单之前做完，否则新来的内容会排在旧内容前面。
        await queue.restorePersisted()

        let handler = ConnectionHandler(
            queue: queue, config: config, asrEngine: asrEngine, engine: engine,
            statusProvider: { [weak self] in
                guard let snapshot = await self?.makeStatusSnapshot() else { return nil }
                return try? JSONEncoder().encode(snapshot)
            }
        )
        try await server.start(path: socketPath, handler: handler)

        Log.info("iVox 已启动，监听 \(socketPath)")
        if MediaControlConfig.default.httpServerEnabled {
            startMediaHTTPServer()
        }
        startModelLoading()
        let overlay = await MainActor.run { OverlayService(config: config.resolvedOverlay) }
        self.overlay = overlay
        // 屏幕清单打出来：以后想改钉哪块屏，从这里抄 UUID（配置 overlay.screen）
        let screens = await MainActor.run { ScreenIdentity.inventory() }
        Log.info("屏幕清单: \(screens)")
        await setUpHotKeys()
        await setUpCaption()
        // 探一次注入设备在不在：屏幕锁这条能力全靠它，不探就没法在 status 里说真话
        Task { await HidInjector.shared.probe() }

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

        let webUI: String
        if !MediaControlConfig.default.httpServerEnabled {
            webUI = "off"
        } else if mediaHTTPServer?.isRunning == true {
            webUI = "ok"
        } else {
            webUI = "error:Web 服务未监听"
        }

        // 自动播报：播报总开关关着就是「未启用」，与引擎状态无关；
        // 开着才看 TTS 模型是否就绪。
        let playbackHealth: String
        if await queue.isEnabled == false {
            playbackHealth = "off"
        } else {
            switch await engine.state {
            case .ready: playbackHealth = "ok"
            case .failed(let message): playbackHealth = "error:\(message)"
            case .notStarted, .loading: playbackHealth = "loading"
            }
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
                mediaControl: webUI,
                screen: await ScreenControl.health()
            ),
            permissions: .init(
                microphone: mic,
                deviceControl: MediaController.checkDeviceControlPermission()
            )
        )
    }

    /// 注册 POSIX 信号（SIGINT/SIGTERM）监听，收到后触发优雅 shutdown。
    /// 信号源（SIGINT / SIGTERM）。**必须一直留着**——
    /// `DispatchSource` 一旦被释放就等于**取消**，信号也就再也不会送达：
    /// 于是 daemon 收 SIGTERM 纹丝不动，只能 `kill -9`（这个毛病从 2026-10-19
    /// 就记在案里，一直没查着原因——今天查实了：它当时是个**局部变量**，
    /// 函数一返回就没了）。
    ///
    /// 这条修好的意义：停 daemon 终于有了**正经办法**（发 SIGTERM，走有日志、
    /// 有清理、有退出栈的退出路径），不必再靠「一句话就让整个进程 exit(0)」。
    private var signalSources: [DispatchSourceSignal] = []

    private func installSignalSource(_ sig: Int32) {
        let source = DispatchSource.makeSignalSource(signal: sig, queue: DispatchQueue(label: "com.user.ivox.signals", qos: .userInitiated))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Log.info("收到信号 \(sig)，开始退出")
            // 同上：这行是「为什么退的」唯一的自证，退出前必须落盘（异步写会丢）
            Log.flush()
            Task { await self.initiateShutdown() }
        }
        signal(sig, SIG_IGN)
        source.activate()
        signalSources.append(source)   // **留住它**：释放即取消（见上面那段注释）
    }

    /// 标记 shutdown 状态，唤醒 run() 中的 continuation 以退出主循环。
    private func initiateShutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        shutdownContinuation?.resume()
        shutdownContinuation = nil
    }

    /// 后台加载 TTS 模型（异步），并启动语音输入服务。
    /// **ASR 不在这里加载**：它改成「按需加载 + 空闲卸载」（权重 2.5G，常驻太奢侈），
    /// 第一次按下语音键时才加载，且与录音并行——用户照样立刻能说话。
    private func startModelLoading() {
        Task { [engine, config, speechInput] in
            do {
                try await engine.loadModel()
                await engine.warmup(voiceID: config.defaultVoice)
            } catch {
                Log.error("TTS 模型加载失败: \(error)")
            }

        if config.speechInput?.enabled ?? SpeechInputConfig.default.enabled {
            // 隔离实例不开语音输入：麦克风是**独占设备**，两份实例一起开会互相抢；
            // 而且它要「麦克风」授权，手起的实例同样会被算到启动者名下 → 弹框。
            if AppPaths.isIsolatedInstance {
                Log.info("隔离实例：不开语音输入（麦克风是独占设备，且会引出权限框）")
            } else {
                speechInput?.start()
            }
        }
        // 键盘事件层**不在这里**启动：等 setUpHotKeys() 把处理器装好再开 tap，
        // 否则启动瞬间到达的按键会撞上「tap 已开、handler 还是 nil」的窗口。
        }
    }

    /// /health 运行态快照：TTS 引擎状态 + 模型名 + 播放队列
    func makeHealthSnapshot() async -> HealthSnapshot {
        let ttsPath = ModelPaths.tts
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
            playing: await queue.isProcessing,
            playbackEnabled: await queue.isEnabled,
            audibleTurn: await queue.audibleTurn,
            audiblePage: await queue.audiblePage
        )
    }

    /// 启动媒体控制 HTTP 服务器（提供 Web UI），端口由配置指定。
    /// 装配热键：键盘事件层收到组合键后，按**能力归属**分派给各自的服务。
    /// 划词翻译与 Finder 快捷是两个独立能力域，这里只做分发，不把逻辑揉在一起。
    private func setUpHotKeys() async {
        // 隔离实例不装热键：热键是**全局资源**（一个 tap 监听全系统键盘），
        // 两份实例各装一个就会抢同一个右⌘；而且 tap 要「辅助功能」授权，
        // 从命令行手起的实例会被 macOS 算到启动者名下 → 每起一次弹一次框
        // （2026-10-26 实测，见 AppPaths.isIsolatedInstance 的注释）。
        if AppPaths.isIsolatedInstance {
            Log.info("隔离实例（IVOX_SOCKET=\(AppPaths.socketPath)）：不装热键——热键是全局资源，装了会跟正式那份抢")
            return
        }
        guard let overlay else { return }
        let coordinator = await MainActor.run {
            TranslationCoordinator(config: config, queue: queue, overlay: overlay)
        }
        let quickActionsService = await MainActor.run { QuickActionsService() }
        translationCoordinator = coordinator
        quickActions = quickActionsService

        keyTap.onHotKey = { hotKey, chord, location in
            Task { @MainActor in
                switch hotKey {
                case .translate:
                    guard coordinator.isEnabled else { return }
                    await coordinator.translateSelection()
                case .openTerminal, .openTerminalClaude,
                     .openTerminalCodex, .openTerminalPi, .copyPath:
                    await quickActionsService.handle(hotKey, at: location)
                case .skipAll:
                    // 手动打断三档之「掀桌」：Ctrl+3 用户不想说话，只静音播报。
                    // **不碰背景音乐**——播报不再借音乐，这里也就没有"还"要补（见 PlaybackQueue 文件头）。
                    // 归因带**实际生效的键位**（键位可配，写死 "Ctrl+3" 就是句假话）。
                    await self.queue.cancelAll(.hotkey(chord))
                case .skipBucket:
                    // 手动打断三档之「中」：丢正在播的这一轮（连同其后分块），从下一桶接着播。
                    await self.queue.skipCurrentBucket(.hotkey(chord))
                case .skipPage:
                    // 手动打断三档之「轻」：Ctrl+1 丢正在播的这一页，同一轮剩下的照常念。
                    await self.queue.skipCurrentPage(.hotkey(chord))
                }
            }
        }
        // 处理器都装好了，这时才开 tap（顺序反了会让启动瞬间的按键落到 nil handler 上）
        keyTap.start()
        let speak = config.resolvedTranslation.speechEnabled ? "浮窗 + 朗读" : "仅浮窗"
        // 键位本身不写在这里：各动作实际绑了哪组键，由键盘事件层逐行打「热键: xxx = <键位>」，
        // 改过配置后那里就是真相（这里再写一遍就成了第二份、还会漂移）。
        Log.info("热键已装配（划词翻译 \(speak)；QuickActions 五项；手动打断三档：跳整摞 / 掀桌 / 读下一页）")
    }

    /// 播报字幕（配置开启才装）：把队列广播的「正在念的这句」交给浮窗服务显示。
    /// 队列在后台 actor、AppKit 必须在主线程——跨过去由闭包里的 `Task { @MainActor in }` 承担。
    private func setUpCaption() async {
        guard config.resolvedCaptions.resolvedEnabled else {
            Log.info("播报字幕: 未开启（config 的 captions.enabled）")
            return
        }
        guard let overlay else { return }
        let panel = await MainActor.run {
            CaptionPanel(service: overlay)
        }   // 面板是 @MainActor 类型，构造要在主线程
        captionPanel = panel
        await queue.setCaptionSink { frame in
            Task { @MainActor in panel.update(frame) }
        }
        Log.info("播报字幕: 已开启")
    }

    private func startMediaHTTPServer() {
        // 隔离实例不起 Web 控制台：端口是全局资源，跟正式那份必然撞
        // （撞了只会得到一句 "Address already in use"，是噪音不是信息）。
        if AppPaths.isIsolatedInstance {
            Log.info("隔离实例：不起 Web 控制台（端口跟正式那份撞）")
            return
        }
        let port = UInt16(MediaControlConfig.default.httpServerPort)
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
        // 子进程是 spawn 出来的，`_exit(0)` 不跑析构，不显式收就是孤儿：
        // 它自己 `while true` 常驻，会一路抱着 GPU 跑到下次开机。
        await (engine as? TSPRemote)?.stopChild()
        Log.info("守护进程已退出")
        // ⚠️ **退出前必须刷盘**：日志是**异步写**的（Logger 排队后落盘），而这里紧接着
        // exit(0)——不刷的话「为什么退的」这几行永远等不到写出去，现场就丢了
        //（2026-10-26 实测：守护进程一天没了三次，日志里连一句「收到信号」都没有）。
        Log.flush()
        exit(0)
    }
}
