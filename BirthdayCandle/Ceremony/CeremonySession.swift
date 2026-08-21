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
/// Avg”. `dbFS` is in dB; every other value is 0–1 normalized.
struct SpectrumRollingSummary: Sendable {
    let sampleCount: Int
    let dbFSAverage: Float
    let dbFSPeak: Float
    let windBandRMSAverage: Float
    let windBandRMSPeak: Float
    let windRatioAverage: Float
    let windRatioPeak: Float
    let rawAverage: Float
    let rawPeak: Float
    let smoothedAverage: Float
    let smoothedPeak: Float

    static let empty = SpectrumRollingSummary(
        sampleCount: 0,
        dbFSAverage: -120,
        dbFSPeak: -120,
        windBandRMSAverage: 0,
        windBandRMSPeak: 0,
        windRatioAverage: 0,
        windRatioPeak: 0,
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
    private var blowEvidence: TimeInterval = 0
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
            // Let the music fade-in settle (iOS Voice Processing cancels it
            // from the mic), then light the flame. Detection only runs while
            // phase is lit/wishing, so the fade is never scored.
            try? await Task.sleep(for: .seconds(CeremonyTiming.lightingDuration))
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
        blowEvidence = 0
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
        // Blow intensity is only consumed while the candle is lit. The 0…1
        // value drives the flame response in real time; extinguish is decided
        // here only by how long the intensity stays above the thresholds.
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
        // Evidence accumulator: strong blowing adds fast, weak (maintain-level)
        // adds slowly, and sub-maintain decays — a short dip mid-blow must not
        // erase the whole effort.
        if blowIntensity >= parameters.strongBlowThreshold {
            blowEvidence += elapsed
        } else if blowIntensity >= parameters.strongBlowMaintainThreshold {
            blowEvidence += elapsed * 0.60
        } else {
            blowEvidence = max(0, blowEvidence - elapsed * parameters.strongBlowDecayRate)
        }

        // A 5 ms tolerance absorbs float rounding in the accumulated evidence.
        if blowEvidence + 0.005 >= parameters.requiredStrongBlowDuration {
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
        blowEvidence = 0
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

    var debugVoiceProcessingEnabled: Bool {
        audioEngine?.isVoiceProcessingEnabled ?? false
    }

    var debugMicrophonePermissionGranted: Bool {
        audioEngine?.debugMicrophonePermissionGranted ?? false
    }

    var debugAudioSessionActive: Bool {
        audioEngine?.debugAudioSessionActive ?? false
    }

    var debugLastStartDiagnostic: String? {
        audioEngine?.lastStartDiagnostic
    }

    var debugPeakHoldDuration: TimeInterval {
        blowConfiguration.peakHoldDuration
    }

    func setDebugPeakHoldDuration(_ value: Double) {
        blowConfiguration.peakHoldDuration = max(0, min(value, 1))
    }

    var debugSpectrumRollingSummary: SpectrumRollingSummary {
        guard !spectrumHistory.isEmpty else { return .empty }
        var count = 0
        var rmsSquaredSum: Float = 0
        var dbPeak: Float = -120
        var windRMSSum: Float = 0
        var windRMSPeak: Float = 0
        var windRatioSum: Float = 0
        var windRatioPeak: Float = 0
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
            windRMSSum += snapshot.windBandRMS
            windRMSPeak = max(windRMSPeak, snapshot.windBandRMS)
            windRatioSum += snapshot.windRatio
            windRatioPeak = max(windRatioPeak, snapshot.windRatio)
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
            windBandRMSAverage: windRMSSum / total,
            windBandRMSPeak: windRMSPeak,
            windRatioAverage: windRatioSum / total,
            windRatioPeak: windRatioPeak,
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
        // Drop everything older than the 3s window.
        let cutoff = uptime - 3.0
        spectrumHistory.removeAll { $0.uptime < cutoff }
    }

    var debugBlowEvidence: TimeInterval { blowEvidence }

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

    var debugWindStart: Float {
        blowConfiguration.windStart
    }

    var debugWindFull: Float {
        blowConfiguration.windFull
    }

    var debugWindRatioStart: Float {
        blowConfiguration.windRatioStart
    }

    var debugWindRatioFull: Float {
        blowConfiguration.windRatioFull
    }

    var debugEnergyWeight: Float {
        blowConfiguration.energyWeight
    }

    var debugRatioWeight: Float {
        blowConfiguration.ratioWeight
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

    func setDebugWindStart(_ value: Float) {
        blowConfiguration.windStart = max(value, 0)
    }

    func setDebugWindFull(_ value: Float) {
        blowConfiguration.windFull = max(value, 0)
    }

    func setDebugWindRatioStart(_ value: Float) {
        blowConfiguration.windRatioStart = min(max(value, 0), 1)
    }

    func setDebugWindRatioFull(_ value: Float) {
        blowConfiguration.windRatioFull = min(max(value, 0), 1)
    }

    func setDebugEnergyWeight(_ value: Float) {
        blowConfiguration.energyWeight = min(max(value, 0), 1)
    }

    func setDebugRatioWeight(_ value: Float) {
        blowConfiguration.ratioWeight = min(max(value, 0), 1)
    }

    func setDebugMusicVolume(_ volume: Float) {
        audioEngine?.setMusicVolume(volume)
    }
    #endif
}