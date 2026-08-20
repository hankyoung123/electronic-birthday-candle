import SwiftUI

@MainActor
struct MusicPicker: View {
    let session: CeremonySession

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(.white.opacity(0.2))
                .frame(width: 38, height: 5)
                .padding(.top, 10)

            Text("Music")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .padding(.top, 24)
                .padding(.bottom, 18)

            VStack(spacing: 2) {
                ForEach(MusicTrack.all) { track in
                    selectionRow(
                        title: track.title,
                        selected: session.musicEnabled && session.selectedMusic == track
                    ) {
                        session.selectedMusic = track
                        session.musicEnabled = true
                    }
                }

                selectionRow(title: "None", selected: !session.musicEnabled) {
                    session.musicEnabled = false
                }
            }

            Spacer(minLength: 24)

            Button("Light the Candle") {
                dismiss()
                session.lightCandle()
            }
            .buttonStyle(PreparationButtonStyle())
            .padding(.bottom, 26)
        }
        .padding(.horizontal, 24)
        .presentationDetents([.height(500)])
        .presentationDragIndicator(.hidden)
        .presentationBackground(Color(red: 0.07, green: 0.065, blue: 0.055))
        .accessibilityElement(children: .contain)
    }

    private func selectionRow(
        title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.orange : Color.white.opacity(0.22))
            }
            .font(.system(size: 17, weight: .regular, design: .rounded))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 18)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PreparationButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(.white.opacity(configuration.isPressed ? 0.72 : 0.96), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}
