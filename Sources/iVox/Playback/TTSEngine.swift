import Foundation
@preconcurrency import MLX
import MLXAudioCore
import MLXAudioTTS
import iVoxKit

// 本地 TTS 引擎（mlx-audio-swift）。

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
    private var stateContinuations: [CheckedContinuation<Void, Never>] = []

    // 合成串行闸门：MLX 模型非并发安全，bargeIn 取消旧推理是协作式的（要等下一个
    // 取消检查点才真正退出）。若新推理在旧推理退出前进入 generateStream，两个推理并发
    // 砸同一模型会触发 "expected a non-empty mlx_array" 致命错误、整个 daemon 崩溃。
    // 用单调世代串行化：第 N 代必须等第 N-1 代完全离开模型后才能进入。
    private var currentSynthGen: UInt = 0
    private var lastFinishedGen: UInt = 0
    private var gateWaiters: [UInt: [CheckedContinuation<Void, Never>]] = [:]
    /// 作废纪元：bargeIn 递增。捕获旧纪元的合成（含在 gate 排队者）放行后一律抛
    /// CancellationError、绝不进 MLX。不依赖 Swift 任务取消能否传播到内部 Task。
    private var epoch: UInt = 0

    /// 已解析的参考音频缓存：key = 路径 + mtime（文件被 voice add 覆盖即失效）。
    /// 一次播报内音色固定，缓存后免掉每句一次的 wav 读盘/解码/重采样。
    /// 参考音频缓存。存的是**重采样后的采样数据**而不是 `MLXArray`——
    /// `mlx-swift 0.32` 起 `generateStream(refAudio:)` 的参数带 `sending`，要求调用方
    /// **转移所有权**，可缓存里的实例缓存自己还持有一份，直接交出去就成了数据竞争
    /// （2026-10-18 升级时报 `sending 'refAudio' risks causing data races`）。
    ///
    /// ⚠️ 但**不能改成每次现场造一个新 `MLXArray`**：`mlx-audio-swift` 内部用
    /// `ObjectIdentifier(refAudio)` 认参考音频来复用整份输入准备上下文（音色编码 +
    /// 语音编码），对象地址每次都变 → 那层缓存永不命中 → 每块合成多花 1~2 秒
    /// （实测 4~5s 涨到 5~7s），预取余量被挤小，`check-tts` 的 `A-tail` 尾音用例转红
    /// （2026-10-18 实测）。故用下面的盒子包一层：`@unchecked Sendable` 让 `sending`
    /// 检查通过，而盒内的 `MLXArray` 始终是**同一个实例**，库内部缓存照旧命中。
    private struct RefAudioEntry: Sendable {
        let mtime: Date
        let box: RefAudioBox
    }

    /// 编译期视图：`@unchecked` 把实例稳定性寄托在「我们只读不写、且始终交同一个实例」
    /// 上（`MLXArray` 底层是引用计数的 handle，库内部会 retain）。
    private struct RefAudioBox: @unchecked Sendable {
        let array: MLXArray
    }
    private var refAudioCache: [String: RefAudioEntry] = [:]
    /// 最近一次 `cancelActiveSynthesis` 的打断来源，供合成取消日志对上因果（见 cancelActiveSynthesis）
    private var cancelReason = "?"

    init(config: Config) {
        self.config = config
        self.ttsConfig = config.resolvedTTS
    }

    var isLoaded: Bool { model != nil }

    var state: LoadState { loadState }

    func loadModel() async throws {
        if model != nil {
            if case .ready = loadState { resumeAllWaiters() }
            return
        }
        loadState = .loading
        let modelPath = expandPath(config.models?.ttsPath ?? "~/.config/ivox/model/Qwen3-TTS-12Hz-1.7B-Base-8bit")
        Log.debug("加载 TTS 模型: \(modelPath)")
        do {
            model = try await TTS.loadModel(modelRepo: modelPath)
            loadState = .ready
            resumeAllWaiters()
            Log.debug("TTS 模型加载完成")
        } catch {
            loadState = .failed(String(describing: error))
            resumeAllWaiters()
            throw error
        }
    }

    func warmup(voiceID: String) async {
        do {
            Log.debug("TTS 预热 [\(voiceID)]...")
            let stream = synthesizeStream(text: "你好，模型预热完成。", voiceID: voiceID)
            for try await _ in stream { }
            Log.debug("TTS 预热完成 [\(voiceID)]")
        } catch {
            Log.debug("TTS 预热跳过 [\(voiceID)]: \(error)")
        }
    }

    /// 等待模型就绪（事件驱动，不再轮询）
    func waitUntilReady() async {
        switch loadState {
        case .ready: return
        case .failed(let msg): Log.error("TTS 模型加载失败: \(msg)"); return
        case .notStarted, .loading:
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.stateContinuations.append(continuation)
            }
        }
    }

    private func resumeAllWaiters() {
        let waiters = stateContinuations
        stateContinuations.removeAll()
        for cont in waiters { cont.resume() }
    }

    func synthesizeStream(text: String, voiceID: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await synthesize(text: text, voiceID: voiceID, continuation: continuation)
                } catch is CancellationError {
                    Log.info("TTS 合成已取消（打断来源=\(cancelReason)）")
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private func synthesize(
        text: String, voiceID: String,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) async throws {
        guard let model else { throw TTSError.notLoaded }

        let voice = config.voice(id: voiceID)
        let refText = voice?.refText
        let refAudio = try await loadRefAudio(voice?.refAudio, sampleRate: model.sampleRate)
        Log.info("TTS 请求: voice=\(voiceID) text_chars=\(text.count)")

        // 串行闸门：等上一代合成彻底离开模型再进入（refAudio 是普通 IO，已在闸外完成）。
        let myEpoch = epoch
        currentSynthGen &+= 1
        let myGen = currentSynthGen
        let prevGen = myGen &- 1
        // 无论成功/失败/取消都必须释放闸门，否则下一代永久等待
        defer { finishSynthesis(myGen) }
        if lastFinishedGen < prevGen {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                gateWaiters[prevGen, default: []].append(cont)
            }
        }
        // 被 bargeIn 作废（纪元已推进）：放行后直接退出，绝不进 MLX。
        // 正在 MLX 中的那一句无法中途打断（库限制），跑完即止，产出落到已关闭的流、无害。
        if myEpoch != epoch { throw CancellationError() }

        let stream = model.generateStream(
            text: text,
            voice: nil,
            refAudio: refAudio?.array,
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

    /// 离开模型：推进完成世代并放行等待下一代的合成（一次只可能有一个等待者）。
    /// 被取消的世代也会推进世代号，使后续已取消的排队者能链式快速退出、不进 MLX。
    private func finishSynthesis(_ gen: UInt) {
        if gen > lastFinishedGen { lastFinishedGen = gen }
        if let waiters = gateWaiters[gen] {
            gateWaiters[gen] = nil
            waiters.forEach { $0.resume() }
        }
    }

    /// bargeIn：推进纪元并唤醒所有 gate 排队者。旧纪元的合成被唤醒后检查到纪元失配，
    /// 直接抛 CancellationError 退出、不进 MLX；新纪元的合成此刻尚未入队，不受影响，
    /// 仍由世代闸门保证在「正在跑的那一句」结束后才进入模型。
    func cancelActiveSynthesis(reason: String) {
        // 记下这次是谁打断的，供被取消的合成子 task 打「TTS 合成已取消」时对上因果。
        // 合成串行、打断只在 bargeIn 一处发起，写入不会被并发覆盖出错误归属。
        cancelReason = reason
        epoch &+= 1
        let waiters = gateWaiters
        gateWaiters.removeAll()
        waiters.values.forEach { $0.forEach { $0.resume() } }
    }

    /// 返回**盒子**而非裸 `MLXArray`：见 `RefAudioBox` 的注释——既让 `sending` 检查
    /// 通过，又保证盒内 `MLXArray` 全程是同一实例（库内部缓存靠它命中）。
    private func loadRefAudio(_ path: String?, sampleRate: Int) async throws -> sending RefAudioBox? {
        guard let path, !path.isEmpty else { return nil }
        let expanded = expandPath(path)
        guard FileManager.default.fileExists(atPath: expanded) else {
            Log.info("参考音频不存在，跳过: \(expanded)")
            return nil
        }

        // 命中缓存（路径 + mtime 一致）：直接复用，免读盘/解码/重采样，
        // 也保住盒内 `MLXArray` 的实例身份（库内部缓存靠它，见 RefAudioEntry 的注释）。
        // key 含目标采样率，模型重载后采样率变化也不会错配。
        let mtime = (try? FileManager.default.attributesOfItem(atPath: expanded)[.modificationDate] as? Date) ?? Date.distantPast
        let cacheKey = "\(expanded)#\(sampleRate)"
        if let entry = refAudioCache[cacheKey], entry.mtime == mtime {
            Log.debug("参考音频命中缓存: \(expanded)")
            return entry.box
        }

        // 磁盘 I/O 在后台执行，避免阻塞 actor
        let url = URL(fileURLWithPath: expanded)
        let refAudio = try await Task.detached(priority: .userInitiated) {
            try loadAudioArray(from: url, sampleRate: sampleRate).1
        }.value
        let box = RefAudioBox(array: refAudio)
        refAudioCache[cacheKey] = RefAudioEntry(mtime: mtime, box: box)
        Log.debug("参考音频已缓存: \(expanded)")
        return box
    }

    private func expandPath(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }
}

enum TTSError: Error {
    case notLoaded
}
