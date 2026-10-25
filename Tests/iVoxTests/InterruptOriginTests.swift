import XCTest
@testable import iVox

// 打断归因（档位 × 入口）的写法契约。日志里那一句 `掀摞·键盘 ctrl+2`
// 是「谁按的什么键、掀的是哪一档」的唯一出口，措辞被改了这儿就红。

final class InterruptOriginTests: XCTestCase {

    /// 归因要一眼答完两问：**谁按的什么**（入口）× **掀的哪一档**（档位）。
    func testDescriptionCarriesBothTierAndTrigger() {
        XCTAssertEqual(InterruptOrigin(.skipStack, .hotkey("ctrl+2")).description, "掀摞·键盘 ctrl+2")
        XCTAssertEqual(InterruptOrigin(.skipPage, .hotkey("ctrl+1")).description, "掀页·键盘 ctrl+1")
        XCTAssertEqual(InterruptOrigin(.skipAll, .hotkey("ctrl+3")).description, "全掀·键盘 ctrl+3")
        XCTAssertEqual(InterruptOrigin(.cancelTurn, .request("pi")).description, "取消本轮·请求方 pi")
        XCTAssertEqual(InterruptOrigin(.shutdown, .system).description, "退出清场·系统")
    }

    /// 键位是**可配**的：日志里必须打实际生效的那一组，照抄默认键位就是句假话。
    func testHotkeyTriggerKeepsTheResolvedChord() {
        let remapped = InterruptOrigin(.skipStack, .hotkey("cmd+alt+7"))
        XCTAssertEqual(remapped.description, "掀摞·键盘 cmd+alt+7")
    }
}
