import XCTest
@testable import BirthdayCandle

final class BlowDetectorTests: XCTestCase {
    private let sampleRate = 44_100.0
    private let frameCount = 2_048

    func testSilenceProducesLowIntensity() {
        let detector = BlowDetector()
        let silence = [Float](repeating: 0, count: frameCount)

        let result = analyzeRepeatedly(silence, detector: detector)

        XCTAssertLessThan(result, 0.03)
    }

    func testSpeechLikeToneStaysLowAcrossCommonSampleRates() {
        let results = [44_100.0, 48_000.0].map { sampleRate in
            analyzeRepeatedly(
                speechLikeSignal(sampleRate: sampleRate),
                detector: BlowDetector(),
                sampleRate: sampleRate
            )
        }

        for result in results {
            XCTAssertLessThan(result, BlowDetectionConfiguration.standard.strongBlowThreshold)
        }
        XCTAssertEqual(results[0], results[1], accuracy: 0.08)
    }

    func testShortImpulseDoesNotRemainStrong() {
        let detector = BlowDetector()
        var impulse = [Float](repeating: 0, count: frameCount)
        impulse[frameCount / 2] = 1

        impulse.withUnsafeBufferPointer { samples in
            _ = detector.analyze(samples: samples, sampleRate: sampleRate)
        }
        let result = analyzeRepeatedly([Float](repeating: 0, count: frameCount), detector: detector)

        XCTAssertLessThan(result, 0.08)
    }

    func testContinuousWindProducesHighStableIntensity() {
        let detector = BlowDetector()
        let wind = deterministicNoise(amplitude: 0.22)

        let result = analyzeRepeatedly(wind, detector: detector, count: 18)

        XCTAssertGreaterThan(result, BlowDetectionConfiguration.standard.strongBlowThreshold)
    }

    func testFluctuatingWindStillProducesHighStableIntensity() {
        let detector = BlowDetector()
        let wind = fluctuatingWind(peakAmplitude: 0.26)

        let result = analyzeRepeatedly(wind, detector: detector, count: 18)

        XCTAssertGreaterThan(result, BlowDetectionConfiguration.standard.strongBlowThreshold)
    }

    func testWindIntensityIsStableAcrossCommonSampleRates() {
        let wind44 = deterministicNoise(amplitude: 0.11)
        let wind48 = deterministicNoise(amplitude: 0.11)

        let result44 = analyzeRepeatedly(
            wind44,
            detector: BlowDetector(),
            sampleRate: 44_100
        )
        let result48 = analyzeRepeatedly(
            wind48,
            detector: BlowDetector(),
            sampleRate: 48_000
        )

        XCTAssertEqual(result44, result48, accuracy: 0.08)
    }

    func testMusicLikeSignalStaysBelowStrongBlow() {
        let sampleRate = 48_000.0
        let music = musicLikeSignal(sampleRate: sampleRate)

        let result = analyzeRepeatedly(
            music,
            detector: BlowDetector(),
            sampleRate: sampleRate
        )

        XCTAssertLessThan(result, BlowDetectionConfiguration.standard.strongBlowThreshold)
    }

    func testMusicWithWeakNoiseStaysBelowStrongBlow() {
        let sampleRate = 48_000.0
        let signal = mix(
            musicLikeSignal(sampleRate: sampleRate),
            deterministicNoise(amplitude: 0.018)
        )

        let result = analyzeRepeatedly(
            signal,
            detector: BlowDetector(),
            sampleRate: sampleRate,
            count: 18
        )

        XCTAssertLessThan(result, BlowDetectionConfiguration.standard.strongBlowThreshold)
    }

    func testMusicWithStrongWindExceedsStrongBlowThreshold() {
        let sampleRate = 48_000.0
        let signal = mix(
            musicLikeSignal(sampleRate: sampleRate),
            deterministicNoise(amplitude: 0.22)
        )

        let result = analyzeRepeatedly(
            signal,
            detector: BlowDetector(),
            sampleRate: sampleRate,
            count: 18
        )

        XCTAssertGreaterThan(result, BlowDetectionConfiguration.standard.strongBlowThreshold)
    }

    private func analyzeRepeatedly(
        _ samples: [Float],
        detector: BlowDetector,
        sampleRate: Double? = nil,
        count: Int = 12
    ) -> Float {
        var result: Float = 0
        for _ in 0..<count {
            result = samples.withUnsafeBufferPointer { buffer in
                detector.analyze(samples: buffer, sampleRate: sampleRate ?? self.sampleRate)
            }
        }
        return result
    }

    private func sineWave(
        frequency: Double,
        amplitude: Float,
        sampleRate: Double? = nil
    ) -> [Float] {
        let sampleRate = sampleRate ?? self.sampleRate
        return (0..<frameCount).map { index in
            amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / sampleRate))
        }
    }

    private func speechLikeSignal(sampleRate: Double) -> [Float] {
        mix(
            sineWave(frequency: 180, amplitude: 0.11, sampleRate: sampleRate),
            sineWave(frequency: 360, amplitude: 0.045, sampleRate: sampleRate),
            sineWave(frequency: 720, amplitude: 0.018, sampleRate: sampleRate)
        )
    }

    private func musicLikeSignal(sampleRate: Double) -> [Float] {
        let tones = mix(
            sineWave(frequency: 262, amplitude: 0.10, sampleRate: sampleRate),
            sineWave(frequency: 330, amplitude: 0.075, sampleRate: sampleRate),
            sineWave(frequency: 392, amplitude: 0.065, sampleRate: sampleRate),
            sineWave(frequency: 1_048, amplitude: 0.025, sampleRate: sampleRate)
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

    private func fluctuatingWind(peakAmplitude: Float) -> [Float] {
        let noise = deterministicNoise(amplitude: 1)
        return noise.enumerated().map { index, sample in
            let progress = Double(index) / Double(frameCount)
            let envelope = Float(0.35 + 0.65 * abs(sin(2 * Double.pi * 2.3 * progress)))
            return sample * envelope * peakAmplitude
        }
    }
}
