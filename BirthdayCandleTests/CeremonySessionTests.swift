import CoreMedia
import XCTest
@testable import BirthdayCandle

@MainActor
final class CeremonySessionTests: XCTestCase {
    func testEmberAppearsOnlyAfterExtinguishingCompletes() {
        XCTAssertFalse(CeremonyPhase.extinguishing.showsEmber)
        XCTAssertTrue(CeremonyPhase.extinguished.showsEmber)
        XCTAssertTrue(CeremonyPhase.smoking.showsEmber)
        XCTAssertFalse(CeremonyPhase.greeting.showsEmber)
    }

    func testPrototypePhaseVisualSemantics() {
        XCTAssertTrue(CeremonyPhase.lighting.showsCelebrationParticles)
        XCTAssertTrue(CeremonyPhase.celebrating.showsCelebrationParticles)
        XCTAssertTrue(CeremonyPhase.extinguished.showsSmoke)
        XCTAssertTrue(CeremonyPhase.smoking.showsSmoke)
        XCTAssertTrue(CeremonyPhase.greeting.showsSmoke)
        XCTAssertTrue(CeremonyPhase.greeting.showsGreeting)
        XCTAssertTrue(CeremonyPhase.completed.showsGreeting)
        XCTAssertFalse(CeremonyPhase.restartable.showsCandle)
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

    func testLitPhaseCannotBeExtinguished() async {
        let session = await makeLitSession()
        session.extinguish()
        feedIntensity(0.9, count: 20, into: session)

        XCTAssertEqual(session.phase, .lit)
        XCTAssertEqual(session.blowIntensity, 0.9, accuracy: 0.001)
        XCTAssertFalse(session.debugBlowCandidateActive)
        XCTAssertEqual(session.debugStrongBlowDuration, 0)
    }

    func testQualifiedAirflowWaitsForSpeechObservation() async {
        let session = await makeWishingSession()
        feedIntensity(0.7, count: 12, into: session)

        XCTAssertEqual(session.phase, .wishing)
        XCTAssertTrue(session.debugBlowCandidateActive)
        XCTAssertTrue(session.debugAwaitingSpeechCheck)
    }

    func testCoveringLowSpeechObservationConfirmsCandidate() async {
        let session = await makeWishingSession()
        feedIntensity(0.7, count: 12, into: session)

        session.receiveSpeechObservation(
            observation(confidence: 0.05, start: 0.95, duration: 0.5)
        )

        XCTAssertEqual(session.phase, .extinguishing)
    }

    func testCoveringStrongSpeechObservationRejectsCandidate() async {
        let session = await makeWishingSession()
        feedIntensity(0.7, count: 12, into: session)

        session.receiveSpeechObservation(
            observation(confidence: 0.9, start: 0.95, duration: 0.5)
        )

        XCTAssertEqual(session.phase, .wishing)
        XCTAssertFalse(session.debugBlowCandidateActive)
        XCTAssertFalse(session.debugAwaitingSpeechCheck)
        XCTAssertEqual(session.debugStrongBlowDuration, 0)
    }

    func testObservationFromBeforeCandidateCannotConfirm() async {
        let session = await makeWishingSession()
        session.receiveSpeechObservation(
            observation(confidence: 0.02, start: 0, duration: 0.5)
        )
        feedIntensity(0.7, count: 12, into: session)

        XCTAssertEqual(session.phase, .wishing)
        XCTAssertTrue(session.debugAwaitingSpeechCheck)

        session.receiveSpeechObservation(
            observation(confidence: 0.02, start: 0.95, duration: 0.5)
        )
        XCTAssertEqual(session.phase, .extinguishing)
    }

    func testObservationThatDoesNotCoverCandidateStartCannotConfirm() async {
        let session = await makeWishingSession()
        feedIntensity(0.7, count: 12, into: session)

        session.receiveSpeechObservation(
            observation(confidence: 0.02, start: 1.1, duration: 0.5)
        )

        XCTAssertEqual(session.phase, .wishing)
        XCTAssertTrue(session.debugAwaitingSpeechCheck)
    }

    func testShortAirflowCandidateIsRejectedBeforeSpeechCheck() async {
        let session = await makeWishingSession()
        feedIntensity(0.8, count: 4, into: session)
        session.receiveBlowIntensity(
            0.1,
            at: 1.2,
            analysisTime: streamTime(1.2)
        )

        XCTAssertEqual(session.phase, .wishing)
        XCTAssertFalse(session.debugBlowCandidateActive)
        XCTAssertFalse(session.debugAwaitingSpeechCheck)
    }

    func testRestartClearsCandidateAndSpeechState() async {
        let session = await makeWishingSession()
        feedIntensity(0.8, count: 4, into: session)
        session.receiveSpeechObservation(
            observation(confidence: 0.9, start: 0.9, duration: 0.5)
        )
        session.restart()

        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.blowIntensity, 0)
        XCTAssertEqual(session.debugSpeechConfidence, 0)
        XCTAssertFalse(session.debugBlowCandidateActive)
        XCTAssertFalse(session.debugBlowDetectionEnabled)
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
            XCTAssertFalse(session.debugBlowDetectionEnabled)
        }
    }

    func testExtinguishingCompletesInsideCollapseWindow() async {
        XCTAssertTrue((0.15...0.25).contains(CeremonyTiming.extinguishingDuration))
        let session = await makeWishingSession()
        session.extinguish()
        XCTAssertEqual(session.phase, .extinguishing)

        try? await Task.sleep(for: .milliseconds(260))
        XCTAssertEqual(session.phase, .extinguished)
        XCTAssertNotNil(session.extinguishedAt)
    }

    func testPostExtinguishCeremonyBecomesRestartable() async {
        let session = await makeWishingSession()
        session.extinguish()

        let postExtinguishDuration = CeremonyTiming.extinguishingDuration
            + CeremonyTiming.extinguishedHoldDuration
            + CeremonyTiming.smokeRiseDuration
            + CeremonyTiming.greetingRevealDuration
            + CeremonyTiming.celebrationDuration
            + CeremonyTiming.completedHoldDuration
        try? await Task.sleep(for: .seconds(postExtinguishDuration + 0.25))

        XCTAssertEqual(session.phase, .restartable)
        session.restart()
        XCTAssertEqual(session.phase, .ready)
        XCTAssertNil(session.extinguishedAt)
    }

    private func makeLitSession() async -> CeremonySession {
        let session = CeremonySession()
        session.lightCandle()
        try? await Task.sleep(for: .milliseconds(1_200))
        XCTAssertEqual(session.phase, .lit)
        return session
    }

    private func makeWishingSession() async -> CeremonySession {
        let session = CeremonySession()
        session.lightCandle()
        try? await Task.sleep(for: .milliseconds(3_200))
        XCTAssertEqual(session.phase, .wishing)
        XCTAssertTrue(session.debugBlowDetectionEnabled)
        return session
    }

    private func feedIntensity(
        _ intensity: Float,
        count: Int,
        into session: CeremonySession,
        start: TimeInterval = 1
    ) {
        for index in 0..<count {
            let time = start + Double(index) / 30.0
            session.receiveBlowIntensity(
                intensity,
                at: time,
                analysisTime: streamTime(time)
            )
        }
    }

    private func observation(
        confidence: Double,
        start: TimeInterval,
        duration: TimeInterval
    ) -> SpeechObservation {
        SpeechObservation(
            confidence: confidence,
            timeRange: CMTimeRange(
                start: streamTime(start),
                duration: streamTime(duration)
            )
        )
    }

    private func streamTime(_ seconds: TimeInterval) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 1_000_000)
    }
}
