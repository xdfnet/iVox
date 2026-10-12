import ArgumentParser
import Foundation
import iVoxKit

/// 划词翻译。
///
/// 纯文本路径**不依赖 daemon**（直接调 `TranslationService`），
/// 所以它是整条链路的可验证接缝：daemon 没起、热键没授权时，也能单独确认翻译本身通不通。
struct TranslateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "translate",
        abstract: "翻译文本（默认英译中）"
    )

    @Argument(help: "要翻译的文本")
    var text: String

    @Flag(name: .long, help: "以 JSON 输出（含原文 / 服务商）")
    var json = false

    func run() async throws {
        let config = (try? loadConfig())?.resolvedTranslation ?? .default
        guard config.enabled else {
            FileHandle.standardError.write(Data("划词翻译已关闭（config.json 里 translation.enabled = false）\n".utf8))
            throw ExitCode.failure
        }

        let result = await TranslationService(config: config).translate(text)

        switch result {
        case .success(let translated):
            if json {
                let payload: [String: String] = [
                    "source": text,
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
}
