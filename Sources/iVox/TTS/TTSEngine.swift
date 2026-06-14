import Foundation
@preconcurrency import MLX
import MLXAudioCore
import MLXAudioTTS
import iVoxKit

actor TTSEngine {
    enum LoadState: Sendable {
        case notStarted
        case loading
        case ready
        case failed(String)
    }

    private var model: (any SpeechGenerationModel)?
    private var config: Config
    private let ttsConfig: TTSConfig
    private var loadState: LoadState = .notStarted

    init(config: Config) {
        self.config = config
        self.ttsConfig = config.resolvedTTS
    }

    var isLoaded: Bool { model != nil }
    var state: LoadState { loadState }

    func loadModel() async throws {
        if model != nil { return }
        loadState = .loading
        let modelPath = expandPath(config.models?.ttsPath ?? "~/.config/ivox/model/Qwen3-TTS-12Hz-1.7B-Base-8bit")
        Log.info("加载 TTS 模型: \(modelPath)")
        do {
            model = try await TTS.loadModel(modelRepo: modelPath)
            loadState = .ready
            Log.info("TTS 模型加载完成")
        } catch {
            loadState = .failed(String(describing: error))
            throw error
        }
    }

    func warmup(voiceID: String) async {
        do {
            Log.info("TTS 预热 [\(voiceID)]...")
            let stream = synthesizeStream(text: "你好，模型预热完成。", voiceID: voiceID)
            for try await _ in stream { }
            Log.info("TTS 预热完成 [\(voiceID)]")
        } catch {
            Log.info("TTS 预热跳过 [\(voiceID)]: \(error)")
        }
    }

    func synthesizeStream(text: String, voiceID: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await synthesizeWithRetry(text: text, voiceID: voiceID, continuation: continuation)
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private func synthesizeWithRetry(
        text: String, voiceID: String,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) async {
        for attempt in 0...ttsConfig.maxRetries {
            do {
                try Task.checkCancellation()
                try await synthesizeOnce(text: text, voiceID: voiceID, continuation: continuation)
                return
            } catch is CancellationError {
                Log.info("TTS 合成已取消")
                continuation.finish(throwing: CancellationError())
                return
            } catch {
                let isLast = attempt == ttsConfig.maxRetries
                Log.error("TTS 合成失败 (attempt \(attempt+1)/\(ttsConfig.maxRetries+1)): \(error)")
                if isLast {
                    continuation.finish(throwing: error)
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(ttsConfig.retryDelayMs) * 1_000_000)
            }
        }
    }

    private func synthesizeOnce(
        text: String, voiceID: String,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) async throws {
        guard let model else { throw TTSError.notLoaded }

        let voice = config.voice(id: voiceID)
        let refText = voice?.refText
        let refAudio = try loadRefAudio(voice?.refAudio, sampleRate: model.sampleRate)
        Log.info("TTS 请求: voice=\(voiceID) text_chars=\(text.count)")

        let stream = model.generateStream(
            text: text,
            voice: nil,
            refAudio: refAudio,
            refText: refText,
            language: ttsConfig.language,
            generationParameters: model.defaultGenerationParameters,
            streamingInterval: ttsConfig.streamingInterval
        )

        var chunkIdx = 0
        for try await event in stream {
            try Task.checkCancellation()
            if case .audio(let chunk) = event {
                let samples: [Float] = chunk.asArray(Float.self)
                let pcm = audioToPCM(
                    samples,
                    inputSampleRate: model.sampleRate,
                    outputSampleRate: ttsConfig.outputSampleRate
                )
                if chunkIdx == 0 {
                    Log.info("TTS 流式开始: samples=\(samples.count) pcm_bytes=\(pcm.count)")
                }
                continuation.yield(pcm)
                chunkIdx += 1
            }
        }
        try Task.checkCancellation()
        Log.info("TTS 流式完成: chunks=\(chunkIdx)")
        continuation.finish()
    }

    private func loadRefAudio(_ path: String?, sampleRate: Int) throws -> MLXArray? {
        guard let path, !path.isEmpty else { return nil }
        let expanded = expandPath(path)
        let url = URL(fileURLWithPath: expanded)
        guard FileManager.default.fileExists(atPath: expanded) else {
            Log.info("参考音频不存在，跳过: \(expanded)")
            return nil
        }
        let (_, refAudio) = try loadAudioArray(from: url, sampleRate: sampleRate)
        return refAudio
    }

    private func expandPath(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }
}

enum TTSError: Error {
    case notLoaded
}
