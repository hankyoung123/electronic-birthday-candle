import SwiftUI

struct SmokeView: View {
    let startedAt: Date

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 / 12.0 : 1.0 / 30.0)) { timeline in
            let elapsed = max(timeline.date.timeIntervalSince(startedAt), 0)
            let rise = reduceMotion ? 0 : min(elapsed / 3.5, 1) * 34
            let sway = reduceMotion ? 0 : sin(elapsed * 1.35) * (4 + min(elapsed, 2.5) * 2.4)

            ZStack(alignment: .bottom) {
                Image("CeremonyEmberSmoke")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 150, height: 300)
                    .clipped()
                    .opacity(emberSmokeOpacity(at: elapsed))
                    .scaleEffect(
                        x: 1 + min(elapsed, 1.8) * 0.025,
                        y: 1 + min(elapsed, 1.8) * 0.055,
                        anchor: .bottom
                    )

                Image("CeremonySmoke")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 154, height: 310)
                    .clipped()
                    .blendMode(.screen)
                    .opacity(smokeOpacity(at: elapsed))
                    .scaleEffect(
                        x: 0.9 + min(elapsed / 2.6, 1) * 0.18,
                        y: 0.82 + min(elapsed / 2.8, 1) * 0.28,
                        anchor: .bottom
                    )
                    .offset(x: sway, y: -rise)
                    .blur(radius: min(elapsed / 3.0, 1) * 1.4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }

    private func emberSmokeOpacity(at elapsed: TimeInterval) -> Double {
        guard elapsed < 2.2 else { return 0 }
        return min(elapsed / 0.18, 1) * max(1 - elapsed / 2.2, 0)
    }

    private func smokeOpacity(at elapsed: TimeInterval) -> Double {
        let fadeIn = min(elapsed / 0.35, 1)
        let fadeOut = max(1 - max(elapsed - 2.2, 0) / 1.6, 0)
        return fadeIn * fadeOut * 0.76
    }
}
