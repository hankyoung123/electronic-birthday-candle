import SwiftUI

@MainActor
struct CeremonyView: View {
    let session: CeremonySession
    @State private var activeSheet: CeremonySheet?

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
            Button("Start") { activeSheet = .preparation }
                .buttonStyle(CeremonyButtonStyle())
        case .lit, .wishing:
            #if DEBUG
            VStack(spacing: 14) {
                Slider(
                    value: Binding(
                        get: { Double(session.blowIntensity) },
                        set: { session.setDevelopmentBlowIntensity(Float($0)) }
                    ),
                    in: 0...1
                )
                .tint(.orange.opacity(0.7))
                .accessibilityLabel("Development wind intensity")

            }
            #endif
        case .celebrating:
            Button("Again") { session.restart() }
                .buttonStyle(CeremonyButtonStyle())
        case .lighting, .extinguishing, .extinguished:
            EmptyView()
        }
    }
}

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
