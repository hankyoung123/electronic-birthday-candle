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

    func testAboveMaintainButBelowStartDoesNotBeginAccumulation() async {
        let session = CeremonySession()
        session.lightCandle()
        try? await Task.sleep(for: .milliseconds(600))

        // 0.35 sits above the maintain threshold (0.25) but below the start
        // threshold (0.45). Before the start threshold is crossed once, no
        // blow time may accrue — speech-like energy must never slowly count
        // toward an extinguish.
        session.receiveBlowIntensity(0.35, at: 1)
        session.receiveBlowIntensity(0.35, at: 1.1)
        session.receiveBlowIntensity(0.35, at: 1.2)

        XCTAssertEqual(session.phase, .lit)
        XCTAssertEqual(session.debugStrongBlowDuration, 0, accuracy: 0.0001)
    }

    func testMaintainLevelAfterStartKeepsAccumulating() async {
        let session = CeremonySession()
        session.lightCandle()
        try? await Task.sleep(for: .milliseconds(600))

        // Once the start threshold is crossed, the blow keeps counting while
        // intensity stays above the maintain threshold, even if it dips below
        // the start threshold in the middle of a real (fluctuating) blow.
        session.receiveBlowIntensity(0.9, at: 1)
        session.receiveBlowIntensity(0.9, at: 1.1)
        session.receiveBlowIntensity(0.5, at: 1.2)
        session.receiveBlowIntensity(0.5, at: 1.3)
        session.receiveBlowIntensity(0.5, at: 1.4)
        session.receiveBlowIntensity(0.5, at: 1.5)

        XCTAssertEqual(session.phase, .extinguishing)
    }

    func testDecayedProgressRequiresCrossingStartAgain() async {
        let session = CeremonySession()
        session.lightCandle()
        try? await Task.sleep(for: .milliseconds(600))

        // Accumulate a little, then fall silent long enough for the slow decay
        // to erase everything back to zero. Sub-start maintain-level energy
        // (0.30, above maintain 0.25) afterwards must NOT resume the count; a
        // fresh crossing of the start threshold is required.
        session.receiveBlowIntensity(0.9, at: 1)
        session.receiveBlowIntensity(0.9, at: 1.1)
        session.receiveBlowIntensity(0.05, at: 1.2)
        session.receiveBlowIntensity(0.05, at: 1.3)
        session.receiveBlowIntensity(0.05, at: 1.4)
        session.receiveBlowIntensity(0.3, at: 1.5)
        session.receiveBlowIntensity(0.3, at: 1.6)
        session.receiveBlowIntensity(0.3, at: 1.7)
        session.receiveBlowIntensity(0.9, at: 1.8)
        session.receiveBlowIntensity(0.9, at: 1.9)
        session.receiveBlowIntensity(0.9, at: 2.0)
        session.receiveBlowIntensity(0.9, at: 2.1)

        XCTAssertEqual(session.phase, .extinguishing)
    }

    func testThreeSecondHistoryStaysBounded() async {
        let session = CeremonySession()
        session.lightCandle()
        try? await Task.sleep(for: .milliseconds(600))

        // Simulate ~10 s of ticks at 30 Hz. Values are sub-start (0.35 < 0.45)
        // so the candle never extinguishes and every tick is recorded. The
        // rolling window must settle near N ≈ 90 and never keep growing.
        for index in 0..<300 {
            session.receiveBlowIntensity(0.35, at: 1.0 + Double(index) / 30.0)
        }
        let summary = session.debugSpectrumRollingSummary

        XCTAssertGreaterThanOrEqual(summary.sampleCount, 80)
        XCTAssertLessThanOrEqual(summary.sampleCount, 100)
    }

    func testOldPeakDisappearsAfterThreeSeconds() async {
        let session = CeremonySession()
        session.lightCandle()
        try? await Task.sleep(for: .milliseconds(600))

        // Loud (but sub-start) phase for ~1 s at 20 Hz.
        for index in 0..<20 {
            session.receiveBlowIntensity(0.38, at: 1.0 + Double(index) * 0.05)
        }
        // While the loud frames are still inside the window, the peak shows it.
        XCTAssertGreaterThanOrEqual(session.debugSpectrumRollingSummary.smoothedPeak, 0.36)

        // Quiet for well over 3 s — the old peak must fall out of the window.
        for index in 0..<70 {
            session.receiveBlowIntensity(0.05, at: 2.0 + Double(index) * 0.05)
        }
        let summary = session.debugSpectrumRollingSummary
        XCTAssertLessThan(summary.smoothedPeak, 0.10)
        XCTAssertLessThanOrEqual(summary.sampleCount, 100)
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
