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

/// 媒体控制（Web 控制台）的配置：**代码内配置**，不进外部配置。
///
/// 端口与开关是产品的一部分（Web 控制台一直在 8888），不是「你常改的」——
/// 2026-10-21 飞哥裁决从外部配置挪进代码。外部配置里再写 `mediaControl` 段会被忽略，
/// 并被配置审计点名（写了不生效）。
public struct MediaControlConfig: Codable, Sendable {
    /// 是否开 Web 控制台
    public var httpServerEnabled: Bool
    /// Web 控制台端口
    public var httpServerPort: Int

    public init(httpServerEnabled: Bool = true, httpServerPort: Int = 8888) {
        self.httpServerEnabled = httpServerEnabled
        self.httpServerPort = httpServerPort
    }

    /// 生效值：代码内配置就是它自己
    public static let `default` = MediaControlConfig()

    enum CodingKeys: String, CodingKey, CaseIterable {
        case httpServerEnabled
        case httpServerPort
    }
}

public struct PlaybackConfig: Codable, Sendable {
    /// 空闲宽限期（秒）：声音停下后再等这么久没新内容，才判「说完了」并收字幕/还音量
    public var idleGraceSeconds: Double?

    /// 空闲宽限的默认值（秒），也是全仓唯一一处写着这个数的地方。
    ///
    /// **为什么是 60 秒而不是 5 秒（2026-10-24 实测改）**：宽限是「端说完了没有」的**兜底**，
    /// 常态的判据是端自己的收尾信号（Claude 的 Stop / pi 的 `{end}`）——它一到就立刻收，不等宽限。
    /// 早先的 5 秒在实况里几乎每轮都会误判「说完了」：Claude 一轮里的多页之间本来就隔着
    /// 工具调用（实测同轮内批间隔 20~130 秒），5 秒一到就把这一摞盖印、结算、收字幕、还音量，
    /// 下一分钟又来一页 → **一轮被切成好几摞、汽水音量一升一降**（而「一摞 = 一次输入引发的
    /// 全部回复」正是用户按 Ctrl+1 时心里的那一个）。
    ///
    /// 60 秒盖住「同一轮里两页之间的正常间隔」；再长的间隔（跑长测试、长时间想）仍会切一次，
    /// 那是兜底的代价，认了。宽限只盖印不埋碑：内容后来再到来照样揭封续播。
    public static let defaultIdleGraceSeconds: Double = 60

    public static let `default` = PlaybackConfig(idleGraceSeconds: defaultIdleGraceSeconds)

    /// 未配置时的回退见 `defaultIdleGraceSeconds`
    public var resolvedIdleGraceSeconds: Double { idleGraceSeconds ?? Self.defaultIdleGraceSeconds }
    /// 键名清单（配置审计用）：由 CodingKeys 派生，不另抄一份——两份清单迟早会漂。
    public static var knownKeys: Set<String> { Set(CodingKeys.allCases.map(\.stringValue)) }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case idleGraceSeconds
    }

}

/// 字幕浮窗在屏上的落点。
public enum CaptionPosition: String, Codable, Sendable, CaseIterable {
    /// 贴底（默认）：浮窗底边距可见区底边 `inset` 点
    case bottom
    /// 贴顶：浮窗顶边距可见区顶边 `inset` 点
    case top
    /// 垂直居中
    case center
}

/// 播报字幕（**独立一段**，不塞在播报里）：开关 + 钉在哪块屏 + 长什么样、落在哪儿。
///
/// 2026-10-24 从 `[playback]` 挪出来：字幕是「屏幕上的显示」，跟「播报怎么排队收尾」
/// 是两件事，混在一段里时用户改字幕开关要去翻播报的配置。
///
/// 字段一律**非可选 + 缺省用默认**（同 `SpeechInputConfig` 的写法）：默认值只写这一处，
/// 模板与代码由测试钉住不会出现两份。旧配置缺字段也能加载。
public struct CaptionsConfig: Codable, Sendable {
    /// 是否显示播报字幕（念到哪句就在屏上显示哪句）
    public var enabled: Bool
    /// 字幕钉在哪块屏：那块屏的 UUID；空 = 主屏。
    ///
    /// 填 UUID 而不是序号/型号：同型号同分辨率的两块屏（两块 Redmi 27 NU）只有 UUID 认得出，
    /// 而这个 UUID 系统自己拿来记屏幕摆位——拔插、重启、改分辨率都不变。
    public var screen: String
    /// 落点：贴底 / 贴顶 / 垂直居中
    public var position: CaptionPosition
    /// 距落点那条边的点数
    public var inset: Double
    /// 内容宽度上限（超出折行）
    public var maxWidth: Double
    /// 内容高度上限＝可见高的比例（超出截尾）
    public var maxHeightRatio: Double
    /// 字号
    public var fontSize: Double
    /// 内边距
    public var padding: Double
    /// 圆角
    public var cornerRadius: Double

    /// 缺字段用默认值：TOML 里只写要改的那一项也能加载
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? Self.default.enabled
        self.screen = try c.decodeIfPresent(String.self, forKey: .screen) ?? Self.default.screen
        self.position = try c.decodeIfPresent(CaptionPosition.self, forKey: .position) ?? Self.default.position
        self.inset = try c.decodeIfPresent(Double.self, forKey: .inset) ?? Self.default.inset
        self.maxWidth = try c.decodeIfPresent(Double.self, forKey: .maxWidth) ?? Self.default.maxWidth
        self.maxHeightRatio = try c.decodeIfPresent(Double.self, forKey: .maxHeightRatio) ?? Self.default.maxHeightRatio
        self.fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? Self.default.fontSize
        self.padding = try c.decodeIfPresent(Double.self, forKey: .padding) ?? Self.default.padding
        self.cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? Self.default.cornerRadius
    }

    public init(enabled: Bool = false, screen: String = "", position: CaptionPosition = .bottom,
                inset: Double = 18, maxWidth: Double = 600, maxHeightRatio: Double = 0.3,
                fontSize: Double = 16, padding: Double = 14, cornerRadius: Double = 10) {
        self.enabled = enabled
        self.screen = screen
        self.position = position
        self.inset = inset
        self.maxWidth = maxWidth
        self.maxHeightRatio = maxHeightRatio
        self.fontSize = fontSize
        self.padding = padding
        self.cornerRadius = cornerRadius
    }

    /// 默认值真源（全仓只此一处）：字幕默认关、贴底 18 点、宽 600、字号 16。
    public static let `default` = CaptionsConfig()

    /// 字幕默认关：它会一直占着屏幕，只在你明确要看时才开
    public var resolvedEnabled: Bool { enabled }
    /// 空串按「没指定屏」算 = 主屏
    public var resolvedScreen: String? {
        let trimmed = screen.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    /// 键名清单（配置审计用）：由 CodingKeys 派生，不另抄一份——两份清单迟早会漂。
    public static var knownKeys: Set<String> { Set(CodingKeys.allCases.map(\.stringValue)) }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case enabled
        case screen
        case position
        case inset
        case maxWidth
        case maxHeightRatio
        case fontSize
        case padding
        case cornerRadius
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
        self.claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath) ?? WeChatConfig.defaultClaudePath
        self.askTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .askTimeoutSeconds)
    }

    /// claude 可执行文件的默认位置（配置里不写就用它）
    public static let defaultClaudePath = "~/.local/bin/claude"

    public init(token: String = "", baseURL: String = "https://ilinkai.weixin.qq.com", allowFrom: String = "", longPollMS: Int = 35000, dataDir: String = "", claudePath: String? = WeChatConfig.defaultClaudePath, askTimeoutSeconds: Int? = nil) {
        self.token = token
        self.baseURL = baseURL
        self.allowFrom = allowFrom
        self.longPollMS = longPollMS
        self.dataDir = dataDir
        self.claudePath = claudePath
        self.askTimeoutSeconds = askTimeoutSeconds
    }

    public var enabled: Bool { !token.isEmpty }
    public var resolvedClaudePath: String { claudePath ?? Self.defaultClaudePath }
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
    public var playback: PlaybackConfig? = nil
    /// 播报字幕（独立段：屏幕上的显示，与「播报怎么排队收尾」分开）
    public var captions: CaptionsConfig? = nil
    /// 来源 → 音色 id 的映射。**`"default"` 键就是默认音色**（没有来源时用它），
    /// 所以不再单设一个 `defaultVoice` 字段——一处说清，别两处各写一遍。
    public var sourceVoices: [String: String]
    /// **用户自建/覆盖的音色**（可选）。内置音色在代码里（`VoiceCatalog`），
    /// 不进外部配置；两者合并见 `resolvedVoices`。
    public var voices: [VoiceInfo]? = nil
    public var speechInput: SpeechInputConfig?
    public var wechat: WeChatConfig?
    public var translation: TranslationConfig? = nil
    /// 热键覆盖：键是动作名（见 `HotKeyAction`），值是组合键串（`"opt+w"`）。
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
    public var resolvedPlayback: PlaybackConfig { playback ?? .default }
    public var resolvedCaptions: CaptionsConfig { captions ?? .default }
    public var resolvedTranslation: TranslationConfig { translation ?? .default }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case hotkeys
        case speechInput
        case translation
        case playback
        case captions
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

/// 字幕键挪段迁移（2026-10-24）：字幕从 `[playback]` 挪到了独立的 `[captions]` 段。
///
/// 老配置里写着 `playback.captions` / `playback.captionScreen`——照搬会让用户的字幕开关
/// 升级后**无声失效**（变成默认关，看着像「字幕坏了」）。这里把它们搬过来照常生效，
/// 审计再告诉用户去把文件里的那两行挪过去（见 `ConfigAudit.movedKeys`）。
private func migrateCaptionKeys(_ object: inout [String: Any]) -> Bool {
    guard var playback = object["playback"] as? [String: Any] else { return false }
    var captions = object["captions"] as? [String: Any] ?? [:]
    var moved = false
    if let value = playback.removeValue(forKey: "captions"), captions["enabled"] == nil {
        captions["enabled"] = value
        moved = true
    }
    if let value = playback.removeValue(forKey: "captionScreen"), captions["screen"] == nil {
        captions["screen"] = value
        moved = true
    }
    if playback.isEmpty { object.removeValue(forKey: "playback") } else { object["playback"] = playback }
    if !captions.isEmpty { object["captions"] = captions }
    return moved
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
    var object = object
    if migrateCaptionKeys(&object) {
        Log.info("配置迁移：字幕键已从 playback 段挪到 captions 段（enabled / screen）——"
                 + "请把 config.toml 里那两行挪到 [captions] 段")
    }
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
    // 字幕的外观数字：写错（负数、零宽、比例超 1）当场报错，别等渲染时才发现
    let captions = config.resolvedCaptions
    if captions.inset < 0 { throw ConfigError.invalidConfig("captions.inset 不能为负") }
    if captions.maxWidth <= 0 { throw ConfigError.invalidConfig("captions.maxWidth 必须大于 0") }
    if captions.maxHeightRatio <= 0 || captions.maxHeightRatio > 1 {
        throw ConfigError.invalidConfig("captions.maxHeightRatio 必须在 0~1 之间")
    }
    if captions.fontSize <= 0 { throw ConfigError.invalidConfig("captions.fontSize 必须大于 0") }
    if captions.padding < 0 { throw ConfigError.invalidConfig("captions.padding 不能为负") }
    if captions.cornerRadius < 0 { throw ConfigError.invalidConfig("captions.cornerRadius 不能为负") }
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
