import CoreGraphics

// 浮窗锚定几何（纯函数）。

/// 浮窗锚定几何：纯计算，不碰 NSScreen / NSEvent，便于单测。
///
/// 与 iDict `WindowPositionCalculator` 的差异：原实现把鼠标换成「屏幕内坐标」再与
/// `visibleFrame` 的**宽高**（不含 origin）混算，副屏（origin 非零）会算错位置。
/// 这里自始至终只用**全局坐标**，夹紧边界一律取自 `visibleFrame` 的 min/max，天然正确。
///
/// - Parameters:
///   - anchor: 锚点（通常是鼠标位置），全局坐标
///   - visibleFrame: 所在屏幕的可见区（已避开菜单栏 / Dock），全局坐标
///   - size: 浮窗尺寸
///   - offset: 浮窗与锚点的间距
/// - Returns: 浮窗左下角在全局坐标中的位置（AppKit 坐标系，y 向上）
public func placeNearAnchor(
    anchor: CGPoint,
    visibleFrame: CGRect,
    size: CGSize,
    offset: CGFloat = 20
) -> CGPoint {
    let minX = visibleFrame.minX
    let maxX = visibleFrame.maxX - size.width
    let minY = visibleFrame.minY
    let maxY = visibleFrame.maxY - size.height

    let x = min(max(anchor.x - size.width / 2, minX), max(minX, maxX))

    let below = anchor.y - size.height - offset   // 首选：鼠标下方
    let above = anchor.y + offset                 // 备选：鼠标上方

    let y: CGFloat
    if below >= minY {
        y = min(below, max(minY, maxY))
    } else if above <= maxY {
        y = max(above, minY)
    } else {
        y = min(max(below, minY), max(minY, maxY))
    }
    return CGPoint(x: x, y: y)
}
