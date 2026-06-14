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

/// float32 音频 → int16 PCM bytes (含 24k→48k 上采样 + 限幅)
public func audioToPCM(_ samples: [Float], peakLimit: Float = 0.98) -> Data {
    guard !samples.isEmpty else { return Data() }
    var audio = samples
    let peak = audio.map { abs($0) }.max() ?? 0
    if peak > peakLimit && peak > 0 {
        audio = audio.map { $0 * (peakLimit / peak) }
    }
    audio = upsample2x(audio)
    var pcm = Data(capacity: audio.count * 2)
    for s in audio {
        let clamped = max(-32768, min(32767, Int32(s * 32767)))
        var sample = Int16(clamped).littleEndian
        pcm.append(Data(bytes: &sample, count: 2))
    }
    return pcm
}
