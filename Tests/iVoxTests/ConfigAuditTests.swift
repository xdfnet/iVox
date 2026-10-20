import XCTest
@testable import iVoxKit

/// 配置键名审计：把「写了但没人认领」的键揪出来。
final class ConfigAuditTests: XCTestCase {

    private func audit(_ json: String) -> [ConfigUnknownKey] {
        ConfigAudit.unknownKeys(in: Data(json.utf8))
    }

    func testReportsUnknownTopLevelKey() {
        let issues = audit(#"{"hotkey": {"translate": "cmd+d"}}"#)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.path, "hotkey")
        // hotkey → hotkeys：写错一个字母能猜出来
        XCTAssertEqual(issues.first?.suggestion, "hotkeys")
    }

    func testReportsUnknownKeyInsideSection() {
        let issues = audit(#"{"wechat": {"allow_from": "abc"}}"#)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues.first?.path, "wechat.allow_from")
        XCTAssertEqual(issues.first?.suggestion, "allowFrom")
    }

    func testSuggestsSnakeCaseToCamelCase() {
        let issues = audit(#"{"wechat": {"base_url": "x", "long_poll_timeout_ms": 1, "data_dir": "d"}}"#)
        let suggestions = issues.compactMap(\.suggestion)
        XCTAssertTrue(suggestions.contains("baseURL"))
        XCTAssertTrue(suggestions.contains("longPollMS"))
        XCTAssertTrue(suggestions.contains("dataDir"))
    }

    func testIgnoresKnownKeys() {
        let issues = audit("""
        {
          "hotkeys": { "translate": "cmd+d", "voice": "rightcmd" },
          "sourceVoices": { "default": "taozi", "claude": "taozi" },
          "voices": [ { "id": "x" } ]
        }
        """)
        XCTAssertTrue(issues.isEmpty, "不该有告警，实际: \(issues.map(\.path))")
    }

    func testModelsAndTTSAreNowInternalAndReported() {
        // 模型路径与合成参数挪进代码内了，外部配置里再写会被点名（写了不生效）
        let issues = audit(#"{"models": {"asrPath": "a"}, "tts": {"language": "Chinese"}}"#)
        let paths = issues.map(\.path)
        XCTAssertTrue(paths.contains("models"))
        XCTAssertTrue(paths.contains("tts"))
    }

    func testReportsRemovedTopLevelDefaultVoice() {
        // 默认音色已并进 sourceVoices.default，老写法 defaultVoice 现在没人认领
        let issues = audit(#"{"defaultVoice": "taozi"}"#)
        XCTAssertEqual(issues.map(\.path), ["defaultVoice"])
    }

    func testDoesNotInspectDynamicSectionKeys() {
        // hotkeys 的键名是动作名、sourceVoices 是来源名——不是配置键，不该被当成写错
        let issues = audit(#"{"hotkeys": { "translate": "cmd+d", "某个自造动作": "cmd+e" }}"#)
        XCTAssertTrue(issues.isEmpty)
    }

    func testAuditKnowsWeChatKeysAreCamelCaseNow() {
        // 键名统一成驼峰后，蛇形写法会被指出来（这是这次统一的目的）
        let issues = audit(#"{"wechat": {"token": "t", "allowFrom": "u"}}"#)
        XCTAssertTrue(issues.isEmpty)
    }
}
