@preconcurrency import AVFoundation
import Foundation

enum AudioEngineError: Error {
    case microphonePermissionDenied
    case microphoneUnavailable
}

private enum AudioConversionError: Error {
    case invalidFormat
    case converterUnavailable
    case bufferAllocationFailed
    case conversionFailed
}

@MainActor
final class AudioEngine {
    var onBlowIntensity: (@MainActor @Sendable (Float) -> Void)?

    private let engine = AVAudioEngine()
    private let musicPlayer = AVAudioPlayerNode()
    private let effectPlayer = AVAudioPlayerNode()
    private let blowDetector: BlowDetector
    private var inputTapInstalled = false
    private var detectionRequested = false
    private var musicFadeTask: Task<Void, Never>?
    private var notificationTokens: [NSObjectProtocol] = []
    private var wasMusicPlayingBeforeInterruption = false

    init(blowDetector: BlowDetector = BlowDetector()) {
        self.blowDetector = blowDetector
        engine.attach(musicPlayer)
        engine.attach(effectPlayer)
        engine.connect(musicPlayer, to: engine.mainMixerNode, format: nil)
        engine.connect(effectPlayer, to: engine.mainMixerNode, format: nil)
        observeAudioSession()
    }

    func start() async throws {
        detectionRequested = true
        guard await requestMicrophonePermission() else {
            throw AudioEngineError.microphonePermissionDenied
        }

        try configureSession()
        try installInputTapIfNeeded()
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    func stop() {
        musicFadeTask?.cancel()
        musicPlayer.stop()
        effectPlayer.stop()
        stopBlowDetection()
        engine.stop()
        blowDetector.reset()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func stopBlowDetection() {
        detectionRequested = false
        if inputTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        blowDetector.reset()
    }

    func play(track: MusicTrack) throws {
        guard let buffer = try playbackBuffer(resourceName: track.resourceName, for: musicPlayer) else { return }

        musicPlayer.stop()
        musicPlayer.volume = 0
        musicPlayer.scheduleBuffer(buffer, at: nil, options: .loops)
        musicPlayer.play()
        fadeMusic(to: 0.72, duration: 1.1)
    }

    func stopMusic() {
        musicFadeTask?.cancel()
        musicPlayer.stop()
    }

    func setMusicVolume(_ volume: Float) {
        musicFadeTask?.cancel()
        musicPlayer.volume = min(max(volume, 0), 1)
    }

    func fadeMusic(to target: Float, duration: TimeInterval) {
        musicFadeTask?.cancel()
        let start = musicPlayer.volume
        let clampedTarget = min(max(target, 0), 1)
        let steps = max(Int(duration / 0.03), 1)
        musicFadeTask = Task { [weak self] in
            for step in 1...steps {
                guard !Task.isCancelled, let self else { return }
                let progress = Float(step) / Float(steps)
                self.musicPlayer.volume = start + (clampedTarget - start) * progress
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
    }

    func playEffect(resourceName: String, volume: Float = 0.7) {
        do {
            guard let buffer = try playbackBuffer(resourceName: resourceName, for: effectPlayer) else { return }
            effectPlayer.stop()
            effectPlayer.volume = volume
            effectPlayer.scheduleBuffer(buffer)
            effectPlayer.play()
        } catch {
            return
        }
    }

    private func playbackBuffer(
        resourceName: String,
        for player: AVAudioPlayerNode
    ) throws -> AVAudioPCMBuffer? {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "wav") else {
            return nil
        }

        let file = try AVAudioFile(forReading: url)
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw AudioConversionError.bufferAllocationFailed
        }
        try file.read(into: sourceBuffer)

        return try Self.convert(sourceBuffer, to: player.outputFormat(forBus: 0))
    }

    static func convert(
        _ sourceBuffer: AVAudioPCMBuffer,
        to outputFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        guard
            sourceBuffer.format.channelCount > 0,
            sourceBuffer.format.sampleRate > 0,
            outputFormat.channelCount > 0,
            outputFormat.sampleRate > 0
        else {
            throw AudioConversionError.invalidFormat
        }

        if sourceBuffer.format == outputFormat {
            return sourceBuffer
        }

        guard let converter = AVAudioConverter(from: sourceBuffer.format, to: outputFormat) else {
            throw AudioConversionError.converterUnavailable
        }

        let sampleRateRatio = outputFormat.sampleRate / sourceBuffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(
            ceil(Double(sourceBuffer.frameLength) * sampleRateRatio) + 32
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputCapacity
        ) else {
            throw AudioConversionError.bufferAllocationFailed
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .endOfStream
                return nil
            }

            suppliedInput = true
            inputStatus.pointee = .haveData
            return sourceBuffer
        }

        guard
            conversionError == nil,
            status != .error,
            outputBuffer.frameLength > 0
        else {
            throw conversionError ?? AudioConversionError.conversionFailed
        }

        return outputBuffer
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        try session.setActive(true)
    }

    private func installInputTapIfNeeded() throws {
        guard detectionRequested, !inputTapInstalled else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioEngineError.microphoneUnavailable
        }

        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            guard
                let self,
                let channel = buffer.floatChannelData?.pointee
            else { return }

            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            let intensity = self.blowDetector.analyze(samples: samples, sampleRate: format.sampleRate)
            Task { @MainActor [weak self] in
                self?.onBlowIntensity?(intensity)
            }
        }
        inputTapInstalled = true
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.handleInterruption(notification)
                }
            }
        )
        notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.handleRouteChange(notification)
                }
            }
        )
    }

    private func handleInterruption(_ notification: Notification) {
        guard
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        switch type {
        case .began:
            wasMusicPlayingBeforeInterruption = musicPlayer.isPlaying
            musicPlayer.pause()
            effectPlayer.pause()
            engine.pause()
        case .ended:
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            guard options.contains(.shouldResume) else { return }
            do {
                try configureSession()
                try installInputTapIfNeeded()
                try engine.start()
                if wasMusicPlayingBeforeInterruption { musicPlayer.play() }
            } catch {
                stop()
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard
            let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason),
            reason == .oldDeviceUnavailable || reason == .newDeviceAvailable
        else { return }

        let shouldResumeMusic = musicPlayer.isPlaying
        if inputTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        engine.stop()
        do {
            try configureSession()
            try installInputTapIfNeeded()
            engine.prepare()
            try engine.start()
            if shouldResumeMusic { musicPlayer.play() }
        } catch {
            stop()
        }
    }
}
