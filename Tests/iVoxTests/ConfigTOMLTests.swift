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

    [playback.sourceVoices]
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

    func testUpdatingValueKeepsTrailingCommentIntact() throws {
        // 改一个带行尾注释的值：注释与它前面的空格都要原样留着
        // （早先值范围把尾随空格一起吞了 → 改完变成 `enabled = true# 注释`）
        let path = tempPath("comment")
        let text = """
        [playback]
        enabled = true                  # 播报总开关 ｜ 默认 true ｜ true/false
        """
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        try updateConfigValues(at: path, ["playback.enabled": .boolean(false)])
        let updated = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(updated.contains("enabled = false                  # 播报总开关"),
                      "改值不该动行尾注释与它的空格，实际：\(updated)")
    }

    func testSavingWritesTOML() throws {
        let path = tempPath("save")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let config = Config(playback: PlaybackConfig(
            sourceVoices: ["default": "taozi", "pi": "wanwan"],
            voices: [VoiceInfo(id: "v1", name: "测试")]
        ))
        try saveConfig(config, to: path)

        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(text.contains("[playback.sourceVoices]"))
        XCTAssertTrue(text.contains("default = \"taozi\""))
        XCTAssertTrue(text.contains("[[playback.voices]]"))

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
