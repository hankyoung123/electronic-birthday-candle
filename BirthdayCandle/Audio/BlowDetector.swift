import Foundation

final class BlowDetector: @unchecked Sendable {
    private let configuration: BlowDetectionConfiguration
    private let lock = NSLock()
    private var smoothedIntensity: Float = 0

    init(configuration: BlowDetectionConfiguration = .standard) {
        self.configuration = configuration
    }

    @discardableResult
    func analyze(samples: [Float], sampleRate: Double) -> Float {
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
        let highFrequencyRatio = rms > 0.000_001 ? min(differenceRMS / (rms * 1.42), 1) : 0

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

        lock.lock()
        let coefficient = rawScore > smoothedIntensity
            ? configuration.attackSmoothing
            : configuration.releaseSmoothing
        smoothedIntensity += (rawScore - smoothedIntensity) * coefficient
        let result = smoothedIntensity
        lock.unlock()
        return result
    }

    var currentIntensity: Float {
        lock.withLock { smoothedIntensity }
    }

    func reset() {
        lock.withLock { smoothedIntensity = 0 }
    }

    private func normalized(_ value: Float, lower: Float, upper: Float) -> Float {
        guard upper > lower else { return 0 }
        return min(max((value - lower) / (upper - lower), 0), 1)
    }
}
