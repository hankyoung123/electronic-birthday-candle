import Foundation

enum CeremonyTiming {
    static let extinguishingDuration = 0.18
    /// How long the lighting phase lasts: long enough for the music fade-in to
    /// complete (iOS Voice Processing cancels it from the mic) before the flame
    /// lights and blow detection begins.
    static let lightingDuration: TimeInterval = 1.1
    static let extinguishedHoldDuration: TimeInterval = 0.55
    static let smokeRiseDuration: TimeInterval = 1.15
    static let greetingRevealDuration: TimeInterval = 1.0
    static let celebrationDuration: TimeInterval = 2.0
    static let completedHoldDuration: TimeInterval = 1.2
}

enum CeremonyPhase: String, CaseIterable, Sendable {
    case ready
    case lighting
    case lit
    case wishing
    case extinguishing
    case extinguished
    case smoking
    case greeting
    case celebrating
    case completed
    case restartable

    var showsFlame: Bool {
        switch self {
        case .lighting, .lit, .wishing, .extinguishing:
            true
        case .ready, .extinguished, .smoking, .greeting, .celebrating, .completed, .restartable:
            false
        }
    }

    var showsEmber: Bool {
        self == .extinguished || self == .smoking
    }

    var showsSmoke: Bool {
        self == .extinguished || self == .smoking || self == .greeting
    }

    var showsCandle: Bool {
        self != .restartable
    }

    var showsGreeting: Bool {
        self == .greeting || self == .celebrating || self == .completed
    }

    var showsCelebrationParticles: Bool {
        self == .lighting || self == .celebrating
    }
}
