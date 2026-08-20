import SwiftUI

struct SmokeView: View {
    let startedAt: Date

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 / 12.0 : 1.0 / 30.0)) { timeline in
            Canvas(rendersAsynchronously: true) { context, size in
                let elapsed = max(timeline.date.timeIntervalSince(startedAt), 0)
                for index in 0..<6 {
                    drawPuff(index: index, elapsed: elapsed, size: size, context: &context)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func drawPuff(
        index: Int,
        elapsed: TimeInterval,
        size: CGSize,
        context: inout GraphicsContext
    ) {
        let delay = Double(index) * 0.14
        let age = max(elapsed - delay, 0)
        guard age > 0, age < 3.2 else { return }

        let progress = age / 3.2
        let sway = reduceMotion ? 0 : sin(age * 2.1 + Double(index) * 1.7) * (12 + progress * 20)
        let x = size.width * 0.5 + sway
        let y = size.height * 0.94 - progress * size.height * 0.82
        let diameter = 10 + progress * 35
        let opacity = (1 - progress) * 0.26

        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 5 + progress * 6))
            layer.opacity = opacity
            layer.fill(
                Path(ellipseIn: CGRect(x: x - diameter / 2, y: y - diameter / 2, width: diameter, height: diameter * 1.35)),
                with: .color(.white)
            )
        }
    }
}
