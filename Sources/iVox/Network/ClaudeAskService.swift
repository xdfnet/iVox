import Foundation
import iVoxKit

// MARK: - 原生 Claude Agent（Swift 直连 claude，stdio NDJSON）

actor ClaudeAskService {
    private let dataDir: String
    private let workDir: String
    private let stateFile: String
    private let claudePath: String
    private let model: String
    private let timeoutSeconds: Int

    private var proc: Process?
    private var stdinPipe: Pipe?
    private var sessionID = ""

    private var nextID = 0
    private var pending: [String: CheckedContinuation<String, Error>] = [:]
    private var waitOrder: [String] = []   // FIFO：result 按发送顺序匹配
    private var stdoutBuffer = Data()

    init(dataDir: String, claudePath: String = "", timeoutSeconds: Int = 120) {
        self.dataDir = dataDir
        self.workDir = dataDir + "/workspace"
        self.stateFile = dataDir + "/bridge_state.json"
        self.claudePath = NSString(string: claudePath.isEmpty ? "~/.local/bin/claude" : claudePath).expandingTildeInPath
        self.timeoutSeconds = timeoutSeconds

        let env = ProcessInfo.processInfo.environment
        self.model = env["ANTHROPIC_MODEL"] ?? "doubao-seed-2.0-mini"

        try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        self.sessionID = Self.readSessionID(stateFile: stateFile)
    }

    // MARK: - 公开接口

    /// 向常驻 agent 提问，返回本轮回复文本
    func ask(text: String) async throws -> String {
        // /new：重置会话，不发给模型
        if text.trimmingCharacters(in: .whitespaces) == "/new" {
            await terminateProc()
            sessionID = ""
            saveState()
            return "已开启新会话"
        }

        try ensureProcess()
        let id = String(format: "%08x", consumeID())
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            waitOrder.append(id)
            let wrapped = ClaudeInput(type: "user", message: .init(role: "user", content: text))
            if let line = try? JSONEncoder().encode(wrapped) {
                stdinPipe?.fileHandleForWriting.write(line)
                stdinPipe?.fileHandleForWriting.write(Data("\n".utf8))
            }
            armTimeout(id: id)
        }
    }

    /// 停止：关 stdin，等待退出，超时强杀
    func stop() async {
        stdinPipe?.fileHandleForWriting.closeFile()
        if let proc {
            for _ in 0..<60 where proc.isRunning {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if proc.isRunning { proc.terminate() }
        }
        failAllPending(WeChatError.unknown("agent 已停止"))
        Log.info("Claude agent 已停止")
    }

    // MARK: - 进程管理

    private func ensureProcess() throws {
        guard proc == nil || proc?.isRunning != true else { return }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.resolveClaude(preferred: claudePath))
        var args = [
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--dangerously-skip-permissions",
            "--model", model,
        ]
        if !sessionID.isEmpty { args += ["--resume", sessionID] }
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: workDir)
        p.environment = ProcessInfo.processInfo.environment

        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = Pipe()
        Self.installStdoutReader(on: outPipe.fileHandleForReading) { [weak self] chunk in
            Task { await self?.consume(chunk: chunk) }
        }

        try p.run()
        proc = p
        stdinPipe = inPipe
        Log.info("Claude agent 已启动: \(p.executableURL?.path ?? "")（resume: \(sessionID.isEmpty ? "否" : sessionID)）")
    }

    private func terminateProc() async {
        proc?.terminate()
        if let proc {
            for _ in 0..<40 where proc.isRunning {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        proc = nil
        stdinPipe = nil
        failAllPending(WeChatError.unknown("会话已被 /new 重置"))
    }

    // MARK: - 结果分发

    private func consumeID() -> Int {
        nextID += 1
        return nextID
    }

    private func armTimeout(id: String) {
        let seconds = timeoutSeconds
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            await self?.resolve(id: id, result: .failure(WeChatError.unknown("等待回复超时 (\(seconds)s)")))
        }
    }

    private func resolve(id: String, result: Result<String, Error>) {
        guard let cont = pending.removeValue(forKey: id) else { return }
        waitOrder.removeAll { $0 == id }
        cont.resume(with: result)
    }

    private func failAllPending(_ error: Error) {
        for (_, cont) in pending { cont.resume(throwing: error) }
        pending.removeAll()
        waitOrder.removeAll()
    }

    // MARK: - stdout 解析

    private nonisolated static func installStdoutReader(
        on handle: FileHandle,
        onChunk: @escaping @Sendable (Data) -> Void
    ) {
        handle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            onChunk(chunk)
        }
    }

    private func consume(chunk: Data) {
        stdoutBuffer.append(chunk)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.subdata(in: 0..<nl)
            stdoutBuffer.removeSubrange(0...nl)
            guard !lineData.isEmpty,
                  let o = try? JSONDecoder().decode(ClaudeOutput.self, from: lineData) else { continue }
            guard o.type == "result" else { continue }

            if let sid = o.sessionID, !sid.isEmpty {
                sessionID = sid
                saveState()
            }
            // result 按 FIFO 匹配当前最早等待者（单 agent 串行，无 user 路由）
            guard let id = waitOrder.first(where: { pending[$0] != nil }) else { continue }
            waitOrder.removeAll { $0 == id }
            if o.isError == true {
                resolve(id: id, result: .failure(WeChatError.unknown(o.resultText ?? "agent 执行出错")))
            } else {
                resolve(id: id, result: .success(o.resultText ?? ""))
            }
        }
    }

    // MARK: - 状态持久化

    private nonisolated static func readSessionID(stateFile: String) -> String {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: stateFile)),
              let s = try? JSONDecoder().decode(StateFile.self, from: data) else { return "" }
        return s.sessionID ?? ""
    }

    private func saveState() {
        if let data = try? JSONEncoder().encode(StateFile(sessionID: sessionID.isEmpty ? nil : sessionID)) {
            try? data.write(to: URL(fileURLWithPath: stateFile))
        }
    }

    private nonisolated static func resolveClaude(preferred: String) -> String {
        let candidates = [preferred, "/Users/admin/.local/bin/claude", "/usr/local/bin/claude", "/opt/homebrew/bin/claude"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["which", "claude"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? "/Users/admin/.local/bin/claude" : out
    }
}

// MARK: - 消息模型

private struct ClaudeInput: Codable, Sendable {
    let type: String
    let message: Message
    struct Message: Codable, Sendable { let role: String; let content: String }
}

private struct ClaudeOutput: Codable, Sendable {
    let type: String
    let resultText: String?
    let sessionID: String?
    let isError: Bool?

    enum CodingKeys: String, CodingKey {
        case type
        case resultText = "result"
        case sessionID = "session_id"
        case isError = "is_error"
    }
}

private struct StateFile: Codable, Sendable {
    let sessionID: String?
    enum CodingKeys: String, CodingKey { case sessionID = "session_id" }
}
