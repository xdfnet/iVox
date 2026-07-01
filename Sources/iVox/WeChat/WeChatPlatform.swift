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

    // 状态持久化
    private var dataDir: String
    private var syncBuf = ""
    private var tokens: [String: String] = [:]
    private var dedup: [String: Date] = [:]

    // Typing
    private var typingTickets: [String: TypingTicketCache] = [:]
    private let typingTTL: TimeInterval = 600 // 10 min

    init(config: WeChatConfig) {
        self.config = config
        self.client = WeChatClient(baseURL: config.baseURL, token: config.token)
        let dir = config.dataDir.isEmpty
            ? NSString(string: "~/.config/ivox").expandingTildeInPath + "/wechat"
            : config.dataDir + "/wechat"
        self.dataDir = dir
        // 在 init 中直接加载状态（不能调 actor-isolated 方法）
        let fm = FileManager.default
        if let data = try? Data(contentsOf: URL(fileURLWithPath: dir + "/get_updates.buf")),
           let buf = String(data: data, encoding: .utf8) {
            self.syncBuf = buf
        }
        if let data = try? Data(contentsOf: URL(fileURLWithPath: dir + "/context_tokens.json")),
           let tokens = try? JSONDecoder().decode([String: String].self, from: data) {
            self.tokens = tokens
        }
    }

    // MARK: - 生命周期

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

    func sendMessage(to userID: String, text: String) async throws {
        guard let token = tokens[userID] else {
            throw WeChatError.unknown("没有找到用户 \(userID) 的 context_token")
        }
        try await sendMessageChunked(to: userID, text: text, contextToken: token)
    }

    private func sendMessageChunked(to userID: String, text: String, contextToken: String) async throws {
        let maxChunk = 3800
        let chunks = splitRunes(text, max: maxChunk)
        for (i, chunk) in chunks.enumerated() {
            if i > 0 { try await Task.sleep(nanoseconds: 100_000_000) }
            let cid = "ivox-" + randomHex(6)
            try await client.sendText(to: userID, text: chunk, contextToken: contextToken, clientID: cid)
        }
    }

    // MARK: - Typing 指示器

    func startTyping(userID: String) async -> Task<Void, Never>? {
        guard let token = tokens[userID] else { return nil }
        let ticket: String
        do {
            ticket = try await getOrFetchTypingTicket(userID: userID, contextToken: token)
        } catch {
            Log.warn("获取 typing_ticket 失败: \(error)")
            return nil
        }

        return Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.sendTyping(userID: userID, ticket: ticket, status: .start)
            } catch {
                Log.warn("发送输入状态失败: \(error)")
                return
            }
            // 每 5s 刷新一次
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { break }
                do {
                    try await self.client.sendTyping(userID: userID, ticket: ticket, status: .start)
                } catch {
                    Log.warn("刷新输入状态失败: \(error)")
                    break
                }
            }
            // 停止
            try? await self.client.sendTyping(userID: userID, ticket: ticket, status: .stop)
        }
    }

    private func getOrFetchTypingTicket(userID: String, contextToken: String) async throws -> String {
        if let cached = typingTickets[userID], Date().timeIntervalSince(cached.fetchedAt) < typingTTL {
            return cached.value
        }
        let ticket = try await client.getTypingTicket(userID: userID, contextToken: contextToken)
        typingTickets[userID] = TypingTicketCache(value: ticket, fetchedAt: Date())
        return ticket
    }

    // MARK: - 轮询循环

    private func pollLoop() async {
        var backoff: TimeInterval = 1
        let maxBackoff: TimeInterval = 30

        while isRunning && !Task.isCancelled {
            if Task.isCancelled { break }

            let resp: GetUpdatesResp
            do {
                resp = try await client.getUpdates(buf: syncBuf, timeoutMs: config.longPollMS)
            } catch {
                if Task.isCancelled { break }
                if isNetworkError(error) || isTimeoutError(error) {
                    Log.warn("长轮询失败: \(error) (\(Int(backoff))s 后重试)")
                }
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                backoff = min(backoff * 2, maxBackoff)
                continue
            }
            backoff = 1

            if resp.errcode == sessionExpiredErrcode {
                Log.warn("会话过期，\(Int(backoff))s 后重试")
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                backoff = min(backoff * 2, maxBackoff)
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

        // Allow list 过滤
        guard isAllowed(from) else {
            Log.warn("用户 \(from) 不在 allow_from 列表中，已忽略")
            return
        }

        // 去重
        let dk = "\(from)|\(m.messageID ?? 0)|\(m.createTimeMs ?? 0)"
        let now = Date()
        dedup = dedup.filter { now.timeIntervalSince($0.value) < 300 } // 5 min 清理
        if dedup[dk] != nil { return }
        dedup[dk] = now

        // 保存 context_token
        if let tok = m.contextToken?.trimmingCharacters(in: .whitespaces), !tok.isEmpty {
            tokens[from] = tok
            persistTokens()
        }

        // 提取文本
        guard let body = extractText(m.itemList), !body.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        let msgID = m.messageID.map { "\($0)" } ?? randomHex(8)
        let incoming = IncomingMessage(
            fromUserID: from,
            content: body,
            contextToken: m.contextToken?.trimmingCharacters(in: .whitespaces) ?? "",
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

    private func persistTokens() {
        let path = dataDir + "/context_tokens.json"
        try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(tokens) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: - 工具

    private func isAllowed(_ userID: String) -> Bool {
        let allow = config.allowFrom.trimmingCharacters(in: .whitespaces)
        if allow.isEmpty || allow == "*" { return true }
        return allow.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == userID }
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

func isNetworkError(_ error: Error) -> Bool {
    let ns = error as NSError
    return ns.domain == NSURLErrorDomain
}

func isTimeoutError(_ error: Error) -> Bool {
    let ns = error as NSError
    return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorTimedOut
}
