import XCTest
@testable import iVoxKit

final class ConfigTests: XCTestCase {

    func testValidationFailsOnMissingDefaultVoice() {
        let config = Config(
            api: APIConfig(baseURL: "http://127.0.0.1:8150/v1"),
            defaultVoice: "missing",
            sourceVoices: [:],
            voices: [VoiceInfo(id: "voice", description: nil)],
            configBaseDir: nil
        )
        XCTAssertThrowsError(try validate(config))
    }

    func testValidationFailsOnMissingSourceVoice() {
        let config = Config(
            api: APIConfig(baseURL: "http://127.0.0.1:8150/v1"),
            defaultVoice: "voice",
            sourceVoices: ["codex": "missing"],
            voices: [VoiceInfo(id: "voice", description: nil)],
            configBaseDir: nil
        )
        XCTAssertThrowsError(try validate(config))
    }

    func testValidationPassesOnValidConfig() {
        let config = Config(
            api: APIConfig(baseURL: "http://127.0.0.1:8150/v1"),
            defaultVoice: "v1",
            sourceVoices: ["c": "v1"],
            voices: [VoiceInfo(id: "v1", description: nil)],
            configBaseDir: nil
        )
        XCTAssertNoThrow(try validate(config))
    }
}
