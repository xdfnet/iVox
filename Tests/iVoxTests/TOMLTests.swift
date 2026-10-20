import XCTest
@testable import iVoxKit

/// TOML 解析 / 序列化 / 就地编辑。
final class TOMLTests: XCTestCase {

    // MARK: - 解析

    func testParsesTableAndComments() throws {
        let text = """
        # 这是注释
        [hotkeys]
        translate = "cmd+d"   # 行尾注释
        """
        let root = try TOML.parse(text)
        guard case .table(let hotkeys)? = root["hotkeys"] else {
            return XCTFail("没解析出 hotkeys 段")
        }
        XCTAssertEqual(hotkeys["translate"], .string("cmd+d"))
    }

    func testParsesTypes() throws {
        let text = """
        a = 1
        b = 2.5
        c = true
        d = ["x", "y"]
        e = { k = "v" }
        """
        let root = try TOML.parse(text)
        XCTAssertEqual(root["a"], .integer(1))
        XCTAssertEqual(root["b"], .double(2.5))
        XCTAssertEqual(root["c"], .boolean(true))
        XCTAssertEqual(root["d"], .array([.string("x"), .string("y")]))
        XCTAssertEqual(root["e"], .table(["k": .string("v")]))
    }

    func testParsesMultilineString() throws {
        let text = """
        [voices]
        refText = \"\"\"
        第一行
        第二行\"\"\"
        """
        let root = try TOML.parse(text)
        guard case .table(let voices)? = root["voices"] else {
            return XCTFail("没解析出 voices 段")
        }
        XCTAssertEqual(voices["refText"], .string("第一行\n第二行"))
    }

    func testParsesNestedTable() throws {
        let text = """
        [a.b]
        k = "v"
        """
        let root = try TOML.parse(text)
        guard case .table(let a)? = root["a"], case .table(let b)? = a["b"] else {
            return XCTFail("没解析出嵌套表")
        }
        XCTAssertEqual(b["k"], .string("v"))
    }

    func testArrayTableKeysBelongToLastElement() throws {
        let text = """
        [[voices]]
        id = "a"

        [[voices]]
        id = "b"
        """
        let root = try TOML.parse(text)
        guard case .array(let voices)? = root["voices"], voices.count == 2 else {
            return XCTFail("没解析出两个元素，实际 \(String(describing: root["voices"]))")
        }
        XCTAssertEqual(voices[0], .table(["id": .string("a")]))
        XCTAssertEqual(voices[1], .table(["id": .string("b")]))
    }

    func testReportsErrorWithLineNumber() {
        let text = """
        [a]
        x = 1
        y = "没闭合
        """
        XCTAssertThrowsError(try TOML.parse(text)) { error in
            guard let e = error as? TOMLError else { return XCTFail("不是 TOMLError") }
            XCTAssertEqual(e.line, 3)
        }
    }

    // MARK: - 序列化

    func testSerializesInGivenOrder() {
        let root: [String: TOMLValue] = [
            "zeta": .string("z"),
            "alpha": .string("a"),
        ]
        let text = TOML.string(from: root, order: ["": ["zeta", "alpha"]])
        XCTAssertTrue(text.hasPrefix("zeta = \"z\"\n"))
        XCTAssertTrue(text.contains("alpha = \"a\""))
    }

    func testSerializesNestedTableAsSection() {
        let root: [String: TOMLValue] = [
            "hotkeys": .table(["translate": .string("cmd+d")]),
        ]
        let text = TOML.string(from: root)
        XCTAssertTrue(text.contains("[hotkeys]"))
        XCTAssertTrue(text.contains("translate = \"cmd+d\""))
    }

    func testSerializesArrayOfTables() {
        let root: [String: TOMLValue] = [
            "voices": .array([.table(["id": .string("a")])]),
        ]
        let text = TOML.string(from: root)
        XCTAssertTrue(text.contains("[[voices]]"))
        XCTAssertTrue(text.contains("id = \"a\""))
    }

    func testRoundTripThroughJSONCompatibleDictionary() throws {
        let root: [String: TOMLValue] = [
            "hotkeys": .table(["translate": .string("cmd+d")]),
            "n": .integer(3),
        ]
        let object = TOML.jsonObject(from: root)
        XCTAssertEqual(object["n"] as? Int, 3)
        let reparsed = try TOML.parse(TOML.string(from: root))
        XCTAssertEqual(reparsed, root)
    }

    // MARK: - 就地编辑（保留注释）

    func testSettingExistingKeyKeepsTrailingComment() throws {
        let text = """
        [hotkeys]
        translate = "cmd+d"   # 我爱用 cmd+d
        """
        let doc = try TOMLDocument.parse(text)
        let updated = doc.setting(.string("cmd+shift+d"), forKey: "hotkeys.translate")
        XCTAssertTrue(updated.contains("translate = \"cmd+shift+d\"   # 我爱用 cmd+d"))
    }

    func testSettingMissingKeyInsertsIntoSection() throws {
        let text = """
        [hotkeys]
        translate = "cmd+d"

        [other]
        k = "v"
        """
        let doc = try TOMLDocument.parse(text)
        let updated = doc.setting(.string("ctrl+1"), forKey: "hotkeys.skipBucket")
        XCTAssertTrue(updated.contains("skipBucket = \"ctrl+1\""))
        // 插在 hotkeys 段内、other 段之前
        let hotkeysIdx = try XCTUnwrap(updated.range(of: "[hotkeys]"))
        let insertIdx = try XCTUnwrap(updated.range(of: "skipBucket"))
        let otherIdx = try XCTUnwrap(updated.range(of: "[other]"))
        XCTAssertTrue(hotkeysIdx.lowerBound < insertIdx.lowerBound)
        XCTAssertTrue(insertIdx.lowerBound < otherIdx.lowerBound)
    }

    func testRemovingKeyRemovesWholeLine() throws {
        let text = """
        [hotkeys]
        translate = "cmd+d"
        skipBucket = "ctrl+1"
        """
        let doc = try TOMLDocument.parse(text)
        let updated = doc.removingValue(forKey: "hotkeys.translate")
        XCTAssertFalse(updated.contains("translate"))
        XCTAssertTrue(updated.contains("skipBucket"))
    }

    func testAppendingToArrayTable() throws {
        let text = """
        [[voices]]
        id = "a"
        """
        let doc = try TOMLDocument.parse(text)
        let updated = doc.appendingToArrayTable("voices", element: .table(["id": .string("b")]))
        XCTAssertTrue(updated.contains("[[voices]]"))
        XCTAssertTrue(updated.contains("id = \"b\""))
        // 原有内容还在
        XCTAssertTrue(updated.contains("id = \"a\""))
    }

    func testRemovingFromArrayTable() throws {
        let text = """
        [[voices]]
        id = "a"

        [[voices]]
        id = "b"
        """
        let doc = try TOMLDocument.parse(text)
        XCTAssertEqual(doc.arrayTableCount("voices"), 2)
        let updated = doc.removingFromArrayTable("voices", index: 0)
        XCTAssertFalse(updated.contains("id = \"a\""))
        XCTAssertTrue(updated.contains("id = \"b\""))
    }
}
