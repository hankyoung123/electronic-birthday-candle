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

    /// Sustained strong wind (start threshold crossed, held ≥ required) extinguishes.
    func testSustainedWindExtinguishes() async {
        let session = await makeLitSession()
        feedIntensity(0.7, count: 12, into: session) // ~0.37 s ≥ 0.35 s
        XCTAssertEqual(session.phase, .extinguishing)
    }

    /// Maintain-level intensity must NOT begin accumulation from zero: the
    /// start threshold has to be crossed first.
    func testMaintainDoesNotStartFromZero() async {
        let session = await makeLitSession()

        // 0.2 is above maintain (0.18) but below start (0.35).
        feedIntensity(0.2, count: 20, into: session)

        XCTAssertEqual(session.phase, .lit)
        XCTAssertEqual(session.debugStrongBlowDuration, 0, accuracy: 0.0001)
    }

    /// After the start threshold is crossed once, maintain-level energy keeps
    /// the candidate accruing (weak blow still finishes).
    func testWeakBlowAccumulatesAfterStart() async {
        let session = await makeLitSession()

        feedIntensity(0.6, count: 3, into: session) // establish candidate (~0.07 s)
        XCTAssertEqual(session.phase, .lit)
        feedIntensity(0.2, count: 9, into: session, start: 1.1) // maintain-level finishes it

        XCTAssertEqual(session.phase, .extinguishing)
    }

    /// A short impulse (one loud frame, then silence) must not extinguish.
    func testShortImpulseDoesNotExtinguish() async {
        let session = await makeLitSession()
        session.receiveBlowIntensity(0.95, at: 1)
        session.receiveBlowIntensity(0.05, at: 1.05)
        session.receiveBlowIntensity(0.05, at: 1.15)
        XCTAssertEqual(session.phase, .lit)
    }

    /// Strong speech veto: Apple speech ≥ 0.80 blocks a new candidate from ever
    /// starting, even when the wind score is strong.
    func testStrongSpeechVetoBlocksStart() async {
        let session = await makeLitSession()
        session.receiveSpeechConfidence(0.9)
        feedIntensity(0.6, count: 12, into: session)
        XCTAssertEqual(session.phase, .lit)
        XCTAssertEqual(session.debugStrongBlowDuration, 0, accuracy: 0.0001)
    }

    /// Once a candidate is established, the veto is more lenient (≥ 0.90), and a
    /// high veto fast-decays the earned evidence instead of extinguishing it.
    func testStrongSpeechVetoDecaysEstablishedCandidate() async {
        let session = await makeLitSession()
        feedIntensity(0.6, count: 3, into: session) // candidate starts
        XCTAssertGreaterThan(session.debugStrongBlowDuration, 0)

        session.receiveSpeechConfidence(0.95)
        feedIntensity(0.6, count: 8, into: session) // all vetoed, evidence decays ×2
        XCTAssertEqual(session.phase, .lit)
        XCTAssertEqual(session.debugStrongBlowDuration, 0, accuracy: 0.0001)
    }

    /// Moderate speech (0.85) after the candidate is established does NOT veto
    /// (threshold is 0.90 then), so a real blow over mild speech still works.
    func testBlowContinuesUnderModerateSpeechAfterStart() async {
        let session = await makeLitSession()
        feedIntensity(0.6, count: 3, into: session) // candidate starts
        session.receiveSpeechConfidence(0.85)
        feedIntensity(0.6, count: 9, into: session, start: 1.1)
        XCTAssertEqual(session.phase, .extinguishing)
    }

    func testSpeechIgnoredWhileLighting() async {
        let session = CeremonySession()
        session.lightCandle()
        session.receiveSpeechConfidence(0.95)
        feedIntensity(1, count: 20, into: session)

        XCTAssertEqual(session.phase, .lighting)
        XCTAssertEqual(session.blowIntensity, 0)
        XCTAssertEqual(session.debugStrongBlowDuration, 0)
    }

    func testRestartClearsDetectionState() async {
        let session = await makeLitSession()
        session.receiveBlowIntensity(0.8, at: 1)
        session.receiveSpeechConfidence(0.9)
        session.restart()

        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.blowIntensity, 0)
        XCTAssertEqual(session.debugSpeechConfidence, 0)
        XCTAssertEqual(session.debugStrongBlowDuration, 0)
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

    private func feedIntensity(
        _ intensity: Float,
        count: Int,
        into session: CeremonySession,
        start: TimeInterval = 1
    ) {
        for index in 0..<count {
            session.receiveBlowIntensity(intensity, at: start + Double(index) / 30.0)
        }
    }
}
