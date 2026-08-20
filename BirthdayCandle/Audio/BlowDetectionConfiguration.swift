import Foundation

struct BlowDetectionConfiguration: Sendable {
    var silenceFloorRMS: Float = 0.012
    var fullScaleRMS: Float = 0.06
    var minimumHighFrequencyRatio: Float = 0.08
    var fullHighFrequencyRatio: Float = 0.45
    var textureReferenceSampleRate: Double = 44_100
    var attackSmoothing: Float = 0.28
    var releaseSmoothing: Float = 0.10

    /// How much the raw score should still depend on texture.
    /// Lower values make energy more dominant, helping real low-frequency
    /// breath noise pass even when it is not as “hissy” as synthetic white noise.
    var textureWeight: Float = 0.45

    /// Minimum energy contribution even when texture score is zero.
    var textureBaseline: Float = 0.55

    var strongBlowThreshold: Float = 0.62
    var strongBlowMaintainThreshold: Float = 0.40
    var strongBlowDecayRate: Double = 0.5
    var requiredStrongBlowDuration: TimeInterval = 0.48

    static let standard = BlowDetectionConfiguration()
}
