import ApplicationServices
import ArgumentParser
import Foundation
import iVoxKit

// CLI 子命令 ivox translate：划词翻译。

/// 划词翻译命令行。
///
/// 纯文本路径**不依赖 daemon**（直接调 `TranslationService`），所以它是整条链路的可验证接缝：
/// daemon 没起、热键没授权时，也能单独确认翻译本身、以及 `--selection` 的剪贴板链路通不通。
///
/// 注：这里**不弹浮窗**——CLI 进程执行完就退出，没有 run loop 让 NSPanel 存活。
/// 浮窗属于 daemon 内的 `TranslationCoordinator`（Opt+W 那条路）。
struct TranslateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "translate",
        abstract: "翻译文本（默认英译中）"
    )

    @Argument(help: "要翻译的文本；与 --selection 二选一")
    var text: String?

    @Flag(name: .long, help: "翻译当前选中的文本（模拟 Cmd+C 取剪贴板）")
    var selection = false

    @Flag(name: .long, help: "以 JSON 输出（含原文 / 服务商）")
    var json = false

    @MainActor
    func run() async throws {
        let source = try await resolveSource()
        let config = (try? loadConfig())?.resolvedTranslation ?? .default
        guard config.enabled else {
            throw ValidationError("划词翻译已关闭（config.toml 里 translation.enabled = false）")
        }

        switch await TranslationService(config: config).translate(source) {
        case .success(let translated):
            if json {
                let payload: [String: String] = [
                    "source": source,
                    "target": translated,
                    "provider": config.provider.rawValue,
                ]
                let data = try JSONSerialization.data(
                    withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                print(String(data: data, encoding: .utf8) ?? "{}")
            } else {
                print(translated)
            }
        case .failed(_, let error):
            FileHandle.standardError.write(Data("翻译失败: \(error)\n".utf8))
            throw ExitCode.failure
        }
    }

    @MainActor
    private func resolveSource() async throws -> String {
        if selection {
            guard AXIsProcessTrusted() else {
                throw ValidationError("模拟 Cmd+C 需要「辅助功能 / 输入监控」权限")
            }
            guard let raw = await ClipboardReader.copyAndRead(),
                  let cleaned = validateSelectionText(raw) else {
                throw ValidationError("没有取到选中文本（或文本过长）")
            }
            return cleaned
        }
        guard let text, !text.isEmpty else {
            throw ValidationError("请给出要翻译的文本，或加 --selection 翻译当前选中内容")
        }
        return text
    }
}
