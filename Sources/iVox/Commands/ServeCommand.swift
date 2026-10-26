import ArgumentParser
import Foundation
import iVoxKit

// CLI 子命令 ivox serve：前台运行守护进程。

struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "以前台模式运行守护进程（供 LaunchAgent 拉起）"
    )

    func run() async throws {
        // 模型全部走本地目录，不依赖 Hub：设离线标志，避免任何启动期联网检查卡顿
        // （防御性：当前 Swift 依赖栈主要靠「本地目录」判据，这两个变量也惠及子进程透传）
        setenv("HF_HUB_OFFLINE", "1", 1)
        setenv("TRANSFORMERS_OFFLINE", "1", 1)

        // 退出留证：退出的调用栈写进 daemon.log（不管从哪条路退的）
        ExitTrace.install()

        let socketPath = AppPaths.socketPath
        // **实例独占锁**：这台机器上同一把 socket 只允许一个 daemon。
        // 抢不到就自己退出——第二份 daemon 会 unlink 掉 socket 把先跑的那份变成
        // 哑巴（它还占着全局热键和麦克风），这种「看着一个、其实两个」最难查
        // （2026-10-26 实测过）。锁由内核持有，进程退出自动释放。
        let lock: InstanceLock.Holder
        do {
            lock = try InstanceLock.acquire(path: AppPaths.lockPath)
            Log.info("实例锁已获取: \(lock.path)（pid=\(lock.pid)）")
        } catch let error as InstanceLock.AcquireError {
            switch error {
            case .held(let pid, let path):
                let who = pid.map { "pid=\($0)" } ?? "持有者未知"
                print("错误: 已有一个守护进程在跑（\(who)，锁 \(path)）")
                print("别再起第二个：先把它停掉（ivox off），或用 IVOX_SOCKET 指定别的 socket 做隔离调试")
            case .failed(let message):
                print("错误: \(message)")
            }
            throw ExitCode.failure
        }
        // 锁由 InstanceLock 内部持有（进程活多久就持有多久），这里只留个凭证
        // 免得它被当成没用的变量丢掉
        _ = lock

        if SocketClient.isRunning(path: socketPath) {
            print("错误: 守护进程已在运行，使用 ivox off 停止后再启动前台进程")
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

        // 配置里有没人认领的键（写错了、或写了已挪进内部的旧段）→ 记进日志，
        // 免得「配了却没生效」只能靠猜
        if let text = try? String(contentsOfFile: ConfigFile.path, encoding: .utf8) {
            let issues = ConfigAudit.unknownKeys(inTOMLText: text)
            if !issues.isEmpty {
                Log.warn("配置里有 \(issues.count) 个键没人认领（写了但没生效）：\(ConfigAudit.describe(issues))")
            }
        }

        let daemon = Daemon(config: config)
        try await daemon.run()
        // 正常收尾后**不走静态析构**：mlx 全局持有一张 `CommandEncoder` 哈希表，进程退出时
        // `__cxa_finalize_ranges` → 表析构 → `CommandEncoder::~CommandEncoder` →
        // `end_encoding` 在仍挂着未收口的 encoder 时 SIGSEGV（2026-10-19 15:20 实测：
        // `ivox restart` 恰好在合成进行中，整进程被这一下带崩，自检里连着几个用例 ECONNREFUSED）。
        // 收尾已完成、日志已落盘，直接刷盘退场，不给析构函数碰 GPU 的机会。
        fflush(nil)
        _exit(0)
    }
}
