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

    func testSpeechLikeToneStaysBelowStrongBlow() {
        let detector = BlowDetector()
        let speech = sineWave(frequency: 220, amplitude: 0.16)

        let result = analyzeRepeatedly(speech, detector: detector)

        XCTAssertLessThan(result, BlowDetectionConfiguration.standard.strongBlowThreshold)
    }

    func testShortImpulseDoesNotRemainStrong() {
        let detector = BlowDetector()
        var impulse = [Float](repeating: 0, count: frameCount)
        impulse[frameCount / 2] = 1

        _ = detector.analyze(samples: impulse, sampleRate: sampleRate)
        let result = analyzeRepeatedly([Float](repeating: 0, count: frameCount), detector: detector)

        XCTAssertLessThan(result, 0.08)
    }

    func testContinuousWindProducesHighStableIntensity() {
        let detector = BlowDetector()
        let wind = deterministicNoise(amplitude: 0.22)

        let result = analyzeRepeatedly(wind, detector: detector, count: 18)

        XCTAssertGreaterThan(result, BlowDetectionConfiguration.standard.strongBlowThreshold)
    }

    private func analyzeRepeatedly(
        _ samples: [Float],
        detector: BlowDetector,
        count: Int = 12
    ) -> Float {
        var result: Float = 0
        for _ in 0..<count {
            result = detector.analyze(samples: samples, sampleRate: sampleRate)
        }
        return result
    }

    private func sineWave(frequency: Double, amplitude: Float) -> [Float] {
        (0..<frameCount).map { index in
            amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / sampleRate))
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
}
