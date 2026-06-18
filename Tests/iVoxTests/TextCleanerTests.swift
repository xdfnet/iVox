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
        // 短代码块现在保留为 inline： "代码：let x = 1 print(x)"
        XCTAssertTrue(got.contains("开头"))
        XCTAssertTrue(got.contains("结尾"))
        XCTAssertTrue(got.contains("代码："))
        XCTAssertTrue(got.contains("let x"))
    }

    func testLongCodeBlockSkipped() {
        let input = """
        开头
        ```
        let x = 1
        let y = 2
        let z = x + y
        print(z)
        ```
        结尾
        """
        let got = cleanText(input)
        XCTAssertTrue(got.contains("开头"))
        XCTAssertTrue(got.contains("结尾"))
        XCTAssertFalse(got.contains("let x"), "长代码块应跳过")
    }

    func testPreservesUsefulInlineContent() {
        let input = "飞哥，版本 v1.2.0，API Config.load，测试通过率 95%，可以发布。"
        XCTAssertEqual(cleanText(input), input)
    }

    func testRemovesInlineNoise() {
        let input = "路径 /Users/admin/file，URL https://example.com，commit a97e57d12345，UUID 550e8400-e29b-41d4-a716-446655440000，速度 12MB/s，状态 ✅ → 完成"
        let got = cleanText(input)
        // commit a97e57d12345 只有 12 位，不再被删（新阈值 16-40）
        XCTAssertTrue(got.contains("a97e57d12345"))
        XCTAssertTrue(got.contains("commit"))
        XCTAssertTrue(got.contains("状态 成功"))
        XCTAssertFalse(got.contains("/Users/admin/file"))
        XCTAssertFalse(got.contains("https://example.com"))
        XCTAssertFalse(got.contains("550e8400"))
        XCTAssertFalse(got.contains("12MB/s"))
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
        // 新逻辑：两段落，各自补句号
        XCTAssertEqual(got, "结果如下。 以上是兼容性。")
    }

    func testKeepsChinesePercent() {
        let input = "测试通过率 95%，可以发布。"
        XCTAssertEqual(cleanText(input), input)
    }

    func testEmptyInput() {
        XCTAssertEqual(cleanText(""), "")
    }

    func testOnlyShortCodeBlock() {
        let input = """
        ```
        code here
        ```
        """
        // 短代码块不再跳过，转为 inline 保留
        let got = cleanText(input)
        XCTAssertFalse(got.isEmpty)
        XCTAssertTrue(got.contains("代码："))
        XCTAssertTrue(got.contains("code here"))
    }

    func testShortCommitHashPreserved() {
        // 7 位短 commit hash 应保留
        let input = "提交 `8257e39` 已推送"
        let got = cleanText(input)
        XCTAssertTrue(got.contains("8257e39"))
    }

    func testLongCommitHashRemoved() {
        // 16 位完整 SHA 应删除
        let input = "提交 a97e57d12345abcd 完成"
        let got = cleanText(input)
        XCTAssertFalse(got.contains("a97e57d12345abcd"))
    }

    func testHeadingStructure() {
        let input = "# 版本更新\n修复了一个 bug"
        let got = cleanText(input)
        // 两段落各自补句号
        XCTAssertTrue(got.contains("版本更新"))
        XCTAssertTrue(got.contains("修复了一个 bug"))
        // 确认不是逗号连接
        XCTAssertTrue(got.contains("。"))
    }

    func testPreservesOriginalPunctuation() {
        let input = "真的吗？太好了！"
        let got = cleanText(input)
        // 问号和感叹号是句尾标点，不应被额外句号覆盖
        XCTAssertEqual(got, input)
    }

    func testMultipleBlocksWithPunctuation() {
        let input = "第一段。\n\n第二段？\n\n第三段！"
        let got = cleanText(input)
        // 三段都已句尾标点结尾，不额外添加
        XCTAssertEqual(got, "第一段。 第二段？ 第三段！")
    }
}
