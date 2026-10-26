import Foundation
import iVoxKit

// 常驻 claude 子进程（stdio NDJSON），微信桥的问答后端。
// MARK: - 原生 Claude Agent（Swift 直连 claude，stdio NDJSON）

actor ClaudeAskService {
    private let dataDir: String
    private let workDir: String
    private let stateFile: String
    private let claudePath: String
    private let timeoutSeconds: Int

    private var proc: Process?
    private var stdinPipe: Pipe?
    private var sessionID = ""

    private var nextID = 0
    private var pending: [String: CheckedContinuation<Void, Error>] = [:]
    private var waitOrder: [String] = []   // FIFO：result 按发送顺序匹配
    /// 每个在等结果的问题，额外挂一个「过程段」回调：assistant 帧到达时调用，把过程增量吐出去。
    /// 过程段即完整回复（含最后一条 assistant = 结尾），result 内容与之重复，故不再取 result 文本。
    private var pendingOnSegment: [String: @Sendable (String) -> Void] = [:]
    private var stdoutBuffer = Data()

    init(dataDir: String, claudePath: String = "", timeoutSeconds: Int = 120) {
        self.dataDir = dataDir
        self.workDir = dataDir + "/workspace"
        self.stateFile = dataDir + "/bridge_state.json"
        self.claudePath = NSString(string: claudePath.isEmpty ? "~/.local/bin/claude" : claudePath).expandingTildeInPath
        self.timeoutSeconds = timeoutSeconds

        // 不在这里配模型：claude 子进程自动继承环境/自身配置（~/.claude/settings.json 的 ANTHROPIC_MODEL）。
        // 曾在此硬编码 model 并 spawn 自带 --model——daemon 启动环境缺该变量会兜底错模型（doubao），
        // 且这个隐含覆盖点藏得深、极易被忘记（飞哥点名）。spawn 时不再传 --model，全走进程自身默认。
        try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        self.sessionID = Self.readSessionID(stateFile: stateFile)
    }

    // MARK: - 公开接口

    /// 提问并回调过程段，最后一条 assistant（含完整回复与结尾）通过 onSegment 送出后返回。
    /// 微信链路用：assistant 帧逐段回调（过程可见），不单独取 result（内容与之重复）。
    /// - Parameters:
    ///   - text: 发送给 agent 的用户消息
    ///   - onSegment: 每段 assistant 文本回调（含最后的完整结尾），@Sendable 可在任意队列调用
    func askStreaming(
        text: String,
        onSegment: @escaping @Sendable (String) -> Void
    ) async throws {
        if text.trimmingCharacters(in: .whitespaces) == "/new" {
            await terminateProc()
            sessionID = ""
            saveState()
            // 必须回一句：否则微信端「正在输入」闪一下就灭、之后石沉大海，
            // 用户无从判断这条命令到底生效没（2026-10-26 实测踩到）。
            onSegment("已开启新会话")
            return
        }
        try ensureProcess()
        let id = String(format: "%08x", consumeID())
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pending[id] = continuation
            pendingOnSegment[id] = onSegment
            waitOrder.append(id)
            let wrapped = ClaudeInput(type: "user", message: .init(role: "user", content: text))
            if let line = try? JSONEncoder().encode(wrapped) {
                stdinPipe?.fileHandleForWriting.write(line)
                stdinPipe?.fileHandleForWriting.write(Data("\n".utf8))
            } else {
                // 编码失败 = 请求压根没发出去。若还照常起超时表，微信那边「正在输入」
                // 会转满 300 秒才超时，日志里只剩超时那一句，看不出请求没发（2026-10-18 补）。
                Log.error("Claude 请求编码失败，放弃本轮 id=\(id)")
                pending[id] = nil
                pendingOnSegment[id] = nil
                continuation.resume()
                return
            }
            armTimeout(id: id)
        }
        // continuation 为 Void：结果完全经 onSegment 回调交付，resume 仅作「本轮结束」信号。
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
        ]
        if !sessionID.isEmpty { args += ["--resume", sessionID] }
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: workDir)
        p.environment = ProcessInfo.processInfo.environment

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        // stderr 必须有人读：管道写满（约 64KB）会让 claude 阻塞在写 stderr 上，
        // ask() 的 continuation 就永不完成，只能干等到超时。转进日志即可。
        p.standardError = errPipe
        Self.installStdoutReader(on: outPipe.fileHandleForReading) { [weak self] chunk in
            Task { await self?.consume(chunk: chunk) }
        }
        Self.installStderrReader(on: errPipe.fileHandleForReading)

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

    private func resolve(id: String, result: Result<Void, Error>) {
        guard let cont = pending.removeValue(forKey: id) else { return }
        waitOrder.removeAll { $0 == id }
        pendingOnSegment.removeValue(forKey: id)
        cont.resume(with: result)
    }

    private func failAllPending(_ error: Error) {
        for (_, cont) in pending { cont.resume(throwing: error) }
        pending.removeAll()
        waitOrder.removeAll()
        pendingOnSegment.removeAll()
    }

    // MARK: - stdout 解析

    /// stderr 不参与协议，只把管道读空并记进日志（截断），避免子进程写满阻塞。
    private nonisolated static func installStderrReader(on handle: FileHandle) {
        handle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            let text = String(data: chunk, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // 子进程 stderr 是「这条为什么没跑完」的第一手材料（鉴权失败、额度、参数错
            // 全在里面），藏 DEBUG 等于默认级别下完全查不到（2026-10-18 提为 warn）。
            if !text.isEmpty { Log.warn("claude stderr: \(text.prefix(500))") }
        }
    }

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
            guard !lineData.isEmpty else { continue }
            guard let o = try? JSONDecoder().decode(ClaudeOutput.self, from: lineData) else {
                // claude 一改输出格式，这里每帧都被静默跳过，请求一路走到超时，全程零线索——
                // 而这是外部依赖格式漂移的唯一探针位置（2026-10-18 补）。
                Log.error("claude 输出帧解析失败，已丢弃 \(lineData.count) 字节: \(lineData.prefix(200))")
                continue
            }

            // assistant 帧 = 一段完整回复文本 → 当过程段回调吐给最早等待者（最后一条 assistant 即完整结尾）。
            // result 内容与 assistant 重复，不单独取文本；assistant 帧不终结本轮（等 result 收尾）。
            if o.type == "assistant", let seg = o.assistantText, !seg.isEmpty {
                if let id = waitOrder.first(where: { pending[$0] != nil }) {
                    pendingOnSegment[id]?(seg)
                }
                continue
            }
            guard o.type == "result" else { continue }

            if let sid = o.sessionID, !sid.isEmpty {
                sessionID = sid
                saveState()
            }
            // result 只作「本轮结束」信号（内容与最后 assistant 重复，不另发）；不取文本、不去重。
            guard let id = waitOrder.first(where: { pending[$0] != nil }) else { continue }
            waitOrder.removeAll { $0 == id }
            pendingOnSegment.removeValue(forKey: id)   // 收尾，清掉过程回调
            if o.isError == true {
                resolve(id: id, result: .failure(WeChatError.unknown(o.resultText ?? "agent 执行出错")))
            } else {
                resolve(id: id, result: .success(()))
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
        let candidates = [preferred, "\(NSHomeDirectory())/.local/bin/claude", "/usr/local/bin/claude", "/opt/homebrew/bin/claude"]
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
        return out.isEmpty ? "\(NSHomeDirectory())/.local/bin/claude" : out
    }
}

// MARK: - 消息模型

private struct ClaudeInput: Codable, Sendable {
    let type: String
    let message: Message
    struct Message: Codable, Sendable { let role: String; let content: String }
}

private struct ClaudeOutput: Decodable, Sendable {
    let type: String
    let resultText: String?
    let sessionID: String?
    let isError: Bool?
    /// {type:assistant} 帧的文本——`message.content[]` 里各 `text` 块拼起来。
    /// 关键：assistant 是「整段回复文本」，不是逐字 delta（探针实测）。用于把过程段回传。
    let assistantText: String?

    enum CodingKeys: String, CodingKey {
        case type
        case resultText = "result"
        case sessionID = "session_id"
        case isError = "is_error"
        case assistantMessage = "message"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        resultText = try c.decodeIfPresent(String.self, forKey: .resultText)
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        isError = try c.decodeIfPresent(Bool.self, forKey: .isError)
        // assistant 帧的文本藏在 message.content[]（array，text 块）。非 assistant 帧没有 message 则留空。
        assistantText = try Self.extractAssistantText(from: c)
    }

    private static func extractAssistantText(from c: KeyedDecodingContainer<CodingKeys>) throws -> String? {
        struct ContentBlock: Decodable { let text: String? }
        struct Msg: Decodable { let content: [ContentBlock]? }
        guard let m = try? c.decodeIfPresent(Msg.self, forKey: .assistantMessage),
              let blocks = m.content else { return nil }
        let joined = blocks.compactMap { $0.text }.joined()
        return joined.isEmpty ? nil : joined
    }
}

private struct StateFile: Codable, Sendable {
    let sessionID: String?
    enum CodingKeys: String, CodingKey { case sessionID = "session_id" }
}
