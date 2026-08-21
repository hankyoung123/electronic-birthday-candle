import Accelerate
import Foundation

#if DEBUG
/// Full-frame diagnostics for the Inspector. Band values are *ratios* (sum to
/// one); raw powers stay internal to the detector.
struct BlowDebugSnapshot: Sendable {
    let rms: Float
    let dbFS: Float
    let lowRatio: Float
    let midRatio: Float
    let upperRatio: Float
    let highRatio: Float
    let broadbandActiveProportion: Float
    let broadbandScore: Float
    let energyScore: Float
    let rawScore: Float
    let smoothedIntensity: Float
    let flatness: Float

    static let zero = BlowDebugSnapshot(
        rms: 0,
        dbFS: -120,
        lowRatio: 0,
        midRatio: 0,
        upperRatio: 0,
        highRatio: 0,
        broadbandActiveProportion: 0,
        broadbandScore: 0,
        energyScore: 0,
        rawScore: 0,
        smoothedIntensity: 0,
        flatness: 0
    )
}
#endif

/// Core per-frame band analysis (also used in Release — it IS the detector).
/// Band energies are the raw mean-per-bin powers; ratios are the comparable,
/// loudness-independent view used by the Inspector.
private struct BandAnalysis {
    let lowEnergy: Float
    let midEnergy: Float
    let upperEnergy: Float
    let highEnergy: Float
    let lowRatio: Float
    let midRatio: Float
    let upperRatio: Float
    let highRatio: Float
    let broadbandActiveProportion: Float
    let broadbandScore: Float
    let flatness: Float
}

final class BlowDetector: @unchecked Sendable {
    private let configuration: BlowDetectionConfiguration
    private let lock = NSLock()
    private var smoothedIntensity: Float = 0
    #if DEBUG
    private var debugSnapshot: BlowDebugSnapshot = .zero
    #endif

    // Reused FFT scratch. The FFT now runs on every frame in every build
    // because band energy + broadband are the primary detection features.
    private let spectrumFFTSize = 1_024
    private var fftSetup: FFTSetup?
    private var spectrumInterleaved: [Float] = []
    private var spectrumReal: [Float] = []
    private var spectrumImag: [Float] = []
    private var spectrumPower: [Float] = []
    private var spectrumWindow: [Float] = []

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

        let analysis = analyzeBands(samples, sampleRate: sampleRate, rms: rms, config: config)

        let energyScore = normalized(
            rms,
            lower: config.silenceFloorRMS,
            upper: config.fullScaleRMS
        )
        let broadbandScore = analysis.broadbandScore
        // Additive mix over the two most reliable cues: loud enough, and
        // broad across 80–2000 Hz. Band ratios are diagnostics only.
        let rawScore = min(
            max(
                config.energyScoreWeight * energyScore
                    + config.broadbandScoreWeight * broadbandScore,
                0
            ),
            1
        )

        return lock.withLock {
            let coefficient = rawScore > smoothedIntensity
                ? config.attackSmoothing
                : config.releaseSmoothing
            smoothedIntensity += (rawScore - smoothedIntensity) * coefficient
            #if DEBUG
            debugSnapshot = BlowDebugSnapshot(
                rms: rms,
                dbFS: rms > 0 ? max(-120, 20 * log10(rms)) : -120,
                lowRatio: analysis.lowRatio,
                midRatio: analysis.midRatio,
                upperRatio: analysis.upperRatio,
                highRatio: analysis.highRatio,
                broadbandActiveProportion: analysis.broadbandActiveProportion,
                broadbandScore: broadbandScore,
                energyScore: energyScore,
                rawScore: rawScore,
                smoothedIntensity: smoothedIntensity,
                flatness: analysis.flatness
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
                lowEnergy: 0, midEnergy: 0, upperEnergy: 0, highEnergy: 0,
                lowRatio: 0, midRatio: 0, upperRatio: 0, highRatio: 0,
                broadbandActiveProportion: 0, broadbandScore: 0, flatness: 0
            )
        }

        let count = min(samples.count, n)
        let log2n = vDSP_Length(log2(Double(n)))

        // The interleaved buffer viewed as (real, imag) complex pairs matches
        // exactly the even/odd packing vDSP_fft_zrip expects for a forward
        // transform of a real signal.
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

        let lowEnergy = meanPower(lowStart, lowEnd)
        let midEnergy = meanPower(lowEnd, midEnd)
        let upperEnergy = meanPower(midEnd, upperEnd)
        let highEnergy = meanPower(upperEnd, highEnd)

        // Loudness-independent, comparable view: each band's share of total
        // band power. A 1e-12 epsilon keeps ratios stable at silence.
        let totalPower = lowEnergy + midEnergy + upperEnergy + highEnergy + 1e-12
        let lowRatio = lowEnergy / totalPower
        let midRatio = midEnergy / totalPower
        let upperRatio = upperEnergy / totalPower
        let highRatio = highEnergy / totalPower

        // Broadband: how much of [broadbandLower, broadbandUpper) rose at once.
        let bbStart = bandLower(config.broadbandLowerHz)
        let bbEnd = bandUpper(config.broadbandUpperHz)
        var activeProportion: Float = 0
        var broadbandScore: Float = 0
        var flatness: Float = 0
        if bbEnd > bbStart {
            var maxPower: Float = 0
            var powerSum: Float = 0
            power.withUnsafeBufferPointer { p in
                guard let base = p.baseAddress else { return }
                let length = vDSP_Length(bbEnd - bbStart)
                vDSP_maxv(base + bbStart, 1, &maxPower, length)
                vDSP_sve(base + bbStart, 1, &powerSum, length)
            }
            let bandCount = bbEnd - bbStart
            let arithmeticMean = powerSum / Float(bandCount)

            var logSum: Float = 0
            var activeCount = 0
            for k in bbStart..<bbEnd {
                let pk = max(power[k], 1e-12)
                logSum += log(pk)
                if power[k] >= maxPower * config.broadbandRelativeThreshold {
                    activeCount += 1
                }
            }
            let geometricMean = exp(logSum / Float(bandCount))
            flatness = arithmeticMean > 0 ? geometricMean / arithmeticMean : 0

            if maxPower > 1e-9, rms >= config.silenceFloorRMS {
                let proportion = Float(activeCount) / Float(bandCount)
                activeProportion = proportion
                broadbandScore = normalized(
                    proportion,
                    lower: config.broadbandActiveMinProportion,
                    upper: config.broadbandActiveFullProportion
                )
            }
        }

        return BandAnalysis(
            lowEnergy: lowEnergy,
            midEnergy: midEnergy,
            upperEnergy: upperEnergy,
            highEnergy: highEnergy,
            lowRatio: lowRatio,
            midRatio: midRatio,
            upperRatio: upperRatio,
            highRatio: highRatio,
            broadbandActiveProportion: activeProportion,
            broadbandScore: broadbandScore,
            flatness: flatness
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