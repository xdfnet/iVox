import ArgumentParser
import Foundation
import iVoxKit

// `ivox init-config`：生成默认配置（`~/.config/ivox/config.toml`），
// 并把「运行时家当说明」拷到同一个目录（`runtime-files.md`）。
//
// 为什么要它：默认配置此前在**三处**各写一遍（代码仓模板、安装脚本内嵌的那份、
// 首装生成的文件），迟早漂移。现在模板是唯一真源（`ConfigTemplate.tomlText`）——
// 安装脚本直接调本命令，不再内嵌一份。
//
// 格式是 TOML：能写注释，配置里每项是干嘛的一目了然。

/// 生成默认配置。**已存在则不动**。
struct InitConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init-config",
        abstract: "生成默认配置（TOML，已存在则不动）"
    )

    /// 写到别处（测试用）；默认写 `~/.config/ivox/config.toml`。
    @Option(name: .customLong("out"), help: "输出路径（默认 ~/.config/ivox/config.toml）")
    var out: String?

    func run() throws {
        // 家当说明先放：它是随版本的说明，**每次都刷新**（不含用户数据），
        // 与配置「已存在就不动」是两回事
        try installRuntimeDoc()

        let path = out ?? ConfigFile.path
        if FileManager.default.fileExists(atPath: path) {
            print("配置已存在，未改动: \(path)")
            return
        }
        // 有老配置（config.json）就**迁移**它，别拿模板盖掉用户已经调好的设置
        if out == nil, FileManager.default.fileExists(atPath: ConfigFile.legacyJSONPath) {
            do {
                try migrateLegacyJSON(ConfigFile.legacyJSONPath, to: path)
                print("✓  已把老配置迁移过来: \(path)（旧文件保留，可自行删除）")
                return
            } catch {
                print("✗  老配置迁移失败（\(error.localizedDescription)），改用默认模板")
            }
        }
        // 模板里写 "~/.config/ivox/..."，落盘时换成真实家目录
        let home = NSHomeDirectory()
        let text = ConfigTemplate.tomlText.replacingOccurrences(of: "\"~", with: "\"\(home)")

        try FileManager.default.createDirectory(
            atPath: (out.map { ($0 as NSString).deletingLastPathComponent }
                     ?? AppPaths.configDir),
            withIntermediateDirectories: true, attributes: nil)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        // 配置里可能有微信 token 等凭据，只给本人读写
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: path)
        print("✓  已生成默认配置: \(path)")
    }

    /// 把「运行时家当说明」拷到 `~/.config/ivox/`——**总是覆盖**：
    /// 它是随版本更新的说明，不含用户数据；不刷新就会和代码里的现状脱节。
    private func installRuntimeDoc() throws {
        guard let source = Self.runtimeDocURL() else {
            print("⚠️  找不到家当说明（runtime-files.md 不在二进制旁边？）")
            return
        }
        let target = AppPaths.configDir + "/runtime-files.md"
        try FileManager.default.createDirectory(
            atPath: AppPaths.configDir, withIntermediateDirectories: true, attributes: nil)
        // 覆盖写（不是 copyItem——目标已存在会直接报错，而说明是要刷新的）
        let data = try Data(contentsOf: source)
        try data.write(to: URL(fileURLWithPath: target), options: .atomic)
        print("✓  已放好家当说明: \(target)")
    }

    /// 家当说明在 SPM 资源包里。不同 SwiftPM 版本的包内布局略有差别，所以按候选逐个试。
    private static func runtimeDocURL() -> URL? {
        let bundle = Bundle.module
        var candidates: [URL?] = []
        if let resourceURL = bundle.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("Resources/runtime-files.md"))
            candidates.append(resourceURL.appendingPathComponent("runtime-files.md"))
        }
        candidates.append(bundle.url(forResource: "runtime-files", withExtension: "md"))
        candidates.append(bundle.url(
            forResource: "runtime-files", withExtension: "md", subdirectory: "Resources"))
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
