import XCTest
@testable import iVoxKit

final class ConfigTests: XCTestCase {

    func testValidationFailsOnMissingDefaultVoice() {
        let config = Config(playback: PlaybackConfig(
            sourceVoices: ["default": "missing"],
            voices: [VoiceInfo(id: "voice", description: nil)]
        ))
        XCTAssertThrowsError(try validate(config))
    }

    func testValidationFailsOnMissingSourceVoice() {
        let config = Config(playback: PlaybackConfig(
            sourceVoices: ["default": "voice", "pi": "missing"],
            voices: [VoiceInfo(id: "voice", description: nil)]
        ))
        XCTAssertThrowsError(try validate(config))
    }

    func testValidationPassesOnValidConfig() {
        let config = Config(playback: PlaybackConfig(
            sourceVoices: ["default": "v1", "c": "v1"],
            voices: [VoiceInfo(id: "v1", description: nil)]
        ))
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
        XCTAssertEqual(config.resolvedOverlay.resolvedScreen, "D6F7A473-6F62-468C-8698-1B1944615CF7",
                       "老键 playback.captionScreen 应照常生效（经 captions 段再落到 overlay 段）")
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
        XCTAssertEqual(config.resolvedOverlay.resolvedScreen, "AAAA")
    }

    // MARK: - 字幕落点挪到浮窗段（2026-10-25：字幕与译文合成一块浮窗）

    /// 老配置把钉屏与落点写在 `[captions]` 段——升级后**不能无声失效**
    ///（浮窗悄悄跟到鼠标屏去，看着像「钉屏坏了」）。
    func testLegacyCaptionPlacementMovesToOverlaySection() throws {
        let toml = """
        [sourceVoices]
        default = "taozi"

        [captions]
        enabled = true
        screen = "84945B9B-26CB-4240-AA2A-7E86CF1B0942"
        inset = 30
        padding = 20
        cornerRadius = 6
        position = "top"
        """
        let path = NSTemporaryDirectory() + "ivox-legacy-overlay.toml"
        try toml.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let config = try loadConfig(from: path)
        XCTAssertEqual(config.resolvedOverlay.resolvedScreen, "84945B9B-26CB-4240-AA2A-7E86CF1B0942",
                       "钉屏应挪到 overlay 段照常生效")
        XCTAssertEqual(config.resolvedOverlay.inset, 30, "落点间距应挪到 overlay 段照常生效")
        XCTAssertEqual(config.resolvedOverlay.padding, 20, "载体内边距应挪到 overlay 段照常生效")
        XCTAssertEqual(config.resolvedOverlay.cornerRadius, 6, "载体圆角应挪到 overlay 段照常生效")
        XCTAssertTrue(config.resolvedCaptions.resolvedEnabled, "字幕开关不该受迁移影响")
    }

    /// 新段优先：overlay 段已写了值，老的 captions 段不再覆盖它。
    func testOverlaySectionWinsOverLegacyCaptionPlacement() throws {
        let toml = """
        [sourceVoices]
        default = "taozi"

        [captions]
        screen = "OLD"

        [overlay]
        screen = "NEW"
        """
        let path = NSTemporaryDirectory() + "ivox-both-overlay.toml"
        try toml.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let config = try loadConfig(from: path)
        XCTAssertEqual(config.resolvedOverlay.resolvedScreen, "NEW")
    }

    // MARK: - 音色挪进播报段（2026-10-29）

    /// 老配置把 `sourceVoices` / `voices` 挂在顶层——升级后**不能无声失效**
    ///（否则播报悄悄退回内置音色，看着像「音色丢了」）。
    func testLegacyTopLevelVoicesStillTakeEffect() throws {
        let toml = """
        [sourceVoices]
        default = "taozi"
        claude = "wanwan"

        [[voices]]
        id = "mine"
        name = "我的音色"
        """
        let path = NSTemporaryDirectory() + "ivox-legacy-voices.toml"
        try toml.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let config = try loadConfig(from: path)
        XCTAssertEqual(config.defaultVoice, "taozi")
        XCTAssertEqual(config.sourceVoices["claude"], "wanwan")
        XCTAssertEqual(config.voice(id: "mine")?.name, "我的音色")
    }

    /// 新的位置：`[playback.sourceVoices]` + `[[playback.voices]]`。
    func testVoicesInsidePlaybackSectionTakeEffect() throws {
        let toml = """
        [playback]
        enabled = true

        [playback.sourceVoices]
        default = "taozi"
        claude = "wanwan"

        [[playback.voices]]
        id = "mine"
        name = "我的音色"
        """
        let path = NSTemporaryDirectory() + "ivox-playback-voices.toml"
        try toml.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let config = try loadConfig(from: path)
        XCTAssertEqual(config.sourceVoices["claude"], "wanwan")
        XCTAssertEqual(config.voice(id: "mine")?.name, "我的音色")
        XCTAssertTrue(config.resolvedPlayback.resolvedEnabled)
    }

    // MARK: - 播报总开关

    /// 播报总开关：没写就是**开着**（默认开），写了 false 就关——两种都得对。
    func testPlaybackEnabledDefaultsToTrueAndHonoursFalse() throws {
        let base = """
        [sourceVoices]
        default = "taozi"
        """
        let onPath = NSTemporaryDirectory() + "ivox-playback-on.toml"
        try base.write(toFile: onPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: onPath) }
        XCTAssertTrue(try loadConfig(from: onPath).resolvedPlayback.resolvedEnabled,
                      "没写 playback.enabled 就是开着")

        let offPath = NSTemporaryDirectory() + "ivox-playback-off.toml"
        try (base + "\n[playback]\nenabled = false\n").write(toFile: offPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: offPath) }
        XCTAssertFalse(try loadConfig(from: offPath).resolvedPlayback.resolvedEnabled,
                       "写了 playback.enabled = false 就是关着")
    }
}
