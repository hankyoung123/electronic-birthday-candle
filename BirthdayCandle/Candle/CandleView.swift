import SwiftUI

struct CandleView: View {
    let phase: CeremonyPhase
    let blowIntensity: Float
    let extinguishedAt: Date?

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.98, green: 0.86, blue: 0.62), Color(red: 0.72, green: 0.47, blue: 0.25)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 66, height: 250)

            Capsule()
                .fill(.black.opacity(0.84))
                .frame(width: 4, height: 27)
                .offset(y: -239)

            if phase.showsEmber {
                Circle()
                    .fill(Color(red: 1, green: 0.19, blue: 0.04))
                    .frame(width: 7, height: 7)
                    .shadow(color: .red.opacity(0.9), radius: 8)
                    .offset(y: -260)
                    .transition(.opacity)
            }

            FlameView(blowIntensity: blowIntensity, phase: phase)
                .frame(width: 152, height: 164)
                .offset(y: -247)
                .opacity(flameOpacity)
                .scaleEffect(flameScale, anchor: .bottom)
                .animation(flameAnimation, value: phase)

            if phase.showsSmoke, let extinguishedAt {
                SmokeView(startedAt: extinguishedAt)
                    .frame(width: 190, height: 250)
                    .offset(y: -252)
                    .transition(.opacity)
            }
        }
        .frame(width: 190, height: 420, alignment: .bottom)
        .animation(.easeOut(duration: 0.24), value: phase.showsEmber)
        .animation(.easeOut(duration: 0.45), value: phase.showsSmoke)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(phase.showsFlame ? "Lit candle" : "Unlit candle")
    }

    private var flameOpacity: Double {
        switch phase {
        case .lighting, .lit, .wishing:
            1
        case .extinguishing:
            0.08
        case .ready, .extinguished, .celebrating:
            0
        }
    }

    private var flameScale: CGFloat {
        switch phase {
        case .lighting, .lit, .wishing:
            1
        case .ready, .extinguishing, .extinguished, .celebrating:
            0.08
        }
    }

    private var flameAnimation: Animation {
        switch phase {
        case .extinguishing:
            .easeIn(duration: CeremonyTiming.extinguishingDuration)
        case .extinguished:
            .linear(duration: 0.04)
        case .ready, .lighting, .lit, .wishing, .celebrating:
            .easeOut(duration: 0.45)
        }
    }
}
