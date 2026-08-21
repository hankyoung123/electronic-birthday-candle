import AVFoundation
import Foundation

enum AudioEngineError: Error, Equatable, Sendable {
    case microphonePermissionDenied
    case microphoneUnavailable
    case sessionActivationFailed
    case interruptionRecoveryFailed
    case routeRecoveryFailed
}

private enum AudioConversionError: Error {
    case invalidFormat
    case converterUnavailable
    case bufferAllocationFailed
    case conversionFailed
}

private final class AudioConversionInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private let lock = NSLock()
    private var supplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.withLock {
            guard !supplied else {
                status.pointee = .endOfStream
                return nil
            }

            supplied = true
            status.pointee = .haveData
            return buffer
        }
    }
}

@MainActor
final class AudioEngine {
    var onBlowIntensity: (@MainActor @Sendable (Float) -> Void)?
    var onFailure: (@MainActor @Sendable (AudioEngineError) -> Void)?

    #if DEBUG
    private(set) var currentInputDescription = "Unavailable"
    private(set) var currentInputSampleRate: Double = 0

    var currentBlowDebugSnapshot: BlowDebugSnapshot {
        blowDetector.currentDebugSnapshot
    }

    var currentMusicVolume: Float { musicPlayer.volume }
    #endif

    private let engine = AVAudioEngine()
    private let musicPlayer = AVAudioPlayerNode()
    private let effectPlayer = AVAudioPlayerNode()
    private let blowDetector: BlowDetector
    private var inputTapInstalled = false
    private var detectionRequested = false
    private var intensityDeliveryTask: Task<Void, Never>?
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

    func prepareMicrophoneAccess() async throws {
        guard await requestMicrophonePermission() else {
            throw AudioEngineError.microphonePermissionDenied
        }
    }

    func start() async throws {
        guard AVAudioApplication.shared.recordPermission == .granted else {
            #if DEBUG
            lastStartDiagnostic = "Microphone permission denied"
            #endif
            throw AudioEngineError.microphonePermissionDenied
        }
        detectionRequested = true

        do {
            // Single AEC/input path: session → voice processing → tap → engine.
            try configureInputPath()
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
        } catch let error as AudioEngineError {
            throw error
        } catch {
            #if DEBUG
            lastStartDiagnostic = "Audio session activation failed"
            #endif
            throw AudioEngineError.sessionActivationFailed
        }
        #if DEBUG
        lastStartDiagnostic = nil
        #endif
        startIntensityDelivery()
    }

    /// Whether Voice Processing (system AEC) is active on the mic input.
    var isVoiceProcessingEnabled: Bool {
        engine.inputNode.isVoiceProcessingEnabled
    }

    /// Human-readable reason for the last start failure (Debug only).
    #if DEBUG
    private(set) var lastStartDiagnostic: String?
    #endif

    /// Uniform input-path setup shared by first start, interruption recovery and
    /// route changes: activate the session, enable Voice Processing (the only
    /// AEC path), then install the mic tap on the voice-processed input.
    private func configureInputPath() throws {
        try configureSession()
        try enableVoiceProcessing()
        try installInputTapIfNeeded()
    }

    private func enableVoiceProcessing() throws {
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
        } catch {
            #if DEBUG
            lastStartDiagnostic = "Voice Processing initialization failed"
            #endif
            throw AudioEngineError.sessionActivationFailed
        }
        // Enabling voice processing can change the input node's format; the tap
        // (re)installed afterwards runs on the voice-processed input.
        if inputTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
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
        #if DEBUG
        audioSessionActive = false
        #endif
    }

    func stopBlowDetection() {
        detectionRequested = false
        intensityDeliveryTask?.cancel()
        intensityDeliveryTask = nil
        if inputTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        blowDetector.reset()
    }

    func handleRuntimeFailure(_ error: AudioEngineError) {
        stop()
        onFailure?(error)
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

        let conversionInput = AudioConversionInput(buffer: sourceBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            conversionInput.next(status: inputStatus)
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
            options: [.defaultToSpeaker]
        )
        #if DEBUG
        do {
            try session.setActive(true)
            audioSessionActive = true
        } catch {
            lastStartDiagnostic = "Audio session activation failed"
            throw error
        }
        #else
        try session.setActive(true)
        #endif
        preferBuiltInMicrophone(on: session)
        try session.overrideOutputAudioPort(.speaker)
        updateCurrentInputDescription(from: session)
    }

    /// Current session context for the Debug panel.
    #if DEBUG
    private(set) var audioSessionActive = false

    var debugMicrophonePermissionGranted: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    var debugAudioSessionActive: Bool {
        audioSessionActive
    }
    #endif

    private func preferBuiltInMicrophone(on session: AVAudioSession) {
        guard let builtInMicrophone = session.availableInputs?.first(where: {
            $0.portType == .builtInMic
        }) else {
            return
        }

        // Mic preference is best-effort and must never abort the ceremony.
        // Prefer the front-facing built-in microphone (usually the best pick
        // for blowing at the phone screen), but if that preference fails the
        // system keeps the default built-in mic and recording still works.
        try? session.setPreferredInput(builtInMicrophone)

        if let frontSource = builtInMicrophone.dataSources?.first(where: {
            $0.orientation == .front
        }) {
            try? builtInMicrophone.setPreferredDataSource(frontSource)
        }
    }

    private func updateCurrentInputDescription(from session: AVAudioSession) {
        #if DEBUG
        guard let input = session.currentRoute.inputs.first else {
            currentInputDescription = "Unavailable"
            return
        }

        if let dataSource = input.selectedDataSource {
            currentInputDescription = "\(input.portName) — \(dataSource.dataSourceName)"
        } else {
            currentInputDescription = input.portName
        }
        #endif
    }

    private func installInputTapIfNeeded() throws {
        guard detectionRequested, !inputTapInstalled else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioEngineError.microphoneUnavailable
        }
        #if DEBUG
        currentInputSampleRate = format.sampleRate
        #endif

        input.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: format,
            block: Self.makeInputTap(
                detector: blowDetector,
                sampleRate: format.sampleRate
            )
        )
        inputTapInstalled = true
    }

    nonisolated private static func makeInputTap(
        detector: BlowDetector,
        sampleRate: Double
    ) -> AVAudioNodeTapBlock {
        { @Sendable buffer, _ in
            guard
                let channel = buffer.floatChannelData?.pointee
            else { return }

            let samples = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
            detector.analyze(samples: samples, sampleRate: sampleRate)
        }
    }

    private func startIntensityDelivery() {
        guard intensityDeliveryTask == nil else { return }
        intensityDeliveryTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.onBlowIntensity?(self.blowDetector.currentIntensity)
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else {
                    return
                }
                let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                Task { @MainActor [weak self] in
                    self?.handleInterruption(type: type, options: options)
                }
            }
        )
        notificationTokens.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt else {
                    return
                }
                Task { @MainActor [weak self] in
                    self?.handleRouteChange(reason: reason)
                }
            }
        )
    }

    private func handleInterruption(type rawType: UInt, options rawOptions: UInt) {
        guard
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        switch type {
        case .began:
            wasMusicPlayingBeforeInterruption = musicPlayer.isPlaying
            musicPlayer.pause()
            effectPlayer.pause()
            engine.pause()
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            guard options.contains(.shouldResume) else {
                handleRuntimeFailure(.interruptionRecoveryFailed)
                return
            }
            do {
                try configureInputPath()
                try engine.start()
                if wasMusicPlayingBeforeInterruption { musicPlayer.play() }
            } catch {
                handleRuntimeFailure(.interruptionRecoveryFailed)
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reason rawReason: UInt) {
        guard
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
            try configureInputPath()
            engine.prepare()
            try engine.start()
            if shouldResumeMusic { musicPlayer.play() }
        } catch {
            handleRuntimeFailure(.routeRecoveryFailed)
        }
    }
}
