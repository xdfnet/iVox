import Foundation

/// 对文本做最低限度清洗，然后交给 Qwen3 TTS 直接朗读。
///
/// Qwen3 TTS 是 LLM 基座，能自然理解标点、emoji、URL、代码、Markdown 等格式。
/// 当前不做任何过滤，保留原文全部内容。
public func cleanText(_ text: String) -> String {
    text
}
