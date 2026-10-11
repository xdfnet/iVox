import XCTest
@testable import iVoxKit

final class StreamBufferTests: XCTestCase {

    // 把整段按给定增量逐块喂入，收集 append 吐出的安全前缀 + finish 尾部。
    private func stream(_ whole: String, chunkSize: Int) -> [String] {
        let buf = StreamBuffer()
        var blocks: [String] = []
        let chars = Array(whole)
        var i = 0
        while i < chars.count {
            let piece = String(chars[i..<min(i + chunkSize, chars.count)])
            blocks.append(contentsOf: buf.append(piece))
            i += chunkSize
        }
        if let rest = buf.finish() { blocks.append(rest) }
        return blocks
    }

    // 核心契约：无论怎么切增量，各块 cleanText 拼起来 == 整段一次 cleanText。
    private func assertConsistent(_ whole: String, chunkSizes: [Int] = [1, 3, 7],
                                  file: StaticString = #filePath, line: UInt = #line) {
        let expected = cleanText(whole)
        for size in chunkSizes {
            let blocks = stream(whole, chunkSize: size)
            let joined = blocks.map { cleanText($0) }.joined()
            XCTAssertEqual(joined, expected,
                           "增量切分 \(size) 字后清洗结果与整段不一致", file: file, line: line)
        }
    }

    func testHalfSentenceBufferedUntilBoundary() {
        let buf = StreamBuffer(minFlushChars: 1)
        XCTAssertTrue(buf.append("你好").isEmpty)          // 无句末边界
        let ready = buf.append("，世界。")
        XCTAssertEqual(ready.count, 1)
        XCTAssertEqual(ready.first, "你好，世界。")
        XCTAssertNil(buf.finish())                          // 无残留
    }

    func testCompleteSentenceFlushesHalfKept() {
        let buf = StreamBuffer(minFlushChars: 1)
        let ready = buf.append("你好。世界")                 // 完整句 + 半句
        XCTAssertEqual(ready, ["你好。"])
        XCTAssertEqual(buf.finish(), "世界")
    }

    func testSemicolonFlushesAsBoundary() {
        let buf = StreamBuffer(minFlushChars: 1)
        // 分号即边界：第一个并列分句立即吐出，后续半句保留
        XCTAssertEqual(buf.append("先修登录；"), ["先修登录；"])
        XCTAssertEqual(buf.finish(), nil)
        let two = StreamBuffer(minFlushChars: 1)
        XCTAssertEqual(two.append("先修登录；再改支付"), ["先修登录；"])
        XCTAssertEqual(two.finish(), "再改支付")
    }

    // 默认最小颗粒：短句（好的。/明白。）攒到 minFlushChars 才吐，避免一个字一个字蹦
    func testShortSentencesAccumulateToMinFlush() {
        let buf = StreamBuffer()                 // 默认 24
        XCTAssertTrue(buf.append("好的。").isEmpty)
        XCTAssertTrue(buf.append("我明白了。").isEmpty)
        // 攒够后在最近边界一次吐出（可能含两句）
        let ready = buf.append("我们这就开始处理这个问题，请稍等。")
        XCTAssertEqual(ready.count, 1)
        XCTAssertTrue(ready[0].hasPrefix("好的。"))
        XCTAssertTrue(ready[0].contains("请稍等。"))
        XCTAssertNil(buf.finish())
    }

    // finish 不受最小颗粒限制：残尾（哪怕一两个短句）也全部播出
    func testFinishFlushesBelowMinChars() {
        let buf = StreamBuffer()
        XCTAssertTrue(buf.append("好的。").isEmpty)
        XCTAssertEqual(buf.finish(), "好的。")
    }

    func testUnclosedFenceSuppressesFlush() {
        let buf = StreamBuffer(minFlushChars: 1)
        XCTAssertTrue(buf.append("```swift\nlet x = 1\n").isEmpty)  // 围栏未闭合
        // 闭合后，连同正文一起吐出；代码经 cleanText 被剥离
        let ready = buf.append("```\n好的，做完了。")
        XCTAssertEqual(ready.count, 1)
        let spoken = cleanText(ready[0])
        XCTAssertFalse(spoken.contains("let x"), "代码块内容不应被念出：\(spoken)")
        XCTAssertTrue(spoken.contains("好的"))
    }

    func testFinishFlushesTailWithoutTerminator() {
        let buf = StreamBuffer(minFlushChars: 1)
        _ = buf.append("就这一句没有句号")
        XCTAssertEqual(buf.finish(), "就这一句没有句号")
    }

    func testFinishEmptyAfterFullFlush() {
        let buf = StreamBuffer(minFlushChars: 1)
        _ = buf.append("完事。")
        XCTAssertNil(buf.finish())
    }

    func testCancelLikeDropDiscardsRest() {
        let buf = StreamBuffer(minFlushChars: 1)
        _ = buf.append("第一句。还没念的半句")
        // 取消语义由调用层丢弃 finish 结果；这里只验证缓冲确实还持有半句
        XCTAssertEqual(buf.finish(), "还没念的半句")
    }

    // 纯散文：没有块结构，流式各前缀清洗拼接必须与整段逐字一致（标点也不能差）。
    func testStreamedCleaningEqualsWholeForProse() {
        let text = "好的，我来帮你改。这个函数现在更简洁了，主要做了三件事：抽取公共逻辑、删掉重复分支、补上注释。你再跑一下测试看看。"
        assertConsistent(text)
    }

    // 含 markdown/代码/URL：流式与整段路径在「块末补句号/空格」上会有无害差异
    // （AST 对整段会补伪句号），故只断言真正的契约——只说人话，代码与符号绝不被念出。
    func testStreamedMarkdownOnlySpeaksHumanText() {
        let text = """
        我已经改好了。

        主要改动如下：

        - 删掉了没用的变量
        - 把重复逻辑抽成了一个函数

        代码在这里：

        ```swift
        func load() -> Int {
            return 42
        }
        ```

        详情见 https://example.com/docs ，你可以看看。
        """
        for size in [1, 3, 7] {
            let spoken = stream(text, chunkSize: size).map { cleanText($0) }.joined()
            XCTAssertFalse(spoken.contains("```"), "切分\(size): 念出了围栏符号\n\(spoken)")
            XCTAssertFalse(spoken.contains("func load"), "切分\(size): 念出了代码\n\(spoken)")
            XCTAssertFalse(spoken.contains("return 42"), "切分\(size): 念出了代码\n\(spoken)")
            XCTAssertFalse(spoken.contains("http"), "切分\(size): 念出了 URL\n\(spoken)")
            XCTAssertFalse(spoken.contains("：。"), "切分\(size): 出现块末伪句号\n\(spoken)")
            for expect in ["我已经改好了", "删掉了没用的变量", "把重复逻辑抽成了一个函数", "你可以看看"] {
                XCTAssertTrue(spoken.contains(expect), "切分\(size): 漏播正文「\(expect)」\n\(spoken)")
            }
        }
    }

    func testStreamedCleaningEqualsWholeWithEmoji() {
        assertConsistent("👌 好的，我这就去办。🎉 搞定了，记得跑测试。")
    }
}
