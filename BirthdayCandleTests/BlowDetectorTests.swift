import XCTest
@testable import BirthdayCandle

final class BlowDetectorTests: XCTestCase {
    private let sampleRate = 44_100.0
    private let frameCount = 2_048

    // MARK: - Structural / feature tests

    func testSilenceProducesLowIntensity() {
        let detector = BlowDetector()
        silence(detector: detector, count: 14)
        XCTAssertLessThan(detector.currentIntensity, 0.03)
    }

    func testBandRatiosSumToOne() {
        for snapshot in [
            debugSnapshot(forSignal: deterministicNoise(amplitude: 0.18)),
            debugSnapshot(forSignal: speechLikeSignal()),
        ] {
            let sum = snapshot.lowRatio + snapshot.midRatio
                + snapshot.upperRatio + snapshot.highRatio
            XCTAssertEqual(sum, 1.0, accuracy: 0.02)
        }
    }

    func testLowFrequencyToneConcentratesInLowBand() {
        let snapshot = debugSnapshot(forSignal: sineWave(frequency: 150, amplitude: 0.5))

        XCTAssertGreaterThan(snapshot.lowRatio, 0.5)
        XCTAssertGreaterThan(snapshot.lowRatio, snapshot.midRatio)
        XCTAssertGreaterThan(snapshot.lowRatio, snapshot.upperRatio)
        XCTAssertGreaterThan(snapshot.lowRatio, snapshot.highRatio)
    }

    func testHighFrequencyToneConcentratesInHighBand() {
        let snapshot = debugSnapshot(forSignal: sineWave(frequency: 4_000, amplitude: 0.5))

        XCTAssertGreaterThan(snapshot.highRatio, snapshot.upperRatio)
        XCTAssertGreaterThan(snapshot.highRatio, snapshot.midRatio)
    }

    func testDbFSForHalfScaleSineIsAboutMinusNine() {
        let snapshot = debugSnapshot(forSignal: sineWave(frequency: 1_000, amplitude: 0.5))

        XCTAssertEqual(snapshot.dbFS, -9.0, accuracy: 1.2)
    }

    /// A short loud impulse spikes the score but the release smoothing pulls it
    /// back down (and CeremonySession's temporal confirmation rejects it).
    func testShortImpulseDoesNotRemainStrong() {
        let detector = BlowDetector()
        silence(detector: detector, count: 5)
        var impulse = [Float](repeating: 0, count: frameCount)
        impulse[frameCount / 2] = 1
        impulse.withUnsafeBufferPointer { b in
            _ = detector.analyze(samples: b, sampleRate: sampleRate)
        }
        silence(detector: detector, count: 6)

        XCTAssertLessThan(detector.currentIntensity, 0.20)
    }

    // MARK: - Adaptive baseline: steady inputs must NOT trigger

    func testSteadyMusicDoesNotTrigger() {
        let detector = BlowDetector()
        let music = musicLikeSignal(sampleRate: sampleRate)

        let result = feed(music, detector: detector, count: 60)

        XCTAssertLessThan(result, BlowDetectionConfiguration.standard.strongBlowThreshold)
    }

    func testSteadyNoiseDoesNotTrigger() {
        let detector = BlowDetector()
        let noise = deterministicNoise(amplitude: 0.18)

        // Quiet/steady broadband noise is absorbed into the baseline — the
        // exact case the old absolute-energy model got wrong.
        let result = feed(noise, detector: detector, count: 60)

        XCTAssertLessThan(result, BlowDetectionConfiguration.standard.strongBlowThreshold)
    }

    func testHarmonicVoiceToneDoesNotTrigger() {
        let detector = BlowDetector()
        let speech = speechLikeSignal()

        let result = feed(speech, detector: detector, count: 60)

        XCTAssertLessThan(result, BlowDetectionConfiguration.standard.strongBlowThreshold)
    }

    // MARK: - Adaptive baseline: blow over an established ambient must trigger

    func testWindOverSilenceTriggers() {
        let detector = BlowDetector()
        silence(detector: detector, count: 20)
        let wind = windLikeSignal(amplitude: 0.18)

        let result = feed(wind, detector: detector, count: 4)

        XCTAssertGreaterThan(result, BlowDetectionConfiguration.standard.strongBlowThreshold)
    }

    func testWindOverMusicTriggers() {
        let detector = BlowDetector()
        let music = musicLikeSignal(sampleRate: sampleRate)
        _ = feed(music, detector: detector, count: 60) // ambient = birthday music
        // Mouth at the mic, music faded on the speaker: the low/mid breath
        // clearly dominates the ambient.
        let overMusic = mix(music, windLikeSignal(amplitude: 0.25))

        let result = feed(overMusic, detector: detector, count: 4)

        XCTAssertGreaterThan(result, BlowDetectionConfiguration.standard.strongBlowThreshold)
    }

    func testSustainedWindDoesNotGetAbsorbedByBaseline() {
        let detector = BlowDetector()
        silence(detector: detector, count: 20)
        let wind = windLikeSignal(amplitude: 0.18)

        // Blow for a long stretch: the frozen baseline must not swallow it.
        let result = feed(wind, detector: detector, count: 60)

        XCTAssertGreaterThan(result, BlowDetectionConfiguration.standard.strongBlowThreshold)
    }

    func testMusicVolumeStepOnlyCausesTransient() {
        let detector = BlowDetector()
        // Modest (+2.5 dB) step: a small rise absorbed by the baseline, never
        // reaching the start threshold. (A large, sustained step is a known
        // device-tuning limitation — see docs.)
        let quietMusic = musicLikeSignal(sampleRate: sampleRate, amplitude: 0.75)
        let loudMusic = musicLikeSignal(sampleRate: sampleRate, amplitude: 1.0)
        _ = feed(quietMusic, detector: detector, count: 50)
        let peakDuringStep = trackPeak(loudMusic, detector: detector, count: 12)
        let result = feed(loudMusic, detector: detector, count: 100)

        XCTAssertLessThan(peakDuringStep, BlowDetectionConfiguration.standard.strongBlowThreshold)
        XCTAssertLessThan(result, 0.10)
    }

    func testBaselineConvergesAfterEnvironmentChange() {
        let detector = BlowDetector()
        // Detection always starts with the ambient already present (frame 1
        // seeds the baseline), exactly like the app: candle lit, environment on.
        let quiet = deterministicNoise(amplitude: 0.04)
        _ = feed(quiet, detector: detector, count: 40)
        // A modest (+~2 dB) ambient change: the baseline must re-converge and
        // the deltas must return near zero.
        let louder = deterministicNoise(amplitude: 0.05)
        _ = feed(louder, detector: detector, count: 80)

        XCTAssertLessThan(detector.currentIntensity, 0.25) // stayed sub-candidate
        let snapshot = detector.currentDebugSnapshot
        XCTAssertLessThan(abs(snapshot.totalDeltaDB), 2.0)
        XCTAssertLessThan(abs(snapshot.baselineDbFS - snapshot.dbFS), 2.0)
    }

    func testLowMidDeltaDominatesWind() {
        let detector = BlowDetector()
        silence(detector: detector, count: 20)
        let wind = windLikeSignal(amplitude: 0.18)
        _ = feed(wind, detector: detector, count: 3)

        let snapshot = detector.currentDebugSnapshot
        // Breath is low/mid-dominant (the high band is not even scored).
        XCTAssertGreaterThan(snapshot.lowDeltaDB, snapshot.upperDeltaDB)
        XCTAssertGreaterThan(snapshot.midDeltaDB, snapshot.upperDeltaDB)
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

    func testBaselineDoesNotUpdateWhileCandidateBlowIsActive() {
        let detector = BlowDetector()
        silence(detector: detector, count: 20)
        let baselineBefore = detector.currentDebugSnapshot.baselineDbFS
        let wind = windLikeSignal(amplitude: 0.18)
        _ = feed(wind, detector: detector, count: 1)

        let baselineAfter = detector.currentDebugSnapshot.baselineDbFS
        XCTAssertEqual(baselineAfter, baselineBefore, accuracy: 0.1)
        XCTAssertGreaterThan(detector.currentIntensity, 0.20) // candidate active
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

    /// Feeds the signal and returns the peak currentIntensity reached.
    private func trackPeak(
        _ samples: [Float],
        detector: BlowDetector,
        count: Int
    ) -> Float {
        var peak: Float = 0
        for _ in 0..<count {
            let value = samples.withUnsafeBufferPointer { b in
                detector.analyze(samples: b, sampleRate: sampleRate)
            }
            peak = max(peak, value)
        }
        return peak
    }

    private func silence(detector: BlowDetector, count: Int) {
        feed([Float](repeating: 0, count: frameCount), detector: detector, count: count)
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

    private func speechLikeSignal() -> [Float] {
        mix(
            sineWave(frequency: 180, amplitude: 0.05, sampleRate: sampleRate),
            sineWave(frequency: 360, amplitude: 0.022, sampleRate: sampleRate),
            sineWave(frequency: 720, amplitude: 0.012, sampleRate: sampleRate),
            sineWave(frequency: 2_400, amplitude: 0.006, sampleRate: sampleRate)
        )
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

    /// Breath-like noise with a low-pass tilt: strongest 200–500 Hz, rolling
    /// off through 2 kHz — so low/mid dominate the deltas.
    private func windLikeSignal(amplitude: Float) -> [Float] {
        let noise = deterministicNoise(amplitude: 1)
        var output = [Float](repeating: 0, count: noise.count)
        var previous: Float = 0
        for index in 0..<noise.count {
            previous += 0.12 * (noise[index] - previous)
            output[index] = previous
        }
        var sumSquares: Float = 0
        for sample in output { sumSquares += sample * sample }
        let rms = sqrt(sumSquares / Float(output.count))
        guard rms > 0 else { return output }
        let scale = amplitude / rms
        return output.map { $0 * scale }
    }
}