import XCTest
@testable import BirthdayCandle

final class BlowDetectorTests: XCTestCase {
    private let sampleRate = 44_100.0
    private let frameCount = 2_048

    func testSilenceProducesLowIntensity() {
        let detector = BlowDetector()
        let result = feed([Float](repeating: 0, count: frameCount), detector: detector, count: 12)
        XCTAssertLessThan(result, 0.03)
    }

    /// A real breath = low-frequency airflow: the direct 80–500 Hz band RMS
    /// lights up and the wind ratio is high → clear score.
    func testLowFrequencyWindProducesHighScore() {
        let detector = BlowDetector()
        let wind = windLikeSignal(amplitude: 0.16)
        let result = feed(wind, detector: detector, count: 16)
        XCTAssertGreaterThan(result, BlowDetectionConfiguration.standard.strongBlowThreshold)
    }

    /// Light wind produces a clearly visible (flame-response) score without
    /// being deaf or at full scale.
    func testLightWindProducesUsefulScore() {
        let detector = BlowDetector()
        let wind = windLikeSignal(amplitude: 0.05)
        let result = feed(wind, detector: detector, count: 16)
        XCTAssertGreaterThan(result, 0.15)
        XCTAssertLessThan(result, 1.0)
    }

    /// A brief dip in the signal must not collapse the (smoothed) wind score.
    func testWindScoreSurvivesShortSignalDrop() {
        let detector = BlowDetector()
        let wind = windLikeSignal(amplitude: 0.16)
        _ = feed(wind, detector: detector, count: 10)
        let steady = detector.currentIntensity

        _ = feed([Float](repeating: 0, count: frameCount), detector: detector, count: 2)
        let dipped = detector.currentIntensity
        XCTAssertGreaterThan(dipped, steady * 0.5)

        _ = feed(wind, detector: detector, count: 4)
        let recovered = detector.currentIntensity
        XCTAssertGreaterThan(recovered, steady * 0.8)
    }

    /// High-frequency-only sound carries almost no 80–500 Hz energy → low score.
    func testHighFrequencySoundDoesNotTrigger() {
        let detector = BlowDetector()
        let high = highFrequencyNoise(amplitude: 0.3)
        let result = feed(high, detector: detector, count: 16)
        XCTAssertLessThan(result, BlowDetectionConfiguration.standard.strongBlowThreshold)
    }

    /// A loud mid-frequency tone is not wind → must not trigger.
    func testMidFrequencyToneDoesNotTrigger() {
        let detector = BlowDetector()
        let tone = sineWave(frequency: 1_000, amplitude: 0.5)
        let result = feed(tone, detector: detector, count: 16)
        XCTAssertLessThan(result, BlowDetectionConfiguration.standard.strongBlowThreshold)
    }

    /// The soft shape check: wind concentrates below 500 Hz, so its wind ratio
    /// is clearly higher than flat/white noise spread up to 5 kHz.
    func testWindRatioIncreasesForWindLikeSignal() {
        let wind = debugSnapshot(forSignal: windLikeSignal(amplitude: 0.16))
        let noise = debugSnapshot(forSignal: deterministicNoise(amplitude: 0.16))
        XCTAssertGreaterThan(wind.windRatio, 0.5)
        XCTAssertGreaterThan(wind.windRatio, noise.windRatio)
    }

    /// The band-passed 80–500 Hz RMS grows with louder wind and stays bounded
    /// by the total RMS.
    func testWindBandRMSGrowsWithWindLevel() {
        let light = debugSnapshot(forSignal: windLikeSignal(amplitude: 0.08))
        let strong = debugSnapshot(forSignal: windLikeSignal(amplitude: 0.22))
        XCTAssertGreaterThan(strong.windBandRMS, light.windBandRMS)
        XCTAssertLessThanOrEqual(strong.windBandRMS, strong.rms + 0.0001)
    }

    /// A short impulse spikes but release smoothing pulls it back quickly.
    func testShortImpulseDoesNotRemainStrong() {
        let detector = BlowDetector()
        var impulse = [Float](repeating: 0, count: frameCount)
        impulse[frameCount / 2] = 1
        impulse.withUnsafeBufferPointer { b in
            _ = detector.analyze(samples: b, sampleRate: sampleRate)
        }
        _ = feed([Float](repeating: 0, count: frameCount), detector: detector, count: 6)
        XCTAssertLessThan(detector.currentIntensity, 0.20)
    }

    func testDbFSForHalfScaleSineIsAboutMinusNine() {
        let snapshot = debugSnapshot(forSignal: sineWave(frequency: 1_000, amplitude: 0.5))
        XCTAssertEqual(snapshot.dbFS, -9.0, accuracy: 1.2)
    }

    func testSilenceNeverProducesNaN() {
        let detector = BlowDetector()
        _ = feed([Float](repeating: 0, count: frameCount), detector: detector, count: 10)
        let values = Mirror(reflecting: detector.currentDebugSnapshot).children
            .compactMap { $0.value as? Float }
        for value in values where !value.isFinite {
            XCTFail("non-finite snapshot value: \(value)")
        }
    }

    // MARK: - Helpers

    @discardableResult
    private func feed(
        _ samples: [Float],
        detector: BlowDetector,
        count: Int,
        sampleRate: Double? = nil
    ) -> Float {
        var result: Float = 0
        let sr = sampleRate ?? self.sampleRate
        for _ in 0..<count {
            result = samples.withUnsafeBufferPointer { b in
                detector.analyze(samples: b, sampleRate: sr)
            }
        }
        return result
    }

    private func debugSnapshot(
        forSignal signal: [Float],
        sampleRate: Double = 44_100
    ) -> BlowDebugSnapshot {
        let detector = BlowDetector()
        signal.withUnsafeBufferPointer { b in
            _ = detector.analyze(samples: b, sampleRate: sampleRate)
        }
        return detector.currentDebugSnapshot
    }

    private func sineWave(
        frequency: Double,
        amplitude: Float,
        sampleRate: Double? = nil
    ) -> [Float] {
        let sr = sampleRate ?? self.sampleRate
        return (0..<frameCount).map { i in
            amplitude * Float(sin(2 * Double.pi * frequency * Double(i) / sr))
        }
    }

    private func musicLikeSignal(sampleRate: Double, amplitude: Float = 1.0) -> [Float] {
        let tones = mix(
            sineWave(frequency: 262, amplitude: 0.06 * amplitude, sampleRate: sampleRate),
            sineWave(frequency: 330, amplitude: 0.045 * amplitude, sampleRate: sampleRate),
            sineWave(frequency: 392, amplitude: 0.04 * amplitude, sampleRate: sampleRate),
            sineWave(frequency: 1_048, amplitude: 0.015 * amplitude, sampleRate: sampleRate)
        )
        return tones.enumerated().map { index, sample in
            let time = Double(index) / sampleRate
            let envelope = Float(0.78 + 0.22 * sin(2 * Double.pi * 3.2 * time))
            return sample * envelope
        }
    }

    private func mix(_ signals: [Float]...) -> [Float] {
        (0..<frameCount).map { index in
            min(max(signals.reduce(0) { $0 + $1[index] }, -1), 1)
        }
    }

    private func deterministicNoise(amplitude: Float) -> [Float] {
        var state: UInt64 = 0x9E3779B97F4A7C15
        return (0..<frameCount).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let unit = Float((state >> 40) & 0xFFFF) / Float(0xFFFF)
            return (unit * 2 - 1) * amplitude
        }
    }

    /// Breath-like, low-passed noise with a steep tilt: most energy below
    /// ~450 Hz — the strongest 80–500 Hz airflow signature.
    private func windLikeSignal(amplitude: Float) -> [Float] {
        let noise = deterministicNoise(amplitude: 1)
        var output = [Float](repeating: 0, count: noise.count)
        var previous: Float = 0
        for index in 0..<noise.count {
            previous += 0.07 * (noise[index] - previous)
            output[index] = previous
        }
        var sumSquares: Float = 0
        for sample in output { sumSquares += sample * sample }
        let rms = sqrt(sumSquares / Float(output.count))
        guard rms > 0 else { return output }
        let scale = amplitude / rms
        return output.map { $0 * scale }
    }

    /// High-frequency noise: white noise with the low band removed.
    private func highFrequencyNoise(amplitude: Float) -> [Float] {
        let noise = deterministicNoise(amplitude: amplitude)
        var low = [Float](repeating: 0, count: noise.count)
        var previous: Float = 0
        for index in 0..<noise.count {
            previous += 0.12 * (noise[index] - previous)
            low[index] = previous
        }
        return zip(noise, low).map { $0 - $1 }
    }
}
