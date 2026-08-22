import SwiftUI

struct FlameView: View {
    let blowIntensity: Float
    let phase: CeremonyPhase

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 / 15.0 : 1.0 / 60.0)) { timeline in
            GeometryReader { geometry in
                let motion = motionValues(at: timeline.date.timeIntervalSinceReferenceDate)

                ZStack {
                    Image("CeremonyFlame")
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()

                    Image("CeremonyFlame")
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .blur(radius: 9)
                        .opacity(0.2)
                        .blendMode(.plusLighter)
                }
                .scaleEffect(
                    x: motion.widthScale,
                    y: motion.heightScale,
                    anchor: .bottom
                )
                .rotationEffect(.degrees(motion.rotation), anchor: .bottom)
                .offset(x: motion.horizontalOffset, y: motion.verticalOffset)
                .brightness(motion.brightness)
                .shadow(
                    color: Color.orange.opacity(motion.glowOpacity),
                    radius: motion.glowRadius
                )
                .compositingGroup()
            }
        }
        .accessibilityHidden(true)
    }

    private func motionValues(at time: TimeInterval) -> FlameMotionValues {
        let wind = CGFloat(blowIntensity.clamped(to: 0...1))
        let slowFlicker = reduceMotion ? 0 : smoothNoise(at: time * 1.7, seed: 0.37)
        let quickFlicker = reduceMotion ? 0 : smoothNoise(at: time * 7.8, seed: 1.91)
        let struggle = reduceMotion
            ? 0
            : smoothNoise(at: time * (9.0 + Double(wind) * 12.0), seed: 8.17)
        let lightingScale: CGFloat = phase == .lighting ? 0.74 : 1

        return FlameMotionValues(
            widthScale: (1 + wind * 0.2 + abs(quickFlicker) * 0.025) * lightingScale,
            heightScale: (1 - wind * 0.24 + slowFlicker * 0.025 + struggle * wind * 0.045)
                * lightingScale,
            rotation: Double(-wind * 31 + slowFlicker * 2.2 + quickFlicker * 0.75),
            horizontalOffset: -wind * 17 + slowFlicker * 1.8,
            verticalOffset: wind * 4 - quickFlicker * 0.8,
            brightness: Double(quickFlicker * 0.025 - wind * 0.035),
            glowOpacity: 0.42 - Double(wind) * 0.1,
            glowRadius: 20 + wind * 8
        )
    }

    private func smoothNoise(at position: Double, seed: Double) -> CGFloat {
        let lower = floor(position)
        let fraction = position - lower
        let eased = fraction * fraction * (3 - 2 * fraction)
        let start = noiseValue(at: lower, seed: seed)
        let end = noiseValue(at: lower + 1, seed: seed)
        return CGFloat(start + (end - start) * eased)
    }

    private func noiseValue(at position: Double, seed: Double) -> Double {
        let value = sin(position * 12.9898 + seed * 78.233) * 43_758.5453
        return (value - floor(value)) * 2 - 1
    }
}

private struct FlameMotionValues {
    let widthScale: CGFloat
    let heightScale: CGFloat
    let rotation: Double
    let horizontalOffset: CGFloat
    let verticalOffset: CGFloat
    let brightness: Double
    let glowOpacity: Double
    let glowRadius: CGFloat
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
