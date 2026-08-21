import Foundation

enum CeremonyTiming {
    static let extinguishingDuration = 0.18
    /// How long the lighting phase lasts: long enough for the music fade-in to
    /// complete (iOS Voice Processing cancels it from the mic) before the flame
    /// lights and blow detection begins.
    static let lightingDuration: TimeInterval = 1.1
}

enum CeremonyPhase: String, CaseIterable, Sendable {
    case ready
    case lighting
    case lit
    case wishing
    case extinguishing
    case extinguished
    case celebrating

    var showsFlame: Bool {
        switch self {
        case .lighting, .lit, .wishing, .extinguishing:
            true
        case .ready, .extinguished, .celebrating:
            false
        }
    }

    var showsEmber: Bool {
        self == .extinguished
    }

    var showsSmoke: Bool {
        self == .extinguished || self == .celebrating
    }
}
