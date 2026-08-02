import XCTest
@testable import iVoxKit

final class StreamFrameTests: XCTestCase {

    func testChunkEncoding() {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        let frame = StreamFrame.chunk(pcm)
        XCTAssertEqual(frame.count, 8)
        // 小端 UInt32 长度前缀 4
        XCTAssertEqual(Array(frame[0..<4]), [0x04, 0x00, 0x00, 0x00])
        XCTAssertEqual(Array(frame[4..<8]), [0x01, 0x02, 0x03, 0x04])
    }

    func testChunkLargeLength() {
        // 超过 255 字节验证 4 字节前缀
        let pcm = Data(repeating: 0xAB, count: 300)
        let frame = StreamFrame.chunk(pcm)
        XCTAssertEqual(Array(frame[0..<4]), [0x2C, 0x01, 0x00, 0x00])
        XCTAssertEqual(frame.count, 304)
    }

    func testRoundtripMultipleChunks() {
        let chunks = [Data([1]), Data(repeating: 2, count: 100), Data([3, 4, 5])]
        var wire = Data()
        for chunk in chunks { wire.append(StreamFrame.chunk(chunk)) }
        wire.append(StreamFrame.end)

        var remaining = [UInt8]()
        var parsed: [Data] = []
        // 模拟跨多次读取：每次喂 1 字节，确保任意边界不丢帧
        for byte in wire {
            parsed += StreamFrame.parseChunks(from: Data([byte]), into: &remaining)
        }
        XCTAssertEqual(parsed.count, 3)
        for (i, chunk) in chunks.enumerated() {
            XCTAssertEqual(parsed[i], chunk)
        }
        XCTAssertTrue(remaining.isEmpty, "end 之后不应有剩余")
    }

    func testEndStopsParsing() {
        var remaining = [UInt8]()
        let frames = StreamFrame.parseChunks(from: StreamFrame.chunk(Data([9])) + StreamFrame.end + StreamFrame.chunk(Data([10])), into: &remaining)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0], Data([9]))
    }

    func testHalfChunkKeepsRemaining() {
        var remaining = [UInt8]()
        let wire = StreamFrame.chunk(Data([7, 8]))
        let half = wire.count / 2
        let first = StreamFrame.parseChunks(from: wire.prefix(half), into: &remaining)
        XCTAssertTrue(first.isEmpty)
        XCTAssertFalse(remaining.isEmpty)
        let second = StreamFrame.parseChunks(from: wire.suffix(wire.count - half), into: &remaining)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0], Data([7, 8]))
        XCTAssertTrue(remaining.isEmpty)
    }

    func testOversizedFrameDropped() {
        var remaining = [UInt8]()
        // 小端 0x0C000000 = 201326592（~192MB），超过 maxFrameBytes
        let bad = Data([0x00, 0x00, 0x00, 0x0C])
        let frames = StreamFrame.parseChunks(from: bad, into: &remaining)
        XCTAssertTrue(frames.isEmpty)
        XCTAssertTrue(remaining.isEmpty, "超大帧应清空缓冲")
    }

    func testNormalFrameBelowLimit() {
        var remaining = [UInt8]()
        let wire = StreamFrame.chunk(Data(repeating: 1, count: 1024))
        let frames = StreamFrame.parseChunks(from: wire, into: &remaining)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].count, 1024)
    }

    func testEmptyChunk() {
        var remaining = [UInt8]()
        let frames = StreamFrame.parseChunks(from: Data([0, 0, 0, 0]), into: &remaining)
        XCTAssertTrue(frames.isEmpty)
        XCTAssertTrue(remaining.isEmpty)
    }
}
