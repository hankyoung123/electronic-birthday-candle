import Foundation

#if DEBUG
struct BlowDebugSnapshot: Sendable {
    let rms: Float
    let texture: Float
    let rawScore: Float
    let smoothedIntensity: Float

    static let zero = BlowDebugSnapshot(
        rms: 0,
        texture: 0,
        rawScore: 0,
        smoothedIntensity: 0
    )
}
#endif

final class BlowDetector: @unchecked Sendable {
    private let configuration: BlowDetectionConfiguration
    private let lock = NSLock()
    private var smoothedIntensity: Float = 0
    #if DEBUG
    private var debugSnapshot: BlowDebugSnapshot = .zero
    #endif

    init(configuration: BlowDetectionConfiguration = .standard) {
        self.configuration = configuration
    }

    @discardableResult
    func analyze(samples: UnsafeBufferPointer<Float>, sampleRate: Double) -> Float {
        guard samples.count > 8, sampleRate > 0 else { return currentIntensity }

        var sumSquares: Float = 0
        var differenceSquares: Float = 0
        var previous = samples[0]

        for sample in samples {
            sumSquares += sample * sample
            let difference = sample - previous
            differenceSquares += difference * difference
            previous = sample
        }

        let count = Float(samples.count)
        let rms = sqrt(sumSquares / count)
        let differenceRMS = sqrt(differenceSquares / count)
        let sampleRateScale = Float(sampleRate / configuration.textureReferenceSampleRate)
        let normalizedDifferenceRMS = differenceRMS * sampleRateScale
        let highFrequencyRatio = rms > 0.000_001
            ? min(normalizedDifferenceRMS / (rms * 1.42), 1)
            : 0

        let energyScore = normalized(
            rms,
            lower: configuration.silenceFloorRMS,
            upper: configuration.fullScaleRMS
        )
        let textureScore = normalized(
            highFrequencyRatio,
            lower: configuration.minimumHighFrequencyRatio,
            upper: configuration.fullHighFrequencyRatio
        )
        let rawScore = energyScore * textureScore

        return lock.withLock {
            let coefficient = rawScore > smoothedIntensity
                ? configuration.attackSmoothing
                : configuration.releaseSmoothing
            smoothedIntensity += (rawScore - smoothedIntensity) * coefficient
            #if DEBUG
            debugSnapshot = BlowDebugSnapshot(
                rms: rms,
                texture: textureScore,
                rawScore: rawScore,
                smoothedIntensity: smoothedIntensity
            )
            #endif
            return smoothedIntensity
        }
    }

    var currentIntensity: Float {
        lock.withLock { smoothedIntensity }
    }

    #if DEBUG
    var currentDebugSnapshot: BlowDebugSnapshot {
        lock.withLock { debugSnapshot }
    }
    #endif

    func reset() {
        lock.withLock {
            smoothedIntensity = 0
            #if DEBUG
            debugSnapshot = .zero
            #endif
        }
    }

    private func normalized(_ value: Float, lower: Float, upper: Float) -> Float {
        guard upper > lower else { return 0 }
        return min(max((value - lower) / (upper - lower), 0), 1)
    }
}
