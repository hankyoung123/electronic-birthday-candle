import Foundation

/// All blow-detection knobs in one place.
///
/// The configuration is a reference type so the Debug Inspector can retune it
/// live on a real device without rebuilding: `BlowDetector` (audio tap thread)
/// and `CeremonySession` (main actor) both read from the same instance every
/// frame. Every access is serialized under a lock to stay safe across threads.
/// In Release builds nothing mutates the shared `.standard` instance, so the
/// values behave as constants.
///
/// Detection model (the proven design):
///
///     iOS Voice Processing (AEC) removes our own music from the mic,
///     then a low-frequency wind detector scores the residual:
///
///     windBandRMS ≈ RMS of the 80–500 Hz band (Parseval-normalized)
///     windRatio   = power(80–500 Hz) / power(80–5000 Hz)
///
///     windEnergyScore = normalize(windBandRMS, windStart, windFull)
///     windRatioScore  = normalize(windRatio,  windRatioStart, windRatioFull)
///     rawScore = windEnergyScore × energyWeight + windRatioScore × ratioWeight
///
/// Additive only — no hard conjunctions, no energy × ratio products, no fixed
/// peak frequency. No adaptive baseline, no broadband/flatness features, and no
/// absolute silence hard-gate (low volume maps to ~0 through `windStart`).
final class BlowDetectionConfiguration: @unchecked Sendable {
    private let lock = NSLock()

    // Wind band edges (Hz).
    private var _windBandLowerHz: Double = 80
    private var _windBandUpperHz: Double = 500
    /// Upper edge of the reference band used for the wind ratio.
    private var _referenceBandUpperHz: Double = 5_000

    // Wind-energy score normalization (RMS units, 0 = silence .. 0.3+ loud).
    private var _windStart: Float = 0.03
    private var _windFull: Float = 0.14

    // Wind-ratio score normalization (fraction of 80–5000 Hz energy below 500 Hz).
    private var _windRatioStart: Float = 0.35
    private var _windRatioFull: Float = 0.65

    // Additive final-score weights (sum ≈ 1).
    private var _energyWeight: Float = 0.75
    private var _ratioWeight: Float = 0.25

    // Attack / release smoothing of the final score.
    private var _attackSmoothing: Float = 0.28
    private var _releaseSmoothing: Float = 0.10

    // Strong-blow state machine (CeremonySession) — deliberately lenient.
    private var _strongBlowThreshold: Float = 0.35
    private var _strongBlowMaintainThreshold: Float = 0.18
    private var _strongBlowDecayRate: Double = 0.4
    private var _requiredStrongBlowDuration: TimeInterval = 0.35

    init() {}

    var windBandLowerHz: Double {
        get { lock.withLock { _windBandLowerHz } }
        set { lock.withLock { _windBandLowerHz = newValue } }
    }

    var windBandUpperHz: Double {
        get { lock.withLock { _windBandUpperHz } }
        set { lock.withLock { _windBandUpperHz = newValue } }
    }

    var referenceBandUpperHz: Double {
        get { lock.withLock { _referenceBandUpperHz } }
        set { lock.withLock { _referenceBandUpperHz = newValue } }
    }

    var windStart: Float {
        get { lock.withLock { _windStart } }
        set { lock.withLock { _windStart = newValue } }
    }

    var windFull: Float {
        get { lock.withLock { _windFull } }
        set { lock.withLock { _windFull = newValue } }
    }

    var windRatioStart: Float {
        get { lock.withLock { _windRatioStart } }
        set { lock.withLock { _windRatioStart = newValue } }
    }

    var windRatioFull: Float {
        get { lock.withLock { _windRatioFull } }
        set { lock.withLock { _windRatioFull = newValue } }
    }

    var energyWeight: Float {
        get { lock.withLock { _energyWeight } }
        set { lock.withLock { _energyWeight = newValue } }
    }

    var ratioWeight: Float {
        get { lock.withLock { _ratioWeight } }
        set { lock.withLock { _ratioWeight = newValue } }
    }

    var attackSmoothing: Float {
        get { lock.withLock { _attackSmoothing } }
        set { lock.withLock { _attackSmoothing = newValue } }
    }

    var releaseSmoothing: Float {
        get { lock.withLock { _releaseSmoothing } }
        set { lock.withLock { _releaseSmoothing = newValue } }
    }

    // Strong-blow state machine knobs.
    /// Intensity that must first be crossed before blow evidence can begin.
    var strongBlowThreshold: Float {
        get { lock.withLock { _strongBlowThreshold } }
        set { lock.withLock { _strongBlowThreshold = newValue } }
    }

    /// Once a candidate has started, intensity above this keeps it accruing.
    var strongBlowMaintainThreshold: Float {
        get { lock.withLock { _strongBlowMaintainThreshold } }
        set { lock.withLock { _strongBlowMaintainThreshold = newValue } }
    }

    var strongBlowDecayRate: Double {
        get { lock.withLock { _strongBlowDecayRate } }
        set { lock.withLock { _strongBlowDecayRate = newValue } }
    }

    var requiredStrongBlowDuration: TimeInterval {
        get { lock.withLock { _requiredStrongBlowDuration } }
        set { lock.withLock { _requiredStrongBlowDuration = newValue } }
    }

    func snapshot() -> BlowDetectionParameters {
        lock.withLock {
            BlowDetectionParameters(
                windBandLowerHz: _windBandLowerHz,
                windBandUpperHz: _windBandUpperHz,
                referenceBandUpperHz: _referenceBandUpperHz,
                windStart: _windStart,
                windFull: _windFull,
                windRatioStart: _windRatioStart,
                windRatioFull: _windRatioFull,
                energyWeight: _energyWeight,
                ratioWeight: _ratioWeight,
                attackSmoothing: _attackSmoothing,
                releaseSmoothing: _releaseSmoothing,
                strongBlowThreshold: _strongBlowThreshold,
                strongBlowMaintainThreshold: _strongBlowMaintainThreshold,
                strongBlowDecayRate: _strongBlowDecayRate,
                requiredStrongBlowDuration: _requiredStrongBlowDuration
            )
        }
    }

    static let standard = BlowDetectionConfiguration()
}

/// Immutable copy of every tunable parameter, captured atomically.
struct BlowDetectionParameters: Sendable {
    let windBandLowerHz: Double
    let windBandUpperHz: Double
    let referenceBandUpperHz: Double
    let windStart: Float
    let windFull: Float
    let windRatioStart: Float
    let windRatioFull: Float
    let energyWeight: Float
    let ratioWeight: Float
    let attackSmoothing: Float
    let releaseSmoothing: Float
    let strongBlowThreshold: Float
    let strongBlowMaintainThreshold: Float
    let strongBlowDecayRate: Double
    let requiredStrongBlowDuration: TimeInterval
}