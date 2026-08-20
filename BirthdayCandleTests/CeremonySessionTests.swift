import XCTest
@testable import BirthdayCandle

@MainActor
final class CeremonySessionTests: XCTestCase {
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
}
