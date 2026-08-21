import Accelerate
import Foundation

#if DEBUG
/// Full-frame diagnostics for the Inspector, following the adaptive-baseline
/// delta pipeline: current/baseline level, band ratios, band dB deltas,
/// broadband + its delta, and the three score stages.
struct BlowDebugSnapshot: Sendable {
    let rms: Float
    let dbFS: Float
    let baselineDbFS: Float
    let totalDeltaDB: Float
    let lowRatio: Float
    let midRatio: Float
    let upperRatio: Float
    let highRatio: Float
    let lowDeltaDB: Float
    let midDeltaDB: Float
    let upperDeltaDB: Float
    let highDeltaDB: Float
    let broadbandActiveProportion: Float
    let broadbandScore: Float
    let broadbandDelta: Float
    let spectralDeltaScore: Float
    let rawScore: Float
    let smoothedIntensity: Float

    static let zero = BlowDebugSnapshot(
        rms: 0,
        dbFS: -120,
        baselineDbFS: -120,
        totalDeltaDB: 0,
        lowRatio: 0,
        midRatio: 0,
        upperRatio: 0,
        highRatio: 0,
        lowDeltaDB: 0,
        midDeltaDB: 0,
        upperDeltaDB: 0,
        highDeltaDB: 0,
        broadbandActiveProportion: 0,
        broadbandScore: 0,
        broadbandDelta: 0,
        spectralDeltaScore: 0,
        rawScore: 0,
        smoothedIntensity: 0
    )
}
#endif

/// Per-frame band measurements (also used in Release — they ARE the detector
/// input). Powers are mean-per-bin; ratios are the comparable 0–1 view.
private struct BandAnalysis {
    let totalPower: Float
    let lowPower: Float
    let midPower: Float
    let upperPower: Float
    let highPower: Float
    let lowRatio: Float
    let midRatio: Float
    let upperRatio: Float
    let highRatio: Float
    let broadbandActiveProportion: Float
    let broadbandScore: Float
}

/// Ambient-spectrum state: updated by slow EMA, fast during warm-up, frozen
/// while a blow candidate is active.
private struct BaselineState {
    var totalPower: Float = 0
    var lowPower: Float = 0
    var midPower: Float = 0
    var upperPower: Float = 0
    var highPower: Float = 0
    var broadbandScore: Float = 0
    var rms: Float = 0
}

final class BlowDetector: @unchecked Sendable {
    private let configuration: BlowDetectionConfiguration
    private let lock = NSLock()
    private var smoothedIntensity: Float = 0
    private var baseline = BaselineState()
    private var hasBaseline = false
    private var elapsedAtAnalysis: Double = 0
    #if DEBUG
    private var debugSnapshot: BlowDebugSnapshot = .zero
    #endif

    // Reused FFT scratch.
    private let spectrumFFTSize = 1_024
    private var fftSetup: FFTSetup?
    private var spectrumInterleaved: [Float] = []
    private var spectrumReal: [Float] = []
    private var spectrumImag: [Float] = []
    private var spectrumPower: [Float] = []
    private var spectrumWindow: [Float] = []
    /// Floor used to keep `10 * log10((cur+ε)/(base+ε))` finite at silence.
    private let deltaEpsilon: Float = 1e-8

    init(configuration: BlowDetectionConfiguration = .standard) {
        self.configuration = configuration
    }

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    @discardableResult
    func analyze(samples: UnsafeBufferPointer<Float>, sampleRate: Double) -> Float {
        guard samples.count > 8, sampleRate > 0 else { return currentIntensity }
        let config = configuration.snapshot()

        var sumSquares: Float = 0
        for sample in samples {
            sumSquares += sample * sample
        }
        let rms = sqrt(sumSquares / Float(samples.count))
        let bands = analyzeBands(samples, sampleRate: sampleRate, rms: rms, config: config)

        let frameDuration = Double(samples.count) / sampleRate
        elapsedAtAnalysis += frameDuration
        let warmingUp = elapsedAtAnalysis < config.baselineWarmupDuration

        // Deltas vs the ambient baseline (zero until the first frame seeds it).
        var totalDeltaDB: Float = 0
        var lowDeltaDB: Float = 0
        var midDeltaDB: Float = 0
        var upperDeltaDB: Float = 0
        var highDeltaDB: Float = 0
        var broadbandDelta: Float = 0
        var spectralDeltaScore: Float = 0
        var rawScore: Float = 0

        if hasBaseline {
            totalDeltaDB = deltaDB(bands.totalPower, baseline.totalPower)
            lowDeltaDB = deltaDB(bands.lowPower, baseline.lowPower)
            midDeltaDB = deltaDB(bands.midPower, baseline.midPower)
            upperDeltaDB = deltaDB(bands.upperPower, baseline.upperPower)
            highDeltaDB = deltaDB(bands.highPower, baseline.highPower)
            broadbandDelta = bands.broadbandScore - baseline.broadbandScore

            let lowScore = normalized(lowDeltaDB, lower: config.lowDeltaStartDB, upper: config.lowDeltaFullDB)
            let midScore = normalized(midDeltaDB, lower: config.midDeltaStartDB, upper: config.midDeltaFullDB)
            let upperScore = normalized(upperDeltaDB, lower: config.upperDeltaStartDB, upper: config.upperDeltaFullDB)

            // Low/mid/upper only — the high band is diagnostics for now.
            spectralDeltaScore = config.lowWeight * lowScore
                + config.midWeight * midScore
                + config.upperWeight * upperScore
            let spectralWeight = 1 - config.broadbandWeight
            // Additive; no hard gating between the two terms.
            rawScore = min(
                max(spectralWeight * spectralDeltaScore + config.broadbandWeight * bands.broadbandScore, 0),
                1
            )
        }

        return lock.withLock {
            let coefficient = rawScore > smoothedIntensity
                ? config.attackSmoothing
                : config.releaseSmoothing
            smoothedIntensity += (rawScore - smoothedIntensity) * coefficient

            if !hasBaseline {
                // First frame establishes the ambient; nothing to measure yet.
                baseline = BaselineState(
                    totalPower: bands.totalPower,
                    lowPower: bands.lowPower,
                    midPower: bands.midPower,
                    upperPower: bands.upperPower,
                    highPower: bands.highPower,
                    broadbandScore: bands.broadbandScore,
                    rms: rms
                )
                hasBaseline = true
            } else if smoothedIntensity <= config.candidateFreezeThreshold {
                // Not blowing: keep adapting (fast at start, slow afterwards).
                let alpha = Float(warmingUp ? config.baselineWarmupAlpha : config.baselineAlpha)
                baseline.totalPower += (bands.totalPower - baseline.totalPower) * alpha
                baseline.lowPower += (bands.lowPower - baseline.lowPower) * alpha
                baseline.midPower += (bands.midPower - baseline.midPower) * alpha
                baseline.upperPower += (bands.upperPower - baseline.upperPower) * alpha
                baseline.highPower += (bands.highPower - baseline.highPower) * alpha
                baseline.broadbandScore += (bands.broadbandScore - baseline.broadbandScore) * alpha
                baseline.rms += (rms - baseline.rms) * alpha
            }
            // else: a blow candidate is active — baseline is frozen so a
            // sustained blow never gets absorbed into the ambient.

            #if DEBUG
            debugSnapshot = BlowDebugSnapshot(
                rms: rms,
                dbFS: rms > 0 ? max(-120, 20 * log10(rms)) : -120,
                baselineDbFS: baseline.rms > 0 ? max(-120, 20 * log10(baseline.rms)) : -120,
                totalDeltaDB: totalDeltaDB,
                lowRatio: bands.lowRatio,
                midRatio: bands.midRatio,
                upperRatio: bands.upperRatio,
                highRatio: bands.highRatio,
                lowDeltaDB: lowDeltaDB,
                midDeltaDB: midDeltaDB,
                upperDeltaDB: upperDeltaDB,
                highDeltaDB: highDeltaDB,
                broadbandActiveProportion: bands.broadbandActiveProportion,
                broadbandScore: bands.broadbandScore,
                broadbandDelta: broadbandDelta,
                spectralDeltaScore: spectralDeltaScore,
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
            baseline = BaselineState()
            hasBaseline = false
            elapsedAtAnalysis = 0
            #if DEBUG
            debugSnapshot = .zero
            #endif
        }
    }

    private func deltaDB(_ current: Float, _ base: Float) -> Float {
        10 * log10((current + deltaEpsilon) / (base + deltaEpsilon))
    }

    private func normalized(_ value: Float, lower: Float, upper: Float) -> Float {
        guard upper > lower else { return 0 }
        return min(max((value - lower) / (upper - lower), 0), 1)
    }

    // MARK: - Band + broadband analysis

    private func analyzeBands(
        _ samples: UnsafeBufferPointer<Float>,
        sampleRate: Double,
        rms: Float,
        config: BlowDetectionParameters
    ) -> BandAnalysis {
        let n = spectrumFFTSize
        ensureFFTScratch(fftSize: n)
        guard let setup = fftSetup else {
            return BandAnalysis(
                totalPower: 0, lowPower: 0, midPower: 0, upperPower: 0, highPower: 0,
                lowRatio: 0, midRatio: 0, upperRatio: 0, highRatio: 0,
                broadbandActiveProportion: 0, broadbandScore: 0
            )
        }

        let count = min(samples.count, n)
        let log2n = vDSP_Length(log2(Double(n)))

        let window = spectrumWindow
        spectrumInterleaved.withUnsafeMutableBufferPointer { inter in
            for i in 0..<count {
                inter[i] = samples[i] * window[i]
            }
            if count < n {
                for i in count..<n { inter[i] = 0 }
            }
            inter.withUnsafeBufferPointer { interPtr in
                guard let base = interPtr.baseAddress else { return }
                let complexPtr = UnsafeRawPointer(base).assumingMemoryBound(to: DSPComplex.self)
                spectrumReal.withUnsafeMutableBufferPointer { realPtr in
                    spectrumImag.withUnsafeMutableBufferPointer { imagPtr in
                        var split = DSPSplitComplex(
                            realp: realPtr.baseAddress!,
                            imagp: imagPtr.baseAddress!
                        )
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(n / 2))
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                        spectrumPower.withUnsafeMutableBufferPointer { powerPtr in
                            vDSP_zvmags(&split, 1, powerPtr.baseAddress!, 1, vDSP_Length(n / 2))
                        }
                    }
                }
            }
        }

        let power = spectrumPower
        let binWidth = sampleRate / Double(n)

        func bandLower(_ lowerHz: Double) -> Int {
            max(1, Int((lowerHz / binWidth).rounded(.down)))
        }
        func bandUpper(_ upperHz: Double) -> Int {
            min(n / 2, Int((upperHz / binWidth).rounded(.down)))
        }

        let lowStart = bandLower(config.lowBandLowerHz)
        let lowEnd = bandUpper(config.lowBandUpperHz)
        let midEnd = bandUpper(config.midBandUpperHz)
        let upperEnd = bandUpper(config.upperBandUpperHz)
        let highEnd = bandUpper(config.highBandUpperHz)

        func meanPower(_ start: Int, _ end: Int) -> Float {
            guard end > start else { return 0 }
            var sum: Float = 0
            power.withUnsafeBufferPointer { p in
                guard let base = p.baseAddress else { return }
                vDSP_sve(base + start, 1, &sum, vDSP_Length(end - start))
            }
            return sum / Float(end - start)
        }

        let lowPower = meanPower(lowStart, lowEnd)
        let midPower = meanPower(lowEnd, midEnd)
        let upperPower = meanPower(midEnd, upperEnd)
        let highPower = meanPower(upperEnd, highEnd)

        // Comparable view: each band's share of total band power.
        let totalPower = lowPower + midPower + upperPower + highPower + 1e-12
        let lowRatio = lowPower / totalPower
        let midRatio = midPower / totalPower
        let upperRatio = upperPower / totalPower
        let highRatio = highPower / totalPower

        // Broadband: how much of [broadbandLower, broadbandUpper) rose at once.
        let bbStart = bandLower(config.broadbandLowerHz)
        let bbEnd = bandUpper(config.broadbandUpperHz)
        var activeProportion: Float = 0
        var broadbandScore: Float = 0
        if bbEnd > bbStart {
            var maxPower: Float = 0
            power.withUnsafeBufferPointer { p in
                guard let base = p.baseAddress else { return }
                vDSP_maxv(base + bbStart, 1, &maxPower, vDSP_Length(bbEnd - bbStart))
            }
            if maxPower > 1e-9, rms >= config.silenceFloorRMS {
                var activeCount = 0
                for k in bbStart..<bbEnd where power[k] >= maxPower * config.broadbandRelativeThreshold {
                    activeCount += 1
                }
                let proportion = Float(activeCount) / Float(bbEnd - bbStart)
                activeProportion = proportion
                broadbandScore = normalized(
                    proportion,
                    lower: config.broadbandActiveMinProportion,
                    upper: config.broadbandActiveFullProportion
                )
            }
        }

        return BandAnalysis(
            totalPower: totalPower,
            lowPower: lowPower,
            midPower: midPower,
            upperPower: upperPower,
            highPower: highPower,
            lowRatio: lowRatio,
            midRatio: midRatio,
            upperRatio: upperRatio,
            highRatio: highRatio,
            broadbandActiveProportion: activeProportion,
            broadbandScore: broadbandScore
        )
    }

    private func ensureFFTScratch(fftSize: Int) {
        guard fftSetup == nil, spectrumInterleaved.isEmpty else { return }
        fftSetup = vDSP_create_fftsetup(
            vDSP_Length(log2(Double(fftSize))),
            FFTRadix(kFFTRadix2)
        )
        spectrumInterleaved = [Float](repeating: 0, count: fftSize)
        spectrumReal = [Float](repeating: 0, count: fftSize / 2)
        spectrumImag = [Float](repeating: 0, count: fftSize / 2)
        spectrumPower = [Float](repeating: 0, count: fftSize / 2)
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        spectrumWindow = window
    }
}