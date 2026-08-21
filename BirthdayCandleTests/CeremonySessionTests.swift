import XCTest
@testable import BirthdayCandle

@MainActor
final class CeremonySessionTests: XCTestCase {
    func testEmberAppearsOnlyAfterExtinguishingCompletes() {
        XCTAssertFalse(CeremonyPhase.extinguishing.showsEmber)
        XCTAssertTrue(CeremonyPhase.extinguished.showsEmber)
    }

    func testPreparationWithoutAudioEngineCanProceed() async {
        let session = CeremonySession()
        let isReady = await session.prepareMicrophoneAccess()
        XCTAssertTrue(isReady)
        XCTAssertEqual(session.phase, .ready)
    }

    func testReadyCanBeginLighting() {
        let session = CeremonySession()
        session.lightCandle()
        XCTAssertEqual(session.phase, .lighting)
    }

    func testCannotExtinguishBeforeCandleIsLit() {
        let session = CeremonySession()
        session.extinguish()
        XCTAssertEqual(session.phase, .ready)
    }

    func testVisualIntensityNeverExtinguishes() async {
        let session = await makeLitSession()
        for _ in 0..<100 {
            session.receiveBlowIntensity(1)
        }
        XCTAssertEqual(session.phase, .lit)
        XCTAssertEqual(session.blowIntensity, 1)
        XCTAssertEqual(session.debugBlowEvidence, 0)
    }

    func testHighBlowConfidenceExtinguishes() async {
        let session = await makeLitSession()
        feedConfidence(0.95, count: 9, into: session)
        XCTAssertEqual(session.phase, .extinguishing)
    }

    func testSpeechConfidenceDoesNotExtinguish() async {
        let session = await makeLitSession()
        let speech = SoundClassificationSnapshot(classifications: [
            .init(identifier: SoundClassificationSnapshot.windNoiseIdentifier, confidence: 0.95),
            .init(identifier: SoundClassificationSnapshot.speechIdentifier, confidence: 0.95),
        ])

        feedConfidence(speech.blowConfidence, count: 30, into: session)

        XCTAssertLessThan(speech.blowConfidence, 0.55)
        XCTAssertEqual(session.phase, .lit)
        XCTAssertEqual(session.debugBlowEvidence, 0, accuracy: 0.001)
    }

    func testShortClassificationSpikeDoesNotExtinguish() async {
        let session = await makeLitSession()
        session.receiveBlowConfidence(0.9, at: 1.0)
        session.receiveBlowConfidence(0.9, at: 1.0 + 1.0 / 30.0)
        for index in 2..<12 {
            session.receiveBlowConfidence(0, at: 1.0 + Double(index) / 30.0)
        }

        XCTAssertEqual(session.phase, .lit)
        XCTAssertEqual(session.debugBlowEvidence, 0, accuracy: 0.001)
    }

    func testSustainedBlowConfidenceExtinguishes() async {
        let session = await makeLitSession()
        feedConfidence(0.56, count: 9, into: session)
        XCTAssertEqual(session.phase, .extinguishing)
    }

    func testConfidenceIsIgnoredWhileLighting() async {
        let session = CeremonySession()
        session.lightCandle()
        feedConfidence(1, count: 20, into: session)

        XCTAssertEqual(session.phase, .lighting)
        XCTAssertEqual(session.blowConfidence, 0)
        XCTAssertEqual(session.debugBlowEvidence, 0)
    }

    func testRestartClearsDetectionState() async {
        let session = await makeLitSession()
        session.receiveBlowIntensity(0.8)
        session.receiveBlowConfidence(0.9, at: 1)
        session.receiveBlowConfidence(0.9, at: 1.1)
        session.restart()

        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.blowIntensity, 0)
        XCTAssertEqual(session.blowConfidence, 0)
        XCTAssertEqual(session.debugBlowEvidence, 0)
    }

    func testRuntimeAudioFailuresReturnLightingCeremonyToReady() {
        for error in [
            AudioEngineError.routeRecoveryFailed,
            .microphoneUnavailable,
            .sessionActivationFailed,
        ] {
            let audioEngine = AudioEngine()
            let session = CeremonySession(audioEngine: audioEngine)
            session.lightCandle()
            audioEngine.handleRuntimeFailure(error)

            XCTAssertEqual(session.phase, .ready)
            XCTAssertEqual(session.notice, .microphoneUnavailable)
            XCTAssertEqual(session.blowIntensity, 0)
            XCTAssertEqual(session.blowConfidence, 0)
        }
    }

    func testExtinguishingCompletesInsideCollapseWindow() async {
        XCTAssertTrue((0.15...0.25).contains(CeremonyTiming.extinguishingDuration))
        let session = await makeLitSession()
        session.extinguish()
        XCTAssertEqual(session.phase, .extinguishing)

        try? await Task.sleep(for: .milliseconds(260))
        XCTAssertEqual(session.phase, .extinguished)
        XCTAssertNotNil(session.extinguishedAt)
    }

    private func makeLitSession() async -> CeremonySession {
        let session = CeremonySession()
        session.lightCandle()
        try? await Task.sleep(for: .milliseconds(1_200))
        XCTAssertEqual(session.phase, .lit)
        return session
    }

    private func feedConfidence(
        _ confidence: Double,
        count: Int,
        into session: CeremonySession,
        start: TimeInterval = 1
    ) {
        for index in 0..<count {
            session.receiveBlowConfidence(confidence, at: start + Double(index) / 30.0)
        }
    }
}
