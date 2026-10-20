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
}
