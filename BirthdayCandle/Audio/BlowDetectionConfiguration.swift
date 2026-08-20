import Foundation

struct BlowDetectionConfiguration: Sendable {
    var silenceFloorRMS: Float = 0.012
    var fullScaleRMS: Float = 0.18
    var minimumHighFrequencyRatio: Float = 0.16
    var fullHighFrequencyRatio: Float = 0.58
    var attackSmoothing: Float = 0.28
    var releaseSmoothing: Float = 0.10
    var strongBlowThreshold: Float = 0.64
    var requiredStrongBlowDuration: TimeInterval = 0.48

    static let standard = BlowDetectionConfiguration()
}
