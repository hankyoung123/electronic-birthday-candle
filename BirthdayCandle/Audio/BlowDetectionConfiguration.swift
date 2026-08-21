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
/// Detection model (this round):
///
///     Clean Mic PCM (echo-cancelled input from AudioEngine)
///     → 80–500 Hz band-pass RMS (direct time-domain)   → windEnergyScore
///     → FFT wind ratio  power(80–500)/power(80–5000)   → windRatioScore
///
///     rawScore = windEnergyScore × energyWeight + windRatioScore × ratioWeight
///
/// Then CeremonySession accumulates temporal evidence before extinguishing.
/// No adaptive baseline, no silence hard-gate, no broadband features.
final class BlowDetectionConfiguration: @unchecked Sendable {
    private let lock = NSLock()

    // Wind band edges (Hz).
    private var _windBandLowerHz: Double = 80
    private var _windBandUpperHz: Double = 500
    /// Upper edge of the FFT reference band used for the wind ratio.
    private var _referenceBandUpperHz: Double = 5_000

    // Wind-energy score normalization (band-passed 80–500 Hz RMS units).
    private var _windStart: Float = 0.012
    private var _windFull: Float = 0.055

    // Wind-ratio score normalization (fraction of 80–5000 Hz energy below 500 Hz).
    private var _windRatioStart: Float = 0.35
    private var _windRatioFull: Float = 0.65

    // Additive final-score weights (sum ≈ 1).
    private var _energyWeight: Float = 0.90
    private var _ratioWeight: Float = 0.10

    // Attack / release smoothing of the held score.
    private var _attackSmoothing: Float = 0.28
    private var _releaseSmoothing: Float = 0.10

    /// How long a recent raw-score peak is held so a brief Voice Processing
    /// dip mid-blow does not interrupt the effort (seconds).
    private var _peakHoldDuration: TimeInterval = 0.15

    // Temporal evidence accumulator (CeremonySession) — tolerant of blips.
    private var _strongBlowThreshold: Float = 0.28
    private var _strongBlowMaintainThreshold: Float = 0.10
    private var _strongBlowDecayRate: Double = 0.40
    private var _requiredStrongBlowDuration: TimeInterval = 0.28

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

    var peakHoldDuration: TimeInterval {
        get { lock.withLock { _peakHoldDuration } }
        set { lock.withLock { _peakHoldDuration = newValue } }
    }

    var attackSmoothing: Float {
        get { lock.withLock { _attackSmoothing } }
        set { lock.withLock { _attackSmoothing = newValue } }
    }

    var releaseSmoothing: Float {
        get { lock.withLock { _releaseSmoothing } }
        set { lock.withLock { _releaseSmoothing = newValue } }
    }

    var strongBlowThreshold: Float {
        get { lock.withLock { _strongBlowThreshold } }
        set { lock.withLock { _strongBlowThreshold = newValue } }
    }

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
                peakHoldDuration: _peakHoldDuration,
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
    let peakHoldDuration: TimeInterval
    let attackSmoothing: Float
    let releaseSmoothing: Float
    let strongBlowThreshold: Float
    let strongBlowMaintainThreshold: Float
    let strongBlowDecayRate: Double
    let requiredStrongBlowDuration: TimeInterval
}