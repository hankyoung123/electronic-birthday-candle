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

@MainActor
@Observable
final class CeremonySession {
    private(set) var phase: CeremonyPhase = .ready
    /// Low-latency 80–500 Hz energy used only by the flame animation.
    private(set) var blowIntensity: Float = 0
    /// Apple Sound Analysis result used by the extinguish policy.
    private(set) var blowConfidence: Double = 0
    private(set) var extinguishedAt: Date?
    var notice: CeremonyNotice?
    var selectedMusic: MusicTrack = .classic
    var musicEnabled = true

    private let audioEngine: AudioEngine?
    private let hapticEngine: HapticEngine?
    private let blowConfiguration: BlowDetectionConfiguration
    private var ceremonyTask: Task<Void, Never>?
    private var blowEvidence: TimeInterval = 0
    private var lastBlowConfidenceTime: TimeInterval?

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
        audioEngine?.onBlowConfidence = { [weak self] confidence in
            self?.receiveBlowConfidence(confidence)
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
        resetBlowState()
        extinguishedAt = nil
        transition(to: .ready)
    }

    /// Visual-only input. It can animate the flame but can never extinguish it.
    func receiveBlowIntensity(_ intensity: Float) {
        guard phase == .lit || phase == .wishing else {
            blowIntensity = 0
            return
        }
        blowIntensity = min(max(intensity, 0), 1)
    }

    /// The sole semantic extinguish input, produced by SoundClassifier.
    func receiveBlowConfidence(
        _ confidence: Double,
        at time: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard phase == .lit || phase == .wishing else {
            blowConfidence = 0
            blowEvidence = 0
            lastBlowConfidenceTime = nil
            return
        }

        blowConfidence = min(max(confidence, 0), 1)
        let elapsed = lastBlowConfidenceTime.map { min(max(time - $0, 0), 0.1) } ?? 0
        lastBlowConfidenceTime = time

        if blowConfidence >= blowConfiguration.blowConfidenceThreshold {
            blowEvidence += elapsed
        } else {
            blowEvidence = max(0, blowEvidence - elapsed * blowConfiguration.decayRate)
        }

        // Absorb floating-point rounding at a 30 Hz delivery cadence.
        if blowEvidence + 0.005 >= blowConfiguration.requiredDuration {
            extinguish()
        }
    }

    private func resetBlowState() {
        blowIntensity = 0
        blowConfidence = 0
        blowEvidence = 0
        lastBlowConfidenceTime = nil
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
        resetBlowState()
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
    var debugInputDescription: String { audioEngine?.currentInputDescription ?? "Unavailable" }
    var debugInputSampleRate: Double { audioEngine?.currentInputSampleRate ?? 0 }
    var debugBlowSnapshot: BlowDebugSnapshot { audioEngine?.currentBlowDebugSnapshot ?? .zero }
    var debugSoundClassificationSnapshot: SoundClassificationSnapshot {
        audioEngine?.currentSoundClassificationSnapshot ?? .zero
    }
    var debugSoundClassificationDiagnostic: String? { audioEngine?.soundClassificationDiagnostic }
    var debugVoiceProcessingEnabled: Bool { audioEngine?.isVoiceProcessingEnabled ?? false }
    var debugMicrophonePermissionGranted: Bool { audioEngine?.debugMicrophonePermissionGranted ?? false }
    var debugAudioSessionActive: Bool { audioEngine?.debugAudioSessionActive ?? false }
    var debugLastStartDiagnostic: String? { audioEngine?.lastStartDiagnostic }
    var debugBlowEvidence: TimeInterval { blowEvidence }
    var debugBlowConfidenceThreshold: Double { blowConfiguration.blowConfidenceThreshold }
    var debugRequiredBlowDuration: TimeInterval { blowConfiguration.requiredDuration }
    var debugBlowDecayRate: Double { blowConfiguration.decayRate }
    var debugMusicVolume: Float { audioEngine?.currentMusicVolume ?? 0 }

    func setDebugMusicVolume(_ volume: Float) {
        audioEngine?.setMusicVolume(volume)
    }
    #endif
}
