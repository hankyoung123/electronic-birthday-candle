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
        try? await Task.sleep(for: .milliseconds(2000))
        session.extinguish()
        session.restart()

        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(session.blowIntensity, 0)
    }

    func testShortImpulseDoesNotExtinguish() async {
        let session = CeremonySession()
        session.lightCandle()
        try? await Task.sleep(for: .milliseconds(2000))

        session.receiveBlowIntensity(0.95, at: 1)
        session.receiveBlowIntensity(0.05, at: 1.05)
        session.receiveBlowIntensity(0.05, at: 1.15)

        XCTAssertEqual(session.phase, .lit)
    }

    func testSustainedStrongBlowBeginsExtinguishing() async {
        let session = CeremonySession()
        session.lightCandle()
        try? await Task.sleep(for: .milliseconds(2000))

        for index in 0..<11 { // ~0.37s of strong wind at ~30 Hz
            session.receiveBlowIntensity(0.7, at: 1.0 + Double(index) / 30.0)
        }

        XCTAssertEqual(session.phase, .extinguishing)
    }

    /// Strong intensity accumulates at full rate and extinguishes quickly.
    func testStrongEvidenceAccumulatesQuickly() async {
        let session = CeremonySession()
        session.lightCandle()
        try? await Task.sleep(for: .milliseconds(2000))

        // 6 ticks (~0.2s) is not enough yet.
        for index in 0..<6 {
            session.receiveBlowIntensity(0.6, at: 1.0 + Double(index) / 30.0)
        }
        XCTAssertEqual(session.phase, .lit)

        // 10 ticks (~0.33s) crosses the 0.30s requirement.
        for index in 6..<10 {
            session.receiveBlowIntensity(0.6, at: 1.0 + Double(index) / 30.0)
        }
        XCTAssertEqual(session.phase, .extinguishing)
    }

    /// Maintain-level intensity accumulates at 65% rate (weak blow keeps going).
    func testWeakEvidenceAccumulatesSlowly() async {
        let session = CeremonySession()
        session.lightCandle()
        try? await Task.sleep(for: .milliseconds(2000))

        // 0.20 is above maintain (0.12) but below start (0.30): ~4 ticks are
        // not enough (≈0.087s of evidence).
        for index in 0..<4 {
            session.receiveBlowIntensity(0.20, at: 1.0 + Double(index) / 30.0)
        }
        XCTAssertEqual(session.phase, .lit)

        // 14 more ticks → 0.65 × 0.6s ≈ 0.39s of evidence ≥ 0.30s → extinguish.
        for index in 4..<18 {
            session.receiveBlowIntensity(0.20, at: 1.0 + Double(index) / 30.0)
        }
        XCTAssertEqual(session.phase, .extinguishing)
    }

    /// A short sub-maintain dip mid-blow must not erase earned evidence.
    func testShortDropDoesNotResetEvidence() async {
        let session = CeremonySession()
        session.lightCandle()
        try? await Task.sleep(for: .milliseconds(2000))

        for index in 0..<6 { session.receiveBlowIntensity(0.6, at: 1.0 + Double(index) / 30.0) } // ~0.2s
        session.receiveBlowIntensity(0.05, at: 1.0 + 6.0 / 30.0) // one dip
        for index in 7..<12 { session.receiveBlowIntensity(0.6, at: 1.0 + Double(index) / 30.0) }

        XCTAssertEqual(session.phase, .extinguishing)
    }

    /// After blowing stops, the evidence decays back to zero and no extinguish.
    func testStoppedBlowDecaysEvidence() async {
        let session = CeremonySession()
        session.lightCandle()
        try? await Task.sleep(for: .milliseconds(2000))

        for index in 0..<5 { session.receiveBlowIntensity(0.6, at: 1.0 + Double(index) / 30.0) } // ~0.17s
        for index in 0..<12 { session.receiveBlowIntensity(0.0, at: 1.2 + Double(index) / 30.0) } // 0.4s of silence

        XCTAssertEqual(session.phase, .lit)
        XCTAssertLessThan(session.debugBlowEvidence, 0.05)
    }

    func testMusicFadeInDoesNotTrigger() async {
        let session = CeremonySession()
        session.lightCandle()

        // While the flame is still lighting (~1.1s), blow intensity is not
        // consumed: strong blow-like values must neither accumulate nor extinguish.
        try? await Task.sleep(for: .milliseconds(500))
        session.receiveBlowIntensity(0.9, at: 1.0)
        session.receiveBlowIntensity(0.9, at: 1.1)
        session.receiveBlowIntensity(0.9, at: 1.2)

        XCTAssertEqual(session.phase, .lighting)
        XCTAssertEqual(session.blowIntensity, 0)
        XCTAssertEqual(session.debugBlowEvidence, 0)

        try? await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(session.phase, .lit)
    }

    func testThreeSecondHistoryStaysBounded() async {
        let session = CeremonySession()
        session.lightCandle()
        try? await Task.sleep(for: .milliseconds(2000))

        // Sub-maintain (0.08 < 0.12) ticks: no evidence, stays lit, all recorded.
        for index in 0..<300 {
            session.receiveBlowIntensity(0.08, at: 1.0 + Double(index) / 30.0)
        }
        let summary = session.debugSpectrumRollingSummary

        XCTAssertGreaterThanOrEqual(summary.sampleCount, 80)
        XCTAssertLessThanOrEqual(summary.sampleCount, 100)
    }

    func testOldPeakDisappearsAfterThreeSeconds() async {
        let session = CeremonySession()
        session.lightCandle()
        try? await Task.sleep(for: .milliseconds(2000))

        // A short loud burst (< required evidence) creates a visible history peak
        // without extinguishing.
        for index in 0..<6 {
            session.receiveBlowIntensity(0.9, at: 1.0 + Double(index) / 30.0)
        }
        XCTAssertGreaterThanOrEqual(session.debugSpectrumRollingSummary.smoothedPeak, 0.8)

        // Quiet for well over 3 s — the old peak must fall out of the window.
        for index in 0..<120 {
            session.receiveBlowIntensity(0.05, at: 2.0 + Double(index) / 30.0)
        }
        let summary = session.debugSpectrumRollingSummary
        XCTAssertLessThan(summary.smoothedPeak, 0.10)
        XCTAssertLessThanOrEqual(summary.sampleCount, 100)
    }

    func testExtinguishingCompletesInsideCollapseWindow() async {
        XCTAssertTrue((0.15...0.25).contains(CeremonyTiming.extinguishingDuration))

        let session = CeremonySession()
        session.lightCandle()
        try? await Task.sleep(for: .milliseconds(2000))

        session.extinguish()
        XCTAssertEqual(session.phase, .extinguishing)

        try? await Task.sleep(for: .milliseconds(260))
        XCTAssertEqual(session.phase, .extinguished)
        XCTAssertNotNil(session.extinguishedAt)
    }
}