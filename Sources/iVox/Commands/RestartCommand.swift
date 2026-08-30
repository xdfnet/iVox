import ArgumentParser
import Foundation

struct RestartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart",
        abstract: "重启守护进程（先停止再启动）"
    )

    func run() throws {
        try StopCommand().run()
        Thread.sleep(forTimeInterval: 0.5)
        try StartCommand().run()
    }
}
