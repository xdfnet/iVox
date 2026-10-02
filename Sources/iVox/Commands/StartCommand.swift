import ArgumentParser

struct StartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "on",
        abstract: "启动守护进程（后台运行），已在运行则重启"
    )

    func run() throws {
        try RestartCommand().run()
    }
}
