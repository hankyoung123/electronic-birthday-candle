import UIKit

@MainActor
final class HapticEngine {
    private let ignitionGenerator = UIImpactFeedbackGenerator(style: .light)
    private let extinguishGenerator = UIImpactFeedbackGenerator(style: .heavy)

    func ignite() {
        ignitionGenerator.prepare()
        ignitionGenerator.impactOccurred(intensity: 0.62)
    }

    func extinguish() {
        extinguishGenerator.prepare()
        extinguishGenerator.impactOccurred(intensity: 0.96)
    }
}
