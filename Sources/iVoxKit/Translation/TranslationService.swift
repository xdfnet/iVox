import CFNetwork
import Foundation

// 翻译服务：Google 双通道容灾 + OpenAI 兼容，直连失败走代理。
// MARK: - 翻译服务（actor，按 provider 分派）

/// 划词翻译入口。搬自 iDict `translationservice.swift`，改动：
/// - 去掉 `@MainActor TranslationServiceManager`，改为 `actor`（与 `WeChatClient` 同构）
/// - 配置不再自读 `~/.config/idict/config.json`，由 iVox 的 `Config.translation` 注入
/// - 可注入 `URLSession` 便于单测
public actor TranslationService {
    private let config: TranslationConfig
    private let session: URLSession
    /// 直连失败后才启用的兜底代理会话（`proxyURL` 为空则为 nil）
    private let proxySession: URLSession?
    /// 一旦确认「直连不通、代理可用」就记住，后续直接走代理（省掉每次十几秒的探测）
    private var preferProxy = false

    public init(config: TranslationConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
        self.proxySession = Self.makeProxySession(config.proxyURL)
    }

    /// 直连优先；不通且配了兜底代理就走代理，并把结论记住。
    /// 两者都失败时报**直连**的错误（那更能说明问题，代理错误多半只是它的下游症状）。
    public func translate(_ text: String) async -> TranslationResult {
        // 上次已确认要走代理：直接上，省一轮探测
        if preferProxy, let proxySession {
            let cached = await dispatch(text, session: proxySession, timeout: config.timeoutSeconds)
            if case .success = cached { return cached }
            Log.warn("翻译: 记住的代理通道也失败了，退回直连")
            preferProxy = false   // 代理也不通了，退回直连再试一次
        }

        // 直连探测用短超时：不通时别让用户干等两轮完整超时
        let probe = min(config.timeoutSeconds, TranslationConfig.directProbeTimeoutSeconds)
        let direct = await dispatch(text, session: session, timeout: probe)
        if case .success = direct { return direct }

        guard let proxySession else { return direct }
        Log.warn("翻译: 直连不通，改走代理 \(config.proxyURL ?? "")")
        let viaProxy = await dispatch(text, session: proxySession, timeout: config.timeoutSeconds)
        if case .success = viaProxy {
            preferProxy = true
            return viaProxy
        }
        return direct
    }

    private func dispatch(
        _ text: String, session: URLSession, timeout: Double
    ) async -> TranslationResult {
        switch config.provider {
        case .google:
            return await GoogleTranslator.translate(text, timeout: timeout, session: session)
        case .openai:
            return await OpenAICompatTranslator.translate(text, config: config, session: session)
        }
    }

    /// 把 `http://host:port` 变成**只属于这个 session** 的代理配置，不改动全局网络设置。
    static func makeProxySession(_ proxyURL: String?) -> URLSession? {
        guard let proxyURL,
              let url = URL(string: proxyURL),
              let host = url.host,
              let port = url.port else { return nil }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: host,
            kCFNetworkProxiesHTTPPort as String: port,
            kCFNetworkProxiesHTTPSEnable as String: true,
            kCFNetworkProxiesHTTPSProxy as String: host,
            kCFNetworkProxiesHTTPSPort as String: port,
        ]
        return URLSession(configuration: cfg)
    }
}

// MARK: - Google（双通道容灾）

public enum GoogleTranslator {
    /// 主通道失败（限流 / HTTP 错 / 网络错 / 空结果）自动切备用通道。
    public static func translate(
        _ text: String, timeout: TimeInterval, session: URLSession
    ) async -> TranslationResult {
        if let translated = await viaPrimary(text, timeout: timeout, session: session),
           !translated.isEmpty {
            return .success(translated)
        }
        Log.debug("翻译通道: google 主通道未命中，降级备用通道 translateHtml")
        let result = await viaBackup(text, timeout: timeout, session: session)
        if case .success = result {
            Log.debug("翻译通道: google 备用通道成功")
        } else {
            Log.warn("翻译通道: google 主备双通道均失败")
        }
        return result
    }

    /// 主通道 translate_a/t（比 single 稳：single 在同一 IP 下易被 302 跳限流页）。
    private static func viaPrimary(
        _ text: String, timeout: TimeInterval, session: URLSession
    ) async -> String? {
        let sl = TranslationConfig.sourceLanguage
        let tl = TranslationConfig.targetLanguage
        guard let url = URL(string:
            "https://translate.googleapis.com/translate_a/t?client=gtx&sl=\(sl)&tl=\(tl)&dt=t")
        else { return nil }

        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "q", value: text)]

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = timeout
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                Log.debug("翻译通道: google 主通道 HTTP \(http.statusCode)")
                return nil
            }
            return parsePrimaryResponse(data)
        } catch {
            Log.debug("翻译通道: google 主通道请求异常: \(error.localizedDescription)")
            return nil
        }
    }

    /// 备用通道 translateHtml：正文 `[[[文本], 源语言, 目标语言], "te_lib"]`，响应 `[["译文"]]`。
    private static func viaBackup(
        _ text: String, timeout: TimeInterval, session: URLSession
    ) async -> TranslationResult {
        guard let url = URL(string: "https://translate-pa.googleapis.com/v1/translateHtml") else {
            return .failed(text, error: "无效的翻译请求 URL")
        }
        let payload: [Any] = [
            [[text], TranslationConfig.sourceLanguage, TranslationConfig.targetLanguage],
            "te_lib",
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return .failed(text, error: "Google 翻译请求构造失败")
        }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = timeout
            request.setValue("application/json+protobuf", forHTTPHeaderField: "Content-Type")
            request.setValue(GOOGLE_PUBLIC_KEY, forHTTPHeaderField: "x-goog-api-key")
            request.httpBody = body
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 429 {
                    return .failed(text, error: "Google 限流：当前网络/代理 IP 被判定为异常流量，请稍后重试或切换网络")
                }
                if !(200...299).contains(http.statusCode) {
                    return .failed(text, error: "Google 翻译请求失败：HTTP \(http.statusCode)")
                }
            }
            if let translated = parseBackupResponse(data), !translated.isEmpty {
                return .success(translated)
            }
        } catch {
            return .failed(text, error: "Google 翻译请求失败: \(error.localizedDescription)")
        }
        return .failed(text, error: "Google 翻译返回空结果")
    }

    /// 备用通道内置的谷歌公共 key（与 iDict 同源）。**可能失效**，仅作主通道的兜底。
    static let GOOGLE_PUBLIC_KEY = "AIzaSyATBXajvzQLTDHEQbcpq0Ihe0vWDHmO520"

    /// t 端点正常返回 `["译文"]`；兼容旧版 `[[["译文", ...], ...]]` 嵌套。
    public static func parsePrimaryResponse(_ data: Data) -> String? {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return nil
        }
        if let strings = array as? [String] { return strings.first }
        if let sentences = array.first as? [[Any]] {
            return sentences.compactMap { $0.first as? String }.joined()
        }
        return nil
    }

    /// translateHtml 返回 `[["译文"]]`；兼容外层直接是 `["译文"]`。
    public static func parseBackupResponse(_ data: Data) -> String? {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return nil
        }
        if let strings = array as? [String] { return strings.first }
        guard let inner = array.first as? [Any] else { return nil }
        if let strings = inner as? [String] { return strings.first }
        return (inner.first as? [Any])?.first as? String
    }
}

// MARK: - OpenAI 兼容

public enum OpenAICompatTranslator {
    struct ChatCompletionResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }

    public static func translate(
        _ text: String, config: TranslationConfig, session: URLSession
    ) async -> TranslationResult {
        guard !config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed(text, error: "OpenAI API Key 未配置")
        }
        guard let url = chatCompletionsURL(baseURL: config.baseURL) else {
            return .failed(text, error: "OpenAI Base URL 无效")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": config.model,
            "messages": [
                ["role": "system", "content": TranslationConfig.systemPrompt],
                ["role": "user", "content": renderUserPrompt(text)],
            ],
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                return .failed(text, error: "OpenAI 翻译请求失败: \(message)")
            }
            return parseTranslation(data, originalText: text)
        } catch {
            return .failed(text, error: "OpenAI 翻译请求失败: \(error.localizedDescription)")
        }
    }

    public static func renderUserPrompt(_ text: String) -> String {
        TranslationConfig.userPromptTemplate.replacingOccurrences(of: "{{text}}", with: text)
    }

    public static func chatCompletionsURL(baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(trimmed)/chat/completions")
    }

    public static func parseTranslation(_ data: Data, originalText: String) -> TranslationResult {
        do {
            let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            let translated = response.choices.first?.message.content?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !translated.isEmpty else {
                return .failed(originalText, error: "OpenAI 翻译返回空结果")
            }
            return .success(translated)
        } catch {
            return .failed(originalText, error: "OpenAI 翻译返回格式无效: \(error.localizedDescription)")
        }
    }
}
