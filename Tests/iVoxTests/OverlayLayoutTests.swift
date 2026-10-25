import XCTest
import CoreGraphics
@testable import iVox

/// iVox 浮窗的**落点与堆叠几何**（渲染与几何分开测：测几何不用开窗口）。
///
/// 落点规则：水平永远在可见区正中、垂直贴底，`inset` 是底边距可见区底边的点数。
/// 堆叠规则：各层从下往上摆（字幕在下、译文在上），层间留 `gap`，每层水平居中。
/// 一条规则一处实现——`IvoxOverlay.origin` / `IvoxOverlay.stackLayout` 是唯一样子。
@MainActor
final class OverlayLayoutTests: XCTestCase {

    /// 假定一块屏的可见区（主屏：1920×1050，菜单栏 30pt 让出）
    private let visible = NSRect(x: 0, y: 0, width: 1920, height: 1050)
    private let size = NSSize(width: 400, height: 47)

    func testSitsInsetAboveVisibleBottom() {
        let p = IvoxOverlay.origin(inset: 24, visible: visible, size: size)
        XCTAssertEqual(p.y, 24, accuracy: 0.01, "贴底：底边应距可见区底边 24 点")
        XCTAssertEqual(p.x, 760, accuracy: 0.01, "水平应居中")
    }

    func testInsetIsHonoured() {
        let p = IvoxOverlay.origin(inset: 100, visible: visible, size: size)
        XCTAssertEqual(p.y, 100, accuracy: 0.01, "inset 该被照用")
    }

    /// 负坐标的屏（放在主屏左侧/下方的屏）不能算歪——落点跟着可见区走
    func testWorksOnScreenWithNegativeOrigin() {
        let lower = NSRect(x: 0, y: -1019, width: 1920, height: 1019)
        let p = IvoxOverlay.origin(inset: 24, visible: lower, size: size)
        XCTAssertEqual(p.y, -995, accuracy: 0.01)
        XCTAssertEqual(p.x, 760, accuracy: 0.01)
    }

    // MARK: - 堆叠

    /// 只有一层时：容器就是它自己，原点在 (0,0)
    func testSingleLayerFillsContainer() {
        let (size, origins) = IvoxOverlay.stackLayout(sizes: [NSSize(width: 400, height: 47)], gap: 8)
        XCTAssertEqual(size.width, 400, accuracy: 0.01)
        XCTAssertEqual(size.height, 47, accuracy: 0.01)
        XCTAssertEqual(origins.count, 1)
        XCTAssertEqual(origins[0].y, 0, accuracy: 0.01)
    }

    /// 两层：下层贴底、上层在它上面，中间隔 gap——上下次序由容器结构保证，
    /// 不再靠一个手写死的像素间隙把两个窗口错开。
    func testTwoLayersStackBottomUpWithGap() {
        let bottom = NSSize(width: 400, height: 47)   // 字幕
        let top = NSSize(width: 300, height: 80)      // 译文
        let (size, origins) = IvoxOverlay.stackLayout(sizes: [bottom, top], gap: 8)

        XCTAssertEqual(size.width, 400, accuracy: 0.01, "容器宽 = 最宽的一层")
        XCTAssertEqual(size.height, 47 + 8 + 80, accuracy: 0.01, "容器高 = 两层 + 一个 gap")

        XCTAssertEqual(origins[0].y, 0, accuracy: 0.01, "下层贴容器底")
        XCTAssertEqual(origins[1].y, 47 + 8, accuracy: 0.01, "上层在下层之上、隔着 gap")
        XCTAssertEqual(origins[0].x, 0, accuracy: 0.01, "下层比容器窄 → 居中")
        XCTAssertEqual(origins[1].x, 50, accuracy: 0.01, "上层比容器窄 → 居中")
    }
}
