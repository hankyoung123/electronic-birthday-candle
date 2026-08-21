import Foundation

#if DEBUG
struct BlowDebugSnapshot: Sendable {
    let rms: Float
    let dbFS: Float
    let windBandRMS: Float
    let visualIntensity: Float

    static let zero = BlowDebugSnapshot(
        rms: 0,
        dbFS: -120,
        windBandRMS: 0,
        visualIntensity: 0
    )
}
#endif

/// Second-order biquad (RBJ cookbook, Direct Form I).
private struct Biquad {
    private var b0: Float = 1
    private var b1: Float = 0
    private var b2: Float = 0
    private var a1: Float = 0
    private var a2: Float = 0
    private var x1: Float = 0
    private var x2: Float = 0
    private var y1: Float = 0
    private var y2: Float = 0

    init(kind: Kind, cutoffHz: Double, sampleRate: Double) {
        let q: Double = 1 / sqrt(2)
        let w0 = 2 * Double.pi * cutoffHz / sampleRate
        let cosw0 = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        let c1 = -2 * cosw0
        let c2 = 1 - alpha

        switch kind {
        case .lowPass:
            b0 = Float((1 - cosw0) / 2 / a0)
            b1 = Float((1 - cosw0) / a0)
            b2 = b0
        case .highPass:
            b0 = Float((1 + cosw0) / 2 / a0)
            b1 = Float(-(1 + cosw0) / a0)
            b2 = b0
        }
        a1 = Float(c1 / a0)
        a2 = Float(c2 / a0)
    }

    enum Kind { case lowPass, highPass }

    mutating func process(_ input: Float) -> Float {
        let output = b0 * input + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1
        x1 = input
        y2 = y1
        y1 = output
        return output
    }
}

/// Low-latency airflow energy for flame animation only.
///
/// This detector deliberately has no semantic “is a blow” output. It reduces
/// microphone PCM to a smoothed 80–500 Hz RMS intensity that may react to any
/// low-frequency sound. SoundClassifier is the sole source of extinguishing.
final class BlowDetector: @unchecked Sendable {
    private let lock = NSLock()
    private var smoothedIntensity: Float = 0
    private var sampleRate: Double = 0
    private var lowPassStages: [Biquad] = []
    private var highPassStages: [Biquad] = []

    #if DEBUG
    private var debugSnapshot: BlowDebugSnapshot = .zero
    #endif

    private let lowerFrequency = 80.0
    private let upperFrequency = 500.0
    private let visualStart: Float = 0.012
    private let visualFull: Float = 0.055
    private let attackSmoothing: Float = 0.28
    private let releaseSmoothing: Float = 0.10

    @discardableResult
    func analyze(samples: UnsafeBufferPointer<Float>, sampleRate: Double) -> Float {
        guard samples.count > 8, sampleRate > 0 else { return currentIntensity }

        return lock.withLock {
            var sumSquares: Float = 0
            for sample in samples {
                sumSquares += sample * sample
            }
            let totalRMS = sqrt(sumSquares / Float(samples.count))
            let windBandRMS = bandPassedRMS(samples, sampleRate: sampleRate)
            let targetIntensity = normalized(
                windBandRMS,
                lower: visualStart,
                upper: visualFull
            )
            let coefficient = targetIntensity > smoothedIntensity
                ? attackSmoothing
                : releaseSmoothing
            smoothedIntensity += (targetIntensity - smoothedIntensity) * coefficient

            #if DEBUG
            debugSnapshot = BlowDebugSnapshot(
                rms: totalRMS,
                dbFS: totalRMS > 0 ? max(-120, 20 * log10(totalRMS)) : -120,
                windBandRMS: windBandRMS,
                visualIntensity: smoothedIntensity
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
            sampleRate = 0
            lowPassStages = []
            highPassStages = []
            #if DEBUG
            debugSnapshot = .zero
            #endif
        }
    }

    private func bandPassedRMS(
        _ samples: UnsafeBufferPointer<Float>,
        sampleRate: Double
    ) -> Float {
        ensureFilters(sampleRate: sampleRate)
        guard !lowPassStages.isEmpty, !highPassStages.isEmpty else { return 0 }

        var sumSquares: Float = 0
        for sample in samples {
            var value = sample
            for index in highPassStages.indices {
                value = highPassStages[index].process(value)
            }
            for index in lowPassStages.indices {
                value = lowPassStages[index].process(value)
            }
            sumSquares += value * value
        }
        return sqrt(sumSquares / Float(samples.count))
    }

    private func ensureFilters(sampleRate: Double) {
        guard self.sampleRate != sampleRate || lowPassStages.isEmpty else { return }
        self.sampleRate = sampleRate
        lowPassStages = (0..<3).map { _ in
            Biquad(kind: .lowPass, cutoffHz: upperFrequency, sampleRate: sampleRate)
        }
        highPassStages = (0..<3).map { _ in
            Biquad(kind: .highPass, cutoffHz: lowerFrequency, sampleRate: sampleRate)
        }
    }

    private func normalized(_ value: Float, lower: Float, upper: Float) -> Float {
        guard upper > lower else { return 0 }
        return min(max((value - lower) / (upper - lower), 0), 1)
    }
}
