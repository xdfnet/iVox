import XCTest
@testable import iVoxKit

final class ConfigRoundTripTests: XCTestCase {

    func testSaveAndLoadRoundTrip() throws {
        let original = Config(
            api: APIConfig(baseURL: "http://127.0.0.1:8150/v1"),
            defaultVoice: "v1",
            sourceVoices: ["s": "v1"],
            voices: [
                VoiceInfo(id: "v1", name: "测试", description: "desc"),
            ],
            configBaseDir: nil
        )

        let tmpPath = NSTemporaryDirectory() + "ivox-test-config.json"

        try saveConfig(original, to: tmpPath)
        let loaded = try loadConfig(from: tmpPath)

        XCTAssertEqual(loaded.defaultVoice, "v1")
        XCTAssertEqual(loaded.api.baseURL, "http://127.0.0.1:8150/v1")
        XCTAssertEqual(loaded.sourceVoices["s"], "v1")
        let v = try XCTUnwrap(loaded.voice(id: "v1"))
        XCTAssertEqual(v.name, "测试")

        try? FileManager.default.removeItem(atPath: tmpPath)
    }

    func testVoiceAddAndRemoveRoundTrip() throws {
        let original = Config(
            api: APIConfig(baseURL: "http://127.0.0.1:8150/v1"),
            defaultVoice: "a",
            sourceVoices: [:],
            voices: [VoiceInfo(id: "a", name: "AA", description: nil)],
            configBaseDir: nil
        )
        let tmpPath = NSTemporaryDirectory() + "ivox-test-voices.json"
        try saveConfig(original, to: tmpPath)

        var reloaded = try loadConfig(from: tmpPath)
        reloaded.voices.append(VoiceInfo(id: "b", name: "BB", description: "new"))
        try saveConfig(reloaded, to: tmpPath)

        let final = try loadConfig(from: tmpPath)
        XCTAssertEqual(final.voices.count, 2)
        XCTAssertNotNil(final.voice(id: "b"))
        XCTAssertEqual(final.voice(id: "b")?.name, "BB")

        try? FileManager.default.removeItem(atPath: tmpPath)
    }
}
