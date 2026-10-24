import XCTest
@testable import iVoxKit

/// 热键配置串的解析与默认值。
///
/// 覆盖三类：写法（修饰符+主键）、错误写法（要报错而不是默默用默认）、默认值。
final class HotKeySpecTests: XCTestCase {

    // MARK: - 解析

    func testParsesCommandD() throws {
        let chord = try HotKeySpec.parseChord("cmd+d")
        XCTAssertEqual(chord.keyCode, 0x02)
        XCTAssertEqual(chord.modifiers, .command)
        XCTAssertEqual(chord.display, "cmd+d")
    }

    func testModifierOrderDoesNotMatter() throws {
        let a = try HotKeySpec.parseChord("cmd+shift+d")
        let b = try HotKeySpec.parseChord("shift+cmd+d")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.display, "cmd+shift+d")
    }

    func testAcceptsModifierAliases() throws {
        let command = try HotKeySpec.parseChord("command+d")
        let control = try HotKeySpec.parseChord("control+1")
        let option = try HotKeySpec.parseChord("alt+z")
        XCTAssertEqual(command.modifiers, .command)
        XCTAssertEqual(control.modifiers, .control)
        XCTAssertEqual(option.modifiers, .option)
    }

    func testIsCaseInsensitive() throws {
        XCTAssertEqual(try HotKeySpec.parseChord("CMD+D"), try HotKeySpec.parseChord("cmd+d"))
        XCTAssertEqual(try HotKeySpec.parseChord("Opt+A"), try HotKeySpec.parseChord("opt+a"))
    }

    func testParsesNonLetterKeys() throws {
        XCTAssertEqual(try HotKeySpec.parseChord("ctrl+esc").keyCode, 0x35)
        XCTAssertEqual(try HotKeySpec.parseChord("ctrl+1").keyCode, 0x12)
        XCTAssertEqual(try HotKeySpec.parseChord("f5").keyCode, 0x60)
    }

    // MARK: - 错误写法必须报错（不能默默用默认）

    func testRejectsUnknownKey() {
        XCTAssertThrowsError(try HotKeySpec.parseChord("cmd+不存在的键"))
    }

    func testRejectsModifierOnly() {
        XCTAssertThrowsError(try HotKeySpec.parseChord("cmd+shift"))
    }

    func testRejectsTwoKeys() {
        XCTAssertThrowsError(try HotKeySpec.parseChord("cmd+a+b"))
    }

    func testRejectsEmpty() {
        XCTAssertThrowsError(try HotKeySpec.parseChord(""))
        XCTAssertThrowsError(try HotKeySpec.parseChord("  +  "))
    }

    // MARK: - 语音键

    func testParsesVoiceSpec() throws {
        XCTAssertEqual(try HotKeySpec.parseVoice("rightcmd"),
                       VoiceKeySpec(rightCommand: true, rightControl: false))
        XCTAssertEqual(try HotKeySpec.parseVoice("rightctrl"),
                       VoiceKeySpec(rightCommand: false, rightControl: true))
        XCTAssertEqual(try HotKeySpec.parseVoice("rightcmd+rightctrl"),
                       VoiceKeySpec(rightCommand: true, rightControl: true))
        // "both" = 两个键都开；默认只要右⌘
        XCTAssertEqual(try HotKeySpec.parseVoice("both"),
                       VoiceKeySpec(rightCommand: true, rightControl: true))
        XCTAssertEqual(VoiceKeySpec.default, VoiceKeySpec(rightCommand: true, rightControl: false))
    }

    func testRejectsUnknownVoiceSpec() {
        XCTAssertThrowsError(try HotKeySpec.parseVoice("左cmd"))
    }

    // MARK: - 默认值

    func testDefaultChordsMatchShippedBindings() {
        // 默认键位是「唯一真源」，改动这里等于改所有没配过这项的用户
        XCTAssertEqual(HotKeySpec.defaultChord(for: .translate).display, "opt+z")
        XCTAssertEqual(HotKeySpec.defaultChord(for: .openTerminal).display, "opt+q")
        XCTAssertEqual(HotKeySpec.defaultChord(for: .openTerminalClaude).display, "opt+a")
        XCTAssertEqual(HotKeySpec.defaultChord(for: .openTerminalCodex).display, "opt+x")
        XCTAssertEqual(HotKeySpec.defaultChord(for: .openTerminalPi).display, "opt+s")
        XCTAssertEqual(HotKeySpec.defaultChord(for: .copyPath).display, "opt+c")
        XCTAssertEqual(HotKeySpec.defaultChord(for: .skipAll).display, "ctrl+2")
        XCTAssertEqual(HotKeySpec.defaultChord(for: .skipBucket).display, "ctrl+1")
        XCTAssertEqual(HotKeySpec.defaultChord(for: .skipPage).display, "ctrl+esc")
    }

    func testDefaultChordsAreAllDistinct() {
        // 默认键位互不撞：撞了会让某个动作在默认配置下不可用
        let chords = HotKeyAction.allCases.map { HotKeySpec.defaultChord(for: $0) }
        XCTAssertEqual(Set(chords).count, chords.count)
    }

    // MARK: - 配置解码

    func testConfigDecodesHotkeysSection() throws {
        let json = """
        {
          "defaultVoice": "v",
          "sourceVoices": {},
          "voices": [{ "id": "v" }],
          "hotkeys": { "translate": "cmd+shift+d", "voice": "rightcmd" }
        }
        """
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(config.hotkeys?["translate"], "cmd+shift+d")
        XCTAssertEqual(config.hotkeys?["voice"], "rightcmd")
    }
}
