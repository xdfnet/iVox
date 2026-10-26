import AppKit
import XCTest
@testable import iVox

/// 浮窗排版：**长文字必须换行**，不能铺成一条几千点宽的单行。
///
/// 这条是 2026-10-26 用户报的：「翻译的内容多了，展示有问题，都挤到一行」。
/// 根因：对 label 型的 `NSTextField`，`sizeToFit()` 按整条文本给宽高、**不换行**
/// （设了 `preferredMaxLayoutWidth` 也不换），于是译文越长、浮窗越宽，最后撑出屏幕。
@MainActor
final class OverlayWrapTests: XCTestCase {
    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 16)
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }

    /// 长文本：宽度不超过上限，高度超过一行（换了行）。
    func testLongTextWraps() {
        let label = makeLabel(String(repeating: "这是一段比较长的中文译文，用来测试换行。", count: 6))
        OverlayService.measure(label, limit: 300)
        XCTAssertLessThanOrEqual(label.frame.width, 300, "不能超过宽度上限")
        XCTAssertGreaterThan(label.frame.height, 25, "长文本必须换成多行")
    }

    /// 短文本：按自然宽（不撑成满宽），高度一行。
    func testShortTextKeepsNaturalWidth() {
        let label = makeLabel("短句")
        OverlayService.measure(label, limit: 300)
        XCTAssertLessThan(label.frame.width, 300, "短文本不该被撑到上限宽")
        XCTAssertLessThan(label.frame.height, 30, "短文本就是一行")
    }

    /// 限行数（高度超限时用）：高度按行数收住，不回到「一整条」。
    func testMaxLinesCapsHeight() {
        let label = makeLabel(String(repeating: "限行测试。", count: 20))
        label.maximumNumberOfLines = 2
        OverlayService.measure(label, limit: 200)
        XCTAssertLessThanOrEqual(label.frame.height, 60, "两行的高度（行高 19 左右）")
        XCTAssertGreaterThan(label.frame.height, 20, "不能压成一行")
    }
}
