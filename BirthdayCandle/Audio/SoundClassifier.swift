import AVFoundation
import CoreMedia
import Foundation
import SoundAnalysis

struct SoundClassificationPrediction: Equatable, Identifiable, Sendable {
    let identifier: String
    let confidence: Double

    var id: String { identifier }
}

struct SoundClassificationSnapshot: Equatable, Sendable {
    static let windNoiseIdentifier = "wind_noise_microphone"
    static let breathingIdentifier = "breathing"
    static let speechIdentifier = "speech"
    static let musicIdentifier = "music"

    let topClassifications: [SoundClassificationPrediction]
    let windNoiseConfidence: Double
    let breathingConfidence: Double
    let speechConfidence: Double
    let musicConfidence: Double
    let blowConfidence: Double

    static let zero = SoundClassificationSnapshot(classifications: [])

    init(classifications: [SoundClassificationPrediction]) {
        let normalized = classifications.map {
            SoundClassificationPrediction(
                identifier: $0.identifier,
                confidence: Self.clamp($0.confidence)
            )
        }
        topClassifications = Array(
            normalized
                .sorted { $0.confidence > $1.confidence }
                .prefix(5)
        )

        var confidenceByIdentifier: [String: Double] = [:]
        for classification in normalized {
            confidenceByIdentifier[classification.identifier] = max(
                confidenceByIdentifier[classification.identifier] ?? 0,
                classification.confidence
            )
        }

        windNoiseConfidence = confidenceByIdentifier[Self.windNoiseIdentifier] ?? 0
        breathingConfidence = confidenceByIdentifier[Self.breathingIdentifier] ?? 0
        speechConfidence = confidenceByIdentifier[Self.speechIdentifier] ?? 0
        musicConfidence = confidenceByIdentifier[Self.musicIdentifier] ?? 0

        let airflowConfidence = max(windNoiseConfidence, breathingConfidence * 0.7)
        blowConfidence = Self.clamp(airflowConfidence * (1 - speechConfidence))
    }

    private static func clamp(_ confidence: Double) -> Double {
        min(max(confidence, 0), 1)
    }
}

/// Apple Sound Analysis classifier fed by AudioEngine's existing microphone tap.
///
/// This component owns sound classification and the minimal blow-confidence
/// formula. AudioEngine remains the sole owner of PCM capture and routing.
final class SoundClassifier: NSObject, SNResultsObserving, @unchecked Sendable {
    private let analyzerLock = NSLock()
    private let resultLock = NSLock()
    private var analyzer: SNAudioStreamAnalyzer?
    private var request: SNClassifySoundRequest?
    private var nextFramePosition: AVAudioFramePosition = 0
    private var snapshot: SoundClassificationSnapshot = .zero
    private var errorDescription: String?

    func start(format: AVAudioFormat) throws {
        stop()
        resultLock.withLock {
            snapshot = .zero
            errorDescription = nil
        }

        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTime(seconds: 0.5, preferredTimescale: 1_000)
            request.overlapFactor = 0.8

            let analyzer = SNAudioStreamAnalyzer(format: format)
            try analyzer.add(request, withObserver: self)

            analyzerLock.withLock {
                self.analyzer = analyzer
                self.request = request
                nextFramePosition = 0
            }
        } catch {
            resultLock.withLock {
                snapshot = .zero
                errorDescription = error.localizedDescription
            }
            throw error
        }
    }

    func analyze(_ buffer: AVAudioPCMBuffer) {
        let analysis: (SNAudioStreamAnalyzer, AVAudioFramePosition)? = analyzerLock.withLock {
            guard let analyzer else { return nil }
            let framePosition = nextFramePosition
            nextFramePosition += AVAudioFramePosition(buffer.frameLength)
            return (analyzer, framePosition)
        }

        guard let analysis else { return }
        analysis.0.analyze(buffer, atAudioFramePosition: analysis.1)
    }

    func stop() {
        let analyzerToComplete = analyzerLock.withLock {
            let currentAnalyzer = analyzer
            analyzer = nil
            request = nil
            nextFramePosition = 0
            return currentAnalyzer
        }
        analyzerToComplete?.completeAnalysis()
    }

    var currentSnapshot: SoundClassificationSnapshot {
        resultLock.withLock { snapshot }
    }

    var lastErrorDescription: String? {
        resultLock.withLock { errorDescription }
    }

    func request(_ request: any SNRequest, didProduce result: any SNResult) {
        guard let classificationResult = result as? SNClassificationResult else { return }
        let classifications = classificationResult.classifications.map {
            SoundClassificationPrediction(
                identifier: $0.identifier,
                confidence: $0.confidence
            )
        }
        let nextSnapshot = SoundClassificationSnapshot(classifications: classifications)
        resultLock.withLock {
            snapshot = nextSnapshot
            errorDescription = nil
        }
    }

    func request(_ request: any SNRequest, didFailWithError error: any Error) {
        resultLock.withLock {
            errorDescription = error.localizedDescription
        }
    }

    func requestDidComplete(_ request: any SNRequest) {}
}
