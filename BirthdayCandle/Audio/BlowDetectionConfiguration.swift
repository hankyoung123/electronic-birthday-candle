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
/// Detection model: the final score is additive over two reliable cues —
///
///     Blow Score = Energy Score × energyScoreWeight        (is it loud?)
///                + Broadband Score × broadbandScoreWeight  (is 80–2000 Hz wide?)
///
/// The four analysis bands (80–300 / 300–800 / 800–2000 / 2000–5000 Hz) are
/// computed every frame but exposed as *ratios* for diagnostics only — they do
/// not feed the decision. No hard energy × texture product gate.
final class BlowDetectionConfiguration: @unchecked Sendable {
    private let lock = NSLock()

    // Loudness normalization for the Energy Score.
    private var _silenceFloorRMS: Float = 0.012
    private var _fullScaleRMS: Float = 0.12

    // Attack / release smoothing of the final score.
    private var _attackSmoothing: Float = 0.28
    private var _releaseSmoothing: Float = 0.10

    // Band edges (Hz). Analysis bands: [80,300) [300,800) [800,2000) [2000,5000).
    private var _lowBandLowerHz: Double = 80
    private var _lowBandUpperHz: Double = 300
    private var _midBandUpperHz: Double = 800
    private var _upperBandUpperHz: Double = 2_000
    private var _highBandUpperHz: Double = 5_000

    // Broadband band edges (Hz) and active-bin criteria.
    //
    // Relaxed enough that a real blow's decaying high end (peak ~200–500 Hz,
    // tapering toward 2 kHz) still counts as broad — but not so relaxed that
    // quiet white-ish room noise saturates the broadband score. Measured on
    // synthetic speech/music/noise/wind, these values keep silence, speech and
    // music below start while real blows pass. All three are live-tunable.
    private var _broadbandLowerHz: Double = 80
    private var _broadbandUpperHz: Double = 2_000
    /// A bin counts as “active” when it holds at least this fraction of the
    /// band’s peak-power bin.
    private var _broadbandRelativeThreshold: Float = 0.25
    /// Proportion of active bins below which Broadband Score is zero.
    private var _broadbandActiveMinProportion: Float = 0.25
    /// Proportion of active bins at/above which Broadband Score is one.
    private var _broadbandActiveFullProportion: Float = 0.70

    // Additive final-score mix (no hard energy × texture gate).
    // The broadband term is a *shape* confirmation (rejects tonal speech/music);
    // energy is what separates a loud blow from quiet broadband room noise.
    private var _energyScoreWeight: Float = 0.65
    private var _broadbandScoreWeight: Float = 0.35

    // Strong-blow accumulator (CeremonySession).
    private var _strongBlowThreshold: Float = 0.45
    private var _strongBlowMaintainThreshold: Float = 0.25
    private var _strongBlowDecayRate: Double = 0.4
    private var _requiredStrongBlowDuration: TimeInterval = 0.4

    init() {}

    var silenceFloorRMS: Float {
        get { lock.withLock { _silenceFloorRMS } }
        set { lock.withLock { _silenceFloorRMS = newValue } }
    }

    var fullScaleRMS: Float {
        get { lock.withLock { _fullScaleRMS } }
        set { lock.withLock { _fullScaleRMS = newValue } }
    }

    var attackSmoothing: Float {
        get { lock.withLock { _attackSmoothing } }
        set { lock.withLock { _attackSmoothing = newValue } }
    }

    var releaseSmoothing: Float {
        get { lock.withLock { _releaseSmoothing } }
        set { lock.withLock { _releaseSmoothing = newValue } }
    }

    var lowBandLowerHz: Double {
        get { lock.withLock { _lowBandLowerHz } }
        set { lock.withLock { _lowBandLowerHz = newValue } }
    }

    var lowBandUpperHz: Double {
        get { lock.withLock { _lowBandUpperHz } }
        set { lock.withLock { _lowBandUpperHz = newValue } }
    }

    var midBandUpperHz: Double {
        get { lock.withLock { _midBandUpperHz } }
        set { lock.withLock { _midBandUpperHz = newValue } }
    }

    var upperBandUpperHz: Double {
        get { lock.withLock { _upperBandUpperHz } }
        set { lock.withLock { _upperBandUpperHz = newValue } }
    }

    var highBandUpperHz: Double {
        get { lock.withLock { _highBandUpperHz } }
        set { lock.withLock { _highBandUpperHz = newValue } }
    }

    var broadbandLowerHz: Double {
        get { lock.withLock { _broadbandLowerHz } }
        set { lock.withLock { _broadbandLowerHz = newValue } }
    }

    var broadbandUpperHz: Double {
        get { lock.withLock { _broadbandUpperHz } }
        set { lock.withLock { _broadbandUpperHz = newValue } }
    }

    var broadbandRelativeThreshold: Float {
        get { lock.withLock { _broadbandRelativeThreshold } }
        set { lock.withLock { _broadbandRelativeThreshold = newValue } }
    }

    var broadbandActiveMinProportion: Float {
        get { lock.withLock { _broadbandActiveMinProportion } }
        set { lock.withLock { _broadbandActiveMinProportion = newValue } }
    }

    var broadbandActiveFullProportion: Float {
        get { lock.withLock { _broadbandActiveFullProportion } }
        set { lock.withLock { _broadbandActiveFullProportion = newValue } }
    }

    var energyScoreWeight: Float {
        get { lock.withLock { _energyScoreWeight } }
        set { lock.withLock { _energyScoreWeight = newValue } }
    }

    var broadbandScoreWeight: Float {
        get { lock.withLock { _broadbandScoreWeight } }
        set { lock.withLock { _broadbandScoreWeight = newValue } }
    }

    /// Intensity that must first be crossed to begin counting blow time.
    var strongBlowThreshold: Float {
        get { lock.withLock { _strongBlowThreshold } }
        set { lock.withLock { _strongBlowThreshold = newValue } }
    }

    /// After accumulation has started, intensity above this keeps counting;
    /// below it, accumulated time slowly decays.
    var strongBlowMaintainThreshold: Float {
        get { lock.withLock { _strongBlowMaintainThreshold } }
        set { lock.withLock { _strongBlowMaintainThreshold = newValue } }
    }

    /// How fast accumulated time decays once intensity falls below the
    /// maintain threshold. 1.0 decays at the same rate real time passes.
    var strongBlowDecayRate: Double {
        get { lock.withLock { _strongBlowDecayRate } }
        set { lock.withLock { _strongBlowDecayRate = newValue } }
    }

    /// Total accumulated strong-blow time needed before the candle goes out.
    var requiredStrongBlowDuration: TimeInterval {
        get { lock.withLock { _requiredStrongBlowDuration } }
        set { lock.withLock { _requiredStrongBlowDuration = newValue } }
    }

    /// One consistent read of every parameter, taken once per analysis frame
    /// so a single frame never mixes values from two different tunings.
    func snapshot() -> BlowDetectionParameters {
        lock.withLock {
            BlowDetectionParameters(
                silenceFloorRMS: _silenceFloorRMS,
                fullScaleRMS: _fullScaleRMS,
                attackSmoothing: _attackSmoothing,
                releaseSmoothing: _releaseSmoothing,
                lowBandLowerHz: _lowBandLowerHz,
                lowBandUpperHz: _lowBandUpperHz,
                midBandUpperHz: _midBandUpperHz,
                upperBandUpperHz: _upperBandUpperHz,
                highBandUpperHz: _highBandUpperHz,
                broadbandLowerHz: _broadbandLowerHz,
                broadbandUpperHz: _broadbandUpperHz,
                broadbandRelativeThreshold: _broadbandRelativeThreshold,
                broadbandActiveMinProportion: _broadbandActiveMinProportion,
                broadbandActiveFullProportion: _broadbandActiveFullProportion,
                energyScoreWeight: _energyScoreWeight,
                broadbandScoreWeight: _broadbandScoreWeight,
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
    let silenceFloorRMS: Float
    let fullScaleRMS: Float
    let attackSmoothing: Float
    let releaseSmoothing: Float
    let lowBandLowerHz: Double
    let lowBandUpperHz: Double
    let midBandUpperHz: Double
    let upperBandUpperHz: Double
    let highBandUpperHz: Double
    let broadbandLowerHz: Double
    let broadbandUpperHz: Double
    let broadbandRelativeThreshold: Float
    let broadbandActiveMinProportion: Float
    let broadbandActiveFullProportion: Float
    let energyScoreWeight: Float
    let broadbandScoreWeight: Float
    let strongBlowThreshold: Float
    let strongBlowMaintainThreshold: Float
    let strongBlowDecayRate: Double
    let requiredStrongBlowDuration: TimeInterval
}