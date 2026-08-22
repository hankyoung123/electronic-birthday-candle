import SwiftUI

struct CandleView: View {
    let phase: CeremonyPhase
    let blowIntensity: Float
    let extinguishedAt: Date?

    var body: some View {
        ZStack(alignment: .bottom) {
            if phase.showsCandle {
                candleShadow
                candleBody

                if phase.showsEmber {
                    ember
                }

                FlameView(blowIntensity: blowIntensity, phase: phase)
                    .frame(width: 170, height: 210)
                    .offset(y: -248)
                    .opacity(flameOpacity)
                    .scaleEffect(flameScale, anchor: .bottom)
                    .animation(flameAnimation, value: phase)
            }

            if phase.showsSmoke, let extinguishedAt {
                SmokeView(startedAt: extinguishedAt)
                    .frame(width: 230, height: 330)
                    .offset(y: -230)
                    .transition(.opacity)
            }
        }
        .frame(width: 230, height: 440, alignment: .bottom)
        .scaleEffect(candleScale, anchor: .bottom)
        .opacity(candleOpacity)
        .animation(.easeInOut(duration: 1.0), value: phase)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var candleBody: some View {
        Image("CeremonyCandle")
            .resizable()
            .scaledToFill()
            .frame(width: 150, height: 320)
            .clipped()
            .offset(y: 20)
            .shadow(color: Color.orange.opacity(bodyGlowOpacity), radius: 28, y: -14)
            .shadow(color: .black.opacity(0.85), radius: 9, y: 7)
    }

    private var ember: some View {
        Circle()
            .fill(Color(red: 1, green: 0.25, blue: 0.025))
            .frame(width: 9, height: 9)
            .overlay {
                Circle()
                    .fill(.white.opacity(0.78))
                    .frame(width: 3, height: 3)
            }
            .shadow(color: Color.orange, radius: 13)
            .offset(y: -268)
            .transition(.scale.combined(with: .opacity))
    }

    private var candleShadow: some View {
        Ellipse()
            .fill(.black.opacity(0.88))
            .frame(width: 172, height: 34)
            .blur(radius: 11)
            .offset(y: -2)
    }

    private var candleScale: CGFloat {
        switch phase {
        case .ready: 0.84
        case .lighting: 0.93
        case .lit, .wishing, .extinguishing: 1
        case .extinguished: 0.97
        case .smoking: 0.92
        case .greeting, .celebrating: 0.84
        case .completed: 0.76
        case .restartable: 0.68
        }
    }

    private var candleOpacity: Double {
        switch phase {
        case .ready: 0.84
        case .lighting: 0.96
        case .lit, .wishing, .extinguishing: 1
        case .extinguished: 0.94
        case .smoking: 0.82
        case .greeting: 0.64
        case .celebrating: 0.72
        case .completed: 0.42
        case .restartable: 0
        }
    }

    private var bodyGlowOpacity: Double {
        switch phase {
        case .lighting, .lit, .wishing: 0.3
        default: 0
        }
    }

    private var flameOpacity: Double {
        switch phase {
        case .lighting, .lit, .wishing: 1
        case .extinguishing: 0.08
        default: 0
        }
    }

    private var flameScale: CGFloat {
        switch phase {
        case .lighting: 0.72
        case .lit, .wishing: 1
        case .extinguishing: 0.05
        default: 0.05
        }
    }

    private var flameAnimation: Animation {
        phase == .extinguishing
            ? .easeIn(duration: CeremonyTiming.extinguishingDuration)
            : .easeOut(duration: 0.55)
    }

    private var accessibilityLabel: String {
        if phase.showsFlame { return "Lit candle" }
        if phase.showsSmoke { return "Extinguished candle with rising smoke" }
        return "Unlit candle"
    }
}
