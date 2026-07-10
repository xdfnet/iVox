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

/// float32 音频 → int16 PCM bytes (重采样 + 限幅，peak 扫描与重采样合并为一次遍历，PCM 写入一次拷贝)
public func audioToPCM(
    _ samples: [Float],
    inputSampleRate: Int = 24_000,
    outputSampleRate: Int = 48_000,
    peakLimit: Float = 0.98
) -> Data {
    guard !samples.isEmpty else { return Data() }

    // 计算输出样本数（2x 上采样特化路径避免比例运算）
    let outputCount: Int
    if inputSampleRate == 24_000 && outputSampleRate == 48_000 {
        outputCount = samples.count * 2
    } else if inputSampleRate == outputSampleRate {
        outputCount = samples.count
    } else {
        let ratio = Double(outputSampleRate) / Double(inputSampleRate)
        outputCount = max(1, Int((Double(samples.count) * ratio).rounded()))
    }

    // 预分配 PCM buffer（避免逐样本 Data.append 的 O(n²) 重新分配）
    var pcm = Data(capacity: outputCount * 2)
    pcm.count = outputCount * 2

    // Pass 1：找峰值（同时为 2x 上采样预计算重采样值，存储到临时 [Float]）
    var peak: Float = 0
    var resampled: [Float]
    if inputSampleRate == 24_000 && outputSampleRate == 48_000 {
        // 线性插值上采样：每相邻样本间插一个中值
        resampled = []
        resampled.reserveCapacity(outputCount)
        for i in 0..<(samples.count - 1) {
            let a = samples[i], b = samples[i + 1]
            resampled.append(a)
            resampled.append((a + b) / 2.0)
            if abs(a) > peak { peak = abs(a) }
            if abs(b) > peak { peak = abs(b) }
        }
        // 末帧重复
        resampled.append(samples[samples.count - 1])
        resampled.append(samples[samples.count - 1])
        if abs(samples[samples.count - 1]) > peak { peak = abs(samples[samples.count - 1]) }
    } else if inputSampleRate == outputSampleRate {
        resampled = samples
        for s in samples { let a = abs(s); if a > peak { peak = a } }
    } else {
        // 通用线性重采样 + 峰值扫描（单 pass）
        let ratio = Double(outputSampleRate) / Double(inputSampleRate)
        resampled = []
        resampled.reserveCapacity(outputCount)
        for i in 0..<outputCount {
            let srcPos = Double(i) / ratio
            let lower = min(Int(srcPos), samples.count - 1)
            let upper = min(lower + 1, samples.count - 1)
            let frac = Float(srcPos - Double(lower))
            let s = samples[lower] + (samples[upper] - samples[lower]) * frac
            resampled.append(s)
            if abs(s) > peak { peak = abs(s) }
        }
    }

    // 最终缩放系数（只在真正过载时才缩放，避免 1.0 时做无效乘法）
    let scale: Float = (peak > peakLimit && peak > 0) ? (peakLimit / peak) : 1.0

    // Pass 2：限幅 + PCM 写入（一次 memcpy，无中间 Data 分配）
    pcm.withUnsafeMutableBytes { buf in
        guard let ptr = buf.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
        if scale == 1.0 {
            for i in 0..<resampled.count {
                let clamped = max(-32768, min(32767, Int32(resampled[i] * 32767)))
                ptr[i] = Int16(clamped).littleEndian
            }
        } else {
            for i in 0..<resampled.count {
                let clamped = max(-32768, min(32767, Int32(resampled[i] * scale * 32767)))
                ptr[i] = Int16(clamped).littleEndian
            }
        }
    }
    return pcm
}
