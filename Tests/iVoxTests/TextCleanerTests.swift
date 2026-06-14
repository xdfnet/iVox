import XCTest
@testable import iVoxKit

final class TextCleanerTests: XCTestCase {

    func testRemovesCodeBlocks() {
        let input = """
        开头
        ```
        let x = 1
        print(x)
        ```
        结尾
        """
        let got = cleanText(input)
        XCTAssertTrue(got.contains("开头"))
        XCTAssertTrue(got.contains("结尾"))
        XCTAssertFalse(got.contains("let x = 1"))
        XCTAssertFalse(got.contains("print(x)"))
    }

    func testPreservesUsefulInlineContent() {
        let input = "飞哥，版本 v1.2.0，API Config.load，测试通过率 95%，可以发布。"
        let got = cleanText(input)
        XCTAssertEqual(got, input)
    }

    func testRemovesInlineNoise() {
        let input = "路径 /Users/admin/file，URL https://example.com，commit a97e57d12345，UUID 550e8400-e29b-41d4-a716-446655440000，速度 12MB/s，状态 ✅ → 完成"
        let got = cleanText(input)
        XCTAssertEqual(got, "路径，URL，commit，UUID，速度，状态 成功 到 完成")
    }

    func testRemovesMarkdownTable() {
        let input = """
        结果如下
        | 名称 | 版本 |
        |------|------|
        | iOS  | 18.0 |
        | iPadOS | 18.0 |

        以上是兼容性
        """
        let got = cleanText(input)
        XCTAssertEqual(got, "结果如下，以上是兼容性")
    }

    func testKeepsChinesePercent() {
        let input = "测试通过率 95%，可以发布。"
        XCTAssertEqual(cleanText(input), input)
    }

    func testEmptyInput() {
        XCTAssertEqual(cleanText(""), "")
    }

    func testOnlyCodeBlock() {
        let input = """
        ```
        code here
        ```
        """
        XCTAssertTrue(cleanText(input).isEmpty)
    }
}
