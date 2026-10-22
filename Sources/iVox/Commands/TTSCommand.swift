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
        setenv("IVOX_ROLE", "tts", 1)

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
                // 加载失败就退出，**不留在那儿假装活着**。
                // 主进程判断「引擎能不能用」的唯一凭据是 socket 在不在；我占着 socket
                // 却干不了活，那个信号就是假的 —— 于是主进程永远不重试、不降级，
                // 每合成一块刷一条同款错误（2026-10-19 23:32 真实卡过一次：
                // 「誊清员无响应」直到重启 daemon 才恢复）。退出去，主进程下一次
                // 连接失败就会按退避重新拉我——退出本身就是那句话。
                Log.error("誊清员: 模型加载失败，退出让主进程重拉: \(error)")
                Darwin.exit(1)   // 不用裸 exit：ArgumentParser 有个同名静态成员会抢解析
            }
        }

        // 盯爸：父进程没了就自己走人。
        //
        // 主进程正常退出时 SIGTERM 走 `Daemon.cleanup()` → `stopChild()`，本进程被带走；
        // **主进程崩溃时那条路来不及跑**，本进程被 init 收养成孤儿——3 GB 内存和一块 GPU
        // 一直挂着干等到下次重启（2026-10-22 实测挂了 9 小时才发现，症状是「怎么有两个
        // ivox 进程」）。launchd 只监督主进程那一个 job，孤儿不在它的视野里。
        //
        // 用 `getppid()` 认「爹还在不在」：父进程一死，本进程被 init 收养，ppid 变成 1。
        // 间隔 5 秒足够——孤儿只是占资源，晚几秒回收没有区别，而误判成自杀才是真的坏。
        Task {
            let parent = Darwin.getppid()
            while true {
                try? await Task.sleep(for: .seconds(5))
                let now = Darwin.getppid()
                if now != parent {
                    Log.info("誊清员: 父进程没了（父=\(parent) 现在=\(now)），自己退出")
                    Darwin.exit(0)   // 不是出错，是「该下班了」，故不用 1
                }
            }
        }

        // 常驻：等主进程 SIGTERM。默认处置就是终止，不必另装信号源。
        // 不用 dispatchMain() 是因为它在 async 上下文中会占死协作线程池的线程。
        while true {
            try? await Task.sleep(for: .seconds(3600))
        }
    }
}
