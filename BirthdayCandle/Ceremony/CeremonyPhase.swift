enum CeremonyTiming {
    static let extinguishingDuration = 0.18
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
