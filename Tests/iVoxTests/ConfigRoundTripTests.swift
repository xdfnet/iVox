import XCTest
@testable import iVoxKit

final class ConfigRoundTripTests: XCTestCase {

    func testSaveAndLoadRoundTrip() throws {
        let original = Config(
            sourceVoices: ["default": "v1", "s": "v1"],
            voices: [
                VoiceInfo(id: "v1", name: "测试", description: "desc"),
            ]
        )

        let tmpPath = NSTemporaryDirectory() + "ivox-test-config.json"

        try saveConfig(original, to: tmpPath)
        let loaded = try loadConfig(from: tmpPath)

        XCTAssertEqual(loaded.defaultVoice, "v1")
        XCTAssertEqual(loaded.sourceVoices["s"], "v1")
        let v = try XCTUnwrap(loaded.voice(id: "v1"))
        XCTAssertEqual(v.name, "测试")

        try? FileManager.default.removeItem(atPath: tmpPath)
    }

    func testVoiceAddAndRemoveRoundTrip() throws {
        let original = Config(
            sourceVoices: ["default": "a"],
            voices: [VoiceInfo(id: "a", name: "AA", description: nil)]
        )
        let tmpPath = NSTemporaryDirectory() + "ivox-test-voices.json"
        try saveConfig(original, to: tmpPath)

        // 用户自建音色写在外部配置层（config.json 的 voices 段）；内置音色在代码里
        var reloaded = try loadConfig(from: tmpPath)
        reloaded.voices = (reloaded.voices ?? []) + [VoiceInfo(id: "b", name: "BB", description: "new")]
        try saveConfig(reloaded, to: tmpPath)

        let final = try loadConfig(from: tmpPath)
        // 用户层：原有 "a" + 新加 "b"
        XCTAssertEqual(final.voices?.count, 2)
        // 生效清单 = 内置 4 个 + 用户层 2 个
        XCTAssertEqual(final.resolvedVoices.count, VoiceCatalog.builtin.count + 2)
        XCTAssertNotNil(final.voice(id: "b"))
        XCTAssertEqual(final.voice(id: "b")?.name, "BB")

        try? FileManager.default.removeItem(atPath: tmpPath)
    }
}
