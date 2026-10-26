import Foundation
@preconcurrency import MLX
import MLXAudioCore
import MLXAudioSTT
import iVoxKit

// 本地语音识别引擎（Qwen3-ASR）。

actor ASREngine {
    private var model: Qwen3ASRModel?
    private let modelPath: String
    /// 正在进行的加载（并发调用共用同一次，别重复加载 2.5G 权重）
    private var loadTask: Task<Void, Error>?
    /// 空闲卸载的巡检任务
    private var idleTask: Task<Void, Never>?
    /// 最后一次用到模型的时间（加载与识别都算）
    private var lastUsedAt: Date?

    var isLoaded: Bool { model != nil }

    /// 空闲多久就卸载模型、把这块内存还回去。
    /// 10 分钟的取舍：偶尔说一句的体感是「随时能说」（加载在录音开始时就并行开始了），
    /// 而内存大部分时间是空的——模型权重 2.5G 常驻其实很奢侈。
    static let idleUnloadSeconds: TimeInterval = 600

    init(modelPath: String) {
        self.modelPath = modelPath
    }

    /// 确保模型可用（没有就加载）。**幂等且并发安全**：录音开始与识别都会调它，
    /// 两次同时来只加载一次。
    func ensureLoaded(language: String = "zh") async throws {
        lastUsedAt = Date()
        if model != nil { return }
        if let existing = loadTask {
            try await existing.value
            return
        }
        let task = Task { try await self.loadModel() }
        loadTask = task
        do {
            try await task.value
            loadTask = nil
            startIdleWatcher()
            await warmup(language: language)
        } catch {
            loadTask = nil
            throw error
        }
    }

    private func loadModel() async throws {
        let url = URL(fileURLWithPath: NSString(string: modelPath).expandingTildeInPath)
        let started = Date()
        let m = try await Qwen3ASRModel.fromModelDirectory(url)
        model = m
        Log.info("ASR 模型已加载（耗时 \(String(format: "%.1f", Date().timeIntervalSince(started))) 秒）")
    }

    /// 用静音音频预热 ASR 模型，初始化 MLX 算子和 KV cache
    func warmup(language: String = "zh") async {
        guard let m = model else { return }
        let sampleRate = 16000
        let duration = 0.5 // seconds of silence
        let numSamples = sampleRate * Int(duration)
        let silence = MLXArray([Float](repeating: 0.0, count: numSamples))

        var params = m.defaultGenerationParameters
        params = STTGenerateParameters(
            maxTokens: params.maxTokens,
            temperature: params.temperature,
            topP: params.topP,
            topK: params.topK,
            verbose: params.verbose,
            language: language,
            chunkDuration: params.chunkDuration,
            minChunkDuration: params.minChunkDuration,
            repetitionPenalty: params.repetitionPenalty,
            repetitionContextSize: params.repetitionContextSize
        )

        Log.debug("ASR 预热中...")
        _ = m.generate(audio: silence, generationParameters: params)
        Log.debug("ASR 预热完成")
    }

    func transcribe(audioData: Data, language: String) async throws -> String {
        guard !language.isEmpty, language.allSatisfy(\.isLetter) else {
            throw ASRError.invalidLanguage(language)
        }
        // 模型可能刚被空闲卸载（或这次是进程启动后第一次识别）——就地加载，不报错。
        try await ensureLoaded(language: language)
        guard let m = model else { throw ASRError.notLoaded }
        lastUsedAt = Date()

        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent("ivox_asr_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try audioData.write(to: tempURL)

        let (_, audio) = try loadAudioArray(from: tempURL, sampleRate: 16000)
        let mono = audio.ndim > 1 ? audio.mean(axis: -1) : audio

        var params = m.defaultGenerationParameters
        params = STTGenerateParameters(
            maxTokens: params.maxTokens,
            temperature: params.temperature,
            topP: params.topP,
            topK: params.topK,
            verbose: params.verbose,
            language: language,
            chunkDuration: params.chunkDuration,
            minChunkDuration: params.minChunkDuration,
            repetitionPenalty: params.repetitionPenalty,
            repetitionContextSize: params.repetitionContextSize
        )

        let output = m.generate(audio: mono, generationParameters: params)
        return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum ASRError: Error {
        case notLoaded
        case invalidLanguage(String)
    }

    // MARK: - 空闲卸载

    /// 巡检：每分钟看一眼，多久没人用了就把模型卸掉、把内存还回去。
    /// 卸载后下一次识别会自己重新加载（见 `ensureLoaded`），用户只多等模型就绪那几秒。
    private func startIdleWatcher() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                if await self.unloadIfIdle() { return }
            }
        }
    }

    /// 空闲超阈值就卸载模型。**正在加载**或**刚用过**都不卸。
    /// - Returns: 是否真的卸了（卸了这条巡检就结束，下次加载会重新起一条）
    private func unloadIfIdle() -> Bool {
        guard model != nil, loadTask == nil else { return false }
        let idle = Date().timeIntervalSince(lastUsedAt ?? .distantPast)
        guard idle >= Self.idleUnloadSeconds else { return false }
        model = nil
        // MLX 自己有一层缓冲缓存：不清，权重虽然没人引用了，内存还压在进程里不放。
        MLX.Memory.clearCache()
        Log.info("ASR 模型空闲 \(Int(idle)) 秒，已卸载（释放内存）")
        return true
    }
}
