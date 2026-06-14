import ArgumentParser
import Foundation
import iVoxKit

struct VoiceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "voice",
        abstract: "音色管理",
        subcommands: [VoiceList.self, VoiceAdd.self, VoiceRemove.self]
    )
}

struct VoiceList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "列出所有可用音色"
    )

    func run() throws {
        guard let config = try? loadConfig() else {
            print("无法加载配置 ~/.config/ivox/config.json")
            return
        }
        for v in config.voices {
            let mark = v.id == config.defaultVoice ? " ●" : "  "
            let name = v.name ?? v.id
            let desc = v.description.map { " — \($0)" } ?? ""
            print("\(mark) \(name) (\(v.id))\(desc)")
        }
    }
}

struct VoiceAdd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "添加音色配置"
    )

    @Option(name: .shortAndLong, help: "音色 ID")
    var id: String

    @Option(name: .shortAndLong, help: "音色名称")
    var name: String?

    @Option(help: "参考音频路径")
    var refAudio: String?

    @Option(help: "参考音频对应文本")
    var refText: String?

    @Option(name: .shortAndLong, help: "音色描述")
    var description: String?

    func run() throws {
        let configPath = NSString(string: "~/.config/ivox/config.json").expandingTildeInPath
        var config = try loadConfig(from: configPath)

        guard config.voice(id: id) == nil else {
            print("[✗] 音色 ID \(id) 已存在")
            return
        }

        let voice = VoiceInfo(
            id: id,
            name: name ?? id,
            refAudio: refAudio,
            refText: refText,
            description: description
        )
        config.voices.append(voice)
        try saveConfig(config, to: configPath)
        print("[✓] 已添加音色: \(voice.name ?? id) (\(id))")
    }
}

struct VoiceRemove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "删除自定义音色"
    )

    @Option(name: .shortAndLong, help: "音色 ID")
    var id: String

    func run() throws {
        let configPath = NSString(string: "~/.config/ivox/config.json").expandingTildeInPath
        var config = try loadConfig(from: configPath)

        guard let voice = config.voice(id: id) else {
            print("[✗] 音色 ID \(id) 不存在")
            return
        }
        guard id != config.defaultVoice else {
            print("[✗] 不能删除默认音色 (\(id))")
            return
        }

        config.voices.removeAll { $0.id == id }
        config.sourceVoices = config.sourceVoices.filter { $0.value != id }
        try saveConfig(config, to: configPath)

        print("[✓] 已删除音色: \(voice.name ?? id) (\(id))")
    }
}
