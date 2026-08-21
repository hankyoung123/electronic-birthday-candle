import XCTest
@testable import BirthdayCandle

final class BlowDetectorTests: XCTestCase {
    private let sampleRate = 44_100.0
    private let frameCount = 2_048

    func testSilenceProducesLowVisualIntensity() {
        let detector = BlowDetector()
        let result = feed([Float](repeating: 0, count: frameCount), detector: detector, count: 12)
        XCTAssertLessThan(result, 0.03)
    }

    func testLowFrequencyWindProducesVisibleIntensity() {
        let detector = BlowDetector()
        let result = feed(windLikeSignal(amplitude: 0.16), detector: detector, count: 16)
        XCTAssertGreaterThan(result, 0.6)
    }

    func testStrongerWindProducesMoreVisualIntensity() {
        let light = BlowDetector()
        let strong = BlowDetector()
        let lightResult = feed(windLikeSignal(amplitude: 0.02), detector: light, count: 10)
        let strongResult = feed(windLikeSignal(amplitude: 0.08), detector: strong, count: 10)
        XCTAssertGreaterThan(strongResult, lightResult)
    }

    func testHighFrequencyNoiseProducesLessIntensityThanWind() {
        let wind = BlowDetector()
        let high = BlowDetector()
        let windResult = feed(windLikeSignal(amplitude: 0.12), detector: wind, count: 12)
        let highResult = feed(highFrequencyNoise(amplitude: 0.12), detector: high, count: 12)
        XCTAssertGreaterThan(windResult, highResult)
    }

    func testMidFrequencyToneProducesLowVisualIntensity() {
        let detector = BlowDetector()
        let result = feed(sineWave(frequency: 1_000, amplitude: 0.5), detector: detector, count: 16)
        XCTAssertLessThan(result, 0.15)
    }

    func testVisualIntensityDecaysAfterImpulse() {
        let detector = BlowDetector()
        var impulse = [Float](repeating: 0, count: frameCount)
        impulse[frameCount / 2] = 1
        _ = feed(impulse, detector: detector, count: 1)
        _ = feed([Float](repeating: 0, count: frameCount), detector: detector, count: 30)
        XCTAssertLessThan(detector.currentIntensity, 0.05)
    }

    func testWindBandRMSGrowsWithWindLevel() {
        let light = debugSnapshot(for: windLikeSignal(amplitude: 0.04))
        let strong = debugSnapshot(for: windLikeSignal(amplitude: 0.16))
        XCTAssertGreaterThan(strong.windBandRMS, light.windBandRMS)
        XCTAssertLessThanOrEqual(strong.windBandRMS, strong.rms + 0.0001)
    }

    func testDbFSForHalfScaleSineIsAboutMinusNine() {
        let snapshot = debugSnapshot(for: sineWave(frequency: 1_000, amplitude: 0.5))
        XCTAssertEqual(snapshot.dbFS, -9.0, accuracy: 1.2)
    }

    func testSilenceNeverProducesNonFiniteDebugValues() {
        let snapshot = debugSnapshot(for: [Float](repeating: 0, count: frameCount))
        XCTAssertTrue(snapshot.rms.isFinite)
        XCTAssertTrue(snapshot.dbFS.isFinite)
        XCTAssertTrue(snapshot.windBandRMS.isFinite)
        XCTAssertTrue(snapshot.visualIntensity.isFinite)
    }

    @discardableResult
    private func feed(_ samples: [Float], detector: BlowDetector, count: Int) -> Float {
        var result: Float = 0
        for _ in 0..<count {
            result = samples.withUnsafeBufferPointer {
                detector.analyze(samples: $0, sampleRate: sampleRate)
            }
        }
        return result
    }

    private func debugSnapshot(for signal: [Float]) -> BlowDebugSnapshot {
        let detector = BlowDetector()
        signal.withUnsafeBufferPointer {
            _ = detector.analyze(samples: $0, sampleRate: sampleRate)
        }
        return detector.currentDebugSnapshot
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

    private func windLikeSignal(amplitude: Float) -> [Float] {
        let noise = deterministicNoise(amplitude: 1)
        var output = [Float](repeating: 0, count: noise.count)
        var previous: Float = 0
        for index in noise.indices {
            previous += 0.07 * (noise[index] - previous)
            output[index] = previous
        }
        let rms = sqrt(output.reduce(0) { $0 + $1 * $1 } / Float(output.count))
        guard rms > 0 else { return output }
        return output.map { $0 * amplitude / rms }
    }

    private func highFrequencyNoise(amplitude: Float) -> [Float] {
        let noise = deterministicNoise(amplitude: amplitude)
        var previous: Float = 0
        return noise.map { sample in
            previous += 0.12 * (sample - previous)
            return sample - previous
        }
    }
}
