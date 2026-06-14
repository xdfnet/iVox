import Foundation

/// 2x 上采样 (线性插值)，24k→48k
public func upsample2x(_ samples: [Float]) -> [Float] {
    let n = samples.count
    guard n >= 2 else { return samples.flatMap { [$0, $0] } }
    var result: [Float] = []
    result.reserveCapacity(n * 2)
    for i in 0..<(n - 1) {
        let a = samples[i]
        let b = samples[i + 1]
        result.append(a)
        result.append((a + b) / 2.0)
    }
    result.append(samples[n - 1])
    result.append(samples[n - 1])
    return result
}

public func resampleLinear(_ samples: [Float], from inputSampleRate: Int, to outputSampleRate: Int) -> [Float] {
    guard !samples.isEmpty else { return [] }
    guard inputSampleRate > 0, outputSampleRate > 0, inputSampleRate != outputSampleRate else {
        return samples
    }
    if inputSampleRate == 24_000, outputSampleRate == 48_000 {
        return upsample2x(samples)
    }

    let ratio = Double(outputSampleRate) / Double(inputSampleRate)
    let outputCount = max(1, Int((Double(samples.count) * ratio).rounded()))
    guard outputCount > 1, samples.count > 1 else {
        return Array(repeating: samples[0], count: outputCount)
    }

    var result: [Float] = []
    result.reserveCapacity(outputCount)
    for i in 0..<outputCount {
        let sourcePosition = Double(i) / ratio
        let lower = min(Int(sourcePosition), samples.count - 1)
        let upper = min(lower + 1, samples.count - 1)
        let fraction = Float(sourcePosition - Double(lower))
        result.append(samples[lower] + (samples[upper] - samples[lower]) * fraction)
    }
    return result
}

/// float32 音频 → int16 PCM bytes (重采样到播放器采样率 + 限幅)
public func audioToPCM(
    _ samples: [Float],
    inputSampleRate: Int = 24_000,
    outputSampleRate: Int = 48_000,
    peakLimit: Float = 0.98
) -> Data {
    guard !samples.isEmpty else { return Data() }
    var audio = samples
    let peak = audio.map { abs($0) }.max() ?? 0
    if peak > peakLimit && peak > 0 {
        audio = audio.map { $0 * (peakLimit / peak) }
    }
    audio = resampleLinear(audio, from: inputSampleRate, to: outputSampleRate)
    var pcm = Data(capacity: audio.count * 2)
    for s in audio {
        let clamped = max(-32768, min(32767, Int32(s * 32767)))
        var sample = Int16(clamped).littleEndian
        pcm.append(Data(bytes: &sample, count: 2))
    }
    return pcm
}
