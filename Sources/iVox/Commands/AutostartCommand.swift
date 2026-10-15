import ArgumentParser
import Foundation
import iVoxKit

// CLI 子命令 ivox autostart on|off：守护进程的**唯一启停入口**（LaunchAgent 托管）。
// RunAtLoad 登录自启、KeepAlive 崩溃自动重启。
// 原先另有 `ivox on/off/restart`（nohup 手动模式），两套并存时 KeepAlive 会把收到停止
// 信号的进程立刻拉回来——`ivox off` 因此总误报「守护进程未退出」，`make update` 还会在
// 进程活着时 cp 覆盖二进制（签名失配 OS_REASON_CODESIGNING、极端情况拉起到截断文件）。
// 已删除那套，启停一律走这里。

struct AutostartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "autostart",
        abstract: "登录自启 + 崩溃自动重启守护进程（LaunchAgent）",
        subcommands: [On.self, Off.self]
    )

    static let label = "com.ivox.daemon"
    static var plistPath: String {
        NSString("~/Library/LaunchAgents/com.ivox.daemon.plist").expandingTildeInPath
    }
    /// autostart 是否已配置（LaunchAgent plist 存在）
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistPath) }
    /// job 是否已加载进 launchd——已加载时 `bootstrap` 会报 EEXIST，该走 `kickstart -k` 重启
    static var isJobLoaded: Bool { launchctl(["print", guiTarget + "/" + label]) == 0 }
    /// 当前登录用户的 launchd 作用域（gui/<UID>）
    static var guiTarget: String { "gui/\(getuid())" }

    struct On: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "on", abstract: "启动守护进程（并开启登录自启）")
        func run() throws {
            // 1) 若有非托管的 daemon（旧版 nohup 起的）在跑，先停掉，避免双 serve 抢 socket。
            //    托管中的 job 不用动——下面 kickstart 会重启它。
            let socket = AppPaths.socketPath
            if SocketClient.isRunning(path: socket), !AutostartCommand.isJobLoaded {
                _ = try? SocketClient.send("__IVOX_STOP__", to: socket)
                for _ in 0..<40 {
                    if !SocketClient.isRunning(path: socket) { break }
                    Thread.sleep(forTimeInterval: 0.25)
                }
            }
            // 2) 写 LaunchAgent plist（RunAtLoad 登录自启 + KeepAlive 崩溃自动重启），
            //    serve 用绝对路径，规避 launchd 受限 PATH
            var binary = AppPaths.binDir + "/ivox"
            if binary.hasPrefix("~") { binary = NSString(string: binary).expandingTildeInPath }
            let log = AppPaths.configDir + "/daemon.log"
            let plist = AutostartCommand.plistXML(program: binary, log: log)
            try? FileManager.default.removeItem(atPath: AutostartCommand.plistPath)
            try plist.write(toFile: AutostartCommand.plistPath, atomically: true, encoding: .utf8)
            // 3) 起或重启：未加载则 bootstrap（首次），已加载则 kickstart -k 重载新二进制。
            //    做成幂等是必须的——`ivox upgrade` 与微信授权后都靠本命令重启，
            //    而那时 job 通常已加载（bootstrap 会报 EEXIST）。
            var status = AutostartCommand.launchctl(["bootstrap", AutostartCommand.guiTarget, AutostartCommand.plistPath])
            if status != 0 {
                status = AutostartCommand.launchctl(["kickstart", "-k", AutostartCommand.guiTarget + "/" + AutostartCommand.label])
            }
            // 4) 等 socket 就绪（30s：模型加载 + 键盘层权限轮询实测要十几秒，10s 会误报）
            for _ in 0..<120 {
                if SocketClient.isRunning(path: socket) {
                    print("✓  守护进程已启动（登录自启 + 崩溃自动重启，LaunchAgent: \(AutostartCommand.label)）")
                    return
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
            print("⚠️  daemon 30s 内未就绪（launchctl exit \(status)），请查看 \(log)")
        }
    }

    struct Off: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "off", abstract: "关闭自启")
        func run() throws {
            // bootout 停掉 launchd job（含其托管的 daemon）
            let status = AutostartCommand.launchctl(["bootout", AutostartCommand.guiTarget + "/" + AutostartCommand.label])
            if status != 0 {
                print("⚠️  launchctl bootout 失败（exit \(status)），自启可能未开启")
            }
            let socket = AppPaths.socketPath
            for _ in 0..<40 {
                if !SocketClient.isRunning(path: socket) { break }
                Thread.sleep(forTimeInterval: 0.25)
            }
            try? FileManager.default.removeItem(atPath: AutostartCommand.plistPath)
            if SocketClient.isRunning(path: socket) {
                print("⚠️  daemon 仍在运行，可手动 pkill -f 'ivox serve'")
            } else {
                print("✓  守护进程已停止（登录自启已关闭；重新启动执行 ivox autostart on）")
            }
        }
    }

    private static func plistXML(program: String, log: String) -> String {
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
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus }
        catch { return -1 }
    }
}