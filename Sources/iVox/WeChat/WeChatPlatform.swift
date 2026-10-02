import Foundation
import iVoxKit

// MARK: - 微信消息处理回调

typealias WeChatMessageHandler = @Sendable (IncomingMessage) async -> Void

// MARK: - 微信 ilink 平台

actor WeChatPlatform {
    let client: WeChatClient
    private let config: WeChatConfig
    private var handler: WeChatMessageHandler?
    private var pollTask: Task<Void, Never>?
    private var isRunning = false

    // 状态持久化（单用户：扫码只注册一个微信用户，重新扫码覆盖）
    private var dataDir: String
    private var syncBuf = ""
    private var userID = ""
    private var contextToken = ""
    private var dedup: [String: Date] = [:]

    // Typing
    private var typingTicket: TypingTicketCache?
    private let typingTTL: TimeInterval = 600 // 10 min

    init(config: WeChatConfig) {
        self.config = config
        self.client = WeChatClient(baseURL: config.baseURL, token: config.token)
        let dir = config.dataDir.isEmpty
            ? NSString(string: "~/.config/ivox").expandingTildeInPath + "/wechat"
            : config.dataDir + "/wechat"
        self.dataDir = dir
        // 在 init 中直接加载状态（不能调 actor-isolated 方法）
        if let data = try? Data(contentsOf: URL(fileURLWithPath: dir + "/get_updates.buf")),
           let buf = String(data: data, encoding: .utf8) {
            self.syncBuf = buf
        }
        if let data = try? Data(contentsOf: URL(fileURLWithPath: dir + "/context_token.json")),
           let state = try? JSONDecoder().decode(SingleUserState.self, from: data) {
            self.userID = state.userID
            self.contextToken = state.contextToken
        }
    }

    // MARK: - 生命周期

    /// 长轮询是否在运行
    var isPolling: Bool { isRunning }

    func start(handler: @escaping WeChatMessageHandler) {
        guard !isRunning else { return }
        isRunning = true
        self.handler = handler
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
        Log.info("微信平台: 长轮询已启动")
    }

    func stop() {
        isRunning = false
        pollTask?.cancel()
        pollTask = nil
        Log.info("微信平台: 已停止")
    }

    // MARK: - 消息发送

    func sendMessage(text: String) async throws {
        guard !contextToken.isEmpty else {
            throw WeChatError.unknown("没有 context_token")
        }
        let maxChunk = 3800
        for (i, chunk) in splitRunes(text, max: maxChunk).enumerated() {
            if i > 0 { try await Task.sleep(nanoseconds: 100_000_000) }
            let cid = "ivox-" + randomHex(6)
            try await client.sendText(to: userID, text: chunk, contextToken: contextToken, clientID: cid)
        }
    }

    // MARK: - Typing 指示器

    func sendTyping(status: TypingStatus) async {
        guard !contextToken.isEmpty else { return }
        do {
            let ticket = try await getOrFetchTypingTicket()
            try await client.sendTyping(userID: userID, ticket: ticket, status: status)
        } catch {
            Log.warn("发送 typing 失败: \(error)")
        }
    }

    private func getOrFetchTypingTicket() async throws -> String {
        if let cached = typingTicket, Date().timeIntervalSince(cached.fetchedAt) < typingTTL {
            return cached.value
        }
        let ticket = try await client.getTypingTicket(userID: userID, contextToken: contextToken)
        typingTicket = TypingTicketCache(value: ticket, fetchedAt: Date())
        return ticket
    }

    // MARK: - 轮询循环

    private func pollLoop() async {
        var backoff: TimeInterval = 1
        let maxBackoff: TimeInterval = 30
        var cycle = 0

        while isRunning && !Task.isCancelled {
            cycle += 1

            let resp: GetUpdatesResp
            do {
                resp = try await client.getUpdates(buf: syncBuf, timeoutMs: config.longPollMS)
            } catch {
                if Task.isCancelled { break }
                Log.warn("长轮询失败: \(error) (\(Int(backoff))s 后重试)")
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                backoff = min(backoff * 2, maxBackoff)
                continue
            }
            backoff = 1
            if cycle % 5 == 0 { Log.debug("微信轮询第 \(cycle) 轮") }

            if resp.errcode == sessionExpiredErrcode {
                Log.warn("Session 过期，尝试重新验证…")
                do {
                    try await client.verifyToken()
                    syncBuf = ""
                    backoff = 1
                } catch {
                    Log.error("Session 刷新失败: \(error)")
                    try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                    backoff = min(backoff * 2, maxBackoff)
                }
                continue
            }
            backoff = 1

            if let buf = resp.getUpdatesBuf, !buf.isEmpty {
                syncBuf = buf
                persistSyncBuf()
            }

            guard let msgs = resp.msgs, let handler = handler else { continue }

            for msg in msgs {
                await handleMessage(msg, handler: handler)
            }
        }
    }

    private func handleMessage(_ m: WeChatMessage, handler: WeChatMessageHandler) async {
        // 过滤机器人消息和自己发出的消息
        guard let msgType = m.messageType, msgType == MessageType.user.rawValue || msgType == 0 else { return }
        guard let from = m.fromUserID?.trimmingCharacters(in: .whitespaces), !from.isEmpty else { return }

        // 单用户白名单：只认扫码注册的那一个
        guard from == config.allowFrom else {
            Log.warn("用户 \(from) 不是已注册用户，已忽略")
            return
        }

        // 去重
        let dk = "\(m.messageID ?? 0)|\(m.createTimeMs ?? 0)"
        let now = Date()
        dedup = dedup.filter { now.timeIntervalSince($0.value) < 300 } // 5 min 清理
        if dedup[dk] != nil { return }
        dedup[dk] = now

        // 保存 context_token
        if let tok = m.contextToken?.trimmingCharacters(in: .whitespaces), !tok.isEmpty {
            userID = from
            contextToken = tok
            persistState()
        }

        // 提取文本
        guard let body = extractText(m.itemList), !body.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        let msgID = m.messageID.map { "\($0)" } ?? randomHex(8)
        let incoming = IncomingMessage(
            fromUserID: from,
            content: body,
            contextToken: contextToken,
            messageID: msgID
        )
        await handler(incoming)
    }

    // MARK: - 持久化

    private func persistSyncBuf() {
        let path = dataDir + "/get_updates.buf"
        try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        try? syncBuf.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func persistState() {
        let path = dataDir + "/context_token.json"
        try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(SingleUserState(userID: userID, contextToken: contextToken)) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    nonisolated private func extractText(_ items: [MessageItem]?) -> String? {
        guard let items else { return nil }
        for item in items {
            if item.type == MessageItemType.text.rawValue, let t = item.textItem {
                return t.text
            }
            if item.type == MessageItemType.voice.rawValue, let v = item.voiceItem, !v.text.isEmpty {
                return "[语音] " + v.text
            }
        }
        return nil
    }
}

// MARK: - 辅助类型

private struct SingleUserState: Codable, Sendable {
    let userID: String
    let contextToken: String
}

struct TypingTicketCache: Sendable {
    let value: String
    let fetchedAt: Date
}

func splitRunes(_ s: String, max: Int) -> [String] {
    guard max > 0, s.count > max else { return [s] }
    return stride(from: 0, to: s.count, by: max).map {
        let start = s.index(s.startIndex, offsetBy: $0)
        let end = s.index(start, offsetBy: min(max, s.count - $0))
        return String(s[start..<end])
    }
}


