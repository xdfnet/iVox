import Foundation

// MARK: - Codable 模型

public struct ModelConfig: Codable, Sendable {
    public var asrPath: String
    public var ttsPath: String
}

public struct TTSConfig: Codable, Sendable {
    public var language: String
    public var streamingInterval: Double
    public var outputSampleRate: Int

    public init(language: String, streamingInterval: Double, outputSampleRate: Int) {
        self.language = language
        self.streamingInterval = streamingInterval
        self.outputSampleRate = outputSampleRate
    }

    public static let `default` = TTSConfig(
        language: "Chinese",
        streamingInterval: 0.08,
        outputSampleRate: 48_000
    )
}

public struct PlaybackConfig: Codable, Sendable {
    public var interruptCurrent: Bool

    public init(interruptCurrent: Bool) {
        self.interruptCurrent = interruptCurrent
    }

    public static let `default` = PlaybackConfig(
        interruptCurrent: true
    )
}

public struct MediaControlConfig: Codable, Sendable {
    public var enabled: Bool
    public var baseURL: String
    public var pausePath: String
    public var resumePath: String
    public var httpServerEnabled: Bool?
    public var httpServerPort: Int?

    public init(enabled: Bool, baseURL: String, pausePath: String, resumePath: String, httpServerEnabled: Bool? = nil, httpServerPort: Int? = nil) {
        self.enabled = enabled
        self.baseURL = baseURL
        self.pausePath = pausePath
        self.resumePath = resumePath
        self.httpServerEnabled = httpServerEnabled
        self.httpServerPort = httpServerPort
    }

    /// 空 baseURL = 本地原生引擎（不依赖外部 HTTP 服务）
    public var isBuiltin: Bool { enabled && baseURL.isEmpty }

    /// 非空 baseURL = 远程模式（调外部 API，向后兼容）
    public var isRemote: Bool { enabled && !baseURL.isEmpty }

    public var resolvedHTTPServerEnabled: Bool { httpServerEnabled ?? false }
    public var resolvedHTTPServerPort: Int { httpServerPort ?? 8888 }

    public static let `default` = MediaControlConfig(
        enabled: true,
        baseURL: "",
        pausePath: "/api/pause",
        resumePath: "/api/play"
    )
}

public struct SpeechInputConfig: Codable, Sendable {
    public var enabled: Bool
    public var language: String
    public var autoEnter: Bool
    public var maxRecordingSeconds: Double

    public init(enabled: Bool, language: String, autoEnter: Bool, maxRecordingSeconds: Double) {
        self.enabled = enabled
        self.language = language
        self.autoEnter = autoEnter
        self.maxRecordingSeconds = maxRecordingSeconds
    }

    public static let `default` = SpeechInputConfig(
        enabled: true,
        language: "zh",
        autoEnter: true,
        maxRecordingSeconds: 30
    )
}

public struct WeChatConfig: Codable, Sendable {
    public var token: String
    public var baseURL: String
    public var allowFrom: String
    public var longPollMS: Int
    public var dataDir: String

    public init(token: String = "", baseURL: String = "https://ilinkai.weixin.qq.com", allowFrom: String = "", longPollMS: Int = 35000, dataDir: String = "") {
        self.token = token
        self.baseURL = baseURL
        self.allowFrom = allowFrom
        self.longPollMS = longPollMS
        self.dataDir = dataDir
    }

    public var enabled: Bool { !token.isEmpty }

    private enum CodingKeys: String, CodingKey {
        case token
        case baseURL = "base_url"
        case allowFrom = "allow_from"
        case longPollMS = "long_poll_timeout_ms"
        case dataDir = "data_dir"
    }
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

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case refAudio
        case refText
        case description
    }
}

public struct Config: Codable, Sendable {
    public var models: ModelConfig?
    public var tts: TTSConfig? = nil
    public var playback: PlaybackConfig? = nil
    public var mediaControl: MediaControlConfig? = nil
    public var defaultVoice: String
    public var sourceVoices: [String: String]
    public var voices: [VoiceInfo]
    public var speechInput: SpeechInputConfig?
    public var wechat: WeChatConfig?
    public var configBaseDir: String?

    public var voiceByID: [String: VoiceInfo] {
        var map: [String: VoiceInfo] = [:]
        for v in voices { map[v.id] = v }
        return map
    }

    public func voice(id: String) -> VoiceInfo? {
        voiceByID[id]
    }

    public var resolvedTTS: TTSConfig { tts ?? .default }
    public var resolvedPlayback: PlaybackConfig { playback ?? .default }
    public var resolvedMediaControl: MediaControlConfig { mediaControl ?? .default }

    private enum CodingKeys: String, CodingKey {
        case models
        case tts
        case playback
        case mediaControl
        case speechInput
        case wechat
        case defaultVoice
        case sourceVoices
        case voices
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
    encoder.outputFormatting = [.prettyPrinted]
    let data = try encoder.encode(config)
    var text = String(data: data, encoding: .utf8) ?? "{}"
    text = text.replacingOccurrences(of: "\\/", with: "/")
    text.append("\n")
    try text.write(toFile: configPath, atomically: true, encoding: .utf8)
}

public func validate(_ config: Config) throws {
    if config.defaultVoice.isEmpty {
        throw ConfigError.invalidConfig("defaultVoice 未设置")
    }
    let tts = config.resolvedTTS
    if tts.streamingInterval <= 0 {
        throw ConfigError.invalidConfig("tts.streamingInterval 必须大于 0")
    }
    if tts.outputSampleRate <= 0 {
        throw ConfigError.invalidConfig("tts.outputSampleRate 必须大于 0")
    }
    let mediaControl = config.resolvedMediaControl
    if mediaControl.isRemote, URL(string: mediaControl.baseURL) == nil {
        throw ConfigError.invalidConfig("mediaControl.baseURL 无效")
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
