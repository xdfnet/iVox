import XCTest
@testable import iVoxKit

final class TextCleanerTests: XCTestCase {

    // MARK: - 基础保留

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

    func testBlocksJoined() {
        let input = "第一段\n\n第二段"
        let got = cleanText(input)
        XCTAssertTrue(got.contains("第一段"))
        XCTAssertTrue(got.contains("第二段"))
        // 无标点换行要补停顿，避免 TTS 连读
        XCTAssertTrue(got.contains("第一段。"))
    }

    func testPreservesComma() {
        // 走 AST 路径（粗体标记触发），保留千分位逗号；块结束补 "。"
        XCTAssertEqual(cleanText("**1,234,567**"), "1,234,567。")
    }

    func testPreservesHyphen() {
        // 英文连字符保留，给 TTS 节奏感（如 "x86-64"）
        XCTAssertEqual(cleanText("**x86-64**"), "x86-64。")
    }

    func testNormalizesWhitespace() {
        // Tab 与 NBSP 当空格合并，前后不留
        let input = "**a\tb\u{00A0}c\u{3000}d**"
        XCTAssertEqual(cleanText(input), "a b c d。")
    }

    func testCollapsesRepeatedSpaces() {
        // 连续半角空格也应折叠成一个
        XCTAssertEqual(cleanText("**x** a    b"), "x a b。")
    }

    func testStripsEmojiModifier() {
        // 👶 主字 + 🏽 肤色修饰符都应砍（未在口语表里的 emoji 仍被剔除）
        let input = "**a👶🏽b**"
        XCTAssertEqual(cleanText(input), "ab。")
    }

    // MARK: - emoji 口语化

    func testEmojiToSpeechFastPath() {
        // 纯中文短文本走快速路径：常见 emoji 换成口语词，不引空格、不加句号
        XCTAssertEqual(cleanText("搞定了👌🎉"), "搞定了好的太棒了")
    }

    func testEmojiToSpeechMarkdownPath() {
        // 粗体触发 AST 路径：emoji 仍替换为口语词，块末补 "。"
        XCTAssertEqual(cleanText("**测试通过✅🙏**"), "测试通过没问题谢谢。")
    }

    func testEmojiSkinToneVariant() {
        // 👍 + 🏼 肤色变体也应命中基础 emoji「赞」
        XCTAssertEqual(cleanText("写得好👍🏼"), "写得好赞")
    }

    func testEmojiOnlyLine() {
        // 一行只剩 emoji：替换为口语词，行尾补句号
        XCTAssertEqual(cleanText("**🚀**"), "起飞。")
    }

    // MARK: - 代码

    func testInlineCode() {
        let input = "运行 `npm install` 安装"
        let got = cleanText(input)
        XCTAssertTrue(got.contains("npm install"))
    }

    func testInlineCodeSeparatedFromFollowingText() {
        // 行内代码后必须补出分词空格，否则 TTS 会把中英边界连读
        let got = cleanText("**x** 调用 `foo` 之后，再调 `bar` 即可")
        XCTAssertTrue(got.contains("foo 之后"), "实际: \(got)")
        XCTAssertTrue(got.contains("bar 即可"), "实际: \(got)")
    }

    func testCodeBlockSkipped() {
        // 播报场景下整段朗读源码没有信息量（README：「跳过代码」）
        let input = """
        开头
        ```
        let x = 1
        ```
        结尾
        """
        let got = cleanText(input)
        XCTAssertFalse(got.contains("let x"), "代码块不应进入播报，实际: \(got)")
        XCTAssertTrue(got.contains("开头"))
        XCTAssertTrue(got.contains("结尾"))
    }

    // MARK: - 链接与 URL

    func testLinkTextPreserved() {
        let input = "参考 [Apple](https://apple.com)"
        let got = cleanText(input)
        XCTAssertTrue(got.contains("Apple"))
        XCTAssertFalse(got.contains("https://"))
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

    // MARK: - 噪音剔除

    func testStripsANSI() {
        let got = cleanText("**x** 输出 \u{1B}[31mERROR\u{1B}[0m 结束")
        XCTAssertFalse(got.contains("31m"), "ANSI 数字码不应残留，实际: \(got)")
        XCTAssertTrue(got.contains("ERROR"))
    }

    func testStripsCommitHash() {
        let got = cleanText("**x** 提交 4a287668e97bc130aa6d19f4d64799394caacbad 修复完成")
        XCTAssertFalse(got.contains("4a287668"), "长 hash 不应朗读，实际: \(got)")
        XCTAssertTrue(got.contains("修复完成"))
    }

    func testStripsUUID() {
        let got = cleanText("**x** 会话 550e8400-e29b-41d4-a716-446655440000 已过期")
        XCTAssertFalse(got.contains("550e8400"), "UUID 不应朗读，实际: \(got)")
        XCTAssertTrue(got.contains("已过期"))
    }

    func testKeepsLongPureNumber() {
        // 纯数字长串（订单号/时间戳）不是 hash，应保留
        let got = cleanText("**x** 订单号 123456789012 已支付")
        XCTAssertTrue(got.contains("123456789012"), "实际: \(got)")
    }

    func testPathKeepsBasenameOnly() {
        let got = cleanText("**x** 主要改动在 Sources/iVoxKit/TextCleaner.swift，请复查")
        XCTAssertTrue(got.contains("TextCleaner.swift"), "实际: \(got)")
        XCTAssertFalse(got.contains("Sources/iVoxKit"), "目录部分应被砍，实际: \(got)")
    }

    func testAbsolutePathKeepsBasenameOnly() {
        let got = cleanText("**x** 产物在 /Users/admin/.build/release/iVox，可以直接跑")
        XCTAssertTrue(got.contains("iVox"), "实际: \(got)")
        XCTAssertFalse(got.contains("/Users/admin"), "绝对路径应被砍，实际: \(got)")
    }

    func testStripsProgressNoise() {
        let got = cleanText("**x** 下载中 12MB/s，预计剩余 3 分钟，请稍等")
        XCTAssertFalse(got.contains("12MB/s"), "实际: \(got)")
        XCTAssertFalse(got.contains("预计剩余"), "实际: \(got)")
        XCTAssertTrue(got.contains("请稍等"))
    }

    func testStripsJSONObject() {
        let got = cleanText("**x** 接口返回 {\"code\":0,\"msg\":\"ok\"}，已处理")
        XCTAssertFalse(got.contains("code"), "JSON 不应朗读，实际: \(got)")
        XCTAssertTrue(got.contains("已处理"))
    }

    func testKeepsPlainBracesText() {
        // 无引号的 {} 不当 JSON，避免误删正常文本
        let got = cleanText("**x** 把内容放进 {待办清单} 里")
        XCTAssertTrue(got.contains("待办清单"), "实际: \(got)")
    }

    func testArrowReplacedWithDao() {
        let got = cleanText("**x** 流程是 输入 → 清洗 → 播放")
        XCTAssertFalse(got.contains("→"), "实际: \(got)")
        XCTAssertTrue(got.contains("到"), "实际: \(got)")
    }

    // MARK: - 停顿与分词

    func testNoDoublePeriodInNestedBlocks() {
        // ListItem 内含 Paragraph 会触发两次 endBlock，不应补出「。 。」
        let got = cleanText("- 第一项：修复登录\n- 第二项：补充测试")
        XCTAssertFalse(got.contains("。 。"), "实际: \(got)")
        XCTAssertFalse(got.contains("。。"), "实际: \(got)")
        XCTAssertTrue(got.contains("修复登录。"))
    }

    func testNoDoublePeriodInBlockQuote() {
        let got = cleanText("**x**\n> 引用一句话")
        XCTAssertFalse(got.contains("。 。"), "实际: \(got)")
    }

    func testColonLeadInGetsNoPseudoPeriod() {
        // 「如下：」引出列表，块末不应再补句号变成「如下：。」
        let got = cleanText("主要改动如下：\n\n- 修了登录\n- 补了测试")
        XCTAssertFalse(got.contains("：。"), "冒号引导段被补了伪句号: \(got)")
        XCTAssertTrue(got.contains("如下："))
    }

    func testEnglishPeriodNotDoubled() {
        XCTAssertEqual(cleanText("**x** The build finished."), "x The build finished.")
    }

    func testCJKBoldNotSplitBySpace() {
        // 中文相邻节点不该被插空格
        XCTAssertEqual(cleanText("**加粗**普通文字紧邻"), "加粗普通文字紧邻。")
    }

    func testListItems() {
        let input = "- 苹果\n- 香蕉"
        let got = cleanText(input)
        XCTAssertTrue(got.contains("苹果"))
        XCTAssertTrue(got.contains("香蕉"))
    }

    func testTableCellsSeparated() {
        // 表格单元格之间要有分隔，否则中文连读成「名称版本」
        let input = "结果\n| 名称 | 版本 |\n| iOS | 18.0 |\n以上"
        let got = cleanText(input)
        XCTAssertTrue(got.contains("名称 版本"), "实际: \(got)")
        XCTAssertTrue(got.contains("iOS 18.0"), "实际: \(got)")
        XCTAssertTrue(got.contains("结果"))
        XCTAssertTrue(got.contains("以上"))
    }
}
