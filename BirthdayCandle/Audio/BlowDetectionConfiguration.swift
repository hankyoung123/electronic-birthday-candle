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
/// Detection model (this round — adaptive spectral delta):
///
///     spectrum → adaptive baseline → dB deltas → spectral delta score
///               → raw score → temporal confirmation (CeremonySession)
///
/// The baseline tracks the *ambient* spectrum (including background music /
/// noise) so detection measures how much the input rose ABOVE the environment,
/// not how loud it is in absolute terms. Scoring uses only the low/mid/upper
/// band deltas plus a small broadband confirmation; the high band and absolute
/// RMS are diagnostics only. Single production path, additive, no ML, no AEC.
final class BlowDetectionConfiguration: @unchecked Sendable {
    private let lock = NSLock()

    // Baseline (ambient spectrum) adaptation.
    /// EMA coefficient once the baseline is established.
    private var _baselineAlpha: Double = 0.02
    /// Faster EMA used during the initial warm-up window.
    private var _baselineWarmupAlpha: Double = 0.25
    /// Length of the initial fast-adaptation window after the detector starts.
    private var _baselineWarmupDuration: TimeInterval = 0.6
    /// Above this smoothed score the baseline freezes so a sustained blow never
    /// gets absorbed into the ambient.
    private var _candidateFreezeThreshold: Float = 0.20

    // dB-delta scoring bounds (normalize(deltaDB, startDB, fullDB)).
    private var _lowDeltaStartDB: Float = 1.5
    private var _lowDeltaFullDB: Float = 8.0
    private var _midDeltaStartDB: Float = 1.5
    private var _midDeltaFullDB: Float = 8.0
    private var _upperDeltaStartDB: Float = 1.0
    private var _upperDeltaFullDB: Float = 7.0

    // Weights. spectralDeltaScore = low*lowWt + mid*midWt + upper*upperWt.
    // rawScore = spectralDeltaScore * (1 - broadbandWt) + broadbandScore * broadbandWt.
    private var _lowWeight: Float = 0.40
    private var _midWeight: Float = 0.35
    private var _upperWeight: Float = 0.15
    private var _broadbandWeight: Float = 0.15

    // Band edges (Hz). Analysis bands: [80,300) [300,800) [800,2000) [2000,5000).
    private var _lowBandLowerHz: Double = 80
    private var _lowBandUpperHz: Double = 300
    private var _midBandUpperHz: Double = 800
    private var _upperBandUpperHz: Double = 2_000
    private var _highBandUpperHz: Double = 5_000

    // Broadband band edges (Hz) and active-bin criteria.
    private var _broadbandLowerHz: Double = 80
    private var _broadbandUpperHz: Double = 2_000
    /// A bin counts as “active” when it holds at least this fraction of the
    /// band’s peak-power bin.
    private var _broadbandRelativeThreshold: Float = 0.25
    /// Proportion of active bins below which Broadband Score is zero.
    private var _broadbandActiveMinProportion: Float = 0.25
    /// Proportion of active bins at/above which Broadband Score is one.
    private var _broadbandActiveFullProportion: Float = 0.70

    // Silence handling / smoothing.
    /// Below this RMS the broadband term is disabled (and silence stays clean).
    private var _silenceFloorRMS: Float = 0.012
    private var _attackSmoothing: Float = 0.28
    private var _releaseSmoothing: Float = 0.10

    // Strong-blow accumulator (CeremonySession).
    private var _strongBlowThreshold: Float = 0.40
    private var _strongBlowMaintainThreshold: Float = 0.20
    private var _strongBlowDecayRate: Double = 0.4
    private var _requiredStrongBlowDuration: TimeInterval = 0.4

    init() {}

    var baselineAlpha: Double {
        get { lock.withLock { _baselineAlpha } }
        set { lock.withLock { _baselineAlpha = newValue } }
    }

    var baselineWarmupAlpha: Double {
        get { lock.withLock { _baselineWarmupAlpha } }
        set { lock.withLock { _baselineWarmupAlpha = newValue } }
    }

    var baselineWarmupDuration: TimeInterval {
        get { lock.withLock { _baselineWarmupDuration } }
        set { lock.withLock { _baselineWarmupDuration = newValue } }
    }

    var candidateFreezeThreshold: Float {
        get { lock.withLock { _candidateFreezeThreshold } }
        set { lock.withLock { _candidateFreezeThreshold = newValue } }
    }

    var lowDeltaStartDB: Float {
        get { lock.withLock { _lowDeltaStartDB } }
        set { lock.withLock { _lowDeltaStartDB = newValue } }
    }

    var lowDeltaFullDB: Float {
        get { lock.withLock { _lowDeltaFullDB } }
        set { lock.withLock { _lowDeltaFullDB = newValue } }
    }

    var midDeltaStartDB: Float {
        get { lock.withLock { _midDeltaStartDB } }
        set { lock.withLock { _midDeltaStartDB = newValue } }
    }

    var midDeltaFullDB: Float {
        get { lock.withLock { _midDeltaFullDB } }
        set { lock.withLock { _midDeltaFullDB = newValue } }
    }

    var upperDeltaStartDB: Float {
        get { lock.withLock { _upperDeltaStartDB } }
        set { lock.withLock { _upperDeltaStartDB = newValue } }
    }

    var upperDeltaFullDB: Float {
        get { lock.withLock { _upperDeltaFullDB } }
        set { lock.withLock { _upperDeltaFullDB = newValue } }
    }

    var lowWeight: Float {
        get { lock.withLock { _lowWeight } }
        set { lock.withLock { _lowWeight = newValue } }
    }

    var midWeight: Float {
        get { lock.withLock { _midWeight } }
        set { lock.withLock { _midWeight = newValue } }
    }

    var upperWeight: Float {
        get { lock.withLock { _upperWeight } }
        set { lock.withLock { _upperWeight = newValue } }
    }

    var broadbandWeight: Float {
        get { lock.withLock { _broadbandWeight } }
        set { lock.withLock { _broadbandWeight = newValue } }
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

    var silenceFloorRMS: Float {
        get { lock.withLock { _silenceFloorRMS } }
        set { lock.withLock { _silenceFloorRMS = newValue } }
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
                baselineAlpha: _baselineAlpha,
                baselineWarmupAlpha: _baselineWarmupAlpha,
                baselineWarmupDuration: _baselineWarmupDuration,
                candidateFreezeThreshold: _candidateFreezeThreshold,
                lowDeltaStartDB: _lowDeltaStartDB,
                lowDeltaFullDB: _lowDeltaFullDB,
                midDeltaStartDB: _midDeltaStartDB,
                midDeltaFullDB: _midDeltaFullDB,
                upperDeltaStartDB: _upperDeltaStartDB,
                upperDeltaFullDB: _upperDeltaFullDB,
                lowWeight: _lowWeight,
                midWeight: _midWeight,
                upperWeight: _upperWeight,
                broadbandWeight: _broadbandWeight,
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
                silenceFloorRMS: _silenceFloorRMS,
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
    let baselineAlpha: Double
    let baselineWarmupAlpha: Double
    let baselineWarmupDuration: TimeInterval
    let candidateFreezeThreshold: Float
    let lowDeltaStartDB: Float
    let lowDeltaFullDB: Float
    let midDeltaStartDB: Float
    let midDeltaFullDB: Float
    let upperDeltaStartDB: Float
    let upperDeltaFullDB: Float
    let lowWeight: Float
    let midWeight: Float
    let upperWeight: Float
    let broadbandWeight: Float
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
    let silenceFloorRMS: Float
    let attackSmoothing: Float
    let releaseSmoothing: Float
    let strongBlowThreshold: Float
    let strongBlowMaintainThreshold: Float
    let strongBlowDecayRate: Double
    let requiredStrongBlowDuration: TimeInterval
}