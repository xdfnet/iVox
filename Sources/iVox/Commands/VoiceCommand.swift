import ArgumentParser
import Foundation
import iVoxKit

// CLI 子命令 ivox voice：音色管理。

struct VoiceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "voice",
        abstract: "管理播报音色",
        subcommands: [VoiceList.self, VoiceAdd.self, VoiceRemove.self]
    )
}

struct VoiceList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "列出全部音色"
    )

    func run() throws {
        guard let config = try? loadConfig() else {
            print("错误: 无法加载配置 \(AppPaths.configDir)/config.json")
            throw ExitCode.failure
        }
        let userIDs = Set((config.voices ?? []).map(\.id))
        for v in config.resolvedVoices {
            let name = v.name ?? v.id
            let desc = v.description.map { " — \($0)" } ?? ""
            let isDefault = v.id == config.defaultVoice ? " (默认)" : ""
            // 内置音色在代码里（不可删）；自建音色在 config.json 里
            let origin = userIDs.contains(v.id) ? "自建" : "内置"
            print("\(name) (\(v.id))\(isDefault) [\(origin)]\(desc)")
        }
    }
}

struct VoiceAdd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "添加音色"
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
        let configPath = ConfigFile.path
        let config = try loadConfig(from: configPath)

        let userIDs = Set((config.voices ?? []).map(\.id))
        if userIDs.contains(id) {
            print("错误: 音色 ID \(id) 已存在（自建音色）")
            return
        }
        if VoiceCatalog.isBuiltin(id: id) {
            // 内置音色同 id：允许覆盖（用户想改内置音色就写同名条目）
            print("ℹ️  \(id) 是内置音色，将用你的设置覆盖它")
        }

        // 就地写进配置文件：**保留用户自己写的注释**（整体重排会把它冲掉）
        let text = try String(contentsOfFile: configPath, encoding: .utf8)
        let doc = try TOMLDocument.parse(text, order: ConfigAudit.sectionOrder)
        var element: [String: TOMLValue] = ["id": .string(id)]
        if let name { element["name"] = .string(name) }
        if let refAudio { element["refAudio"] = .string(refAudio) }
        if let refText { element["refText"] = .string(refText) }
        if let description { element["description"] = .string(description) }
        let updated = doc.appendingToArrayTable("playback.voices", element: .table(element))
        try updated.write(toFile: configPath, atomically: true, encoding: .utf8)

        let displayName = name ?? id
        print("已添加音色: \(displayName) (\(id))")
    }
}

struct VoiceRemove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "删除音色"
    )

    @Option(name: .shortAndLong, help: "音色 ID")
    var id: String

    func run() throws {
        let configPath = ConfigFile.path
        let config = try loadConfig(from: configPath)

        let userVoices = config.voices ?? []
        guard let index = userVoices.firstIndex(where: { $0.id == id }) else {
            if VoiceCatalog.isBuiltin(id: id) {
                print("错误: \(id) 是内置音色（在代码里），删不掉；"
                      + "要改它请在 config.toml 的 [[playback.voices]] 里写同名条目覆盖")
            } else {
                print("错误: 音色 ID \(id) 不存在")
            }
            return
        }
        guard id != config.defaultVoice else {
            print("错误: 不能删除默认音色 (\(id))")
            return
        }

        // 删掉 [[playback.voices]] 里的这一条，并清掉 sourceVoices 里指向它的引用。
        // 同样就地改，用户的注释留着。
        let text = try String(contentsOfFile: configPath, encoding: .utf8)
        let doc = try TOMLDocument.parse(text, order: ConfigAudit.sectionOrder)
        let references = config.sourceVoices
            .filter { $0.value == id }
            .map { "playback.sourceVoices.\($0.key)" }
        let withoutRefs = doc.removingValues(forKeys: references)
        let doc2 = try TOMLDocument.parse(withoutRefs, order: ConfigAudit.sectionOrder)
        let updated = doc2.removingFromArrayTable("playback.voices", index: index)
        try updated.write(toFile: configPath, atomically: true, encoding: .utf8)

        let voice = userVoices[index]
        print("已删除音色: \(voice.name ?? id) (\(id))")
    }
}
