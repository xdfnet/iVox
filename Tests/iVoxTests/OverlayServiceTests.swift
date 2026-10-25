import XCTest
import CoreGraphics
@testable import iVox

/// iVox 浮窗服务的**落点几何**与**去重判据**（渲染与逻辑分开测：测它们不用开窗口）。
///
/// 落点规则：水平永远在可见区正中、垂直贴底，`inset` 是底边距可见区底边的点数。
/// 一条规则一处实现——`OverlayService.origin` / `OverlayService.visibleLines` 是唯一样子。
@MainActor
final class OverlayServiceTests: XCTestCase {

    /// 假定一块屏的可见区（主屏：1920×1050，菜单栏 30pt 让出）
    private let visible = NSRect(x: 0, y: 0, width: 1920, height: 1050)
    private let size = NSSize(width: 400, height: 47)

    // MARK: - 落点

    func testSitsInsetAboveVisibleBottom() {
        let p = OverlayService.origin(inset: 24, visible: visible, size: size)
        XCTAssertEqual(p.y, 24, accuracy: 0.01, "贴底：底边应距可见区底边 24 点")
        XCTAssertEqual(p.x, 760, accuracy: 0.01, "水平应居中")
    }

    func testInsetIsHonoured() {
        let p = OverlayService.origin(inset: 100, visible: visible, size: size)
        XCTAssertEqual(p.y, 100, accuracy: 0.01, "inset 该被照用")
    }

    /// 负坐标的屏（放在主屏左侧/下方的屏）不能算歪——落点跟着可见区走
    func testWorksOnScreenWithNegativeOrigin() {
        let lower = NSRect(x: 0, y: -1019, width: 1920, height: 1019)
        let p = OverlayService.origin(inset: 24, visible: lower, size: size)
        XCTAssertEqual(p.y, -995, accuracy: 0.01)
        XCTAssertEqual(p.x, 760, accuracy: 0.01)
    }

    // MARK: - 去重（同一句话不显示两遍）

    /// 翻译朗读时，字幕那句正是译文的一部分 → 字幕那行是回声，去掉；译文照旧显示。
    func testCaptionCoveredByTranslationIsDropped() {
        let contents: [(channel: OverlayService.Channel, lines: [OverlayService.Line])] = [
            (.caption, [.init(text: "音乐的恢复和字幕的恢复还是有问题", style: .normal)]),
            (.translation, [.init(text: "原文", style: .dim),
                            .init(text: "音乐的恢复和字幕的恢复还是有问题，需检查一下", style: .normal)]),
        ]
        let lines = OverlayService.visibleLines(contents)
        XCTAssertEqual(lines.map(\.text), ["原文", "音乐的恢复和字幕的恢复还是有问题，需检查一下"],
                       "字幕那句已被译文包含 → 不该再显示一遍")
    }

    /// 两层内容互不相干 → 都显示（Claude 正在说的话 + 刚翻的译文）
    func testUnrelatedContentsBothStay() {
        let contents: [(channel: OverlayService.Channel, lines: [OverlayService.Line])] = [
            (.caption, [.init(text: "Claude 正在回复里的另一句话", style: .normal)]),
            (.translation, [.init(text: "译文", style: .normal)]),
        ]
        XCTAssertEqual(OverlayService.visibleLines(contents).count, 2)
    }

    /// 字幕与译文**完全相同** → 留译文、去掉字幕。
    /// 译文是用户要的结果，字幕只是它被念出来时的影子（2026-10-25 实测：反过来留字幕、
    /// 把译文藏起来，屏幕上只剩英文原文）。
    func testIdenticalTextKeepsTheTranslation() {
        let contents: [(channel: OverlayService.Channel, lines: [OverlayService.Line])] = [
            (.caption, [.init(text: "同一句话", style: .normal)]),
            (.translation, [.init(text: "同一句话", style: .normal)]),
        ]
        let lines = OverlayService.visibleLines(contents)
        XCTAssertEqual(lines.count, 1, "同一段字只该显示一遍")
        XCTAssertEqual(lines.first?.text, "同一句话")
    }

    /// 实测那次的原样：译文 = 原文 + 译文，字幕正在念的就是那句译文
    func testSpokenTranslationKeepsOriginalAndTranslation() {
        let contents: [(channel: OverlayService.Channel, lines: [OverlayService.Line])] = [
            (.caption, [.init(text: "音乐恢复和字幕恢复仍然有问题", style: .normal)]),
            (.translation, [.init(text: "The music recovery and subtitle recovery still have problems", style: .dim),
                            .init(text: "音乐恢复和字幕恢复仍然有问题", style: .normal)]),
        ]
        let lines = OverlayService.visibleLines(contents)
        XCTAssertEqual(lines.map(\.text),
                       ["The music recovery and subtitle recovery still have problems", "音乐恢复和字幕恢复仍然有问题"],
                       "译文（原文 + 译文）都要留，字幕那行是回声")
    }

    /// 末尾标点对不上也算同一句（字幕那句是从译文里切出来的，标点可能差一个）
    func testTrailingPunctuationIsNormalized() {
        let contents: [(channel: OverlayService.Channel, lines: [OverlayService.Line])] = [
            (.caption, [.init(text: "音乐恢复有问题。", style: .normal)]),
            (.translation, [.init(text: "原文", style: .dim),
                            .init(text: "音乐恢复有问题，需检查", style: .normal)]),
        ]
        let lines = OverlayService.visibleLines(contents)
        XCTAssertFalse(lines.contains { $0.text == "音乐恢复有问题。" },
                       "字幕那句已被译文包含 → 不该再显示一遍")
    }

    /// 原文那行（dim）不参与比对：它是用户随手选的英文短词，
    /// 拿它比会把不相干的字幕误判成回声。
    func testDimOriginalDoesNotHideUnrelatedCaption() {
        let contents: [(channel: OverlayService.Channel, lines: [OverlayService.Line])] = [
            (.caption, [.init(text: "the test passed", style: .normal)]),
            (.translation, [.init(text: "test", style: .dim),
                            .init(text: "测试通过了", style: .normal)]),
        ]
        let lines = OverlayService.visibleLines(contents)
        XCTAssertTrue(lines.contains { $0.text == "the test passed" },
                      "字幕跟译文正文不重叠 → 该留着")
    }
}
