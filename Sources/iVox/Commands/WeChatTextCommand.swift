import ArgumentParser
import Foundation
import iVoxKit

// MARK: - ivox wechat text — 回复微信消息（Stop Hook 调用）

struct WeChatTextCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "text",
        abstract: "回复微信消息（由 Stop Hook 调用）"
    )

    @Argument(help: "要发送的文本")
    var text: String

    func run() async throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // 加载配置
        guard let cfg = try? loadConfig(), let wechat = cfg.wechat, wechat.enabled else {
            return // 没配微信，静默跳过
        }

        // 读取 pending_user
        let dir = wechat.dataDir.isEmpty
            ? NSString(string: "~/.config/ivox").expandingTildeInPath
            : wechat.dataDir
        let pendingFile = dir + "/pending_user"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: pendingFile)),
              let userID = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespaces),
              !userID.isEmpty else {
            return // 没有待回复用户
        }

        // 发消息
        do {
            let platform = WeChatPlatform(config: wechat)
            try await platform.sendMessage(to: userID, text: text)
            try? FileManager.default.removeItem(atPath: pendingFile)
            Log.info("📤 hook-reply: 已发送 \(text.count) 字符 → \(userID.prefix(20))…")
        } catch {
            Log.error("hook-reply: 发送失败: \(error)")
        }
    }
}
