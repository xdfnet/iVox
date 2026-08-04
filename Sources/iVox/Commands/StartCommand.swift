import ArgumentParser
import Foundation
import iVoxKit

struct StartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "启动守护进程（通过 launchd）"
    )

    func run() throws {
        let domain = "gui/\(getuid())"
        let label = "com.user.ivox"
        let plist = AppPaths.launchdPlistPath

        guard FileManager.default.fileExists(atPath: plist) else {
            print("[✗] 未安装 launchd 配置，请先运行: make launchd")
            throw ExitCode.failure
        }
        if SocketClient.isRunning(path: AppPaths.socketPath) {
            print("[✓] 守护进程已在运行")
            return
        }

        // 幂等：先清残留 job 再 bootstrap
        runLaunchctl(["bootout", domain + "/" + label])
        sleep(1)
        guard runLaunchctl(["bootstrap", domain, plist]) else {
            // bootstrap 失败：job 已加载但 socket 未就绪时，用 kickstart 拉起
            if runLaunchctl(["print", domain + "/" + label]) {
                runLaunchctl(["kickstart", "-k", domain + "/" + label])
                print("[✓] 守护进程已启动")
            } else {
                print("[✗] 启动失败，请先运行: make launchd")
                throw ExitCode.failure
            }
            return
        }
        print("[✓] 守护进程已启动")
    }

    @discardableResult
    private func runLaunchctl(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return false
        }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
