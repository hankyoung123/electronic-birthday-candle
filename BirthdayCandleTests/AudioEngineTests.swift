import AVFoundation
import XCTest
@testable import BirthdayCandle

@MainActor
final class AudioEngineTests: XCTestCase {
    func testRuntimeFailuresReachMainActorCallback() {
        let engine = AudioEngine()
        var receivedErrors: [AudioEngineError] = []
        engine.onFailure = { error in
            receivedErrors.append(error)
        }

        engine.handleRuntimeFailure(.routeRecoveryFailed)
        engine.handleRuntimeFailure(.microphoneUnavailable)
        engine.handleRuntimeFailure(.sessionActivationFailed)

        XCTAssertEqual(
            receivedErrors,
            [.routeRecoveryFailed, .microphoneUnavailable, .sessionActivationFailed]
        )
    }

    /// iOS Voice Processing (AEC) must be active on the mic input once
    /// detection has started. Needs a physical device + mic permission.
    func testVoiceProcessingIsEnabledBeforeDetection() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Voice processing requires a physical device.")
        #else
        let engine = AudioEngine()
        do {
            try await engine.start()
        } catch AudioEngineError.microphonePermissionDenied {
            throw XCTSkip("Microphone permission not granted for this test run.")
        } catch {
            throw error
        }
        XCTAssertTrue(engine.isVoiceProcessingEnabled)
        engine.stop()
        #endif
    }

    func testConvertsMonoAssetBufferToStereoPlayerFormat() throws {
        let monoFormat = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)
        )
        let stereoFormat = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)
        )
        let source = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 2_205)
        )
        source.frameLength = source.frameCapacity
        if let channel = source.floatChannelData?.pointee {
            for frame in 0..<Int(source.frameLength) {
                channel[frame] = sin(Float(frame) * 0.04) * 0.2
            }
        }

        let converted = try AudioEngine.convert(source, to: stereoFormat)

        XCTAssertEqual(converted.format.channelCount, stereoFormat.channelCount)
        XCTAssertEqual(converted.format.sampleRate, stereoFormat.sampleRate)
        XCTAssertGreaterThan(converted.frameLength, source.frameLength)
    }
}
