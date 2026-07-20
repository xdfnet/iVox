import XCTest
@testable import iVoxKit

final class TextCleanerTests: XCTestCase {

    func testPreservesText() {
        let input = "飞哥，版本 v1.2.0，测试通过率 95%，可以发布。"
        XCTAssertEqual(cleanText(input), input)
    }

    func testEmptyInput() {
        XCTAssertEqual(cleanText(""), "")
    }

    func testHeadingStripped() {
        let input = "# 标题\n正文"
        let got = cleanText(input)
        XCTAssertTrue(got.contains("标题"))
        XCTAssertTrue(got.contains("正文"))
    }

    func testInlineCode() {
        let input = "运行 `npm install` 安装"
        let got = cleanText(input)
        XCTAssertTrue(got.contains("npm install"))
    }

    func testCodeBlock() {
        let input = """
        开头
        ```
        let x = 1
        ```
        结尾
        """
        let got = cleanText(input)
        XCTAssertTrue(got.contains("let x"))
    }

    func testLinkTextPreserved() {
        let input = "参考 [Apple](https://apple.com)"
        let got = cleanText(input)
        XCTAssertTrue(got.contains("Apple"))
        XCTAssertFalse(got.contains("https://"))
    }

    func testTableSkipped() {
        let input = "结果\n| 名称 | 版本 |\n| iOS | 18.0 |\n以上"
        let got = cleanText(input)
        XCTAssertTrue(got.contains("结果"))
        XCTAssertTrue(got.contains("以上"))
    }

    func testBlocksJoined() {
        let input = "第一段\n\n第二段"
        let got = cleanText(input)
        XCTAssertTrue(got.contains("第一段"))
        XCTAssertTrue(got.contains("第二段"))
    }

    func testListItems() {
        let input = "- 苹果\n- 香蕉"
        let got = cleanText(input)
        XCTAssertTrue(got.contains("苹果"))
        XCTAssertTrue(got.contains("香蕉"))
    }

    func testPreservesComma() {
        // 走 AST 路径（粗体标记触发），保留千分位逗号；块结束补 "。"
        XCTAssertEqual(cleanText("**1,234,567**"), "1,234,567。")
    }

    func testNormalizesWhitespace() {
        // Tab 与 NBSP 当空格合并，前后不留
        let input = "**a\tb\u{00A0}c\u{3000}d**"
        XCTAssertEqual(cleanText(input), "a b c d。")
    }

    func testStripsEmojiModifier() {
        // 👶 主字 + 🏽 肤色修饰符都应砍
        let input = "**a👶🏽b**"
        XCTAssertEqual(cleanText(input), "ab。")
    }

    func testURLSegmentNormalizesTab() {
        // 走 AST（粗体触发），URL 前后段落的 Tab 也合并成空格
        let input = "**参考\thttps://apple.com\t结束**"
        let got = cleanText(input)
        XCTAssertFalse(got.contains("\t"), "Tab 应被合并")
        XCTAssertTrue(got.contains("参考"))
        XCTAssertTrue(got.contains("结束"))
        XCTAssertFalse(got.contains("https://"), "URL 应被砍")
    }
}
