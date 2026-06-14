import XCTest
@testable import iVoxKit

final class ConfigTests: XCTestCase {

    func testValidationFailsOnMissingDefaultVoice() {
        let config = Config(
            models: nil,
            defaultVoice: "missing",
            sourceVoices: [:],
            voices: [VoiceInfo(id: "voice", description: nil)],
            configBaseDir: nil
        )
        XCTAssertThrowsError(try validate(config))
    }

    func testValidationFailsOnMissingSourceVoice() {
        let config = Config(
            models: nil,
            defaultVoice: "voice",
            sourceVoices: ["codex": "missing"],
            voices: [VoiceInfo(id: "voice", description: nil)],
            configBaseDir: nil
        )
        XCTAssertThrowsError(try validate(config))
    }

    func testValidationPassesOnValidConfig() {
        let config = Config(
            models: ModelConfig(
                asrPath: "~/.config/ivox/model/Qwen3-ASR-1.7B-4bit",
                ttsPath: "~/.config/ivox/model/Qwen3-TTS-12Hz-1.7B-Base-8bit"
            ),
            defaultVoice: "v1",
            sourceVoices: ["c": "v1"],
            voices: [VoiceInfo(id: "v1", description: nil)],
            configBaseDir: nil
        )
        XCTAssertNoThrow(try validate(config))
    }
}
