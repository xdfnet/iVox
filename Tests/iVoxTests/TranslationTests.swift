import XCTest
@testable import iVoxKit

// MARK: - 选中文本清洗

final class SelectionTextTests: XCTestCase {
    func testStripsPipeAndCollapsesWhitespace() {
        XCTAssertEqual(cleanSelectionText("  hello│   world \n"), "hello world")
    }

    func testKeepsMultilineTextOnOneLine() {
        XCTAssertEqual(cleanSelectionText("a\n\nb"), "a b")
    }

    func testEmptyAfterCleanIsRejected() {
        XCTAssertNil(validateSelectionText("   \n│  "))
    }

    func testTooLongIsRejected() {
        XCTAssertNil(validateSelectionText(String(repeating: "a", count: 5001)))
        XCTAssertNotNil(validateSelectionText(String(repeating: "a", count: 5000)))
    }

    func testNormalTextPassesThrough() {
        XCTAssertEqual(validateSelectionText("hello world"), "hello world")
    }
}

// MARK: - 翻译响应解析

final class TranslationParseTests: XCTestCase {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    func testPrimaryFlatArray() {
        XCTAssertEqual(GoogleTranslator.parsePrimaryResponse(data(#"["你好"]"#)), "你好")
    }

    func testPrimaryNestedSentenceArray() {
        // 旧版格式：[[["你好",…],["世界",…]]]
        let json = #"[[["你好",null,null],["世界",null,null]]]"#
        XCTAssertEqual(GoogleTranslator.parsePrimaryResponse(data(json)), "你好世界")
    }

    func testPrimaryMalformedReturnsNil() {
        XCTAssertNil(GoogleTranslator.parsePrimaryResponse(data("not json")))
    }

    func testBackupNestedArray() {
        XCTAssertEqual(GoogleTranslator.parseBackupResponse(data(#"[["你好"]]"#)), "你好")
    }

    func testBackupFlatArray() {
        XCTAssertEqual(GoogleTranslator.parseBackupResponse(data(#"["你好"]"#)), "你好")
    }

    func testOpenAIURLTrimsTrailingSlashes() {
        XCTAssertEqual(
            OpenAICompatTranslator.chatCompletionsURL(baseURL: "http://127.0.0.1:8000/v1/")?.absoluteString,
            "http://127.0.0.1:8000/v1/chat/completions")
    }

    func testRenderUserPromptSubstitutesText() {
        XCTAssertTrue(OpenAICompatTranslator.renderUserPrompt("hello").contains("hello"))
        XCTAssertFalse(OpenAICompatTranslator.renderUserPrompt("hello").contains("{{text}}"))
    }

    func testParseOpenAIChoice() {
        let json = #"{"choices":[{"message":{"content":"  你好  "}}]}"#
        XCTAssertEqual(OpenAICompatTranslator.parseTranslation(data(json), originalText: "hi").text, "你好")
    }

    func testParseOpenAIEmptyContentFails() {
        let json = #"{"choices":[{"message":{"content":"   "}}]}"#
        XCTAssertNotNil(OpenAICompatTranslator.parseTranslation(data(json), originalText: "hi").errorMessage)
    }
}

// MARK: - 配置解码兼容

final class TranslationConfigDecodeTests: XCTestCase {
    private func decode(_ json: String) throws -> TranslationConfig {
        try JSONDecoder().decode(TranslationConfig.self, from: Data(json.utf8))
    }

    func testEmptyObjectFallsBackToDefaults() throws {
        let c = try decode("{}")
        XCTAssertEqual(c.provider, .google)
        XCTAssertTrue(c.enabled)
        XCTAssertEqual(c.timeoutSeconds, 20)
    }

    func testPartialSectionKeepsGivenValues() throws {
        let c = try decode(#"{"provider":"openai","apiKey":"sk-x"}"#)
        XCTAssertEqual(c.provider, .openai)
        XCTAssertEqual(c.apiKey, "sk-x")
        XCTAssertEqual(c.model, TranslationConfig.default.model)  // 未给的沿用默认
    }

    /// 老配置完全没有 translation section 时必须仍能解码。
    func testConfigWithoutTranslationSectionDecodes() throws {
        let json = #"{"defaultVoice":"taozi","sourceVoices":{},"voices":[{"id":"taozi"}]}"#
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertNil(config.translation)
        XCTAssertEqual(config.resolvedTranslation.provider, .google)
    }

    func testBlankProxyBecomesNil() throws {
        XCTAssertNil(try decode(#"{"proxyURL":"   "}"#).proxyURL)
        XCTAssertEqual(try decode(#"{"proxyURL":"http://192.168.100.6:10808"}"#).proxyURL,
                       "http://192.168.100.6:10808")
    }
}

// MARK: - 兜底代理会话

final class TranslationProxySessionTests: XCTestCase {
    func testBuildsSessionForValidProxyURL() {
        XCTAssertNotNil(TranslationService.makeProxySession("http://192.168.100.6:10808"))
    }

    func testReturnsNilWhenUnsetOrMalformed() {
        XCTAssertNil(TranslationService.makeProxySession(nil))
        XCTAssertNil(TranslationService.makeProxySession(""))
        XCTAssertNil(TranslationService.makeProxySession("http://host-without-port"))
    }
}

// MARK: - 重复翻译不重复干活

/// 数请求数的假服务：主通道回一个固定的合法译文，让「有没有真的发第二次请求」可断言。
private final class CountingURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestCount = 0
    /// 让第一个请求慢一点，好让「在途去重」那条测试真的撞上并发窗口
    nonisolated(unsafe) static var delaySeconds: Double = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        let finish = { [weak self] in
            let body = Data(#"["译"]"#.utf8)
            self?.client?.urlProtocol(self!, didReceive: HTTPURLResponse(
                url: self!.request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            self?.client?.urlProtocol(self!, didLoad: body)
            self?.client?.urlProtocolDidFinishLoading(self!)
        }
        if Self.delaySeconds > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.delaySeconds, execute: finish)
        } else {
            finish()
        }
    }

    override func stopLoading() {}
}

final class TranslationCacheTests: XCTestCase {
    override func setUp() {
        super.setUp()
        CountingURLProtocol.requestCount = 0
        CountingURLProtocol.delaySeconds = 0
    }

    private func makeService() -> TranslationService {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [CountingURLProtocol.self]
        return TranslationService(config: .init(), session: URLSession(configuration: cfg))
    }

    /// 同一段文字译两次，只该发一次请求；换一段就该再发一次（缓存只留最后一次）。
    func testSameTextTwiceSendsOneRequest() async {
        let service = makeService()
        let a = await service.translate("你好")
        let b = await service.translate("你好")
        XCTAssertEqual(a.text, "译")
        XCTAssertEqual(b.text, "译")
        XCTAssertEqual(CountingURLProtocol.requestCount, 1)

        _ = await service.translate("另一段")
        XCTAssertEqual(CountingURLProtocol.requestCount, 2)
        // 换回第一段：缓存里已经只剩「另一段」了，该重发
        _ = await service.translate("你好")
        XCTAssertEqual(CountingURLProtocol.requestCount, 3)
    }

    /// 同一段文字在途时再按一次 → 等同一次的结果，不另发请求。
    func testConcurrentSameTextSharesOneRequest() async {
        CountingURLProtocol.delaySeconds = 0.3
        let service = makeService()
        async let first = service.translate("同时按下")
        async let second = service.translate("同时按下")
        let (r1, r2) = await (first, second)
        XCTAssertEqual(r1.text, "译")
        XCTAssertEqual(r2.text, "译")
        XCTAssertEqual(CountingURLProtocol.requestCount, 1)
    }
}
