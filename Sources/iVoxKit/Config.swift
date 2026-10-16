import Foundation

// config.json 的模型定义与读写校验。
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

public struct MediaControlConfig: Codable, Sendable {
    public var enabled: Bool
    public var httpServerEnabled: Bool?
    public var httpServerPort: Int?

    public init(enabled: Bool, httpServerEnabled: Bool? = nil, httpServerPort: Int? = nil) {
        self.enabled = enabled
        self.httpServerEnabled = httpServerEnabled
        self.httpServerPort = httpServerPort
    }

    public var resolvedHTTPServerEnabled: Bool { httpServerEnabled ?? true }
    public var resolvedHTTPServerPort: Int { httpServerPort ?? 8888 }

    public static let `default` = MediaControlConfig(enabled: true)
}

public struct PlaybackConfig: Codable, Sendable {
    /// 播报字幕：念到哪句就在屏幕下方显示哪句（常驻，默认关）
    public var captions: Bool?

    public static let `default` = PlaybackConfig(captions: nil)

    /// 默认关：字幕会一直占着屏幕下方，只在你明确要看时才开
    public var resolvedCaptions: Bool { captions ?? false }
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
    public var claudePath: String?
    public var askTimeoutSeconds: Int?

    public init(token: String = "", baseURL: String = "https://ilinkai.weixin.qq.com", allowFrom: String = "", longPollMS: Int = 35000, dataDir: String = "", claudePath: String? = nil, askTimeoutSeconds: Int? = nil) {
        self.token = token
        self.baseURL = baseURL
        self.allowFrom = allowFrom
        self.longPollMS = longPollMS
        self.dataDir = dataDir
        self.claudePath = claudePath
        self.askTimeoutSeconds = askTimeoutSeconds
    }

    public var enabled: Bool { !token.isEmpty }
    public var resolvedClaudePath: String { claudePath ?? "~/.local/bin/claude" }
    /// 单条提问的等待上限。300s 给长任务留余量——测网络、跑脚本这类要串几次带超时的
    /// 外部调用，120s 常在任务真跑完前就放弃（2026-10-16 实测：微信问「GitHub 通不」因此超时）。
    public var resolvedAskTimeoutSeconds: Int { askTimeoutSeconds ?? 300 }

    private enum CodingKeys: String, CodingKey {
        case token
        case baseURL = "base_url"
        case allowFrom = "allow_from"
        case longPollMS = "long_poll_timeout_ms"
        case dataDir = "data_dir"
        case claudePath = "claude_path"
        case askTimeoutSeconds = "ask_timeout_seconds"
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
    public var mediaControl: MediaControlConfig? = nil
    public var playback: PlaybackConfig? = nil
    public var defaultVoice: String
    public var sourceVoices: [String: String]
    public var voices: [VoiceInfo]
    public var speechInput: SpeechInputConfig?
    public var wechat: WeChatConfig?
    public var translation: TranslationConfig? = nil
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
    public var resolvedMediaControl: MediaControlConfig { mediaControl ?? .default }
    public var resolvedPlayback: PlaybackConfig { playback ?? .default }
    public var resolvedTranslation: TranslationConfig { translation ?? .default }

    private enum CodingKeys: String, CodingKey {
        case models
        case tts
        case mediaControl
        case playback
        case speechInput
        case wechat
        case translation
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
    // 配置里有微信 token 等凭据，收到只有本人可读
    try? FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: configPath)
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
    if config.voice(id: config.defaultVoice) == nil {
        throw ConfigError.invalidConfig("defaultVoice 不存在: \(config.defaultVoice)")
    }
    for (source, id) in config.sourceVoices {
        if config.voice(id: id) == nil {
            throw ConfigError.invalidConfig("sourceVoices.\(source) 不存在: \(id)")
        }
    }
    // 翻译配置缺失或未启用都不算错（划词翻译可整体关掉）
    if let t = config.translation, t.enabled {
        if t.provider == .openai, URL(string: t.baseURL) == nil {
            throw ConfigError.invalidConfig("translation.baseURL 无效")
        }
        if t.timeoutSeconds <= 0 {
            throw ConfigError.invalidConfig("translation.timeoutSeconds 必须大于 0")
        }
        if t.panelTimeoutSeconds < 0 {
            throw ConfigError.invalidConfig("translation.panelTimeoutSeconds 不能为负")
        }
    }
}
