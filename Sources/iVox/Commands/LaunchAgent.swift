import ArgumentParser
import Foundation
import iVoxKit

// CLI 子命令 ivox on|off：守护进程的**唯一启停入口**（LaunchAgent 托管）。
// on 写 plist 并拉起（登录自启）；off 卸下 job + disable + 停服务（开机不再自启）。

/// LaunchAgent（`com.ivox.daemon`）的装与卸，`ivox on` / `ivox off` 共用的底座。
///
/// 曾用 `ivox autostart on|off` 两层名字，太长，已收成 on/off 这对短命令。
///
/// 更早的 `ivox on/off` 是 nohup 手动模式，与 launchd 托管并存时 KeepAlive 会把收到停止
/// 信号的进程立刻拉回来——`ivox off` 因此总误报「守护进程未退出」，`make update` 还会在
/// 进程活着时 cp 覆盖二进制（签名失配 OS_REASON_CODESIGNING，极端情况拉起到写了一半的
/// 文件）。现已删净那套，on/off 只剩 launchd 一条实现。
enum LaunchAgent {
    static let label = "com.ivox.daemon"

    static var plistPath: String {
        NSString("~/Library/LaunchAgents/com.ivox.daemon.plist").expandingTildeInPath
    }

    /// job 是否已加载进 launchd——已加载时 `bootstrap` 会报 EEXIST，该走 `kickstart -k` 重启
    static var isJobLoaded: Bool { launchctl(["print", guiTarget + "/" + label]) == 0 }

    /// 当前登录用户的 launchd 作用域（gui/<UID>）
    static var guiTarget: String { "gui/\(getuid())" }

    static func plistXML(program: String, log: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(program)</string>
                <string>serve</string>
            </array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            <key>ProcessType</key><string>Standard</string>
            <key>StandardOutPath</key><string>\(log)</string>
            <key>StandardErrorPath</key><string>\(log)</string>
        </dict>
        </plist>
        """
    }

    @discardableResult
    static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        // 丢弃子进程输出：job 已加载时 `bootstrap` 会报 EEXIST（表现为 "Bootstrap failed:
        // 5: Input/output error"），而那是 On 的**正常**分支——它随即改走 kickstart 重载。
        // 不重定向的话这行吓人的报错会直接漏进用户终端，看着像失败了。
        // 各调用点都判了 terminationStatus，真失败仍有可见反馈。
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus }
        catch { return -1 }
    }
}

/// 配置 launchd + 启动守护进程。幂等：未加载则 bootstrap、已加载则 kickstart -k 重载。
struct OnCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "on",
        abstract: "启动守护进程并配置登录自启（登录自启 + 崩溃自动重启）"
    )

    func run() throws {
        // 1) 若有非托管的 daemon（旧版 nohup 起的）在跑，先停掉，避免双 serve 抢 socket。
        //    托管中的 job 不用动——下面 kickstart 会重启它。
        let socket = AppPaths.socketPath
        if SocketClient.isRunning(path: socket), !LaunchAgent.isJobLoaded {
            _ = try? SocketClient.send("__IVOX_STOP__", to: socket)
            for _ in 0..<40 {
                if !SocketClient.isRunning(path: socket) { break }
                Thread.sleep(forTimeInterval: 0.25)
            }
            // 停不掉就别往下走：托管的那份会因为抢不到实例锁而反复退出，
            // 而 socket 又是那份野 daemon 的——表面「起来了」，实际机器上跑着两个。
            let (pid, held) = InstanceLock.holder(path: AppPaths.lockPath(for: socket))
            if held {
                print("错误: 停不掉另一个守护进程（pid=\(pid.map(String.init) ?? "未知")），已放弃启动")
                print("手动处理：kill 掉那个 pid，或把它的 socket 换到别处（IVOX_SOCKET）")
                throw ExitCode.failure
            }
        }
        // 2) 写 LaunchAgent plist（RunAtLoad 登录自启 + KeepAlive 崩溃自动重启），
        //    serve 用绝对路径，规避 launchd 受限 PATH
        var binary = AppPaths.binDir + "/ivox"
        if binary.hasPrefix("~") { binary = NSString(string: binary).expandingTildeInPath }
        let log = AppPaths.configDir + "/daemon.log"
        let plist = LaunchAgent.plistXML(program: binary, log: log)
        try? FileManager.default.removeItem(atPath: LaunchAgent.plistPath)
        try plist.write(toFile: LaunchAgent.plistPath, atomically: true, encoding: .utf8)
        //    先 enable：`ivox off` 会 disable 本服务，而被 disable 的 job 是 bootstrap 不进去的
        //    （plist 还在、但 launchd 拒绝加载）。顺序不可调换——实测被 disable 时报的是
        //    "Bootstrap failed: 5: Input/output error"，与「job 已加载」**同一个错**，
        //    没法从报错区分，只能把 enable 放在前面兜住。
        LaunchAgent.launchctl(["enable", LaunchAgent.guiTarget + "/" + LaunchAgent.label])
        // 3) 起或重启：未加载则 bootstrap（首次），已加载则 kickstart -k 重载新二进制。
        //    做成幂等是必须的——`ivox update` 与微信授权后都靠本命令重启，
        //    而那时 job 通常已加载（bootstrap 会报 EEXIST）。
        var status = LaunchAgent.launchctl(["bootstrap", LaunchAgent.guiTarget, LaunchAgent.plistPath])
        if status != 0 {
            status = LaunchAgent.launchctl(["kickstart", "-k", LaunchAgent.guiTarget + "/" + LaunchAgent.label])
        }
        // 4) 等 socket 就绪（30s：模型加载 + 键盘层权限轮询实测要十几秒，10s 会误报）
        for _ in 0..<120 {
            if SocketClient.isRunning(path: socket) {
                print("✓  守护进程已启动（登录自启 + 崩溃自动重启，LaunchAgent: \(LaunchAgent.label)）")
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        // 起不来**算失败**（退出码非 0），不只是打印一句警告：`make update` 靠这个退出码
        // 判断「新二进制是不是坏的」，吞掉它就没有回滚的触发点——update 会报成功而服务是死的。
        print("⚠️  daemon 30s 内未就绪（launchctl exit \(status)），请查看 \(log)")
        throw ExitCode.failure
    }
}

/// 卸下 launchd job + disable + 停止守护进程；plist 保留，`ivox on` 可原样恢复。
struct OffCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "off",
        abstract: "停止守护进程并关闭自启（卸下 launchd job + disable；ivox on 恢复）"
    )

    func run() throws {
        // 1) bootout 卸下 job（含其托管的 daemon）。KeepAlive 下只有它能真停——直接发停止信号
        //    会被 launchd 立刻拉回。job 未加载时 bootout 会失败，那是「本来就 off」的正常情况，
        //    别报错吓人。
        let target = LaunchAgent.guiTarget + "/" + LaunchAgent.label
        let status = LaunchAgent.launchctl(["bootout", target])
        if status != 0, LaunchAgent.isJobLoaded {
            print("⚠️  launchctl bootout 失败（exit \(status)）")
        }
        // 2) disable 才真关自启：光 bootout 只是卸下本次会话的 job，plist 还在，
        //    下次登录 launchd 会照样加载（KeepAlive 也会跟着回来）。disable 写进 launchd 的
        //    禁用库，plist 留着但登录不再加载——`ivox on` 里的 enable 负责撤销。
        LaunchAgent.launchctl(["disable", target])
        let socket = AppPaths.socketPath
        for _ in 0..<40 {
            if !SocketClient.isRunning(path: socket) { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        if SocketClient.isRunning(path: socket) {
            print("⚠️  daemon 仍在运行，可手动 pkill -f 'ivox serve'")
        } else {
            print("✓  守护进程已停止（launchd job 已卸下并禁用，开机不再自启；ivox on 恢复）")
        }
    }
}
