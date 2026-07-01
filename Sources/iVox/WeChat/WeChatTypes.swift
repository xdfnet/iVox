import Foundation

// MARK: - 常量

let kChannelVersion = "ivox-weixin/1.0"

enum MessageType: Int {
    case user = 1
    case bot   = 2
}

enum MessageItemType: Int {
    case text  = 1
    case voice = 3
}

let messageStateFinish = 2
let sessionExpiredErrcode = -14

enum TypingStatus: Int {
    case start = 1
    case stop  = 2
}

// MARK: - 请求/响应

struct BaseInfo: Codable, Sendable {
    var channelVersion: String

    enum CodingKeys: String, CodingKey {
        case channelVersion = "channel_version"
    }

    static let `default` = BaseInfo(channelVersion: kChannelVersion)
}

struct GetUpdatesReq: Codable, Sendable {
    let getUpdatesBuf: String
    let baseInfo: BaseInfo

    enum CodingKeys: String, CodingKey {
        case getUpdatesBuf = "get_updates_buf"
        case baseInfo = "base_info"
    }
}

struct GetUpdatesResp: Codable, Sendable {
    let ret: Int?
    let errcode: Int?
    let errmsg: String?
    let msgs: [WeChatMessage]?
    let getUpdatesBuf: String?
    let longpollingTimeoutMs: Int?

    enum CodingKeys: String, CodingKey {
        case ret
        case errcode
        case errmsg
        case msgs
        case getUpdatesBuf = "get_updates_buf"
        case longpollingTimeoutMs = "longpolling_timeout_ms"
    }
}

struct SendMessageReq: Codable, Sendable {
    let msg: WeChatOutboundMsg
    let baseInfo: BaseInfo

    enum CodingKeys: String, CodingKey {
        case msg
        case baseInfo = "base_info"
    }
}

struct SendMessageResp: Codable, Sendable {
    let ret: Int
    let errcode: Int?
    let errmsg: String?
}

struct GetConfigReq: Codable, Sendable {
    let ilinkUserID: String
    let contextToken: String?
    let baseInfo: BaseInfo

    enum CodingKeys: String, CodingKey {
        case ilinkUserID = "ilink_user_id"
        case contextToken = "context_token"
        case baseInfo = "base_info"
    }
}

struct GetConfigResp: Codable, Sendable {
    let ret: Int
    let errcode: Int?
    let errmsg: String?
    let typingTicket: String?

    enum CodingKeys: String, CodingKey {
        case ret
        case errcode
        case errmsg
        case typingTicket = "typing_ticket"
    }
}

struct SendTypingReq: Codable, Sendable {
    let ilinkUserID: String
    let typingTicket: String
    let status: Int
    let baseInfo: BaseInfo

    enum CodingKeys: String, CodingKey {
        case ilinkUserID = "ilink_user_id"
        case typingTicket = "typing_ticket"
        case status
        case baseInfo = "base_info"
    }
}

// MARK: - 消息体

struct WeChatMessage: Codable, Sendable {
    let seq: Int64?
    let messageID: Int64?
    let fromUserID: String?
    let toUserID: String?
    let clientID: String?
    let createTimeMs: Int64?
    let sessionID: String?
    let messageType: Int?
    let messageState: Int?
    let itemList: [MessageItem]?
    let contextToken: String?

    enum CodingKeys: String, CodingKey {
        case seq
        case messageID = "message_id"
        case fromUserID = "from_user_id"
        case toUserID = "to_user_id"
        case clientID = "client_id"
        case createTimeMs = "create_time_ms"
        case sessionID = "session_id"
        case messageType = "message_type"
        case messageState = "message_state"
        case itemList = "item_list"
        case contextToken = "context_token"
    }
}

struct WeChatOutboundMsg: Codable, Sendable {
    let fromUserID: String
    let toUserID: String
    let clientID: String
    let messageType: Int
    let messageState: Int
    let itemList: [MessageItem]?
    let contextToken: String?

    enum CodingKeys: String, CodingKey {
        case fromUserID = "from_user_id"
        case toUserID = "to_user_id"
        case clientID = "client_id"
        case messageType = "message_type"
        case messageState = "message_state"
        case itemList = "item_list"
        case contextToken = "context_token"
    }
}

struct MessageItem: Codable, Sendable {
    let type: Int
    let textItem: TextItem?
    let voiceItem: VoiceItem?

    enum CodingKeys: String, CodingKey {
        case type
        case textItem = "text_item"
        case voiceItem = "voice_item"
    }
}

struct TextItem: Codable, Sendable {
    let text: String
}

struct VoiceItem: Codable, Sendable {
    let text: String
}

// MARK: - 统一入站消息

struct IncomingMessage: Sendable {
    let fromUserID: String
    let content: String
    let contextToken: String
    let messageID: String
}

// MARK: - 扫码登录

struct BotQRResponse: Codable, Sendable {
    let qrcode: String
    let qrcodeImgContent: String

    enum CodingKeys: String, CodingKey {
        case qrcode
        case qrcodeImgContent = "qrcode_img_content"
    }
}

struct QRStatusResponse: Codable, Sendable {
    let status: String?
    let botToken: String?
    let ilinkBotID: String?
    let baseurl: String?
    let ilinkUserID: String?

    enum CodingKeys: String, CodingKey {
        case status
        case botToken = "bot_token"
        case ilinkBotID = "ilink_bot_id"
        case baseurl
        case ilinkUserID = "ilink_user_id"
    }
}
