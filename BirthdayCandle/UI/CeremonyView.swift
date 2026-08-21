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

                controls
                    .frame(minHeight: 76)
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
            case .ready:
                Text("Make a birthday wish.")
            case .lighting:
                Text("Lighting…")
            case .lit, .wishing:
                Text("Make a wish.")
            case .extinguishing, .extinguished:
                Text("")
            case .celebrating:
                Text("Happy Birthday.")
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
                    if isReady {
                        activeSheet = .preparation
                    }
                }
            }
                .buttonStyle(CeremonyButtonStyle())
                .disabled(isRequestingMicrophoneAccess)
        case .lit, .wishing:
            #if DEBUG
            BlowInspector(session: session)
            #endif
        case .celebrating:
            Button("Again") { session.restart() }
                .buttonStyle(CeremonyButtonStyle())
        case .lighting, .extinguishing, .extinguished:
            EmptyView()
        }
    }
}

#if DEBUG
@MainActor
private struct BlowInspector: View {
    let session: CeremonySession
    @State private var copied = false
    @State private var spectrumCopied: String?

    var body: some View {
        let snapshot = session.debugBlowSnapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Wind Inspector")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.orange.opacity(0.9))
                    Spacer()
                    copyButton
                }

                metric("Input Route", session.debugInputDescription)
                metric("Sample Rate", "\(Int(session.debugInputSampleRate.rounded())) Hz")
                if let diagnostic = session.debugLastStartDiagnostic {
                    metric("Start Failure", diagnostic)
                }
                metric("Voice Processing", session.debugVoiceProcessingEnabled ? "On" : "Off")
                metric("Mic Permission", session.debugMicrophonePermissionGranted ? "Granted" : "Denied")
                metric("Session Active", session.debugAudioSessionActive ? "Yes" : "No")
                metric("RMS / dBFS", "\(formatted(snapshot.rms)) / \(String(format: "%.1f dB", snapshot.dbFS))")

                HStack {
                    Text("Wind 80–500 Hz")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.orange.opacity(0.9))
                    Spacer()
                    copyButton("Copy Snapshot", copiedLabel: "Snapshot ✓", text: snapshotText)
                    copyButton("Copy 3s Avg", copiedLabel: "3s Avg ✓", text: rollingText)
                }

                progressRow("Wind RMS", value: Double(snapshot.windBandRMS), detail: formatted(snapshot.windBandRMS))
                progressRow("Wind Ratio", value: Double(snapshot.windRatio), detail: "\(Int((snapshot.windRatio * 100).rounded()))%")
                metric("Wind Energy Score", formatted(snapshot.windEnergyScore))
                metric("Wind Ratio Score", formatted(snapshot.windRatioScore))
                metric("Raw Score", formatted(snapshot.rawScore))
                metric("Held Score", formatted(snapshot.heldScore))
                progressRow("Smoothed", value: Double(snapshot.smoothedIntensity), detail: formatted(snapshot.smoothedIntensity))

                progressRow(
                    "Evidence",
                    value: Double(
                        session.debugRequiredStrongBlowDuration > 0
                            ? session.debugBlowEvidence / session.debugRequiredStrongBlowDuration
                            : 0
                    ),
                    detail: String(
                        format: "%.2f / %.2f s",
                        session.debugBlowEvidence,
                        session.debugRequiredStrongBlowDuration
                    )
                )

                Divider()
                    .overlay(.white.opacity(0.12))

                Text("Live Tuning")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.orange.opacity(0.9))

                sliderRow("Peak Hold", value: Binding(get: { session.debugPeakHoldDuration }, set: { session.setDebugPeakHoldDuration($0) }), in: 0...0.5, step: 0.01, format: "%.2f s")
                sliderRow("Wind Start", value: Binding(get: { Double(session.debugWindStart) }, set: { session.setDebugWindStart(Float($0)) }), in: 0.005...0.5, step: 0.005, format: "%.3f")
                sliderRow("Wind Full", value: Binding(get: { Double(session.debugWindFull) }, set: { session.setDebugWindFull(Float($0)) }), in: 0.01...0.5, step: 0.005, format: "%.3f")
                sliderRow("Wind Ratio Start", value: Binding(get: { Double(session.debugWindRatioStart) }, set: { session.setDebugWindRatioStart(Float($0)) }), in: 0...1, step: 0.05, format: "%.2f")
                sliderRow("Wind Ratio Full", value: Binding(get: { Double(session.debugWindRatioFull) }, set: { session.setDebugWindRatioFull(Float($0)) }), in: 0...1, step: 0.05, format: "%.2f")
                sliderRow("Energy Wt", value: Binding(get: { Double(session.debugEnergyWeight) }, set: { session.setDebugEnergyWeight(Float($0)) }), in: 0...1, step: 0.05, format: "%.2f")
                sliderRow("Ratio Wt", value: Binding(get: { Double(session.debugRatioWeight) }, set: { session.setDebugRatioWeight(Float($0)) }), in: 0...1, step: 0.05, format: "%.2f")
                sliderRow("Start", value: Binding(get: { Double(session.debugStrongBlowStartThreshold) }, set: { session.setDebugStrongBlowStartThreshold(Float($0)) }), in: 0.05...1, step: 0.01, format: "%.2f")
                sliderRow("Maintain", value: Binding(get: { Double(session.debugStrongBlowMaintainThreshold) }, set: { session.setDebugStrongBlowMaintainThreshold(Float($0)) }), in: 0...1, step: 0.01, format: "%.2f")
                sliderRow("Duration", value: Binding(get: { session.debugRequiredStrongBlowDuration }, set: { session.setDebugRequiredStrongBlowDuration($0) }), in: 0.1...2, step: 0.01, format: "%.2f s")
                sliderRow("Decay", value: Binding(get: { session.debugStrongBlowDecayRate }, set: { session.setDebugStrongBlowDecayRate($0) }), in: 0...2, step: 0.05, format: "%.2f")

                Divider()
                    .overlay(.white.opacity(0.12))

                HStack(spacing: 8) {
                    Text("Music")
                        .frame(width: 72, alignment: .leading)
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
                        .frame(width: 40, alignment: .trailing)
                }
            }
            .padding(12)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxHeight: 500)
        .accessibilityElement(children: .contain)
    }

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = copyText
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                copied = false
            }
        } label: {
            Text(copied ? "Copied ✓" : "Copy Values")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(copied ? .green : .orange)
        }
    }

    private var copyText: String {
        String(
            format: "windStart=%.3f\nwindFull=%.3f\nwindRatioStart=%.2f\nwindRatioFull=%.2f\nenergyWt=%.2f\nratioWt=%.2f\nstart=%.2f\nmaintain=%.2f\nduration=%.2f\ndecay=%.2f",
            session.debugWindStart,
            session.debugWindFull,
            session.debugWindRatioStart,
            session.debugWindRatioFull,
            session.debugEnergyWeight,
            session.debugRatioWeight,
            session.debugStrongBlowStartThreshold,
            session.debugStrongBlowMaintainThreshold,
            session.debugRequiredStrongBlowDuration,
            session.debugStrongBlowDecayRate
        )
    }

    private func copyButton(_ title: String, copiedLabel: String, text: String) -> some View {
        Button {
            UIPasteboard.general.string = text
            spectrumCopied = copiedLabel
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                spectrumCopied = nil
            }
        } label: {
            Text(spectrumCopied == copiedLabel ? copiedLabel : title)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(spectrumCopied == copiedLabel ? .green : .orange)
        }
    }

    private var snapshotText: String {
        let s = session.debugBlowSnapshot
        return """
        Input: \(session.debugInputDescription)
        SampleRate: \(Int(session.debugInputSampleRate.rounded()))
        VoiceProcessing: \(session.debugVoiceProcessingEnabled ? "On" : "Off")
        dBFS: \(String(format: "%.1f", s.dbFS))

        WindRMS: \(String(format: "%.3f", s.windBandRMS))
        WindRatio: \(String(format: "%.2f", s.windRatio))

        WindEnergy: \(String(format: "%.2f", s.windEnergyScore))
        WindRatioScore: \(String(format: "%.2f", s.windRatioScore))
        Raw: \(String(format: "%.2f", s.rawScore))
        Held: \(String(format: "%.2f", s.heldScore))
        Smoothed: \(String(format: "%.2f", s.smoothedIntensity))
        """
    }

    private var rollingText: String {
        let s = session.debugSpectrumRollingSummary
        guard s.sampleCount > 0 else {
            return "No samples yet — blow detection must be active for ~3s."
        }
        func f(_ value: Float) -> String { String(format: "%.2f", value) }
        return """
        -- 3s Avg (N=\(s.sampleCount)) --
        dBFS:  \(f(s.dbFSAverage)) (peak \(f(s.dbFSPeak)))
        WindRMS: \(f(s.windBandRMSAverage)) (peak \(f(s.windBandRMSPeak)))
        WindRatio: \(f(s.windRatioAverage)) (peak \(f(s.windRatioPeak)))
        Raw: \(f(s.rawAverage)) (peak \(f(s.rawPeak)))
        Smoothed: \(f(s.smoothedAverage)) (peak \(f(s.smoothedPeak)))
        """
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Spacer(minLength: 0)
        }
    }

    private func progressRow(_ label: String, value: Double, detail: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: 120, alignment: .leading)
            ProgressView(value: value, total: 1)
                .tint(.orange)
            Text(detail)
                .lineLimit(1)
                .frame(width: 100, alignment: .trailing)
        }
    }

    private func sliderRow(
        _ label: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double,
        format: String
    ) -> some View {
        let displayed = String(format: format, value.wrappedValue)
        return HStack(spacing: 8) {
            Text(label)
                .frame(width: 120, alignment: .leading)
            Slider(value: value, in: range, step: step)
                .tint(.orange.opacity(0.72))
            Text(displayed)
                .frame(width: 100, alignment: .trailing)
        }
    }

    private func formatted(_ value: Float) -> String {
        String(format: "%.3f", value)
    }
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
