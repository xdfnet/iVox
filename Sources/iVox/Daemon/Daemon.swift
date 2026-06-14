import Darwin
import Foundation
import iVoxKit

actor Daemon {
    private let config: Config
    private let engine: TTSEngine
    private let queue: PlaybackQueue
    private let server = SocketServer()
    private let speechInput: SpeechInputService?
    private var shutdownContinuation: CheckedContinuation<Void, Never>?

    init(config: Config) {
        self.config = config
        self.engine = TTSEngine(config: config)
        self.queue = PlaybackQueue(engine: engine)
        let siConfig = config.speechInput ?? .default
        let resolved = SpeechInputConfig(
            enabled: siConfig.enabled,
            language: siConfig.language,
            autoEnter: siConfig.autoEnter,
            maxRecordingSeconds: siConfig.maxRecordingSeconds,
            model: siConfig.model,
            baseURL: siConfig.baseURL ?? config.api.baseURL
        )
        self.speechInput = SpeechInputService(config: resolved)
    }

    func run() async throws {
        Log.info("iVox 守护进程启动")

        // DispatchSource 信号处理（比 signal() 安全，回调中可使用 async）
        installSignalSource(SIGINT)
        installSignalSource(SIGTERM)

        let socketPath = NSString(string: "~/.config/ivox/ivox.sock").expandingTildeInPath
        let dir = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)

        let handler = ConnectionHandler(queue: queue, config: config)
        try await server.start(path: socketPath, handler: handler)

        Log.info("iVox 已启动，监听 \(socketPath)")

        if let si = speechInput {
            si.start()
        }

        // 等待退出信号
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.shutdownContinuation = continuation
        }

        await cleanup()
    }

    // MARK: - 信号处理

    private func installSignalSource(_ sig: Int32) {
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Log.info("收到信号 \(sig)，开始退出")
            Task { await self.initiateShutdown() }
        }
        // 必须忽略，否则 DispatchSource 不会捕获信号
        signal(sig, SIG_IGN)
        source.activate()
    }

    private func initiateShutdown() {
        shutdownContinuation?.resume()
        shutdownContinuation = nil
    }

    // MARK: - 清理

    private func cleanup() async {
        Log.info("守护进程退出清理")
        speechInput?.stop()
        await server.stop()
        await queue.shutdown()
        Log.info("守护进程已退出")
        exit(0)
    }
}
