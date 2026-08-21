import Accelerate
import Foundation

#if DEBUG
/// Full-frame diagnostics for the Inspector: levels, the direct wind-band RMS,
/// the FFT wind ratio, and the two additive sub-scores.
struct BlowDebugSnapshot: Sendable {
    let rms: Float
    let dbFS: Float
    let windBandRMS: Float
    let windRatio: Float
    let windEnergyScore: Float
    let windRatioScore: Float
    let rawScore: Float
    let smoothedIntensity: Float

    static let zero = BlowDebugSnapshot(
        rms: 0,
        dbFS: -120,
        windBandRMS: 0,
        windRatio: 0,
        windEnergyScore: 0,
        windRatioScore: 0,
        rawScore: 0,
        smoothedIntensity: 0
    )
}
#endif

/// Second-order biquad (RBJ cookbook, Direct Form I) used to band-pass the mic
/// PCM into the 80–500 Hz wind band before computing its RMS.
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

/// Low-frequency wind detector.
///
/// iOS AEC / echo-cancelled input is expected to have removed our own music
/// from the mic beforehand. This detector scores the residual 80–500 Hz airflow:
/// a direct time-domain band-pass calculates `windBandRMS`, and the FFT wind
/// ratio is a soft shape check. Fully additive, no adaptive baseline, no
/// absolute-silence hard gate (low energy is handled by the wind thresholds).
final class BlowDetector: @unchecked Sendable {
    private let configuration: BlowDetectionConfiguration
    private let lock = NSLock()
    private var smoothedIntensity: Float = 0
    #if DEBUG
    private var debugSnapshot: BlowDebugSnapshot = .zero
    #endif

    // Reused band-pass filters (re-derived when sample rate changes).
    private var bandPassSampleRate: Double = 0
    private var bandPassLowStages: [Biquad] = []
    private var bandPassHighStages: [Biquad] = []

    // Reused FFT scratch (wind ratio only).
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

        let windBandRMS = bandPassedWindRMS(samples, sampleRate: sampleRate, config: config)
        let windRatio = fftWindRatio(samples, sampleRate: sampleRate, config: config)

        // Low-volume control lives entirely in the wind thresholds: at silence
        // the band-passed RMS is ~0 so both sub-scores are ~0 already.
        let windEnergyScore = normalized(windBandRMS, lower: config.windStart, upper: config.windFull)
        let windRatioScore = normalized(windRatio, lower: config.windRatioStart, upper: config.windRatioFull)

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
                windBandRMS: windBandRMS,
                windRatio: windRatio,
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
            bandPassLowStages = []
            bandPassHighStages = []
            bandPassSampleRate = 0
            #if DEBUG
            debugSnapshot = .zero
            #endif
        }
    }

    private func normalized(_ value: Float, lower: Float, upper: Float) -> Float {
        guard upper > lower else { return 0 }
        return min(max((value - lower) / (upper - lower), 0), 1)
    }

    // MARK: - Direct band-pass wind RMS

    private func bandPassedWindRMS(
        _ samples: UnsafeBufferPointer<Float>,
        sampleRate: Double,
        config: BlowDetectionParameters
    ) -> Float {
        guard ensureBandPass(sampleRate: sampleRate, config: config) else { return 0 }

        let count = min(samples.count, spectrumFFTSize)
        var sumSquares: Float = 0
        for index in 0..<count {
            // 6th-order edges (−36 dB/oct): independent biquads per edge so a
            // mid/upper tone is properly rejected from the 80–500 Hz wind band.
            var value = samples[index]
            for stage in bandPassHighStages.indices {
                value = bandPassHighStages[stage].process(value)
            }
            for stage in bandPassLowStages.indices {
                value = bandPassLowStages[stage].process(value)
            }
            sumSquares += value * value
        }
        return sqrt(sumSquares / Float(count))
    }

    private func ensureBandPass(sampleRate: Double, config: BlowDetectionParameters) -> Bool {
        guard bandPassSampleRate != sampleRate || bandPassLowStages.isEmpty else {
            return !bandPassLowStages.isEmpty && !bandPassHighStages.isEmpty
        }
        bandPassSampleRate = sampleRate
        bandPassLowStages = [
            Biquad(kind: .lowPass, cutoffHz: config.windBandUpperHz, sampleRate: sampleRate),
            Biquad(kind: .lowPass, cutoffHz: config.windBandUpperHz, sampleRate: sampleRate),
            Biquad(kind: .lowPass, cutoffHz: config.windBandUpperHz, sampleRate: sampleRate),
        ]
        bandPassHighStages = [
            Biquad(kind: .highPass, cutoffHz: config.windBandLowerHz, sampleRate: sampleRate),
            Biquad(kind: .highPass, cutoffHz: config.windBandLowerHz, sampleRate: sampleRate),
            Biquad(kind: .highPass, cutoffHz: config.windBandLowerHz, sampleRate: sampleRate),
        ]
        return true
    }

    // MARK: - FFT wind ratio

    private func fftWindRatio(
        _ samples: UnsafeBufferPointer<Float>,
        sampleRate: Double,
        config: BlowDetectionParameters
    ) -> Float {
        let n = spectrumFFTSize
        ensureFFTScratch(fftSize: n)
        guard let setup = fftSetup else { return 0 }

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

        var windPower: Float = 0
        var refPower: Float = 0
        power.withUnsafeBufferPointer { p in
            guard let base = p.baseAddress else { return }
            if windEndBin > windStartBin {
                vDSP_sve(base + windStartBin, 1, &windPower, vDSP_Length(windEndBin - windStartBin))
            }
            if refEndBin > windStartBin {
                vDSP_sve(base + windStartBin, 1, &refPower, vDSP_Length(refEndBin - windStartBin))
            }
        }
        return windPower / (refPower + powerEpsilon)
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