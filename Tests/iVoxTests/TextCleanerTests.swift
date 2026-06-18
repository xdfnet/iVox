import XCTest
@testable import iVoxKit

final class TextCleanerTests: XCTestCase {

    func testIdentity() {
        let input = "飞哥，版本 v1.2.0，API Config.load，测试通过率 95%，可以发布。"
        XCTAssertEqual(cleanText(input), input)
    }

    func testEmptyInput() {
        XCTAssertEqual(cleanText(""), "")
    }

    func testPreservesAnsiEscape() {
        // Qwen 自己能处理 ANSI
        let input = "正常文本\u{1b}[31m红色\u{1b}[0m结束"
        XCTAssertEqual(cleanText(input), input)
    }

    func testPreservesWhitespace() {
        let input = "测试    空格    压缩"
        XCTAssertEqual(cleanText(input), input)
    }

    func testPreservesMarkdown() {
        let input = "# 标题\n**加粗** `code` [链接](https://x.com)"
        XCTAssertEqual(cleanText(input), input)
    }

    func testPreservesCodeBlock() {
        let input = #"""
        开头
        ```
        let x = 1
        print(x)
        ```
        结尾
        """#
        XCTAssertEqual(cleanText(input), input)
    }

    func testPreservesTable() {
        let input = "| 名称 | 版本 |\n|---|---|\n| iOS | 18.0 |"
        XCTAssertEqual(cleanText(input), input)
    }

    func testPreservesEmoji() {
        let input = "🎉 ✅ ❌ → 完成"
        XCTAssertEqual(cleanText(input), input)
    }

    func testPreservesUrlAndPath() {
        let input = "路径 /Users/admin/file，URL https://example.com"
        XCTAssertEqual(cleanText(input), input)
    }
}
