import Foundation

// 热键规格：动作名、默认键位、配置串的解析。
//
// 放 iVoxKit 是因为它纯逻辑、无 UI 依赖，且**两边都要用同一份定义**：
// 配置文件（Config.swift）按动作名给键位，键盘事件层（GlobalKeyTap）按动作名去绑定。
// 动作名与默认键位只在这里写一处，其余代码都指回来。
//
// 键码用 macOS ANSI 虚拟键码（与键盘布局无关的**物理位置**）。中文拼音、英文等
// 常见布局的字母/数字位置与 ANSI 一致；非 ANSI 布局（如 Dvorak）字母位置会错位。

/// 一个热键动作：与配置 `hotkeys` 段里的 key 一一对应。
public enum HotKeyAction: String, CaseIterable, Sendable {
    case openTerminalClaude   // 开终端跑 claude
    case copyPath             // 复制 Finder 选中路径
    case openTerminalPi       // 开终端跑 pi
    case translate            // 划词翻译
    case openTerminalCodex    // 开终端跑 codex
    case openTerminal         // 开终端
    case skipAll              // 闭嘴（全掀）
    case skipBucket           // 跳整摞
    case skipPage             // 读下一页（掀页）
}

/// 修饰键集合。用自有位掩码而非 CGEventFlags，好让解析与测试都不依赖 CoreGraphics。
public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 1)
    public static let control = KeyModifiers(rawValue: 2)
    public static let option = KeyModifiers(rawValue: 4)
    public static let command = KeyModifiers(rawValue: 8)
}

/// 一个组合键：主键码 + 修饰键 + 主键名。
///
/// `keyName` 是**按写法记的**（"d" / "2" / "esc"），不是从键码反查的——`1` 与 `u`、
/// `2` 与 `i` 键码相同，反查出来的名字会变成 "ctrl+u"，用户看着莫名其妙。
/// 显示名与配置里的写法一致（`opt+s`），看到日志就知道该往配置里写什么。
public struct KeyChord: Sendable, Hashable {
    public let keyCode: Int64
    public let modifiers: KeyModifiers
    public let keyName: String

    public init(keyCode: Int64, modifiers: KeyModifiers, keyName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyName = keyName
    }

    /// 修饰键按 cmd → ctrl → opt → shift 排序：`cmd+shift+d` / `ctrl+2`。
    public var display: String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("cmd") }
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        parts.append(keyName)
        return parts.joined(separator: "+")
    }
}

/// 语音键（右⌘ / 右⌃ 长按说话）用哪几个。
public struct VoiceKeySpec: Sendable, Equatable {
    public var rightCommand: Bool
    public var rightControl: Bool

    public init(rightCommand: Bool, rightControl: Bool) {
        self.rightCommand = rightCommand
        self.rightControl = rightControl
    }

    /// 默认语音键：**只要右⌘**（2026-10-21 飞哥裁决，右⌃ 不再作默认）。
    /// 配置里可改成 `rightctrl` / `rightcmd+rightctrl` / `none`。
    public static let `default` = VoiceKeySpec(rightCommand: true, rightControl: false)

    /// 一个都不启用时，语音层等于关掉。
    public var isEmpty: Bool { !rightCommand && !rightControl }
}

/// 配置串解析失败的原因。描述给人看，daemon 启动时原样打进日志。
public enum HotKeyParseError: Error, CustomStringConvertible, Equatable {
    case empty
    case unknownModifier(String)
    case unknownKey(String)
    case missingKey
    case tooManyKeys([String])
    case unknownAction(String)

    public var description: String {
        switch self {
        case .empty:
            return "空的"
        case .unknownModifier(let m):
            return "不认识的修饰键「\(m)」（可用：cmd / ctrl / opt / shift）"
        case .unknownKey(let k):
            return "不认识的按键「\(k)」（可用：a-z、0-9、esc、space、tab、return、backspace、delete、f1-f12、方向键）"
        case .missingKey:
            return "只有修饰键、没写主键"
        case .tooManyKeys(let keys):
            return "写了多个主键（\(keys.joined(separator: "、"))），一个组合只能有一个主键"
        case .unknownAction(let a):
            return "不存在的动作「\(a)」"
        }
    }
}

/// 解析与默认值。
public enum HotKeySpec {
    /// ANSI 物理位置的虚拟键码。
    public static let keyTable: [String: Int64] = [
        // 字母
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
        "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
        "w": 0x0D, "e": 0x0E, "r": 0x0F, "t": 0x10, "y": 0x11, "u": 0x12,
        "i": 0x13, "o": 0x14, "p": 0x15, "l": 0x1B, "j": 0x1D, "k": 0x1E,
        "n": 0x2D, "m": 0x2E,
        // 数字
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "5": 0x16,
        "6": 0x17, "7": 0x1A, "8": 0x1C, "9": 0x25, "0": 0x29,
        // 常用
        "esc": 0x35, "space": 0x31, "tab": 0x30, "return": 0x24, "enter": 0x24,
        "backspace": 0x33, "delete": 0x75,
        // 功能键
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61,
        "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
        // 方向键
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
    ]

    /// 修饰键别名 → 掩码。
    static let modifierAliases: [String: KeyModifiers] = [
        "cmd": .command, "command": .command, "⌘": .command,
        "ctrl": .control, "control": .control, "⌃": .control,
        "opt": .option, "option": .option, "alt": .option, "⌥": .option,
        "shift": .shift, "⇧": .shift,
    ]

    /// 各动作的默认键位。**默认只写这一处**，配置文件是它的覆盖。
    public static func defaultChord(for action: HotKeyAction) -> KeyChord {
        switch action {
        case .openTerminalClaude: return chord(keyName: "a", modifiers: .option)    // Opt+A
        case .copyPath:           return chord(keyName: "c", modifiers: .option)    // Opt+C
        case .openTerminalPi:     return chord(keyName: "q", modifiers: .option)    // Opt+Q
        case .translate:          return chord(keyName: "s", modifiers: .option)    // Opt+S
        case .openTerminalCodex:  return chord(keyName: "x", modifiers: .option)    // Opt+X
        case .openTerminal:       return chord(keyName: "z", modifiers: .option)    // Opt+Z
        case .skipAll:            return chord(keyName: "2", modifiers: .control)   // Ctrl+2
        case .skipBucket:         return chord(keyName: "1", modifiers: .control)   // Ctrl+1
        case .skipPage:           return chord(keyName: "esc", modifiers: .control) // Ctrl+Esc
        }
    }

    /// 由主键名 + 修饰键组一个组合键（名字不在表里时调用方自己保证）。
    public static func chord(keyName: String, modifiers: KeyModifiers) -> KeyChord {
        let name = keyName.lowercased()
        return KeyChord(keyCode: keyTable[name] ?? 0, modifiers: modifiers, keyName: name)
    }

    /// 解析一个组合键串，如 `cmd+d`、`ctrl+shift+1`、`opt+esc`。
    /// 分隔符 `+`，顺序随意，大小写不敏感。
    public static func parseChord(_ text: String) throws -> KeyChord {
        let tokens = text.split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { throw HotKeyParseError.empty }

        var modifiers: KeyModifiers = []
        var keys: [String] = []
        for token in tokens {
            if let m = modifierAliases[token] {
                modifiers.insert(m)
            } else if keyTable[token] != nil {
                keys.append(token)
            } else {
                // 分不清是修饰键还是主键时，先看它像不像修饰键，再报「不认识的按键」
                throw HotKeyParseError.unknownKey(token)
            }
        }
        guard !keys.isEmpty else { throw HotKeyParseError.missingKey }
        guard keys.count == 1 else { throw HotKeyParseError.tooManyKeys(keys) }
        return chord(keyName: keys[0], modifiers: modifiers)
    }

    /// 解析语音键串：`rightcmd` / `rightctrl` / `rightcmd+rightctrl` / `both` / `none`。
    public static func parseVoice(_ text: String) throws -> VoiceKeySpec {
        let tokens = text.split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { throw HotKeyParseError.empty }

        var spec = VoiceKeySpec(rightCommand: false, rightControl: false)
        for token in tokens {
            switch token {
            case "rightcmd", "rightcommand", "rcmd": spec.rightCommand = true
            case "rightctrl", "rightcontrol", "rctrl": spec.rightControl = true
            case "both", "all": spec.rightCommand = true; spec.rightControl = true
            case "none", "off": break
            default: throw HotKeyParseError.unknownKey(token)
            }
        }
        return spec
    }
}
