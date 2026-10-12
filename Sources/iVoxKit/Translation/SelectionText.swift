import Foundation

/// 清理从剪贴板取到的选中文本：去竖线噪声，并把任意连续空白（**含换行**）折叠成单个空格。
///
/// 基于 iDict `ClipboardManager.cleanClipboardText`，但分隔符由 `.whitespaces` 换成
/// `.whitespacesAndNewlines`——原版会保留中间换行，多行选中送翻译时译文会带断行。
public func cleanSelectionText(_ raw: String) -> String {
    raw.replacingOccurrences(of: "│", with: "")
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

/// 校验能否送去翻译，返回清理后的文本；`nil` 表示不可用（空 / 超长）。
public func validateSelectionText(_ raw: String, maxLength: Int = 5000) -> String? {
    let cleaned = cleanSelectionText(raw)
    guard !cleaned.isEmpty, cleaned.count <= maxLength else { return nil }
    return cleaned
}
