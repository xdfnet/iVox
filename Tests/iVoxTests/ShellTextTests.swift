import XCTest
@testable import iVoxKit

/// `shellQuote` 是安全相关的纯函数：拼错了就是命令注入。
final class ShellTextTests: XCTestCase {
    func testPlainStringIsWrappedInSingleQuotes() {
        XCTAssertEqual(shellQuote("hello"), "'hello'")
    }

    func testInnerSingleQuoteIsEscaped() {
        XCTAssertEqual(shellQuote("it's"), "'it'\\''s'")
    }

    func testDollarAndBacktickStayLiteral() {
        XCTAssertEqual(shellQuote("$HOME `whoami`"), "'$HOME `whoami`'")
    }

    func testNewlineIsPreservedInsideQuotes() {
        XCTAssertEqual(shellQuote("a\nb"), "'a\nb'")
    }

    func testBackslashStaysLiteral() {
        XCTAssertEqual(shellQuote(#"a\b"#), #"'a\b'"#)
    }

    func testEmptyStringBecomesEmptyQuotes() {
        XCTAssertEqual(shellQuote(""), "''")
    }
}
