import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@MainActor
struct CeremonyView: View {
    let session: CeremonySession
    @State private var activeSheet: CeremonySheet?
    @State private var isRequestingMicrophoneAccess = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 34) {
                Spacer(minLength: 48)
                message
                    .frame(height: 48)
                    .animation(.easeInOut(duration: 0.55), value: session.phase)
                CandleView(
                    phase: session.phase,
                    blowIntensity: session.blowIntensity,
                    extinguishedAt: session.extinguishedAt
                )
                .frame(maxHeight: .infinity)
                controls.frame(minHeight: 76)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
        .statusBarHidden(session.phase != .ready)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .preparation:
                MusicPicker(session: session)
            }
        }
        .alert(item: Binding(get: { session.notice }, set: { session.notice = $0 })) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    @ViewBuilder
    private var message: some View {
        Group {
            switch session.phase {
            case .ready: Text("Make a birthday wish.")
            case .lighting: Text("Lighting…")
            case .lit, .wishing: Text("Make a wish.")
            case .extinguishing, .extinguished: Text("")
            case .celebrating: Text("Happy Birthday.")
            }
        }
        .font(.system(size: session.phase == .celebrating ? 30 : 21, weight: .light, design: .rounded))
        .tracking(0.5)
        .foregroundStyle(.white.opacity(session.phase == .wishing ? 0.68 : 0.9))
        .multilineTextAlignment(.center)
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
        .accessibilityAddTraits(session.phase == .celebrating ? .isHeader : [])
    }

    @ViewBuilder
    private var controls: some View {
        switch session.phase {
        case .ready:
            Button(isRequestingMicrophoneAccess ? "Preparing…" : "Start") {
                guard !isRequestingMicrophoneAccess else { return }
                isRequestingMicrophoneAccess = true
                Task {
                    let isReady = await session.prepareMicrophoneAccess()
                    isRequestingMicrophoneAccess = false
                    if isReady { activeSheet = .preparation }
                }
            }
            .buttonStyle(CeremonyButtonStyle())
            .disabled(isRequestingMicrophoneAccess)
        case .lighting, .lit, .wishing, .extinguishing, .extinguished:
            #if DEBUG
            BlowInspector(session: session)
            #else
            EmptyView()
            #endif
        case .celebrating:
            VStack(spacing: 12) {
                #if DEBUG
                BlowInspector(session: session)
                #endif
                Button("Again") { session.restart() }
                    .buttonStyle(CeremonyButtonStyle())
            }
        }
    }
}

#if DEBUG
@MainActor
private struct BlowInspector: View {
    let session: CeremonySession
    @State private var copiedLabel: String?

    var body: some View {
        let visual = session.debugBlowSnapshot
        let classification = session.debugSoundClassificationSnapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Blow Inspector")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.orange.opacity(0.9))

                metric("Input Route", session.debugInputDescription)
                metric("Sample Rate", "\(Int(session.debugInputSampleRate.rounded())) Hz")
                metric("Voice Processing", session.debugVoiceProcessingEnabled ? "On" : "Off")
                metric("Mic Permission", session.debugMicrophonePermissionGranted ? "Granted" : "Denied")
                metric("Session Active", session.debugAudioSessionActive ? "Yes" : "No")
                if let diagnostic = session.debugLastStartDiagnostic {
                    metric("Start Failure", diagnostic)
                }

                Divider().overlay(.white.opacity(0.12))

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Apple Sound Analysis")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.cyan.opacity(0.9))
                        Text("Classifier — extinguish source")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.52))
                    }
                    Spacer()
                    copyButton("Copy Classifier", label: "Classifier ✓", text: classificationText)
                }

                if let diagnostic = session.debugSoundClassificationDiagnostic {
                    metric("Classifier Error", diagnostic)
                }
                Text("Top 5")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.68))
                if classification.topClassifications.isEmpty {
                    metric("Waiting", "Listening for a 0.5 s window…")
                } else {
                    ForEach(Array(classification.topClassifications.enumerated()), id: \.offset) { index, prediction in
                        classificationRow(index: index + 1, prediction: prediction)
                    }
                }

                progressRow("Wind Noise", value: classification.windNoiseConfidence)
                progressRow("Breathing", value: classification.breathingConfidence)
                progressRow("Speech", value: classification.speechConfidence)
                progressRow("Music", value: classification.musicConfidence)
                progressRow("Current Blow", value: classification.blowConfidence)
                progressRow(
                    "Evidence",
                    value: session.debugRequiredBlowDuration > 0
                        ? session.debugBlowEvidence / session.debugRequiredBlowDuration
                        : 0,
                    detail: String(
                        format: "%.2f / %.2f s",
                        session.debugBlowEvidence,
                        session.debugRequiredBlowDuration
                    )
                )
                metric("Threshold", confidence(session.debugBlowConfidenceThreshold))
                metric("Duration", String(format: "%.2f s", session.debugRequiredBlowDuration))
                metric("Decay", String(format: "%.2f×", session.debugBlowDecayRate))

                Divider().overlay(.white.opacity(0.12))

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Visual Response")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.orange.opacity(0.9))
                        Text("80–500 Hz RMS — animation only")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.52))
                    }
                    Spacer()
                    copyButton("Copy Visual", label: "Visual ✓", text: visualText)
                }
                metric("RMS / dBFS", "\(formatted(visual.rms)) / \(String(format: "%.1f dB", visual.dbFS))")
                metric("80–500 Hz RMS", formatted(visual.windBandRMS))
                progressRow("Visual Intensity", value: Double(visual.visualIntensity))

                Divider().overlay(.white.opacity(0.12))

                HStack(spacing: 8) {
                    Text("Music").frame(width: 120, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { Double(session.debugMusicVolume) },
                            set: { session.setDebugMusicVolume(Float($0)) }
                        ),
                        in: 0...1,
                        step: 0.1
                    )
                    .tint(.orange.opacity(0.72))
                    Text("\(Int((session.debugMusicVolume * 100).rounded()))%")
                        .frame(width: 70, alignment: .trailing)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.white.opacity(0.76))
            .padding(12)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxHeight: 500)
        .accessibilityElement(children: .contain)
    }

    private func copyButton(_ title: String, label: String, text: String) -> some View {
        Button {
            UIPasteboard.general.string = text
            copiedLabel = label
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                copiedLabel = nil
            }
        } label: {
            Text(copiedLabel == label ? label : title)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(copiedLabel == label ? .green : .orange)
        }
    }

    private var classificationText: String {
        let snapshot = session.debugSoundClassificationSnapshot
        let topFive = snapshot.topClassifications.enumerated().map { index, prediction in
            "\(index + 1). \(prediction.identifier)  \(confidence(prediction.confidence))"
        }.joined(separator: "\n")
        return """
        -- Apple Sound Analysis --
        \(topFive.isEmpty ? "No classifications yet" : topFive)

        Wind Noise: \(confidence(snapshot.windNoiseConfidence))
        Breathing: \(confidence(snapshot.breathingConfidence))
        Speech: \(confidence(snapshot.speechConfidence))
        Music: \(confidence(snapshot.musicConfidence))
        Blow Confidence: \(confidence(snapshot.blowConfidence))
        Evidence: \(String(format: "%.2f", session.debugBlowEvidence)) / \(String(format: "%.2f", session.debugRequiredBlowDuration)) s
        """
    }

    private var visualText: String {
        let snapshot = session.debugBlowSnapshot
        return """
        Input: \(session.debugInputDescription)
        Sample Rate: \(Int(session.debugInputSampleRate.rounded())) Hz
        Voice Processing: \(session.debugVoiceProcessingEnabled ? "On" : "Off")
        RMS: \(formatted(snapshot.rms))
        dBFS: \(String(format: "%.1f", snapshot.dbFS))
        80–500 Hz RMS: \(formatted(snapshot.windBandRMS))
        Visual Intensity: \(formatted(snapshot.visualIntensity))
        """
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 120, alignment: .leading)
            Text(value).lineLimit(1).minimumScaleFactor(0.72)
            Spacer(minLength: 0)
        }
    }

    private func progressRow(_ label: String, value: Double, detail: String? = nil) -> some View {
        let clamped = min(max(value, 0), 1)
        return HStack(spacing: 8) {
            Text(label).frame(width: 120, alignment: .leading)
            ProgressView(value: clamped, total: 1).tint(.orange)
            Text(detail ?? confidence(value)).lineLimit(1).frame(width: 70, alignment: .trailing)
        }
    }

    private func classificationRow(index: Int, prediction: SoundClassificationPrediction) -> some View {
        HStack(spacing: 8) {
            Text("\(index).").frame(width: 18, alignment: .trailing).foregroundStyle(.white.opacity(0.48))
            Text(prediction.identifier).lineLimit(1).minimumScaleFactor(0.65)
            Spacer(minLength: 6)
            Text(confidence(prediction.confidence)).frame(width: 44, alignment: .trailing)
        }
    }

    private func formatted(_ value: Float) -> String { String(format: "%.3f", value) }
    private func confidence(_ value: Double) -> String { String(format: "%.2f", value) }
}
#endif

private enum CeremonySheet: String, Identifiable {
    case preparation
    var id: String { rawValue }
}

private struct CeremonyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .medium, design: .rounded))
            .foregroundStyle(.black)
            .padding(.horizontal, 28)
            .frame(height: 52)
            .background(.white.opacity(configuration.isPressed ? 0.72 : 0.94), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}
