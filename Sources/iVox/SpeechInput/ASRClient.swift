import Foundation
@preconcurrency import MLX
import MLXAudioCore
import MLXAudioSTT
import iVoxKit

actor ASREngine {
    private var model: Qwen3ASRModel?
    private let modelPath: String

    var isLoaded: Bool { model != nil }

    init(modelPath: String) {
        self.modelPath = modelPath
    }

    func load() async throws {
        let url = URL(fileURLWithPath: NSString(string: modelPath).expandingTildeInPath)
        let m = try await Qwen3ASRModel.fromModelDirectory(url)
        model = m
        Log.info("ASR 模型已加载")
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
        guard let m = model else { throw ASRError.notLoaded }

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
}
