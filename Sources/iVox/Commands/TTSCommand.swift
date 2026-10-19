import ArgumentParser
import Foundation
import iVoxKit

// CLI 子命令 `ivox tts`：誊清员进程 —— 独立于主 daemon 的 TTS 合成。
//
// 它存在的唯一理由：MLX 的 Metal 命令编码器在析构时会重复释放 GPU 命令队列
// （SIGTRAP），上游未修且无法从 Swift 侧拦截。把这一层单独摘出去，炸的时候
// 主进程里的队列、字条、字幕全都安然无恙，由主进程重新拉起本进程接着誊。

struct TTSCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tts",
        abstract: "誊清员进程（独立于 daemon 的 TTS 合成，由主进程拉起与监督）"
    )

    @Flag(name: .long, help: "常驻监听 socket，等主进程来要字条的音频")
    var serve = false

    func run() async throws {
        // 未加 --serve 时提示用法：目前只有常驻一种形态，不做一次性合成的 CLI
        guard serve else {
            print("用法: ivox tts --serve")
            throw ExitCode.failure
        }

        setenv("HF_HUB_OFFLINE", "1", 1)
        setenv("TRANSFORMERS_OFFLINE", "1", 1)
        // 日志与崩溃现场各落各的文件。三个进程混在一份日志里，出了事就只能靠时间戳
        // 猜是谁干的 —— 2026-10-19 晚上从「pi 没出声」查到「MLX 崩了」翻了三轮，
        // 根子就在那儿。拆开的收益之一是：哪个文件里有现场，就是哪个角色的错。
        setenv("IVOX_LOG_FILE", "~/.config/ivox/tts.log", 1)

        let socketPath = AppPaths.ttsSocketPath
        if SocketClient.isRunning(path: socketPath) {
            print("错误: 誊清员已在运行（\(socketPath)）")
            throw ExitCode.failure
        }

        let config: Config
        do {
            config = try loadConfig()
        } catch {
            print("错误: 配置加载失败: \(error)")
            print("请先运行 make")
            throw ExitCode.failure
        }

        // 本进程才是崩的那个，崩溃现场必须记在自己的文件里（主进程的 crash.log 看不到它）
        CrashTrap.install(role: "tts")

        let engine = TTSEngine(config: config)
        let server = SocketServer()
        let handler = TTSServer(engine: engine, config: config)
        try await server.start(path: socketPath, handler: handler)
        Log.info("誊清员已启动，监听 \(socketPath)")

        // 模型加载与预热放后台：socket 先监听，主进程问「好了没」时由它据实回答，
        // 不必让主进程干等整个模型加载完。
        Task {
            do {
                try await engine.loadModel()
                await engine.warmup(voiceID: config.defaultVoice)
                Log.info("誊清员: 模型就绪")
            } catch {
                Log.error("誊清员: 模型加载失败: \(error)")
            }
        }

        // 常驻：等主进程 SIGTERM。默认处置就是终止，不必另装信号源。
        // 不用 dispatchMain() 是因为它在 async 上下文中会占死协作线程池的线程。
        while true {
            try? await Task.sleep(for: .seconds(3600))
        }
    }
}
