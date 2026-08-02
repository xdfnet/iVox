import ArgumentParser
import Foundation

struct RestartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart",
        abstract: "重启守护进程（通过 launchd）"
    )

    func run() throws {
        let uid = String(getuid())
        let label = "com.user.ivox"

        // kickstart -k 会先 kill 再自动拉起
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["kickstart", "-k", "gui/\(uid)/\(label)"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()

        do {
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0 {
                print("[✓] 守护进程已重启")
            } else {
                print("[✗] 守护进程未注册，请先运行: make launchd")
                throw ExitCode.failure
            }
        } catch {
            print("[✗] 重启失败: \(error)")
            throw ExitCode.failure
        }
    }
}
