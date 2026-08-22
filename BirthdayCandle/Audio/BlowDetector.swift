import Accelerate
import Foundation

#if DEBUG
/// Full-frame diagnostics for the Inspector: raw levels, the wind band features
/// (power / RMS / ratio) and the two additive sub-scores.
struct BlowDebugSnapshot: Sendable {
    let rms: Float
    let dbFS: Float
    let windBandPower: Float
    let windBandRMS: Float
    let windRatio: Float
    let windEnergyScore: Float
    let windRatioScore: Float
    let rawScore: Float
    let smoothedIntensity: Float

    static let zero = BlowDebugSnapshot(
        rms: 0,
        dbFS: -120,
        windBandPower: 0,
        windBandRMS: 0,
        windRatio: 0,
        windEnergyScore: 0,
        windRatioScore: 0,
        rawScore: 0,
        smoothedIntensity: 0
    )
}
#endif

/// Per-frame wind measurements (also used in Release — they ARE the detector).
private struct WindAnalysis {
    let windBandPower: Float
    let windBandRMS: Float
    let windRatio: Float
}

/// Low-frequency wind detector (the proven design). iOS Voice Processing / AEC
/// is expected to have removed our own music from the mic beforehand; this
/// detector scores the residual low-frequency airflow that a real breath
/// produces. Wind energy is the primary feature, wind ratio a soft shape check.
///
/// No silence hard-gate: low volume naturally maps to ~0 through `windStart`.
/// Fully additive, single path, no adaptive baseline / delta / broadband.
final class BlowDetector: @unchecked Sendable {
    private let configuration: BlowDetectionConfiguration
    private let lock = NSLock()
    private var smoothedIntensity: Float = 0
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
    private let powerEpsilon: Float = 1e-12

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
        let totalRMS = sqrt(sumSquares / Float(samples.count))

        let wind = analyzeWind(samples, sampleRate: sampleRate, totalRMS: totalRMS, config: config)

        // Low energy naturally maps to ~0 through the wind thresholds; no hard
        // silence gate that could blank a frame when Voice Processing briefly
        // suppresses the RMS.
        let windEnergyScore = normalized(wind.windBandRMS, lower: config.windStart, upper: config.windFull)
        let windRatioScore = normalized(wind.windRatio, lower: config.windRatioStart, upper: config.windRatioFull)

        // Additive only — no conjunctions, no energy × ratio product.
        let rawScore = min(
            max(
                config.energyWeight * windEnergyScore + config.ratioWeight * windRatioScore,
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
                rms: totalRMS,
                dbFS: totalRMS > 0 ? max(-120, 20 * log10(totalRMS)) : -120,
                windBandPower: wind.windBandPower,
                windBandRMS: wind.windBandRMS,
                windRatio: wind.windRatio,
                windEnergyScore: windEnergyScore,
                windRatioScore: windRatioScore,
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

    // MARK: - Wind-band analysis

    private func analyzeWind(
        _ samples: UnsafeBufferPointer<Float>,
        sampleRate: Double,
        totalRMS: Float,
        config: BlowDetectionParameters
    ) -> WindAnalysis {
        let n = spectrumFFTSize
        ensureFFTScratch(fftSize: n)
        guard let setup = fftSetup else {
            return WindAnalysis(windBandPower: 0, windBandRMS: 0, windRatio: 0)
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
        let totalBins = n / 2
        let windStartBin = max(1, Int((config.windBandLowerHz / binWidth).rounded(.down)))
        let windEndBin = min(totalBins, Int((config.windBandUpperHz / binWidth).rounded(.down)))
        let refEndBin = min(totalBins, Int((config.referenceBandUpperHz / binWidth).rounded(.down)))

        func bandSum(_ start: Int, _ end: Int) -> Float {
            guard end > start else { return 0 }
            var sum: Float = 0
            power.withUnsafeBufferPointer { p in
                guard let base = p.baseAddress else { return }
                vDSP_sve(base + start, 1, &sum, vDSP_Length(end - start))
            }
            return sum
        }

        let windBandPower = bandSum(windStartBin, windEndBin)
        let referenceBandPower = bandSum(windStartBin, refEndBin)
        let totalBandPower = bandSum(1, totalBins)

        // Wind-band RMS, directly comparable to the time-domain total RMS
        // (Parseval): bandRMS = totalRMS × √(bandShare). The share is computed
        // within a single FFT frame, so windowing cancels out.
        let bandShare = windBandPower / (totalBandPower + powerEpsilon)
        let scaledShare = min(bandShare, 1)
        let windBandRMS = sqrt(scaledShare) * totalRMS

        let windRatio = windBandPower / (referenceBandPower + powerEpsilon)

        return WindAnalysis(
            windBandPower: windBandPower,
            windBandRMS: windBandRMS,
            windRatio: windRatio
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