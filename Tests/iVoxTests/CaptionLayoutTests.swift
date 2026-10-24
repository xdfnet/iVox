import XCTest
import CoreGraphics
@testable import iVox

/// 字幕浮窗的**落点几何**（渲染与几何分开测：测几何不用开窗口）。
///
/// 落点规则：水平永远在可见区正中；垂直由 `position` 决定，`inset` 是距那条边的点数。
/// 一条规则一处实现——`CaptionPanel.origin` 是唯一样子。
@MainActor
final class CaptionLayoutTests: XCTestCase {

    /// 假定一块屏的可见区（主屏：1920×1050，菜单栏 30pt 让出）
    private let visible = NSRect(x: 0, y: 0, width: 1920, height: 1050)
    private let size = NSSize(width: 400, height: 47)

    func testBottomSitsInsetAboveVisibleBottom() {
        let p = CaptionPanel.origin(position: .bottom, inset: 24, visible: visible, size: size)
        XCTAssertEqual(p.y, 24, accuracy: 0.01, "贴底：底边应距可见区底边 24 点")
        XCTAssertEqual(p.x, 760, accuracy: 0.01, "水平应居中")
    }

    func testTopSitsInsetBelowVisibleTop() {
        let p = CaptionPanel.origin(position: .top, inset: 24, visible: visible, size: size)
        XCTAssertEqual(p.y, 1050 - 24 - 47, accuracy: 0.01, "贴顶：顶边应距可见区顶边 24 点")
        XCTAssertEqual(p.x, 760, accuracy: 0.01, "水平应居中")
    }

    func testCenterIsVerticallyCentered() {
        let p = CaptionPanel.origin(position: .center, inset: 24, visible: visible, size: size)
        XCTAssertEqual(p.y, (1050 - 47) / 2, accuracy: 0.01, "居中：应在可见区垂直居中")
    }

    func testInsetIsHonoured() {
        let p = CaptionPanel.origin(position: .bottom, inset: 100, visible: visible, size: size)
        XCTAssertEqual(p.y, 100, accuracy: 0.01, "inset 该被照用")
    }

    /// 负坐标的屏（放在主屏左侧/下方的屏）不能算歪——落点跟着可见区走
    func testWorksOnScreenWithNegativeOrigin() {
        let lower = NSRect(x: 0, y: -1019, width: 1920, height: 1019)
        let p = CaptionPanel.origin(position: .bottom, inset: 24, visible: lower, size: size)
        XCTAssertEqual(p.y, -995, accuracy: 0.01)
        XCTAssertEqual(p.x, 760, accuracy: 0.01)
    }
}
