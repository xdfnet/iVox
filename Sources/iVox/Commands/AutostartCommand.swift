import ArgumentParser
import Foundation
import iVoxKit

// CLI 子命令 ivox autostart on|off：登录自启 + 崩溃自动重启守护进程（LaunchAgent）。
// daemon 原来靠 `ivox on`（nohup）手动拉起、无 launchd；这里用 LaunchAgent 托管，
// RunAtLoad 登录自启、KeepAlive 崩溃自动重启。注意：KeepAlive 下 `ivox off` 发停止会被
// 立刻拉起，要真停得 `ivox autostart off`。

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
    /// 当前登录用户的 launchd 作用域（gui/<UID>）
    static var guiTarget: String { "gui/\(getuid())" }

    struct On: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "on", abstract: "开启自启")
        func run() throws {
            // 1) 停掉当前手动 nohup 起的 daemon，交回 launchd 托管，避免双 serve 抢 socket
            let socket = AppPaths.socketPath
            if SocketClient.isRunning(path: socket) {
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
            // 3) bootstrap 载入并启动（RunAtLoad 立即拉起 serve）
            let status = AutostartCommand.launchctl(["bootstrap", AutostartCommand.guiTarget, AutostartCommand.plistPath])
            if status != 0 {
                print("⚠️  launchctl bootstrap 失败（exit \(status)），先卸掉旧 job 再试一次")
            }
            // 4) 等 socket 就绪
            for _ in 0..<40 {
                if SocketClient.isRunning(path: socket) {
                    print("✓  已开启登录自启 + 崩溃自动重启（LaunchAgent: \(AutostartCommand.label)）")
                    return
                }
                Thread.sleep(forTimeInterval: 0.25)
            }
            print("⚠️  自启已配置，但 daemon 未就绪，请查看 \(log)")
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
                print("⚠️  daemon 仍在运行（可能有手动 daemon），可再执行 ivox off 停止")
            } else {
                print("✓  已关闭自启（daemon 已停止；手动启动执行 ivox on）")
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