import SwiftUI

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

    var body: some View {
        let snapshot = session.debugBlowSnapshot
        VStack(alignment: .leading, spacing: 6) {
            Text("Blow Inspector")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.orange.opacity(0.9))

            metric("Input", session.debugInputDescription)
            metric("Sample Rate", "\(Int(session.debugInputSampleRate.rounded())) Hz")
            metric("RMS", formatted(snapshot.rms))
            metric("Texture", formatted(snapshot.texture))
            metric("Raw", formatted(snapshot.rawScore))
            metric("Smoothed", formatted(snapshot.smoothedIntensity))

            HStack(spacing: 8) {
                Text("Blow")
                    .frame(width: 72, alignment: .leading)
                ProgressView(value: Double(session.blowIntensity), total: 1)
                    .tint(.orange)
                Text(formatted(session.blowIntensity))
                    .frame(width: 40, alignment: .trailing)
            }

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

            metric(
                "Strong",
                String(
                    format: "%.2f / %.2f s",
                    session.debugStrongBlowDuration,
                    session.debugRequiredStrongBlowDuration
                )
            )
        }
        .font(.system(size: 11, weight: .regular, design: .monospaced))
        .foregroundStyle(.white.opacity(0.72))
        .padding(12)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Spacer(minLength: 0)
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
