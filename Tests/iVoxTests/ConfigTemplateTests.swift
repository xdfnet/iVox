import XCTest
@testable import iVoxKit

/// 默认模板（`ConfigTemplate.tomlText`）与代码内默认值**必须一致**。
///
/// 模板里写的是「用户装完看到什么」，代码里定的是「不写时用什么」——这是同一件事的
/// 两份副本。改了一边忘了另一边，新装的用户拿到的配置就跟老用户不一样。
/// 这里把它们钉在一起：漂了就测试红。
final class ConfigTemplateTests: XCTestCase {

    private var template: [String: TOMLValue] {
        // 模板是常量，解析失败说明模板本身坏了——直接崩，测试报错更直白
        try! TOML.parse(ConfigTemplate.tomlText)
    }

    /// 模板里 `[段名]` 的出现顺序
    private var sectionOrder: [String] {
        var order: [String] = []
        for line in ConfigTemplate.tomlText.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                let name = String(trimmed.dropFirst().dropLast())
                if !order.contains(name) { order.append(name) }
            }
        }
        return order
    }

    private func section(_ name: String) -> [String: TOMLValue] {
        if case .table(let table)? = template[name] { return table }
        return [:]
    }

    /// TOML 值 → 普通值，好和 JSON 编码出来的默认值比
    private func plain(_ value: TOMLValue) -> Any {
        switch value {
        case .string(let s): return s
        case .integer(let i): return i
        case .double(let d): return d
        case .boolean(let b): return b
        case .array(let a): return a.map { plain($0) }
        case .table(let t): return t.mapValues { plain($0) }
        }
    }

    /// 值的规范写法（布尔统一成 true/false，JSON 那边会把 true 变成 1）
    private func describe(_ value: Any) -> String {
        if let number = value as? NSNumber,
           CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        return String(describing: value)
    }

    private func encoded<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    // MARK: - 结构

    func testTemplateSectionOrderMatchesConfig() {
        // 段的书写顺序 = Config.CodingKeys 的声明顺序（同一处定义，别各写一遍）。
        // 模板可以少写某段（如 voices 只在自建音色时才有），但**顺序不能乱**。
        let expected = Config.CodingKeys.allCases.map(\.stringValue)
        var cursor = expected.startIndex
        for name in sectionOrder {
            guard let index = expected[cursor...].firstIndex(of: name) else {
                return XCTFail("模板里 \(name) 段的位置不对（不在 Config 声明顺序上）")
            }
            cursor = index
        }
    }

    func testTemplateHotkeysCoverEveryAction() {
        // 加了新动作却忘了写进模板 → 新装用户就按不到那个键
        let expected = Set(HotKeyAction.allCases.map(\.rawValue)).union(Set(["voice"]))
        XCTAssertEqual(Set(section("hotkeys").keys), expected)
    }

    func testTemplateSectionsOnlyUseKnownKeys() {
        // 模板里写的键必须都是真有的键（写错的名字早该被发现）
        let expectations: [String: Set<String>] = [
            "speechInput": Set(SpeechInputConfig.CodingKeys.allCases.map(\.stringValue)),
            "translation": Set(TranslationConfig.CodingKeys.allCases.map(\.stringValue)),
            "playback": Set(PlaybackConfig.CodingKeys.allCases.map(\.stringValue)),
            "captions": Set(CaptionsConfig.CodingKeys.allCases.map(\.stringValue)),
            "wechat": Set(WeChatConfig.CodingKeys.allCases.map(\.stringValue)),
        ]
        for (name, known) in expectations {
            let actual = Set(section(name).keys)
            XCTAssertTrue(actual.isSubset(of: known), "\(name) 段写了不存在的键 \(actual.subtracting(known))")
        }
    }

    // MARK: - 值

    func testTemplateValuesMatchCodeDefaults() throws {
        // 模板里的值必须就是代码里的默认值：同一件事不能写两遍还各写各的
        let expectations: [(String, [String: Any])] = [
            ("speechInput", try encoded(SpeechInputConfig.default)),
            ("translation", try encoded(TranslationConfig.default)),
            ("playback", try encoded(PlaybackConfig.default)),
            ("wechat", try encoded(WeChatConfig())),
        ]
        for (name, expected) in expectations {
            // 代码里有默认值的键，模板必须写上（写上就得写对）
            for (key, expectedValue) in expected {
                guard let value = section(name)[key] else {
                    XCTFail("\(name).\(key) 在代码里有默认值，模板却没写")
                    continue
                }
                XCTAssertEqual(
                    describe(plain(value)), describe(expectedValue),
                    "\(name).\(key)：模板值与代码默认值不一致"
                )
            }
        }
    }

    func testTemplateCaptionsSectionMatchesCodeDefaults() {
        // 字幕段（独立段）的默认值：开关关、钉屏留空 = 主屏
        guard case .boolean(let enabled)? = section("captions")["enabled"] else {
            return XCTFail("captions.enabled 不见了")
        }
        XCTAssertFalse(enabled, "字幕默认应是关的")
        guard case .string(let screen)? = section("captions")["screen"] else {
            return XCTFail("captions.screen 不见了")
        }
        XCTAssertTrue(screen.isEmpty, "字幕默认该钉在主屏（screen 留空）")
    }

    func testTemplateDefaultVoiceIsABuiltin() {        // 模板指名的默认音色必须是真存在的内置音色
        guard case .string(let id)? = section("sourceVoices")["default"] else {
            return XCTFail("sourceVoices.default 不见了")
        }
        XCTAssertTrue(VoiceCatalog.isBuiltin(id: id), "默认音色 \(id) 不是内置音色")
    }

    func testTemplateIsLoadable() throws {
        // 模板本身必须能当配置加载（首装就靠它）
        let path = NSTemporaryDirectory() + "ivox-template-load.toml"
        try ConfigTemplate.tomlText.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let config = try loadConfig(from: path)
        XCTAssertFalse(config.defaultVoice.isEmpty)
    }
}
