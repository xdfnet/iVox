import Foundation
import iVoxKit

// MARK: - 常驻 Claude Agent 桥（node sidecar）

actor ClaudeAskService {
    private let workDir: String
    private let bridgeDir: String
    private let bridgeScript: String
    private let timeoutSeconds: Int

    private let proc: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe

    private var nextID = 0
    private var pending: [String: CheckedContinuation<String, Error>] = [:]
    private var stdoutBuffer = Data()

    init(dataDir: String, claudePath _: String = "", timeoutSeconds: Int = 120) {
        self.workDir = dataDir + "/workspace"
        self.bridgeDir = NSString(string: "~/.config/ivox/bridge").expandingTildeInPath
        self.bridgeScript = bridgeDir + "/bridge.messenger.mjs"
        self.timeoutSeconds = timeoutSeconds

        try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)

        proc = Process()
        proc.executableURL = URL(fileURLWithPath: Self.resolveNode())
        proc.arguments = [bridgeScript]
        proc.currentDirectoryURL = URL(fileURLWithPath: bridgeDir)

        var env = ProcessInfo.processInfo.environment
        env["ANTHROPIC_MODEL"] = env["ANTHROPIC_MODEL"] ?? "doubao-seed-2.0-mini"
        env["CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT"] = "1"
        proc.environment = env

        stdinPipe = Pipe()
        stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = Pipe()

        Self.installStdoutReader(on: stdoutPipe.fileHandleForReading) { [weak self] chunk in
            Task { await self?.consume(chunk: chunk) }
        }
        try? proc.run()
        Log.info("Claude 桥已启动: \(Self.resolveNode()) \(bridgeScript)")
    }

    // MARK: - 公开接口

    /// 向常驻 agent 提问，返回本轮回复文本
    func ask(text: String) async throws -> String {
        let id = String(format: "%08x", consumeID())
        let req = ["id": id, "text": text, "cwd": workDir]
        guard let line = try? JSONEncoder().encode(req) else {
            throw WeChatError.unknown("请求编码失败")
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            stdinPipe.fileHandleForWriting.write(line)
            stdinPipe.fileHandleForWriting.write(Data("\n".utf8))
            armTimeout(id: id)
        }
    }

    /// 停止桥：关 stdin，等待退出，超时强杀
    func stop() async {
        stdinPipe.fileHandleForWriting.closeFile()
        for _ in 0..<60 where proc.isRunning {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if proc.isRunning { proc.terminate() }
        failAllPending(WeChatError.unknown("桥已停止"))
        Log.info("Claude 桥已停止")
    }

    // MARK: - 内部

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
        cont.resume(with: result)
    }

    private func failAllPending(_ error: Error) {
        for (_, cont) in pending { cont.resume(throwing: error) }
        pending.removeAll()
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
            guard !lineData.isEmpty,
                  let evt = try? JSONDecoder().decode(BridgeEvent.self, from: lineData) else { continue }
            handleEvent(evt)
        }
    }

    private func handleEvent(_ e: BridgeEvent) {
        switch e.type {
        case "done":
            resolve(id: e.id, result: .success(e.text ?? ""))
        case "error":
            resolve(id: e.id, result: .failure(WeChatError.unknown(e.message ?? "桥错误")))
        default:
            break
        }
    }

    private nonisolated static func resolveNode() -> String {
        let candidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["which", "node"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? "/opt/homebrew/bin/node" : out
    }
}

// MARK: - 桥事件模型

private struct BridgeEvent: Codable, Sendable {
    let id: String
    let type: String
    let text: String?
    let message: String?
    let sessionID: String?

    enum CodingKeys: String, CodingKey {
        case id, type, text, message
        case sessionID = "session_id"
    }
}
