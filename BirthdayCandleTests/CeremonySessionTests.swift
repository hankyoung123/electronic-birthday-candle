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

    func testRestartReturnsToReady() async {
        let session = CeremonySession()
        session.lightCandle()
        try? await Task.sleep(for: .milliseconds(600))
        session.extinguish()
        session.restart()

        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.blowIntensity, 0)
    }

    func testShortImpulseDoesNotExtinguish() async {
        let session = CeremonySession()
        session.lightCandle()
        try? await Task.sleep(for: .milliseconds(600))

        session.receiveBlowIntensity(0.95, at: 1)
        session.receiveBlowIntensity(0.05, at: 1.05)
        session.receiveBlowIntensity(0.05, at: 1.15)

        XCTAssertEqual(session.phase, .lit)
    }

    func testSustainedStrongBlowBeginsExtinguishing() async {
        let session = CeremonySession()
        session.lightCandle()
        try? await Task.sleep(for: .milliseconds(600))

        session.receiveBlowIntensity(0.9, at: 1)
        session.receiveBlowIntensity(0.9, at: 1.1)
        session.receiveBlowIntensity(0.9, at: 1.2)
        session.receiveBlowIntensity(0.9, at: 1.3)
        session.receiveBlowIntensity(0.9, at: 1.4)
        session.receiveBlowIntensity(0.9, at: 1.5)

        XCTAssertEqual(session.phase, .extinguishing)
    }

    func testFluctuatingBlowSurvivesShortDipsAboveMaintain() async {
        let session = CeremonySession()
        session.lightCandle()
        try? await Task.sleep(for: .milliseconds(600))

        // Strong blow with realistic short dips: the energy dips below the
        // start threshold, but remains above the maintain threshold and should
        // not erase the progress already earned.
        session.receiveBlowIntensity(0.9, at: 1)
        session.receiveBlowIntensity(0.5, at: 1.1)
        session.receiveBlowIntensity(0.85, at: 1.2)
        session.receiveBlowIntensity(0.45, at: 1.3)
        session.receiveBlowIntensity(0.9, at: 1.4)
        session.receiveBlowIntensity(0.9, at: 1.5)
        session.receiveBlowIntensity(0.9, at: 1.6)
        session.receiveBlowIntensity(0.9, at: 1.7)

        XCTAssertEqual(session.phase, .extinguishing)
    }

    func testExtinguishingCompletesInsideCollapseWindow() async {
        XCTAssertTrue((0.15...0.25).contains(CeremonyTiming.extinguishingDuration))

        let session = CeremonySession()
        session.lightCandle()
        try? await Task.sleep(for: .milliseconds(600))

        session.extinguish()
        XCTAssertEqual(session.phase, .extinguishing)

        try? await Task.sleep(for: .milliseconds(260))
        XCTAssertEqual(session.phase, .extinguished)
        XCTAssertNotNil(session.extinguishedAt)
    }
}
