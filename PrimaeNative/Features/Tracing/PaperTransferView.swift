import SwiftUI

/// Overlay shown after the freeWrite phase when paper-transfer mode is enabled.
/// Flow: shows the reference letter for 3 s → write-on-paper prompt for 10 s →
/// three-button self-assessment (😊 / 😐 / 😟). Selecting a button calls
/// onComplete with the corresponding score (1.0 / 0.5 / 0.0).
struct PaperTransferView: View {
    @Environment(TracingViewModel.self) private var vm
    let letter: String
    let onComplete: (Double) -> Void
    /// Injectable sleeper so the 3 s / 10 s timing is testable
    /// deterministically without 13 s of wall-clock wait.
    var sleep: Sleeper = realSleeper

    @State private var phase: Phase = .showLetter

    enum Phase: Equatable { case showLetter, writePaper, assess }

    var body: some View {
        ZStack {
            Color.black.opacity(0.65)
                .ignoresSafeArea()

            VStack(spacing: 32) {
                switch phase {
                case .showLetter:
                    Text(letter)
                        .font(.system(size: 180, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.ink)
                        .transition(.opacity)
                        .accessibilityLabel("Buchstabe \(letter)")

                case .writePaper:
                    VStack(spacing: 16) {
                        Image(systemName: "pencil")
                            .font(.system(size: 64))
                            .foregroundStyle(.blue)
                            .accessibilityHidden(true)
                        Text("Schreibe den Buchstaben jetzt auf Papier!")
                            .font(.display(FontSize.lg, weight: .bold))
                            .multilineTextAlignment(.center)
                    }
                    .accessibilityElement(children: .combine)
                    .transition(.opacity)

                case .assess:
                    VStack(spacing: 24) {
                        Text("Ist dir der Buchstabe gut gelungen?")
                            .font(.display(FontSize.lg, weight: .bold))
                            .multilineTextAlignment(.center)
                        HStack(spacing: 20) {
                            assessButton(emoji: "😟", label: "nochmal üben", score: 0.0)
                            assessButton(emoji: "😐", label: "okay",          score: 0.5)
                            assessButton(emoji: "😊", label: "super",         score: 1.0)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .padding(40)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 24)
            .padding(48)
        }
        .task {
            // Children can't read the prompt text; speak each phase
            // aurally so pre-readers get the same instruction.
            vm.prompts.play(.paperShow,   fallbackText: ChildSpeechLibrary.paperTransferShow)
            do {
                try await sleep(.seconds(3))
                withAnimation { phase = .writePaper }
                vm.prompts.play(.paperWrite, fallbackText: ChildSpeechLibrary.paperTransferWrite)
                try await sleep(.seconds(10))
                withAnimation { phase = .assess }
                vm.prompts.play(.paperAssess, fallbackText: ChildSpeechLibrary.paperTransferAssess)
            } catch {}
        }
    }

    private func assessButton(emoji: String, label: String, score: Double) -> some View {
        Button {
            onComplete(score)
        } label: {
            VStack(spacing: 8) {
                Text(emoji)
                    .font(.system(size: 56))
                Text(label)
                    .font(.body(FontSize.md, weight: .semibold))
                    .foregroundStyle(Color.ink)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
