import SwiftUI

@main
struct BirthdayCandleApp: App {
    var body: some Scene {
        WindowGroup {
            CeremonyRootView()
                .preferredColorScheme(.dark)
        }
    }
}

@MainActor
private struct CeremonyRootView: View {
    @State private var session: CeremonySession

    init() {
        let audioEngine = AudioEngine()
        let hapticEngine = HapticEngine()
        _session = State(
            initialValue: CeremonySession(
                audioEngine: audioEngine,
                hapticEngine: hapticEngine
            )
        )
    }

    var body: some View {
        CeremonyView(session: session)
    }
}
