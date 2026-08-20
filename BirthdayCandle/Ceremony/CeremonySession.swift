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

        let elapsed = lastBlowSampleTime.map { min(max(time - $0, 0), 0.1) } ?? 0
        lastBlowSampleTime = time

        if blowIntensity >= blowConfiguration.strongBlowThreshold {
            strongBlowDuration += elapsed
        } else if blowIntensity >= blowConfiguration.strongBlowMaintainThreshold {
            // Short dips during a real blow should not erase already-earned
            // progress. Keep the accumulator alive while the user is still
            // blowing meaningfully.
        } else {
            strongBlowDuration = max(
                0,
                strongBlowDuration - elapsed * blowConfiguration.strongBlowDecayRate
            )
        }

        if strongBlowDuration >= blowConfiguration.requiredStrongBlowDuration {
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

    var debugMusicVolume: Float {
        audioEngine?.currentMusicVolume ?? 0
    }

    func setDebugMusicVolume(_ volume: Float) {
        audioEngine?.setMusicVolume(volume)
    }
    #endif
}
