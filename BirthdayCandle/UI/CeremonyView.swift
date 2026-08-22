import SwiftUI

@MainActor
struct CeremonyView: View {
    let session: CeremonySession
    var visualPrototypeEnabled = false

    @State private var isPreparingMicrophone = false

    private let gold = Color("CeremonyGold")

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                CeremonyBackdrop(phase: session.phase)
                    .animation(.easeInOut(duration: 0.75), value: session.phase)

                if session.phase.showsCelebrationParticles {
                    WarmParticleField(
                        style: session.phase == .lighting ? .ignition : .celebration
                    )
                    .id(session.phase)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.45), value: session.phase)
                }

                ceremonyStage(in: geometry.size)

                if session.phase == .ready {
                    readyCue
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                        .animation(.easeOut(duration: 0.45), value: session.phase)
                }

                if session.phase == .restartable {
                    restartCue
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                        .animation(.easeOut(duration: 0.5), value: session.phase)
                }

                if primaryActionEnabled {
                    Button(action: performPrimaryAction) {
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(primaryActionLabel)
                    .accessibilityHint(primaryActionHint)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .ignoresSafeArea(edges: .bottom)
        .alert(item: Binding(get: { session.notice }, set: { session.notice = $0 })) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func ceremonyStage(in size: CGSize) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: max(size.height * 0.08, 48))

            message
                .frame(height: min(size.height * 0.2, 168))
                .padding(.horizontal, 28)
                .animation(
                    .easeOut(duration: session.phase == .extinguishing ? 0.14 : 0.65),
                    value: session.phase
                )
                .transaction { transaction in
                    if session.phase == .extinguishing {
                        transaction.animation = nil
                    }
                }

            Spacer(minLength: 4)

            CandleView(
                phase: session.phase,
                blowIntensity: session.blowIntensity,
                extinguishedAt: session.extinguishedAt
            )
            .frame(height: min(size.height * 0.56, 470), alignment: .bottom)

            Spacer(minLength: max(size.height * 0.035, 24))
        }
    }

    @ViewBuilder
    private var message: some View {
        switch session.phase {
        case .ready, .lit:
            ritualTitle("Make a wish", style: .prompt)
        case .wishing:
            ritualTitle("Blow out\nthe candle", style: .instruction)
        case .greeting, .celebrating, .completed:
            birthdayArtwork
        case .lighting, .extinguishing, .extinguished, .smoking, .restartable:
            Color.clear
        }
    }

    private var birthdayArtwork: some View {
        Image("CeremonyHappyBirthday")
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .shadow(color: gold.opacity(0.42), radius: 18)
            .scaleEffect(session.phase == .greeting ? 0.94 : 1)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
            .accessibilityLabel("Happy Birthday")
            .accessibilityAddTraits(.isHeader)
    }

    private func ritualTitle(_ text: String, style: RitualTitleStyle) -> some View {
        Text(text)
            .font(style.font)
            .fontWeight(style.weight)
            .fontWidth(.standard)
            .tracking(style.tracking)
            .foregroundStyle(
                LinearGradient(
                    colors: [gold.opacity(style.leadingOpacity), Color.white.opacity(0.72)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .multilineTextAlignment(.center)
            .lineSpacing(1)
            .shadow(color: gold.opacity(0.18), radius: 14)
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    private var readyCue: some View {
        VStack(spacing: 10) {
            if isPreparingMicrophone {
                ProgressView()
                    .controlSize(.regular)
                    .tint(gold)
                Text("Preparing the moment…")
                    .font(.caption)
                    .foregroundStyle(gold.opacity(0.72))
            } else {
                Image(systemName: "hand.tap")
                    .font(.system(size: 30, weight: .light))
                    .symbolEffect(.pulse, options: .repeating)
                    .foregroundStyle(gold)
                Text("Tap anywhere to light the candle")
                    .font(.caption)
                    .tracking(0.45)
                    .foregroundStyle(gold.opacity(0.78))
            }
        }
        .padding(.bottom, 46)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .accessibilityHidden(true)
    }

    private var restartCue: some View {
        VStack {
            Spacer()
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(gold)
                .padding(12)
                .overlay {
                    Circle().stroke(gold.opacity(0.72), lineWidth: 1.2)
                }
                .shadow(color: gold.opacity(0.2), radius: 12)
                .padding(.bottom, 54)
        }
        .accessibilityHidden(true)
    }

    private var primaryActionEnabled: Bool {
        if session.phase == .ready { return !isPreparingMicrophone }
        if session.phase == .restartable { return true }
        #if DEBUG
        if visualPrototypeEnabled, session.phase == .wishing { return true }
        #endif
        return false
    }

    private var primaryActionLabel: String {
        switch session.phase {
        case .ready: "Light the candle"
        case .restartable: "Begin the ceremony again"
        #if DEBUG
        case .wishing where visualPrototypeEnabled: "Extinguish the prototype candle"
        #endif
        default: "Ceremony"
        }
    }

    private var primaryActionHint: String {
        session.phase == .ready
            ? "Requests microphone access and starts the birthday ceremony."
            : "Returns to the unlit candle."
    }

    private func performPrimaryAction() {
        switch session.phase {
        case .ready:
            guard !isPreparingMicrophone else { return }
            isPreparingMicrophone = true
            Task {
                let isReady = await session.prepareMicrophoneAccess()
                isPreparingMicrophone = false
                if isReady { session.lightCandle() }
            }
        case .restartable:
            session.restart()
        #if DEBUG
        case .wishing where visualPrototypeEnabled:
            session.extinguish()
        #endif
        default:
            break
        }
    }
}

private enum RitualTitleStyle: Equatable {
    case prompt
    case instruction

    var font: Font {
        switch self {
        case .prompt: .system(.title3, design: .serif)
        case .instruction: .system(.title2, design: .serif)
        }
    }

    var weight: Font.Weight {
        .medium
    }

    var tracking: CGFloat {
        0.35
    }

    var leadingOpacity: Double {
        0.86
    }
}

private struct CeremonyBackdrop: View {
    let phase: CeremonyPhase

    var body: some View {
        ZStack {
            Color(.systemBackground)

            RadialGradient(
                colors: [
                    Color(red: 0.43, green: 0.2, blue: 0.055).opacity(glowOpacity),
                    Color(red: 0.12, green: 0.055, blue: 0.02).opacity(glowOpacity * 0.45),
                    .clear
                ],
                center: UnitPoint(x: 0.5, y: 0.62),
                startRadius: 4,
                endRadius: 310
            )

            LinearGradient(
                colors: [.clear, .black.opacity(bottomShade)],
                startPoint: .center,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    private var glowOpacity: Double {
        switch phase {
        case .ready: 0.08
        case .lighting: 0.42
        case .lit: 0.58
        case .wishing: 0.5
        case .extinguishing: 0.3
        case .extinguished: 0.13
        case .smoking: 0.06
        case .greeting: 0.05
        case .celebrating: 0.17
        case .completed: 0.06
        case .restartable: 0
        }
    }

    private var bottomShade: Double {
        switch phase {
        case .lighting, .lit, .wishing: 0.18
        default: 0.48
        }
    }
}

private struct WarmParticleField: View {
    enum Style {
        case ignition
        case celebration
    }

    let style: Style

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 / 12.0 : 1.0 / 30.0)) { timeline in
            Canvas(rendersAsynchronously: true) { context, size in
                let elapsed = reduceMotion ? 0.6 : timeline.date.timeIntervalSince(startedAt)
                let count = style == .ignition ? 28 : 52
                for index in 0..<count {
                    drawParticle(index: index, elapsed: elapsed, size: size, context: &context)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func drawParticle(
        index: Int,
        elapsed: TimeInterval,
        size: CGSize,
        context: inout GraphicsContext
    ) {
        let seed = random(index, salt: 0.37)
        let speed = 0.12 + random(index, salt: 2.1) * 0.17
        let progress = (elapsed * speed + seed).truncatingRemainder(dividingBy: 1)
        let width = 2.0 + random(index, salt: 4.7) * 4.5
        let height = width * (0.65 + random(index, salt: 8.2) * 1.4)

        let point: CGPoint
        if style == .ignition {
            let spread = (random(index, salt: 1.7) - 0.5) * size.width * 0.34
            point = CGPoint(
                x: size.width * 0.5 + spread + sin(elapsed * 1.8 + Double(index)) * 8,
                y: size.height * 0.7 - progress * size.height * 0.42
            )
        } else {
            point = CGPoint(
                x: random(index, salt: 6.3) * size.width,
                y: size.height * (0.12 + progress * 0.78)
            )
        }

        let edgeFade = sin(progress * .pi)
        context.drawLayer { layer in
            layer.opacity = edgeFade * (style == .ignition ? 0.48 : 0.58)
            layer.translateBy(x: point.x, y: point.y)
            layer.rotate(by: .degrees(elapsed * 44 + Double(index * 19)))
            let rect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
            layer.fill(
                Path(roundedRect: rect, cornerRadius: width * 0.35),
                with: .color(
                    index.isMultiple(of: 3)
                        ? Color(red: 1, green: 0.68, blue: 0.24)
                        : Color("CeremonyGold")
                )
            )
        }
    }

    private func random(_ index: Int, salt: Double) -> Double {
        let value = sin(Double(index + 1) * 12.9898 + salt * 78.233) * 43_758.5453
        return value - floor(value)
    }
}
