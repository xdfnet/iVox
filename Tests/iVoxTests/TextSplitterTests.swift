import XCTest
@testable import iVoxKit

final class TextSplitterTests: XCTestCase {

    func testEmptyInput() {
        XCTAssertEqual(splitSentences(""), [])
        XCTAssertEqual(splitSentences("   \n "), [])
    }

    func testShortTextStaysSingleChunk() {
        XCTAssertEqual(splitSentences("你好。"), ["你好。"])
    }

    func testMergesShortSentencesUpToLimit() {
        XCTAssertEqual(
            splitSentences("第一句。第二句。第三句。", maxChars: 80),
            ["第一句。第二句。第三句。"])
    }

    func testSplitsWhenExceedingLimit() {
        XCTAssertEqual(
            splitSentences("第一句。第二句。", maxChars: 6),
            ["第一句。", "第二句。"])
    }

    func testPunctuationOnlyNotItsOwnChunk() {
        // 「？！」应并回上一句，而不是产出一个只念停顿的空块
        XCTAssertEqual(
            splitSentences("真的吗？！好吧。", maxChars: 80),
            ["真的吗？！好吧。"])
    }

    func testEnglishMergeKeepsSpace() {
        XCTAssertEqual(
            splitSentences("First one. Second one.", maxChars: 80),
            ["First one. Second one."])
    }

    func testHardSplitsLongRunOn() {
        let runOn = String(repeating: "a", count: 250)
        let got = splitSentences(runOn, maxChars: 80)
        XCTAssertEqual(got.joined(), runOn, "硬切不应丢字符")
        XCTAssertTrue(got.allSatisfy { $0.count <= 160 }, "实际块长: \(got.map(\.count))")
        XCTAssertTrue(got.count >= 2)
    }

    func testLongTextSplitsIntoMultipleChunks() {
        let text = String(repeating: "这是一句大概二十个字左右的测试句子内容。", count: 6)
        let got = splitSentences(text)
        XCTAssertTrue(got.count > 1, "实际块数: \(got.count)")
        XCTAssertTrue(got.allSatisfy { $0.count <= 160 }, "实际块长: \(got.map(\.count))")
    }

    func testDefaultLimitIsPlaybackChunking() {
        XCTAssertEqual(PlaybackChunking.maxChars, 80)
    }
}
