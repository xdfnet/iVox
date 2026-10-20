import XCTest
@testable import iVoxKit

/// 配置走 TOML：读得进、写得出、写回时**不冲掉用户写的注释**。
final class ConfigTOMLTests: XCTestCase {

    private func tempPath(_ name: String) -> String {
        NSTemporaryDirectory() + "ivox-toml-test-\(name).toml"
    }

    private let sample = """
    # iVox 配置
    [hotkeys]
    translate = "cmd+d"     # 我爱用 cmd+d

    [sourceVoices]
    default = "taozi"
    claude = "taozi"
    pi = "wanwan"

    [wechat]
    token = "t"
    allowFrom = "u"
    longPollMS = 35000
    baseURL = "https://ilinkai.weixin.qq.com"
    """

    func testLoadsTOMLConfig() throws {
        let path = tempPath("load")
        try sample.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let config = try loadConfig(from: path)
        XCTAssertEqual(config.hotkeys?["translate"], "cmd+d")
        XCTAssertEqual(config.defaultVoice, "taozi")
        XCTAssertEqual(config.sourceVoices["pi"], "wanwan")
        XCTAssertEqual(config.wechat?.allowFrom, "u")
    }

    func testAuditFindsUnknownKeyInTOML() {
        let text = """
        [wechat]
        allow_from = "abc"
        """
        let issues = ConfigAudit.unknownKeys(inTOMLText: text)
        XCTAssertEqual(issues.map(\.path), ["wechat.allow_from"])
        XCTAssertEqual(issues.first?.suggestion, "allowFrom")
    }

    func testUpdatingValueKeepsComments() throws {
        let path = tempPath("update")
        try sample.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        try updateConfigValues(at: path, ["hotkeys.translate": .string("cmd+shift+d")])
        let updated = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(updated.contains("translate = \"cmd+shift+d\""))
        XCTAssertTrue(updated.contains("# 我爱用 cmd+d"))
        XCTAssertTrue(updated.contains("# iVox 配置"))
    }

    func testSavingWritesTOML() throws {
        let path = tempPath("save")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let config = Config(
            sourceVoices: ["default": "taozi", "pi": "wanwan"],
            voices: [VoiceInfo(id: "v1", name: "测试")]
        )
        try saveConfig(config, to: path)

        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(text.contains("[sourceVoices]"))
        XCTAssertTrue(text.contains("default = \"taozi\""))
        XCTAssertTrue(text.contains("[[voices]]"))

        // 写出来的东西读得回去
        let loaded = try loadConfig(from: path)
        XCTAssertEqual(loaded.defaultVoice, "taozi")
        XCTAssertEqual(loaded.voice(id: "v1")?.name, "测试")
    }

    func testTemplateIsValidConfig() throws {
        // 模板必须自己就能加载（首装就靠它）
        let path = tempPath("template")
        try ConfigTemplate.tomlText.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let config = try loadConfig(from: path)
        XCTAssertFalse(config.defaultVoice.isEmpty)
        XCTAssertTrue(config.hotkeys?["translate"] != nil)
    }
}
