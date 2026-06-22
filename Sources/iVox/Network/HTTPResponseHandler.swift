import Foundation
import Network

/// HTTP 响应处理工具类
enum HTTPResponseHandler {

    private enum StatusCode: Int {
        case ok = 200
        case badRequest = 400
        case notFound = 404

        nonisolated var text: String {
            switch self {
            case .ok: return "OK"
            case .badRequest: return "Bad Request"
            case .notFound: return "Not Found"
            }
        }
    }

    /// 发送文本 HTTP 响应
    nonisolated static func sendResponse(
        _ connection: NWConnection,
        code: Int,
        body: String,
        contentType: String = "text/plain"
    ) {
        let sc = StatusCode(rawValue: code) ?? .ok
        let response = "HTTP/1.1 \(code) \(sc.text)\r\n"
            + "Content-Type: \(contentType); charset=UTF-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\n\r\n"
            + body
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// 发送二进制数据响应
    nonisolated static func sendDataResponse(
        _ connection: NWConnection,
        code: Int,
        data: Data,
        contentType: String
    ) {
        let sc = StatusCode(rawValue: code) ?? .ok
        let header = "HTTP/1.1 \(code) \(sc.text)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(data.count)\r\n"
            + "Connection: close\r\n\r\n"
        var responseData = header.data(using: .utf8)!
        responseData.append(data)
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    nonisolated static func sendHTML(_ connection: NWConnection, _ html: String) {
        sendResponse(connection, code: 200, body: html, contentType: "text/html")
    }

    nonisolated static func sendJSON(_ connection: NWConnection, _ json: String) {
        sendResponse(connection, code: 200, body: json, contentType: "application/json")
    }

    nonisolated static func sendBadRequest(_ connection: NWConnection, message: String = "Bad Request") {
        sendResponse(connection, code: 400, body: message)
    }

    nonisolated static func sendNotFound(_ connection: NWConnection, message: String = "Not Found") {
        sendResponse(connection, code: 404, body: message)
    }

    /// 构建 JSON 响应字符串
    nonisolated static func buildJSONResponse(
        status: String,
        error: String? = nil,
        additionalData: [String: Any]? = nil
    ) -> String {
        var dict: [String: Any] = ["status": status]
        if let error { dict["error"] = error }
        if let additionalData { dict.merge(additionalData) { $1 } }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let str = String(data: data, encoding: .utf8)
        else { return "{\"status\":\"error\"}" }
        return str
    }
}
