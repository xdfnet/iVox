import Foundation
import iVoxKit

// MARK: - Claude CLI 调用服务

actor ClaudeAskService {
    private let sessionsFile: String
    private let claudePath: String
    private let timeoutSeconds: Int
    private var sessions: [String: String] = [:]  // userID -> sessionID
    private var pending: [String: Task<String, Error>] = [:]  // 并发控制

    init(dataDir: String, claudePath: String = "/usr/local/bin/claude", timeoutSeconds: Int = 120) {
        self.sessionsFile = dataDir + "/sessions.json"
        self.claudePath = claudePath
        self.timeoutSeconds = timeoutSeconds
        // 同步加载已有 sessions
        if FileManager.default.fileExists(atPath: sessionsFile),
           let data = try? Data(contentsOf: URL(fileURLWithPath: sessionsFile)),
           let loaded = try? JSONDecoder().decode([String: String].self, from: data) {
            self.sessions = loaded
        }
    }

    // MARK: - 公开接口

    /// 向 Claude 提问，返回回复文本
    func ask(userID: String, text: String) async throws -> String {
        // 并发控制：同一 userID 排队
        if let existing = pending[userID] {
            return try await existing.value
        }
        let task = Task { try await askInternal(userID: userID, text: text) }
        pending[userID] = task
        defer { pending.removeValue(forKey: userID) }
        return try await task.value
    }

    // MARK: - 内部

    private func askInternal(userID: String, text: String) async throws -> String {
        let sessionID = sessions[userID]
        let args: [String]
        let isNewSession: Bool

        if let sid = sessionID {
            // 继续已有 session
            args = ["--print", "--resume", sid, text]
            isNewSession = false
            Log.info("🤖 ask: claude --print --resume \(sid.prefix(8))… \(text.prefix(20))…")
        } else {
            // 首次创建 session
            let newSID = UUID().uuidString.lowercased()
            args = ["--print", "--session-id", newSID, text]
            sessions[newSID] = userID  // 反向映射方便后续查找
            isNewSession = true
            Log.info("🤖 ask: claude --print --session-id \(newSID.prefix(8))… (首次创建) \(text.prefix(20))…")
        }

        let output = try await runClaude(args: args)

        // 解析回复（去掉 stderr 的 model warnings）
        let response = extractResponse(from: output)

        // 如果是首次，保存 session 映射
        if isNewSession {
            // 确认 session 被创建了（输出包含 claude-code: 说明 claude 正常响应）
            if output.contains("[claude-code:") {
                if let sid = sessions.first(where: { $0.value == userID })?.key {
                    sessions[userID] = sid
                    try persistSessions()
                }
            }
        }

        return response
    }

    private func runClaude(args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: claudePath)
            proc.arguments = args
            proc.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())

            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe

            // 超时 timer
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                if proc.isRunning {
                    proc.terminate()
                    Log.warn("🤖 claude 调用超时 (\(timeoutSeconds)s)，已强制终止")
                }
            }

            do {
                try proc.run()
                proc.waitUntilExit()
                timeoutTask.cancel()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: output)
            } catch {
                timeoutTask.cancel()
                continuation.resume(throwing: error)
            }
        }
    }

    /// 从完整输出中提取纯回复文本（去掉 stderr 的 warnings）
    private func extractResponse(from output: String) -> String {
        var lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        // 去掉第一行（如果有 [claude-code:unrecognized_model] 等 warnings）
        if let first = lines.first, first.contains("[claude-code:") {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 持久化

    private func persistSessions() throws {
        let dir = (sessionsFile as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(sessions)
        try data.write(to: URL(fileURLWithPath: sessionsFile))
    }
}
