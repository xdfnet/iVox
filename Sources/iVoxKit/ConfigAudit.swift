import Foundation

// 配置键名审计：把「写了但没人认领」的键揪出来。
//
// 为什么要它：Swift 的 Codable 对**不认识的键直接忽略**——不报错、不提示，那个值静静
// 躺着不生效。配置里把 `allowFrom` 写成 `allow_from` 就是这种：看着配好了，其实没有。
// 审计在解码后对照各段的已知键报出来，还能猜「你是不是想写 allowFrom」。
//
// 已知键从各配置类型的 `CodingKeys` 派生（`knownKeys`），**不另抄一份清单**——
// 两份清单迟早漂移，漂了就变成「告警说某个键无效，但它其实有效」。
// 同一份顺序表还管着**写回时键的排列顺序**（见 `sectionOrder`）。

/// 一个没人认领的键。
public struct ConfigUnknownKey: Sendable {
    /// 键的路径：顶层就是 `foo`，段内是 `wechat.allow_from`
    public let path: String
    /// 疑似想写的键名；猜不出就是 nil
    public let suggestion: String?
    /// 「这个键挪过位置」的说明；有它就不算「没人认领」，只告诉用户新位置在哪
    public let note: String?

    public init(path: String, suggestion: String?, note: String? = nil) {
        self.path = path
        self.suggestion = suggestion
        self.note = note
    }
}

/// 配置键名审计。
public enum ConfigAudit {
    /// 各段的键名与顺序。`""` 是顶层（段本身的顺序）。
    ///
    /// 键名全部由各类型的 `CodingKeys` 派生；`hotkeys` / `sourceVoices` 的键由内容决定
    /// （动作名、来源名），单独列。
    public static let sectionOrder: [String: [String]] = [
        "": Config.CodingKeys.allCases.map(\.stringValue),
        "hotkeys": HotKeyAction.allCases.map(\.rawValue) + ["voice"],
        "speechInput": SpeechInputConfig.CodingKeys.allCases.map(\.stringValue),
        "translation": TranslationConfig.CodingKeys.allCases.map(\.stringValue),
        "playback": PlaybackConfig.CodingKeys.allCases.map(\.stringValue),
        "captions": CaptionsConfig.CodingKeys.allCases.map(\.stringValue),
        "overlay": OverlayConfig.CodingKeys.allCases.map(\.stringValue),
        "sourceVoices": ["default"],
        "wechat": WeChatConfig.CodingKeys.allCases.map(\.stringValue),
        "voices": VoiceInfo.CodingKeys.allCases.map(\.stringValue),
    ]

    /// 这些段的键名由内容决定（动作名、音色 id、来源名），内层不做检查。
    public static let dynamicSections: Set<String> = ["hotkeys", "sourceVoices"]

    /// **挪过位置**的键：老路径 → 新位置。
    ///
    /// 键从一段挪到另一段时，老配置里还留着它。Codable 不认识就静静忽略 → 用户的设置
    /// 升级后无声失效（比报错更坏）。所以加载时会自动搬（见 `migrateCaptionKeys`），审计这边
    /// 也不再把它算成「没人认领」，只告诉用户新位置在哪儿。
    public static let movedKeys: [String: String] = [
        "playback.captions": "captions.enabled",
        "playback.captionScreen": "captions.screen",
        "captions.screen": "overlay.screen",
        "captions.inset": "overlay.inset",
        "captions.padding": "overlay.padding",
        "captions.cornerRadius": "overlay.cornerRadius",
        "captions.fontSize": "overlay.fontSize",
        "captions.maxWidth": "overlay.maxWidth",
        "captions.maxHeightRatio": "overlay.maxHeightRatio",
    ]

    /// **已作废**的键：老配置里还有它，但这个能力已经没有了。
    ///
    /// 跟「挪过位置」分开：挪过去的键换个地方还能用；作废的键**没有新位置**，
    /// 只是留在那儿装样子——留着它还容易被当成「还有效」而误调。
    public static let obsoleteKeys: [String: String] = [
        "captions.position": "浮窗统一贴底，落点不再可配（把这行删掉即可）",
        "overlay.lingerSeconds": "内容空了就立刻收窗，不再等（把这行删掉即可）",
    ]

    /// 某段的已知键（动态段返回空集——不检查内层）。
    static func knownKeys(in section: String) -> Set<String> {
        guard !dynamicSections.contains(section) else { return [] }
        return Set(sectionOrder[section] ?? [])
    }

    /// 从原始 JSON 字节审计（老配置的兼容路径）。
    public static func unknownKeys(in data: Data) -> [ConfigUnknownKey] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else { return [] }
        return unknownKeys(in: root)
    }

    /// 从 TOML 文本审计（当前配置格式）。
    public static func unknownKeys(inTOMLText text: String) -> [ConfigUnknownKey] {
        guard let root = try? TOML.parse(text) else { return [] }
        return unknownKeys(in: TOML.jsonObject(from: root))
    }

    /// 从已解析的字典审计。
    public static func unknownKeys(in root: [String: Any]) -> [ConfigUnknownKey] {
        var issues: [ConfigUnknownKey] = []
        let topKnown = Set(sectionOrder[""] ?? [])
        for (key, value) in root {
            guard topKnown.contains(key) else {
                issues.append(ConfigUnknownKey(path: key, suggestion: suggestion(for: key, known: topKnown)))
                continue
            }
            guard !dynamicSections.contains(key) else { continue }
            let known = knownKeys(in: key)
            guard !known.isEmpty else { continue }

            // 普通段：一张表
            if let dict = value as? [String: Any] {
                for subKey in dict.keys where !known.contains(subKey) {
                    let path = "\(key).\(subKey)"
                    if let obsolete = obsoleteKeys[path] {
                        issues.append(ConfigUnknownKey(
                            path: path, suggestion: nil,
                            note: "已作废：\(obsolete)"
                        ))
                        continue
                    }
                    if let moved = movedKeys[path] {
                        issues.append(ConfigUnknownKey(
                            path: path, suggestion: nil,
                            note: "已挪到 \(moved)（老键照常生效，把这一行挪过去即可）"
                        ))
                        continue
                    }
                    issues.append(ConfigUnknownKey(
                        path: path,
                        suggestion: suggestion(for: subKey, known: known)
                    ))
                }
                continue
            }
            // 数组段（[[voices]]）：逐个元素查
            if let array = value as? [Any] {
                for element in array {
                    guard let dict = element as? [String: Any] else { continue }
                    for subKey in dict.keys where !known.contains(subKey) {
                        issues.append(ConfigUnknownKey(
                            path: "\(key).\(subKey)",
                            suggestion: suggestion(for: subKey, known: known)
                        ))
                    }
                }
            }
        }
        // 顺序稳定：按路径排，免得每次启动报出来的顺序都不同
        return issues.sorted { $0.path < $1.path }
    }

    /// 猜「本来想写什么」：忽略大小写与下划线后比对（`allow_from` ≈ `allowFrom`、
    /// `base_url` ≈ `baseURL`）。猜不出就返回 nil，不硬凑。
    static func suggestion(for key: String, known: Set<String>) -> String? {
        func normalize(_ s: String) -> String {
            s.lowercased().replacingOccurrences(of: "_", with: "")
        }
        let normalized = normalize(key)
        let candidates = known.sorted()
        for candidate in candidates where normalize(candidate) == normalized {
            return candidate
        }
        // 前 4 个字符相同就算像（longPollMS vs long_poll_timeout_ms、baseURL vs
        // base_url…）。比子串/前缀更宽容：多写了中间几个词时两边互不为子串，
        // 但开头是一样的。候选至少 4 个字符，免得 "ms" 之类短串乱认亲。
        let head = 4
        guard normalized.count >= head else { return nil }
        for candidate in candidates {
            let normalizedCandidate = normalize(candidate)
            guard normalizedCandidate.count >= head else { continue }
            if normalizedCandidate.hasPrefix(String(normalized.prefix(head)))
                || normalized.hasPrefix(String(normalizedCandidate.prefix(head))) {
                return candidate
            }
        }
        return nil
    }

    /// 人看的一行行提示。
    public static func describe(_ issues: [ConfigUnknownKey]) -> String {
        issues.map { issue in
            if let note = issue.note { return "\(issue.path) → \(note)" }
            return issue.suggestion.map { "\(issue.path) → 是不是想写「\($0)」？" } ?? issue.path
        }.joined(separator: "；")
    }
}
