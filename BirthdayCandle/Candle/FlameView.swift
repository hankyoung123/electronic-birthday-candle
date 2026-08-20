import SwiftUI

struct FlameView: View {
    let blowIntensity: Float
    let phase: CeremonyPhase

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 / 15.0 : 1.0 / 60.0)) { timeline in
            Canvas(rendersAsynchronously: true) { context, size in
                render(
                    in: &context,
                    size: size,
                    time: timeline.date.timeIntervalSinceReferenceDate
                )
            }
        }
        .accessibilityHidden(true)
    }

    private func render(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let wind = CGFloat(blowIntensity.clamped(to: 0...1))
        let natural = reduceMotion ? 0 : sin(time * 7.1) * 0.045 + sin(time * 13.7) * 0.025
        let struggle = reduceMotion ? 0 : sin(time * (19 + wind * 19)) * (0.025 + wind * 0.095)
        let flicker = natural + struggle
        let lightingScale: CGFloat = phase == .lighting ? 0.72 : 1
        let height = size.height * (0.78 - wind * 0.27 + flicker) * lightingScale
        let width = size.width * (0.29 - wind * 0.075 + abs(natural) * 0.12) * lightingScale
        let bend = size.width * (wind * 0.38 + natural * 0.32)
        let baseY = size.height * 0.93
        let centerX = size.width * 0.5

        context.drawLayer { glow in
            glow.addFilter(.blur(radius: 21 + wind * 7))
            glow.opacity = 0.32 - Double(wind) * 0.08
            let glowRect = CGRect(
                x: centerX - width * 1.15 + bend * 0.25,
                y: baseY - height * 0.95,
                width: width * 2.3,
                height: height * 1.02
            )
            glow.fill(Path(ellipseIn: glowRect), with: .color(Color.orange))
        }

        let outer = flamePath(
            centerX: centerX,
            baseY: baseY,
            width: width,
            height: height,
            bend: bend
        )
        context.fill(
            outer,
            with: .linearGradient(
                Gradient(colors: [
                    Color(red: 1, green: 0.24, blue: 0.02, opacity: 0.82),
                    Color(red: 1, green: 0.61, blue: 0.05),
                    Color(red: 1, green: 0.91, blue: 0.36, opacity: 0.94)
                ]),
                startPoint: CGPoint(x: centerX, y: baseY),
                endPoint: CGPoint(x: centerX + bend, y: baseY - height)
            )
        )

        let inner = flamePath(
            centerX: centerX + bend * 0.15,
            baseY: baseY - 3,
            width: width * 0.52,
            height: height * 0.61,
            bend: bend * 0.62
        )
        context.fill(
            inner,
            with: .linearGradient(
                Gradient(colors: [
                    Color(red: 1, green: 0.93, blue: 0.62),
                    Color(red: 1, green: 0.76, blue: 0.18),
                    Color.white.opacity(0.88)
                ]),
                startPoint: CGPoint(x: centerX, y: baseY),
                endPoint: CGPoint(x: centerX + bend * 0.5, y: baseY - height * 0.65)
            )
        )

        let coreRect = CGRect(
            x: centerX - width * 0.13,
            y: baseY - height * 0.25,
            width: width * 0.26,
            height: height * 0.24
        )
        context.fill(
            Path(ellipseIn: coreRect),
            with: .color(Color(red: 0.76, green: 0.93, blue: 1, opacity: 0.78))
        )
    }

    private func flamePath(
        centerX: CGFloat,
        baseY: CGFloat,
        width: CGFloat,
        height: CGFloat,
        bend: CGFloat
    ) -> Path {
        var path = Path()
        let tip = CGPoint(x: centerX + bend, y: baseY - height)
        let left = CGPoint(x: centerX - width * 0.5, y: baseY - height * 0.13)
        let right = CGPoint(x: centerX + width * 0.5, y: baseY - height * 0.1)

        path.move(to: CGPoint(x: centerX, y: baseY))
        path.addCurve(
            to: left,
            control1: CGPoint(x: centerX - width * 0.26, y: baseY),
            control2: CGPoint(x: left.x, y: baseY - height * 0.04)
        )
        path.addCurve(
            to: tip,
            control1: CGPoint(x: left.x - bend * 0.08, y: baseY - height * 0.48),
            control2: CGPoint(x: tip.x - width * 0.28 - bend * 0.22, y: tip.y + height * 0.32)
        )
        path.addCurve(
            to: right,
            control1: CGPoint(x: tip.x + width * 0.18 + bend * 0.08, y: tip.y + height * 0.28),
            control2: CGPoint(x: right.x + bend * 0.12, y: baseY - height * 0.49)
        )
        path.addCurve(
            to: CGPoint(x: centerX, y: baseY),
            control1: CGPoint(x: right.x, y: baseY - height * 0.03),
            control2: CGPoint(x: centerX + width * 0.25, y: baseY)
        )
        path.closeSubpath()
        return path
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
