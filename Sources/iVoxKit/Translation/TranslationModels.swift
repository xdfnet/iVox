import Foundation

// MARK: - 翻译结果

public enum TranslationResult: Sendable, Equatable {
    case success(String)
    case failed(String, error: String)

    public var text: String? {
        if case .success(let t) = self { return t }
        return nil
    }

    public var errorMessage: String? {
        if case .failed(_, let e) = self { return e }
        return nil
    }
}

// MARK: - 服务提供商

public enum TranslationProvider: String, Codable, Sendable, CaseIterable {
    case google
    case openai
}

// MARK: - 配置

/// 划词翻译配置（config.json 的 `translation` section）。
/// 每个字段都带兜底默认值：**旧配置（完全没有这个 section）解码不会失败**。
public struct TranslationConfig: Codable, Sendable {
    public var enabled: Bool
    public var provider: TranslationProvider
    public var baseURL: String
    public var apiKey: String
    public var model: String
    /// 翻译完成后是否朗读译文
    public var speechEnabled: Bool
    /// 朗读音色；nil = 用 config.defaultVoice
    public var speechVoice: String?
    /// 结果浮窗自动隐藏秒数
    public var panelTimeoutSeconds: Double
    /// 翻译请求超时秒数
    public var timeoutSeconds: Double
    /// 直连失败时的兜底代理（如 `http://192.168.100.6:10808`）。空 / nil = 不走代理。
    /// 只在**直连已经失败之后**才用，所以本地模型（baseURL 指向 127.0.0.1）不受影响。
    public var proxyURL: String?

    public init(
        enabled: Bool = true,
        provider: TranslationProvider = .google,
        baseURL: String = "https://api.openai.com/v1",
        apiKey: String = "",
        model: String = "gpt-5-mini",
        speechEnabled: Bool = true,
        speechVoice: String? = nil,
        panelTimeoutSeconds: Double = 8,
        timeoutSeconds: Double = 20,
        proxyURL: String? = nil
    ) {
        self.enabled = enabled
        self.provider = provider
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.speechEnabled = speechEnabled
        self.speechVoice = speechVoice
        self.panelTimeoutSeconds = panelTimeoutSeconds
        self.timeoutSeconds = timeoutSeconds
        self.proxyURL = proxyURL
    }

    public static let `default` = TranslationConfig()

    // MARK: 翻译指令常量（与 iDict 一致：英译中）

    /// 直连探测用的超时：比正式超时短得多。直连不通（如国内访问 Google）时，
    /// 不该让用户干等两轮完整超时才发现该走代理。Google 有主/备两条通道，
    /// 所以直连阶段的实际等待是它的两倍；3 秒对正常跨国请求也够用，误判了也只是走代理。
    public static let directProbeTimeoutSeconds: Double = 3

    public static let sourceLanguage = "en"
    public static let targetLanguage = "zh"
    public static let systemPrompt =
        "You are a translation engine. Follow the user's translation instruction exactly. Return only the final translation."
    public static let userPromptTemplate = "将下面的文本翻译为自然、准确的简体中文，只返回译文：\n{{text}}"

    private enum CodingKeys: String, CodingKey {
        case enabled, provider, baseURL, apiKey, model
        case speechEnabled, speechVoice, panelTimeoutSeconds, timeoutSeconds, proxyURL
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TranslationConfig.default
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        provider = try c.decodeIfPresent(TranslationProvider.self, forKey: .provider) ?? d.provider
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? d.baseURL
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? d.apiKey
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        speechEnabled = try c.decodeIfPresent(Bool.self, forKey: .speechEnabled) ?? d.speechEnabled
        speechVoice = try c.decodeIfPresent(String.self, forKey: .speechVoice)
        panelTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .panelTimeoutSeconds) ?? d.panelTimeoutSeconds
        timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? d.timeoutSeconds
        let proxy = try c.decodeIfPresent(String.self, forKey: .proxyURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        proxyURL = (proxy?.isEmpty == false) ? proxy : nil
    }
}
