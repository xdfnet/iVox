import XCTest
@testable import iVoxKit

final class AudioPipelineTests: XCTestCase {

    func testUpsample2xLength() {
        let input: [Float] = [0.5, 1.0, 0.0]
        let got = upsample2x(input)
        XCTAssertEqual(got.count, 6)
    }

    func testUpsample2xPreservesEndpoints() {
        let input: [Float] = [0.5, 1.0]
        let got = upsample2x(input)
        XCTAssertEqual(got.first, 0.5)
        XCTAssertEqual(got.last, 1.0)
    }

    func testUpsample2xShortSignal() {
        let input: [Float] = [42.0]
        let got = upsample2x(input)
        XCTAssertEqual(got, [42.0, 42.0])
    }

    func testAudioToPCMProducesInt16Bytes() {
        let samples: [Float] = [0.0, 0.5, -0.5]
        let pcm = audioToPCM(samples)
        // 3 samples → upsampled to 6 → 6 × 2 bytes = 12
        XCTAssertEqual(pcm.count, 12)
    }

    func testAudioToPCMClampsPeak() {
        let samples: [Float] = [2.0, -2.0]
        let pcm = audioToPCM(samples, peakLimit: 1.0)
        // 2 samples → upsampled to 4 → 8 bytes
        let bytes = [UInt8](pcm)
        XCTAssertEqual(bytes.count, 8)
    }

    func testAudioToPCMEmpty() {
        let pcm = audioToPCM([])
        XCTAssertEqual(pcm.count, 0)
    }

    func testAudioToPCMCanKeepNativeSampleRate() {
        let samples: [Float] = [0.0, 0.5, -0.5]
        let pcm = audioToPCM(samples, inputSampleRate: 48_000, outputSampleRate: 48_000)
        XCTAssertEqual(pcm.count, 6)
    }
}
