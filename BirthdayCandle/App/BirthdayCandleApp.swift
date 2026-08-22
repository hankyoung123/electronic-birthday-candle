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
    private let visualPrototypeEnabled: Bool

    init() {
        #if DEBUG
        let visualPrototypeEnabled = ProcessInfo.processInfo.arguments.contains("-VisualPrototype")
        #else
        let visualPrototypeEnabled = false
        #endif
        self.visualPrototypeEnabled = visualPrototypeEnabled
        #if DEBUG
        let audioEngine: AudioEngine? = visualPrototypeEnabled ? nil : AudioEngine()
        #else
        let audioEngine: AudioEngine? = AudioEngine()
        #endif
        let hapticEngine = HapticEngine()
        _session = State(
            initialValue: CeremonySession(
                audioEngine: audioEngine,
                hapticEngine: hapticEngine
            )
        )
    }

    var body: some View {
        CeremonyView(
            session: session,
            visualPrototypeEnabled: visualPrototypeEnabled
        )
    }
}
