import ArgumentParser
import Foundation
import iVoxKit

// `ivox init-config`：生成默认配置（`~/.config/ivox/config.toml`）。
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
}
