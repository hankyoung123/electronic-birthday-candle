import XCTest
@testable import BirthdayCandle

final class SoundClassifierTests: XCTestCase {
    func testExtractsTargetClassificationsAndTopFive() {
        let snapshot = makeSnapshot([
            ("speech", 0.12),
            ("music", 0.24),
            ("wind_noise_microphone", 0.82),
            ("breathing", 0.41),
            ("laughter", 0.18),
            ("applause", 0.09),
        ])

        XCTAssertEqual(snapshot.windNoiseConfidence, 0.82, accuracy: 0.0001)
        XCTAssertEqual(snapshot.breathingConfidence, 0.41, accuracy: 0.0001)
        XCTAssertEqual(snapshot.speechConfidence, 0.12, accuracy: 0.0001)
        XCTAssertEqual(snapshot.musicConfidence, 0.24, accuracy: 0.0001)
        XCTAssertEqual(snapshot.topClassifications.count, 5)
        XCTAssertEqual(snapshot.topClassifications.first?.identifier, "wind_noise_microphone")
    }

    func testMissingClassificationDefaultsToZero() {
        let snapshot = makeSnapshot([("speech", 0.4)])

        XCTAssertEqual(snapshot.windNoiseConfidence, 0)
        XCTAssertEqual(snapshot.breathingConfidence, 0)
        XCTAssertEqual(snapshot.musicConfidence, 0)
    }

    func testConfidenceStaysInZeroToOne() {
        let snapshot = makeSnapshot([
            ("wind_noise_microphone", 1.7),
            ("breathing", -0.4),
            ("speech", -1),
        ])

        XCTAssertEqual(snapshot.windNoiseConfidence, 1)
        XCTAssertEqual(snapshot.breathingConfidence, 0)
        XCTAssertEqual(snapshot.speechConfidence, 0)
        XCTAssertTrue((0...1).contains(snapshot.blowConfidence))
        XCTAssertTrue(snapshot.topClassifications.allSatisfy { (0...1).contains($0.confidence) })
    }

    func testSpeechSuppressesBlowConfidence() {
        let noSpeech = makeSnapshot([
            ("wind_noise_microphone", 0.8),
            ("speech", 0.0),
        ])
        let speech = makeSnapshot([
            ("wind_noise_microphone", 0.8),
            ("speech", 0.9),
        ])

        XCTAssertEqual(noSpeech.blowConfidence, 0.8, accuracy: 0.0001)
        XCTAssertEqual(speech.blowConfidence, 0.08, accuracy: 0.0001)
        XCTAssertLessThan(speech.blowConfidence, noSpeech.blowConfidence)
    }

    func testWindNoiseRaisesBlowConfidence() {
        let quiet = makeSnapshot([("wind_noise_microphone", 0.05)])
        let wind = makeSnapshot([("wind_noise_microphone", 0.9)])

        XCTAssertGreaterThan(wind.blowConfidence, quiet.blowConfidence)
        XCTAssertEqual(wind.blowConfidence, 0.9, accuracy: 0.0001)
    }

    private func makeSnapshot(
        _ classifications: [(identifier: String, confidence: Double)]
    ) -> SoundClassificationSnapshot {
        SoundClassificationSnapshot(
            classifications: classifications.map {
                SoundClassificationPrediction(
                    identifier: $0.identifier,
                    confidence: $0.confidence
                )
            }
        )
    }
}
