import XCTest
@testable import BirthdayCandle

final class SoundClassifierTests: XCTestCase {
    func testExtractsTargetClassificationsAndTopFive() {
        let snapshot = makeSnapshot([
            ("speech", 0.82),
            ("music", 0.24),
            ("wind_noise_microphone", 0.12),
            ("breathing", 0.41),
            ("laughter", 0.18),
            ("applause", 0.09),
        ])

        XCTAssertEqual(snapshot.speechConfidence, 0.82, accuracy: 0.0001)
        XCTAssertEqual(snapshot.windNoiseConfidence, 0.12, accuracy: 0.0001)
        XCTAssertEqual(snapshot.breathingConfidence, 0.41, accuracy: 0.0001)
        XCTAssertEqual(snapshot.musicConfidence, 0.24, accuracy: 0.0001)
        XCTAssertEqual(snapshot.topClassifications.count, 5)
        XCTAssertEqual(snapshot.topClassifications.first?.identifier, "speech")
    }

    func testMissingClassificationDefaultsToZero() {
        let snapshot = makeSnapshot([("speech", 0.4)])

        XCTAssertEqual(snapshot.windNoiseConfidence, 0)
        XCTAssertEqual(snapshot.breathingConfidence, 0)
        XCTAssertEqual(snapshot.musicConfidence, 0)
        XCTAssertEqual(snapshot.speechConfidence, 0.4, accuracy: 0.0001)
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
        XCTAssertTrue(snapshot.topClassifications.allSatisfy { (0...1).contains($0.confidence) })
    }

    /// Speech confidence is read independently of other classes — wind noise or
    /// breathing must never dilute it (Apple is only a speech veto).
    func testSpeechConfidenceIndependentOfOtherClasses() {
        let withSpeech = makeSnapshot([
            ("wind_noise_microphone", 0.9),
            ("breathing", 0.8),
            ("speech", 0.95),
        ])
        let withoutSpeech = makeSnapshot([
            ("wind_noise_microphone", 0.9),
            ("breathing", 0.8),
        ])

        XCTAssertEqual(withSpeech.speechConfidence, 0.95, accuracy: 0.0001)
        XCTAssertEqual(withoutSpeech.speechConfidence, 0)
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
