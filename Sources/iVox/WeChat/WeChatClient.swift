import Foundation

// MARK: - iW 微信 ilink HTTP API 客户端

actor WeChatClient {
    let baseURL: String
    let token: String
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(baseURL: String = "https://ilinkai.weixin.qq.com", token: String) {
        var url = baseURL
        if !url.hasSuffix("/") { url += "/" }
        self.baseURL = url
        self.token = token
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - API 调用

    /// 长轮询获取新消息
    func getUpdates(buf: String, timeoutMs: Int) async throws -> GetUpdatesResp {
        let timeout = timeoutMs > 0 ? Double(timeoutMs) / 1000.0 : 35.0
        let req = GetUpdatesReq(getUpdatesBuf: buf, baseInfo: .default)
        let data = try await post("ilink/bot/getupdates", body: req, timeout: timeout + 5)
        let resp = try decoder.decode(GetUpdatesResp.self, from: data)
        return resp
    }

    /// 发送文本消息
    func sendText(to: String, text: String, contextToken: String?, clientID: String?) async throws {
        let cid = clientID ?? "ivox-" + randomHex(6)
        let items = [MessageItem(type: MessageItemType.text.rawValue,
                                  textItem: TextItem(text: text),
                                  voiceItem: nil)]
        let msg = WeChatOutboundMsg(
            fromUserID: "", toUserID: to, clientID: cid,
            messageType: MessageType.bot.rawValue,
            messageState: messageStateFinish,
            itemList: items, contextToken: contextToken
        )
        let data = try await post("ilink/bot/sendmessage", body: SendMessageReq(msg: msg, baseInfo: .default))
        if data.isEmpty { return }
        let resp = try decoder.decode(SendMessageResp.self, from: data)
        if resp.ret != 0 {
            throw WeChatError.sendFailed(ret: resp.ret, errcode: resp.errcode ?? 0, errmsg: resp.errmsg ?? "")
        }
    }

    /// 获取 typing_ticket
    func getTypingTicket(userID: String, contextToken: String) async throws -> String {
        let req = GetConfigReq(ilinkUserID: userID, contextToken: contextToken, baseInfo: .default)
        let data = try await post("ilink/bot/getconfig", body: req)
        let resp = try decoder.decode(GetConfigResp.self, from: data)
        guard resp.ret == 0, resp.errcode == nil || resp.errcode == 0 else {
            throw WeChatError.configFailed(ret: resp.ret, errcode: resp.errcode ?? 0, errmsg: resp.errmsg ?? "")
        }
        guard let ticket = resp.typingTicket, !ticket.isEmpty else {
            throw WeChatError.missingTypingTicket
        }
        return ticket
    }

    /// 发送输入状态
    func sendTyping(userID: String, ticket: String, status: TypingStatus) async throws {
        let req = SendTypingReq(ilinkUserID: userID, typingTicket: ticket, status: status.rawValue, baseInfo: .default)
        let data = try await post("ilink/bot/sendtyping", body: req)
        if data.isEmpty { return }
        let resp = try decoder.decode(SendMessageResp.self, from: data)
        if resp.ret != 0 {
            throw WeChatError.typingFailed(ret: resp.ret, errcode: resp.errcode ?? 0, errmsg: resp.errmsg ?? "")
        }
    }

    // MARK: - 扫码登录

    func getBotQRCode(botType: String = "3") async throws -> BotQRResponse {
        let url = baseURL + "ilink/bot/get_bot_qrcode?bot_type=" + botType
        var req = URLRequest(url: URL(string: url)!)
        req.timeoutInterval = 15
        let (data, _) = try await session.data(for: req)
        return try decoder.decode(BotQRResponse.self, from: data)
    }

    func pollQRStatus(qrKey: String) async throws -> QRStatusResponse {
        let url = baseURL + "ilink/bot/get_qrcode_status?qrcode=" + qrKey
        var req = URLRequest(url: URL(string: url)!)
        req.timeoutInterval = 40
        req.setValue("1", forHTTPHeaderField: "iLink-App-ClientVersion")
        let (data, _) = try await session.data(for: req)
        return try decoder.decode(QRStatusResponse.self, from: data)
    }

    func verifyToken() async throws {
        let body = "{\"get_updates_buf\":\"\",\"base_info\":{\"channel_version\":\"ivox-verify/1.0\"}}"
        var req = URLRequest(url: URL(string: baseURL + "ilink/bot/getupdates")!)
        req.httpMethod = "POST"
        req.httpBody = body.data(using: .utf8)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&req)
        req.setValue(randomWechatUIN(), forHTTPHeaderField: "X-WECHAT-UIN")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw WeChatError.verifyFailed
        }
        _ = data // 不解析，能拿到 200 就算通过
    }

    // MARK: - HTTP 内部

    private func post(_ endpoint: String, body: some Codable, timeout: Double? = nil) async throws -> Data {
        let url = baseURL + endpoint
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.httpBody = try JSONEncoder().encode(body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&req)
        req.setValue(randomWechatUIN(), forHTTPHeaderField: "X-WECHAT-UIN")
        if let timeout { req.timeoutInterval = timeout }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw WeChatError.network("非 HTTP 响应")
        }
        guard http.statusCode == 200 else {
            throw WeChatError.httpStatus(http.statusCode)
        }
        return data
    }

    private nonisolated func applyAuth(_ req: inout URLRequest) {
        req.setValue("ilink_bot_token", forHTTPHeaderField: "AuthorizationType")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
}

// MARK: - 错误

enum WeChatError: Error, LocalizedError {
    case sendFailed(ret: Int, errcode: Int, errmsg: String)
    case configFailed(ret: Int, errcode: Int, errmsg: String)
    case typingFailed(ret: Int, errcode: Int, errmsg: String)
    case missingTypingTicket
    case verifyFailed
    case network(String)
    case httpStatus(Int)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .sendFailed(let r, let c, let m): return "发送失败: ret=\(r) errcode=\(c) \(m)"
        case .configFailed(let r, let c, let m): return "配置获取失败: ret=\(r) errcode=\(c) \(m)"
        case .typingFailed(let r, let c, let m): return "输入状态失败: ret=\(r) errcode=\(c) \(m)"
        case .missingTypingTicket: return "无法获取 typing_ticket"
        case .verifyFailed: return "Token 验证失败"
        case .network(let s): return "网络错误: \(s)"
        case .httpStatus(let c): return "HTTP \(c)"
        case .unknown(let s): return s
        }
    }
}

// MARK: - 工具函数

func randomHex(_ n: Int) -> String {
    let bytes = (0..<n).map { _ in UInt8.random(in: 0...255) }
    return Data(bytes).map { String(format: "%02x", $0) }.joined()
}

func randomWechatUIN() -> String {
    let num = UInt32.random(in: 0..<UInt32.max)
    return Data("\(num)".utf8).base64EncodedString()
}
