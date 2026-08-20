import UIKit

@MainActor
final class HapticEngine {
    private let ignitionGenerator = UIImpactFeedbackGenerator(style: .light)
    private let windGenerator = UIImpactFeedbackGenerator(style: .soft)
    private let extinguishGenerator = UIImpactFeedbackGenerator(style: .heavy)
    private var lastWindFeedbackTime: TimeInterval = 0

    func ignite() {
        ignitionGenerator.prepare()
        ignitionGenerator.impactOccurred(intensity: 0.62)
    }

    func wind(intensity: Float) {
        guard intensity >= 0.34 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let interval = 0.42 - TimeInterval(min(max(intensity, 0), 1)) * 0.16
        guard now - lastWindFeedbackTime >= interval else { return }

        lastWindFeedbackTime = now
        windGenerator.prepare()
        windGenerator.impactOccurred(intensity: CGFloat(0.2 + intensity * 0.32))
    }

    func extinguish() {
        extinguishGenerator.prepare()
        extinguishGenerator.impactOccurred(intensity: 0.96)
    }
}
