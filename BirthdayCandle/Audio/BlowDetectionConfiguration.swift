import Foundation

/// The complete semantic blow-confirmation policy.
///
/// SoundClassifier decides whether the microphone contains a blow. This type
/// only controls how long that confidence must persist before extinguishing.
/// Visual flame response is intentionally configured inside BlowDetector and
/// has no authority over the ceremony state.
struct BlowDetectionConfiguration: Sendable {
    let blowConfidenceThreshold: Double
    let requiredDuration: TimeInterval
    let decayRate: Double

    init(
        blowConfidenceThreshold: Double = 0.55,
        requiredDuration: TimeInterval = 0.25,
        decayRate: Double = 1.5
    ) {
        self.blowConfidenceThreshold = min(max(blowConfidenceThreshold, 0), 1)
        self.requiredDuration = max(requiredDuration, 0)
        self.decayRate = max(decayRate, 0)
    }

    static let standard = BlowDetectionConfiguration()
}
