import Foundation
import Observation

enum CeremonyNotice: String, Identifiable {
    case microphonePermissionDenied
    case microphoneUnavailable

    var id: String { rawValue }

    var title: String { "Microphone Needed" }

    var message: String {
        switch self {
        case .microphonePermissionDenied:
            "Allow microphone access in Settings so your breath can extinguish the candle."
        case .microphoneUnavailable:
            "The microphone is unavailable right now. Check the audio route and try again."
        }
    }
}

#if DEBUG
/// One timestamped observation, recorded on each intensity tick.
struct TimedSpectrum: Sendable {
    let uptime: TimeInterval
    let snapshot: BlowDebugSnapshot
    let blowScore: Float
}

/// Rolling window statistics (average + peak) for the Inspector's “Copy 3s
/// Avg”. `dbFS`/`baselineDbFS` are in dB; every other value is 0–1 normalized.
struct SpectrumRollingSummary: Sendable {
    let sampleCount: Int
    let dbFSAverage: Float
    let dbFSPeak: Float
    let baselineDbFSAverage: Float
    let totalDeltaDBAverage: Float
    let totalDeltaDBPeak: Float
    let broadbandAverage: Float
    let broadbandPeak: Float
    let rawAverage: Float
    let rawPeak: Float
    let smoothedAverage: Float
    let smoothedPeak: Float

    static let empty = SpectrumRollingSummary(
        sampleCount: 0,
        dbFSAverage: -120,
        dbFSPeak: -120,
        baselineDbFSAverage: -120,
        totalDeltaDBAverage: 0,
        totalDeltaDBPeak: 0,
        broadbandAverage: 0,
        broadbandPeak: 0,
        rawAverage: 0,
        rawPeak: 0,
        smoothedAverage: 0,
        smoothedPeak: 0
    )
}
#endif

@MainActor
@Observable
final class CeremonySession {
    private(set) var phase: CeremonyPhase = .ready
    private(set) var blowIntensity: Float = 0
    private(set) var extinguishedAt: Date?
    var notice: CeremonyNotice?
    var selectedMusic: MusicTrack = .classic
    var musicEnabled = true

    private let audioEngine: AudioEngine?
    private let hapticEngine: HapticEngine?
    private let blowConfiguration: BlowDetectionConfiguration
    private var ceremonyTask: Task<Void, Never>?
    private var strongBlowDuration: TimeInterval = 0
    private var lastBlowSampleTime: TimeInterval?
    #if DEBUG
    private var spectrumHistory: [TimedSpectrum] = []
    #endif

    init(
        audioEngine: AudioEngine? = nil,
        hapticEngine: HapticEngine? = nil,
        blowConfiguration: BlowDetectionConfiguration = .standard
    ) {
        self.audioEngine = audioEngine
        self.hapticEngine = hapticEngine
        self.blowConfiguration = blowConfiguration
        audioEngine?.onBlowIntensity = { [weak self] intensity in
            self?.receiveBlowIntensity(intensity)
        }
        audioEngine?.onFailure = { [weak self] error in
            self?.handleAudioFailure(error)
        }
    }

    func prepareMicrophoneAccess() async -> Bool {
        guard let audioEngine else { return true }
        do {
            try await audioEngine.prepareMicrophoneAccess()
            return true
        } catch let error as AudioEngineError {
            handleAudioFailure(error)
        } catch {
            handleAudioFailure(.microphoneUnavailable)
        }
        return false
    }

    func lightCandle() {
        guard phase == .ready else { return }
        transition(to: .lighting)
        hapticEngine?.ignite()
        ceremonyTask?.cancel()
        ceremonyTask = Task { [weak self] in
            if let audioEngine = self?.audioEngine {
                do {
                    try await audioEngine.start()
                } catch let error as AudioEngineError {
                    self?.handleAudioFailure(error)
                    return
                } catch {
                    self?.handleAudioFailure(.microphoneUnavailable)
                    return
                }
            }
            if let self, self.musicEnabled {
                try? self.audioEngine?.play(track: self.selectedMusic)
            }
            try? await Task.sleep(for: .milliseconds(550))
            guard !Task.isCancelled, let self, self.phase == .lighting else { return }
            self.transition(to: .lit)

            try? await Task.sleep(for: .seconds(1.7))
            guard !Task.isCancelled, self.phase == .lit else { return }
            self.transition(to: .wishing)
        }
    }

    func extinguish() {
        guard phase == .lit || phase == .wishing else { return }
        ceremonyTask?.cancel()
        audioEngine?.stopBlowDetection()
        transition(to: .extinguishing)
        hapticEngine?.extinguish()
        ceremonyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(CeremonyTiming.extinguishingDuration))
            guard !Task.isCancelled, let self, self.phase == .extinguishing else { return }
            self.extinguishedAt = Date()
            self.transition(to: .extinguished)

            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, self.phase == .extinguished else { return }
            self.transition(to: .celebrating)
        }
    }

    func restart() {
        ceremonyTask?.cancel()
        audioEngine?.stop()
        blowIntensity = 0
        strongBlowDuration = 0
        lastBlowSampleTime = nil
        extinguishedAt = nil
        #if DEBUG
        spectrumHistory.removeAll(keepingCapacity: true)
        #endif
        transition(to: .ready)
    }

    func receiveBlowIntensity(
        _ intensity: Float,
        at time: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard phase == .lit || phase == .wishing else {
            blowIntensity = 0
            return
        }
        blowIntensity = min(max(intensity, 0), 1)

        #if DEBUG
        recordSpectrumSample(at: time)
        #endif

        let elapsed = lastBlowSampleTime.map { min(max(time - $0, 0), 0.1) } ?? 0
        lastBlowSampleTime = time

        let parameters = blowConfiguration.snapshot()
        if strongBlowDuration > 0 {
            // Already counting a blow: keep accruing while the user is still
            // blowing meaningfully (above the maintain threshold), and slowly
            // lose progress below it.
            if blowIntensity >= parameters.strongBlowMaintainThreshold {
                strongBlowDuration += elapsed
            } else {
                strongBlowDuration = max(
                    0,
                    strongBlowDuration - elapsed * parameters.strongBlowDecayRate
                )
            }
        } else if blowIntensity >= parameters.strongBlowThreshold {
            // First crossing of the start threshold begins accumulation.
            strongBlowDuration += elapsed
        }

        // A 5 ms tolerance absorbs float rounding in the accumulated time
        // (e.g. four 0.1 s ticks summing to 0.3999…9 instead of 0.4), so a
        // real blow that reached the required duration is never lost.
        if strongBlowDuration + 0.005 >= parameters.requiredStrongBlowDuration {
            extinguish()
        }
    }

    private func transition(to newPhase: CeremonyPhase) {
        phase = newPhase
        switch newPhase {
        case .lit:
            if musicEnabled { audioEngine?.fadeMusic(to: 0.72, duration: 0.4) }
        case .wishing:
            if musicEnabled { audioEngine?.fadeMusic(to: 0.34, duration: 1.2) }
        case .extinguishing:
            audioEngine?.playEffect(resourceName: "extinguish", volume: 0.62)
            if musicEnabled { audioEngine?.fadeMusic(to: 0.18, duration: 0.35) }
        case .celebrating:
            if musicEnabled {
                audioEngine?.fadeMusic(to: 0.46, duration: 0.8)
                audioEngine?.playEffect(resourceName: "celebration", volume: 0.74)
            }
        case .ready, .lighting, .extinguished:
            break
        }
    }

    private func handleAudioFailure(_ error: AudioEngineError) {
        ceremonyTask?.cancel()
        audioEngine?.stop()
        blowIntensity = 0
        strongBlowDuration = 0
        lastBlowSampleTime = nil
        #if DEBUG
        spectrumHistory.removeAll(keepingCapacity: true)
        #endif
        transition(to: .ready)
        switch error {
        case .microphonePermissionDenied:
            notice = .microphonePermissionDenied
        case .microphoneUnavailable,
             .sessionActivationFailed,
             .interruptionRecoveryFailed,
             .routeRecoveryFailed:
            notice = .microphoneUnavailable
        }
    }

    #if DEBUG
    var debugInputDescription: String {
        audioEngine?.currentInputDescription ?? "Unavailable"
    }

    var debugInputSampleRate: Double {
        audioEngine?.currentInputSampleRate ?? 0
    }

    var debugBlowSnapshot: BlowDebugSnapshot {
        audioEngine?.currentBlowDebugSnapshot ?? .zero
    }

    var debugSpectrumRollingSummary: SpectrumRollingSummary {
        guard !spectrumHistory.isEmpty else { return .empty }
        var count = 0
        var rmsSquaredSum: Float = 0
        var dbPeak: Float = -120
        var baselineDbSum: Float = 0
        var totalDeltaSum: Float = 0
        var totalDeltaPeak: Float = 0
        var broadbandSum: Float = 0
        var broadbandPeak: Float = 0
        var rawSum: Float = 0
        var rawPeak: Float = 0
        var smoothedSum: Float = 0
        var smoothedPeak: Float = 0

        for entry in spectrumHistory {
            count += 1
            let snapshot = entry.snapshot
            // Average in the linear power domain, then convert back to dB —
            // averaging dBFS directly would bias toward the quietest frames.
            rmsSquaredSum += snapshot.rms * snapshot.rms
            dbPeak = max(dbPeak, snapshot.dbFS)
            baselineDbSum += snapshot.baselineDbFS
            totalDeltaSum += snapshot.totalDeltaDB
            totalDeltaPeak = max(totalDeltaPeak, snapshot.totalDeltaDB)
            broadbandSum += snapshot.broadbandScore
            broadbandPeak = max(broadbandPeak, snapshot.broadbandScore)
            rawSum += snapshot.rawScore
            rawPeak = max(rawPeak, snapshot.rawScore)
            smoothedSum += entry.blowScore
            smoothedPeak = max(smoothedPeak, entry.blowScore)
        }

        let total = Float(count)
        let meanRmsSquared = rmsSquaredSum / total
        let meanDbFS = meanRmsSquared > 0 ? 10 * log10(meanRmsSquared) : -120
        return SpectrumRollingSummary(
            sampleCount: count,
            dbFSAverage: meanDbFS,
            dbFSPeak: dbPeak,
            baselineDbFSAverage: baselineDbSum / total,
            totalDeltaDBAverage: totalDeltaSum / total,
            totalDeltaDBPeak: totalDeltaPeak,
            broadbandAverage: broadbandSum / total,
            broadbandPeak: broadbandPeak,
            rawAverage: rawSum / total,
            rawPeak: rawPeak,
            smoothedAverage: smoothedSum / total,
            smoothedPeak: smoothedPeak
        )
    }

    /// Called on every intensity tick (~30 Hz) to keep a rolling 3-second
    /// history of observations for the Inspector's “Copy 3s Avg”.
    private func recordSpectrumSample(at uptime: TimeInterval) {
        spectrumHistory.append(
            TimedSpectrum(
                uptime: uptime,
                snapshot: audioEngine?.currentBlowDebugSnapshot ?? .zero,
                blowScore: blowIntensity
            )
        )
        // Drop everything older than the window. Entries are appended in
        // chronological order, but the first stale entry may be index 0, so
        // remove-by-predicate is the correct (and complete) trim.
        let cutoff = uptime - 3.0
        spectrumHistory.removeAll { $0.uptime < cutoff }
    }

    var debugStrongBlowDuration: TimeInterval { strongBlowDuration }

    var debugStrongBlowStartThreshold: Float {
        blowConfiguration.strongBlowThreshold
    }

    var debugStrongBlowMaintainThreshold: Float {
        blowConfiguration.strongBlowMaintainThreshold
    }

    var debugRequiredStrongBlowDuration: TimeInterval {
        blowConfiguration.requiredStrongBlowDuration
    }

    var debugStrongBlowDecayRate: Double {
        blowConfiguration.strongBlowDecayRate
    }

    var debugBaselineAlpha: Double {
        blowConfiguration.baselineAlpha
    }

    var debugLowDeltaStartDB: Float {
        blowConfiguration.lowDeltaStartDB
    }

    var debugLowDeltaFullDB: Float {
        blowConfiguration.lowDeltaFullDB
    }

    var debugMidDeltaStartDB: Float {
        blowConfiguration.midDeltaStartDB
    }

    var debugMidDeltaFullDB: Float {
        blowConfiguration.midDeltaFullDB
    }

    var debugUpperDeltaStartDB: Float {
        blowConfiguration.upperDeltaStartDB
    }

    var debugUpperDeltaFullDB: Float {
        blowConfiguration.upperDeltaFullDB
    }

    var debugLowWeight: Float {
        blowConfiguration.lowWeight
    }

    var debugMidWeight: Float {
        blowConfiguration.midWeight
    }

    var debugUpperWeight: Float {
        blowConfiguration.upperWeight
    }

    var debugBroadbandWeight: Float {
        blowConfiguration.broadbandWeight
    }

    var debugBroadbandRelativeThreshold: Float {
        blowConfiguration.broadbandRelativeThreshold
    }

    var debugBroadbandActiveMinProportion: Float {
        blowConfiguration.broadbandActiveMinProportion
    }

    var debugBroadbandActiveFullProportion: Float {
        blowConfiguration.broadbandActiveFullProportion
    }

    var debugMusicVolume: Float {
        audioEngine?.currentMusicVolume ?? 0
    }

    func setDebugStrongBlowStartThreshold(_ value: Float) {
        blowConfiguration.strongBlowThreshold = min(max(value, 0), 1)
    }

    func setDebugStrongBlowMaintainThreshold(_ value: Float) {
        blowConfiguration.strongBlowMaintainThreshold = min(max(value, 0), 1)
    }

    func setDebugRequiredStrongBlowDuration(_ value: TimeInterval) {
        blowConfiguration.requiredStrongBlowDuration = max(value, 0)
    }

    func setDebugStrongBlowDecayRate(_ value: Double) {
        blowConfiguration.strongBlowDecayRate = max(value, 0)
    }

    func setDebugBaselineAlpha(_ value: Double) {
        blowConfiguration.baselineAlpha = min(max(value, 0), 0.5)
    }

    func setDebugLowDeltaStartDB(_ value: Float) {
        blowConfiguration.lowDeltaStartDB = max(value, 0)
    }

    func setDebugLowDeltaFullDB(_ value: Float) {
        blowConfiguration.lowDeltaFullDB = max(value, 0)
    }

    func setDebugMidDeltaStartDB(_ value: Float) {
        blowConfiguration.midDeltaStartDB = max(value, 0)
    }

    func setDebugMidDeltaFullDB(_ value: Float) {
        blowConfiguration.midDeltaFullDB = max(value, 0)
    }

    func setDebugUpperDeltaStartDB(_ value: Float) {
        blowConfiguration.upperDeltaStartDB = max(value, 0)
    }

    func setDebugUpperDeltaFullDB(_ value: Float) {
        blowConfiguration.upperDeltaFullDB = max(value, 0)
    }

    func setDebugLowWeight(_ value: Float) {
        blowConfiguration.lowWeight = min(max(value, 0), 1)
    }

    func setDebugMidWeight(_ value: Float) {
        blowConfiguration.midWeight = min(max(value, 0), 1)
    }

    func setDebugUpperWeight(_ value: Float) {
        blowConfiguration.upperWeight = min(max(value, 0), 1)
    }

    func setDebugBroadbandWeight(_ value: Float) {
        blowConfiguration.broadbandWeight = min(max(value, 0), 1)
    }

    func setDebugBroadbandRelativeThreshold(_ value: Float) {
        blowConfiguration.broadbandRelativeThreshold = min(max(value, 0), 1)
    }

    func setDebugBroadbandActiveMinProportion(_ value: Float) {
        blowConfiguration.broadbandActiveMinProportion = min(max(value, 0), 1)
    }

    func setDebugBroadbandActiveFullProportion(_ value: Float) {
        blowConfiguration.broadbandActiveFullProportion = min(max(value, 0), 1)
    }

    func setDebugMusicVolume(_ volume: Float) {
        audioEngine?.setMusicVolume(volume)
    }
    #endif
}
