import Foundation

// config.json 的模型定义与读写校验。
// MARK: - Codable 模型



public struct TTSConfig: Codable, Sendable {
    public var language: String
    public var streamingInterval: Double
    public var outputSampleRate: Int

    public init(language: String, streamingInterval: Double, outputSampleRate: Int) {
        self.language = language
        self.streamingInterval = streamingInterval
        self.outputSampleRate = outputSampleRate
    }

    /// 合成参数是**代码内配置**（外部配置不提供）。`streamingInterval` 取 0.15——
    /// 这是飞哥机器上一直在用的值（比默认的 0.08 更稳，代价是首字略慢）。
    public static let `default` = TTSConfig(
        language: "Chinese",
        streamingInterval: 0.15,
        outputSampleRate: 48_000
    )
    /// 键名清单（配置审计用）：由 CodingKeys 派生，不另抄一份——两份清单迟早会漂。
    public static var knownKeys: Set<String> { Set(CodingKeys.allCases.map(\.stringValue)) }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case language
        case streamingInterval
        case outputSampleRate
    }

}

/// 媒体控制/Web UI 的配置。
///
/// 这里**没有** `enabled` 总开关：原先有，但没有任何代码读它（`MediaController` 存了配置
/// 也没用），写 true/false 都一样——是个骗人的死字段，2026-10-21 删掉。
public struct MediaControlConfig: Codable, Sendable {
    public var httpServerEnabled: Bool?
    public var httpServerPort: Int?

    public init(httpServerEnabled: Bool? = nil, httpServerPort: Int? = nil) {
        self.httpServerEnabled = httpServerEnabled
        self.httpServerPort = httpServerPort
    }

    public var resolvedHTTPServerEnabled: Bool { httpServerEnabled ?? true }
    public var resolvedHTTPServerPort: Int { httpServerPort ?? 8888 }

    public static let `default` = MediaControlConfig()
    /// 键名清单（配置审计用）：由 CodingKeys 派生，不另抄一份——两份清单迟早会漂。
    public static var knownKeys: Set<String> { Set(CodingKeys.allCases.map(\.stringValue)) }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case httpServerEnabled
        case httpServerPort
    }

}

public struct PlaybackConfig: Codable, Sendable {
    /// 播报字幕：念到哪句就在屏幕下方显示哪句（常驻，默认关）
    public var captions: Bool?

    public static let `default` = PlaybackConfig(captions: nil)

    /// 默认关：字幕会一直占着屏幕下方，只在你明确要看时才开
    public var resolvedCaptions: Bool { captions ?? false }
    /// 键名清单（配置审计用）：由 CodingKeys 派生，不另抄一份——两份清单迟早会漂。
    public static var knownKeys: Set<String> { Set(CodingKeys.allCases.map(\.stringValue)) }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case captions
    }

}

public struct SpeechInputConfig: Codable, Sendable {
    public var enabled: Bool
    public var language: String
    public var autoEnter: Bool
    public var maxRecordingSeconds: Double

    /// 缺字段用默认值：TOML 里只写要改的那一项也能加载
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? Self.default.enabled
        self.language = try c.decodeIfPresent(String.self, forKey: .language) ?? Self.default.language
        self.autoEnter = try c.decodeIfPresent(Bool.self, forKey: .autoEnter) ?? Self.default.autoEnter
        self.maxRecordingSeconds = try c.decodeIfPresent(Double.self, forKey: .maxRecordingSeconds)
            ?? Self.default.maxRecordingSeconds
    }

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
    /// 键名清单（配置审计用）：由 CodingKeys 派生，不另抄一份——两份清单迟早会漂。
    public static var knownKeys: Set<String> { Set(CodingKeys.allCases.map(\.stringValue)) }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case enabled
        case language
        case autoEnter
        case maxRecordingSeconds
    }

}

public struct WeChatConfig: Codable, Sendable {
    public var token: String
    public var baseURL: String
    public var allowFrom: String
    public var longPollMS: Int
    public var dataDir: String
    public var claudePath: String?
    public var askTimeoutSeconds: Int?

    /// 缺字段用默认值：TOML 里只写 `token` 也能加载
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
        self.baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL)
            ?? "https://ilinkai.weixin.qq.com"
        self.allowFrom = try c.decodeIfPresent(String.self, forKey: .allowFrom) ?? ""
        self.longPollMS = try c.decodeIfPresent(Int.self, forKey: .longPollMS) ?? 35000
        self.dataDir = try c.decodeIfPresent(String.self, forKey: .dataDir) ?? ""
        self.claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath)
        self.askTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .askTimeoutSeconds)
    }

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

    /// **键名一律驼峰**（Swift Codable 的默认写法，全项目统一）。
    /// 早先这里显式映射成蛇形（base_url / allow_from…），同一个 config.json 里就出现了
    /// 两套命名风格；2026-10-21 统一成驼峰，配置审计会指出写错或写旧的键。
    enum CodingKeys: String, CodingKey, CaseIterable {
        case token
        case baseURL
        case allowFrom
        case longPollMS
        case dataDir
        case claudePath
        case askTimeoutSeconds
    }
    /// 键名清单（配置审计用）：由 CodingKeys 派生，不另抄一份——两份清单迟早会漂。
    public static var knownKeys: Set<String> { Set(CodingKeys.allCases.map(\.stringValue)) }

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

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case name
        case refAudio
        case refText
        case description
    }
}

/// 模型路径（**代码内配置**）：模型随产品发布，路径是固定的，不给用户改。
/// 外部配置里再写 `models` 段会被忽略，并被配置审计点名（没人认领的键）。
public enum ModelPaths {
    /// 语音识别模型（Qwen3-ASR）
    public static let asr = "~/.config/ivox/model/Qwen3-ASR-1.7B-8bit"
    /// 语音合成模型（Qwen3-TTS）
    public static let tts = "~/.config/ivox/model/Qwen3-TTS-12Hz-1.7B-Base-8bit"
}

/// 来源 id 的固定取值。`"default"` 既是「没指定来源时」用的来源 id，
/// 也是 `sourceVoices` 里表示**默认音色**的那个键——一处定义，别各写各的。
public enum VoiceSource {
    public static let `default` = "default"
}

public struct Config: Codable, Sendable {
    public var mediaControl: MediaControlConfig? = nil
    public var playback: PlaybackConfig? = nil
    /// 来源 → 音色 id 的映射。**`"default"` 键就是默认音色**（没有来源时用它），
    /// 所以不再单设一个 `defaultVoice` 字段——一处说清，别两处各写一遍。
    public var sourceVoices: [String: String]
    /// **用户自建/覆盖的音色**（可选）。内置音色在代码里（`VoiceCatalog`），
    /// 不进外部配置；两者合并见 `resolvedVoices`。
    public var voices: [VoiceInfo]? = nil
    public var speechInput: SpeechInputConfig?
    public var wechat: WeChatConfig?
    public var translation: TranslationConfig? = nil
    /// 热键覆盖：键是动作名（见 `HotKeyAction`），值是组合键串（`"cmd+d"`）。
    /// 只写要改的，没写的走 `HotKeySpec.defaultChord` 的默认键位。
    /// `"voice"` 是特例：值为 `"rightcmd"` / `"rightctrl"` / `"rightcmd+rightctrl"` / `"none"`。
    public var hotkeys: [String: String]? = nil

    /// 默认音色：取 `sourceVoices["default"]`；没写就落到第一个内置音色。
    /// 写进配置的方式：`"sourceVoices": { "default": "taozi", ... }`。
    public var defaultVoice: String {
        sourceVoices[VoiceSource.default] ?? VoiceCatalog.builtin.first?.id ?? ""
    }

    /// 生效的音色清单：内置（代码里）+ 用户自建/覆盖（配置里），同 id 用户优先。
    public var resolvedVoices: [VoiceInfo] {
        VoiceCatalog.merged(with: voices ?? [])
    }

    public var voiceByID: [String: VoiceInfo] {
        var map: [String: VoiceInfo] = [:]
        for v in resolvedVoices { map[v.id] = v }
        return map
    }

    public func voice(id: String) -> VoiceInfo? {
        voiceByID[id]
    }

    /// 合成参数是**代码内配置**（`TTSConfig.default`），外部配置不提供。
    public var resolvedTTS: TTSConfig { .default }
    public var resolvedMediaControl: MediaControlConfig { mediaControl ?? .default }
    public var resolvedPlayback: PlaybackConfig { playback ?? .default }
    public var resolvedTranslation: TranslationConfig { translation ?? .default }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case hotkeys
        case speechInput
        case translation
        case playback
        case mediaControl
        case sourceVoices
        case wechat
        case voices

    }
    /// 顶层键名清单（配置审计用）。
    public static var knownKeys: Set<String> { Set(CodingKeys.allCases.map(\.stringValue)) }

}

/// 内置音色目录：**产品内容**，写在代码里（不占用户的 config.json）。
///
/// 为什么在代码里：这四个音色随产品发布，参考音频也在代码仓的 `Resources/voices/`。
/// 放进外部配置有两个坏处——① config.json 里塞着四段几十字的参考文本，臃肿；
/// ② 用户会误改，改坏了是「配置错误」而不是「产品内容」。
/// 用户自建/覆盖的音色仍写在外部配置 `config.json` 的 `voices` 段（那是用户的设置），
/// 两边合并：**同 id 时用户的覆盖内置**。
public enum VoiceCatalog {
    /// 内置音色。`refAudio` 指向用户目录下的参考音频（装机时拷进去）。
    public static let builtin: [VoiceInfo] = [
        VoiceInfo(
            id: "taozi",
            name: "甜妹桃子",
            refAudio: "~/.config/ivox/voices/ref_taozi.wav",
            refText: "嗨，我是甜妹桃子。我有着活泼甜美的声线，听起来元气满满。如果你需要一位热情开朗的声音陪伴，选我就对了。",
            description: "Claude 音色"
        ),
        VoiceInfo(
            id: "wanwan",
            name: "湾湾小何",
            refAudio: "~/.config/ivox/voices/ref_wanwan.wav",
            refText: "你好，我是湾湾小何。我的声音温柔知性。",
            description: "温柔知性"
        ),
        VoiceInfo(
            id: "mizai",
            name: "米仔",
            refAudio: "~/.config/ivox/voices/ref_mizai.wav",
            refText: "大家好，我是米仔。我的声音温暖自然，适合日常播报和语音助手场景。无论是读书、讲故事，还是播报天气新闻，我都能轻松应对。",
            description: "备用音色"
        ),
        VoiceInfo(
            id: "dayi",
            name: "大易",
            refAudio: "~/.config/ivox/voices/ref_dayi.wav",
            refText: "大家好，我是大易。我有着沉稳可靠的男声，听起来踏实有力量。需要播报重要通知或者讲述深度内容，交给我就好。",
            description: "PI 音色"
        ),
    ]

    /// 内置 + 用户：用户条目同 id 时**覆盖**内置（用户想改内置音色就写同名条目）。
    public static func merged(with userVoices: [VoiceInfo]) -> [VoiceInfo] {
        var merged = builtin
        for voice in userVoices {
            if let index = merged.firstIndex(where: { $0.id == voice.id }) {
                merged[index] = voice
            } else {
                merged.append(voice)
            }
        }
        return merged
    }

    /// 该 id 是不是内置音色（内置的不给删——删了也还在）。
    public static func isBuiltin(id: String) -> Bool {
        builtin.contains { $0.id == id }
    }
}

// MARK: - 加载

public enum ConfigError: Error {
    case fileNotFound(String)
    case invalidJSON(String)
    case invalidConfig(String)
}

public func loadConfig(from path: String? = nil) throws -> Config {
    let configPath = try resolveConfigPath(path)
    let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
    let text = String(data: data, encoding: .utf8) ?? ""
    let object: [String: Any]
    // 按内容判断格式，不看扩展名：老配置是 JSON，新配置是 TOML
    if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
        // 老配置（JSON）：只为迁移留的口子
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigError.invalidJSON("\(configPath): 不是合法的 JSON")
        }
        object = parsed
    } else {
        do {
            object = TOML.jsonObject(from: try TOML.parse(text))
        } catch let error as TOMLError {
            throw ConfigError.invalidConfig("\(configPath): \(error.description)")
        }
    }
    let config = try decodeConfig(object)
    try validate(config)
    return config
}

/// 配置文件放在哪儿。
public enum ConfigFile {
    /// 生效的配置文件（TOML 格式）
    public static var path: String { AppPaths.configDir + "/config.toml" }
    /// 旧版本的 JSON 配置：迁移后不再读，但**保留不删**（删除交给人）
    public static var legacyJSONPath: String { AppPaths.configDir + "/config.json" }
}

/// 决定这次读哪个文件：指定了就用它；没指定就用 TOML，没有 TOML 但有老 JSON 就先迁移。
private func resolveConfigPath(_ path: String?) throws -> String {
    if let path { return path }
    let tomlPath = ConfigFile.path
    if FileManager.default.fileExists(atPath: tomlPath) { return tomlPath }
    let legacy = ConfigFile.legacyJSONPath
    guard FileManager.default.fileExists(atPath: legacy) else { return tomlPath }
    do {
        try migrateLegacyJSON(legacy, to: tomlPath)
        Log.info("配置已从 config.json 迁移到 config.toml（旧文件保留，可自行删除）")
        return tomlPath
    } catch {
        Log.warn("老配置迁移失败，先直接读它：\(error.localizedDescription)")
        return legacy
    }
}

/// 老 JSON 配置 → TOML。顺手把老写法的 `defaultVoice` 并进 `sourceVoices.default`。
public func migrateLegacyJSON(_ from: String, to: String) throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: from))
    guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ConfigError.invalidJSON("\(from): 不是合法的 JSON")
    }
    if let legacyDefault = object["defaultVoice"] as? String {
        var sourceVoices = object["sourceVoices"] as? [String: Any] ?? [:]
        if sourceVoices["default"] == nil { sourceVoices["default"] = legacyDefault }
        object["sourceVoices"] = sourceVoices
        object.removeValue(forKey: "defaultVoice")
    }
    let text = TOML.string(from: TOML.table(from: object), order: ConfigAudit.sectionOrder)
    try text.write(toFile: to, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: to)
}

/// 字典 → 配置对象（TOML 与 JSON 都归到这里，解码逻辑只有一份）。
private func decodeConfig(_ object: [String: Any]) throws -> Config {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object) else {
        throw ConfigError.invalidConfig("配置内容无法解析")
    }
    do {
        return try JSONDecoder().decode(Config.self, from: data)
    } catch {
        throw ConfigError.invalidConfig("\(error)")
    }
}

public func saveConfig(_ config: Config, to path: String? = nil) throws {
    let configPath = path ?? ConfigFile.path
    let encoder = JSONEncoder()
    let data = try encoder.encode(config)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ConfigError.invalidConfig("配置无法序列化")
    }
    let text = TOML.string(from: TOML.table(from: object), order: ConfigAudit.sectionOrder)
    try text.write(toFile: configPath, atomically: true, encoding: .utf8)
    // 配置里有微信 token 等凭据，收到只有本人可读
    try? FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: configPath)
}

/// 就地改配置里的若干键（`"wechat.token"` 这样写路径）。
///
/// **保留用户写的注释与排版**——整体重写会把注释冲掉，配置是用户自己的地盘。
public func updateConfigValues(at path: String, _ values: [String: TOMLValue]) throws {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    var updated = text
    for (key, value) in values {
        let doc = try TOMLDocument.parse(updated, order: ConfigAudit.sectionOrder)
        updated = doc.setting(value, forKey: key)
    }
    try updated.write(toFile: path, atomically: true, encoding: .utf8)
}

public func validate(_ config: Config) throws {
    if config.defaultVoice.isEmpty {
        throw ConfigError.invalidConfig("sourceVoices.default 未设置")
    }
    let tts = config.resolvedTTS
    if tts.streamingInterval <= 0 {
        throw ConfigError.invalidConfig("tts.streamingInterval 必须大于 0")
    }
    if tts.outputSampleRate <= 0 {
        throw ConfigError.invalidConfig("tts.outputSampleRate 必须大于 0")
    }
    if config.voice(id: config.defaultVoice) == nil {
        throw ConfigError.invalidConfig("sourceVoices.default 不存在: \(config.defaultVoice)")
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
