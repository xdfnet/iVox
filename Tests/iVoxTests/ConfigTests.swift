import XCTest
@testable import iVoxKit

final class ConfigTests: XCTestCase {

    func testValidationFailsOnMissingDefaultVoice() {
        let config = Config(
            sourceVoices: ["default": "missing"],
            voices: [VoiceInfo(id: "voice", description: nil)]
        )
        XCTAssertThrowsError(try validate(config))
    }

    func testValidationFailsOnMissingSourceVoice() {
        let config = Config(
            sourceVoices: ["default": "voice", "pi": "missing"],
            voices: [VoiceInfo(id: "voice", description: nil)]
        )
        XCTAssertThrowsError(try validate(config))
    }

    func testValidationPassesOnValidConfig() {
        let config = Config(
            sourceVoices: ["default": "v1", "c": "v1"],
            voices: [VoiceInfo(id: "v1", description: nil)]
        )
        XCTAssertNoThrow(try validate(config))
    }

    // MARK: - 字幕挪段（2026-10-24：字幕从 [playback] 挪到独立的 [captions]）

    /// 老配置里字幕写在 `[playback]`（`captions` / `captionScreen`）——升级后**不能无声失效**，
    /// 得照常生效（否则用户的字幕开关变成「默认关」，看着像字幕坏了）。
    func testLegacyPlaybackCaptionKeysStillTakeEffect() throws {
        let toml = """
        [sourceVoices]
        default = "taozi"

        [playback]
        captions = true
        captionScreen = "D6F7A473-6F62-468C-8698-1B1944615CF7"
        idleGraceSeconds = 60
        """
        let path = NSTemporaryDirectory() + "ivox-legacy-captions.toml"
        try toml.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let config = try loadConfig(from: path)
        XCTAssertTrue(config.resolvedCaptions.resolvedEnabled, "老键 playback.captions 应照常生效")
        XCTAssertEqual(config.resolvedCaptions.resolvedScreen, "D6F7A473-6F62-468C-8698-1B1944615CF7",
                       "老键 playback.captionScreen 应照常生效")
        XCTAssertEqual(config.resolvedPlayback.resolvedIdleGraceSeconds, 60, "同段里的别的键不该受影响")
    }

    /// 新段优先：老键与新键同时存在时，用新键（老键只是兜底迁移）。
    func testNewCaptionsSectionWinsOverLegacyKeys() throws {
        let toml = """
        [sourceVoices]
        default = "taozi"

        [playback]
        captions = false

        [captions]
        enabled = true
        screen = "AAAA"
        """
        let path = NSTemporaryDirectory() + "ivox-both-captions.toml"
        try toml.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let config = try loadConfig(from: path)
        XCTAssertTrue(config.resolvedCaptions.resolvedEnabled)
        XCTAssertEqual(config.resolvedCaptions.resolvedScreen, "AAAA")
    }
}
