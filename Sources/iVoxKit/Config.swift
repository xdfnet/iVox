import Foundation

// MARK: - Codable 模型

public struct APIConfig: Codable, Sendable {
    public var baseURL: String
    public var ttsModel: String?
}

public struct SpeechInputConfig: Codable, Sendable {
    public var enabled: Bool
    public var language: String
    public var autoEnter: Bool
    public var maxRecordingSeconds: Double
    public var model: String
    public var baseURL: String?

    public init(enabled: Bool, language: String, autoEnter: Bool, maxRecordingSeconds: Double, model: String, baseURL: String?) {
        self.enabled = enabled
        self.language = language
        self.autoEnter = autoEnter
        self.maxRecordingSeconds = maxRecordingSeconds
        self.model = model
        self.baseURL = baseURL
    }

    public static let `default` = SpeechInputConfig(
        enabled: true,
        language: "zh",
        autoEnter: true,
        maxRecordingSeconds: 30,
        model: "Qwen3-ASR-1.7B-4bit",
        baseURL: nil
    )
}

public struct VoiceInfo: Codable, Sendable {
    public init(id: String, name: String? = nil, refAudio: String? = nil, refText: String? = nil, description: String? = nil) {
        self.id = id
        self.name = name
        self.refAudio = refAudio
        self.refText = refText
        self.description = description
    }

    public var id: String
    public var name: String?
    public var refAudio: String?
    public var refText: String?
    public var description: String?
}

public struct Config: Codable, Sendable {
    public var api: APIConfig
    public var defaultVoice: String
    public var sourceVoices: [String: String]
    public var voices: [VoiceInfo]
    public var speechInput: SpeechInputConfig?
    public var configBaseDir: String?

    public var voiceByID: [String: VoiceInfo] {
        var map: [String: VoiceInfo] = [:]
        for v in voices { map[v.id] = v }
        return map
    }

    public func voice(id: String) -> VoiceInfo? {
        voiceByID[id]
    }
}

// MARK: - 加载

public enum ConfigError: Error {
    case fileNotFound(String)
    case invalidJSON(String)
    case invalidConfig(String)
}

public func loadConfig(from path: String? = nil) throws -> Config {
    let configPath = path ?? NSString(string: "~/.config/ivox/config.json").expandingTildeInPath
    guard FileManager.default.fileExists(atPath: configPath) else {
        throw ConfigError.fileNotFound(configPath)
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
    let decoder = JSONDecoder()
    var config: Config
    do {
        config = try decoder.decode(Config.self, from: data)
    } catch {
        throw ConfigError.invalidJSON("\(configPath): \(error)")
    }
    config.configBaseDir = (configPath as NSString).deletingLastPathComponent
    try validate(config)
    return config
}

public func saveConfig(_ config: Config, to path: String? = nil) throws {
    let configPath = path ?? NSString(string: "~/.config/ivox/config.json").expandingTildeInPath
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(config)
    var text = String(data: data, encoding: .utf8) ?? "{}"
    text = text.replacingOccurrences(of: "\\/", with: "/")
    text.append("\n")
    try text.write(toFile: configPath, atomically: true, encoding: .utf8)
}

public func validate(_ config: Config) throws {
    if config.api.baseURL.isEmpty {
        throw ConfigError.invalidConfig("api.baseURL 未设置")
    }
    if config.defaultVoice.isEmpty {
        throw ConfigError.invalidConfig("defaultVoice 未设置")
    }
    if config.voice(id: config.defaultVoice) == nil {
        throw ConfigError.invalidConfig("defaultVoice 不存在: \(config.defaultVoice)")
    }
    for (source, id) in config.sourceVoices {
        if config.voice(id: id) == nil {
            throw ConfigError.invalidConfig("sourceVoices.\(source) 不存在: \(id)")
        }
    }
}
