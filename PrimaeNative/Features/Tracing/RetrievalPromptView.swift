// RetrievalPromptView.swift
// PrimaeNative
//
// Spaced-retrieval recognition prompt (Roediger & Karpicke 2006).
// Every Nth letter selection plays the audio and shows three
// candidates; the child's answer lands on
// `LetterProgress.retrievalAttempts`.
//
// COMPILED OUT OF THE STUDY BUILD. Child-reachable, not the tracing
// task, not proctor-facing, not a research surface — decided by the
// recorded classification criteria. Its enqueue site was already
// `studyMode`-gated (TracingViewModel.loadRecommendedLetter's early
// return); this closes the gap between "never enqueued" and "never
// compiled in", matching StrokeCalibrationOverlay's precedent. The CI
// identity scan asserts this via SURFACES (ios-build.yml).
#if !STUDY_BUILD
import SwiftUI

struct RetrievalPromptView: View {
    @Environment(TracingViewModel.self) private var vm
    let target: String
    let distractors: [String]
    /// Replays the audio cue. The VM wires this to `replayAudio()` so
    /// the parent's name / phoneme toggle is honoured automatically.
    let onPlayAudio: () -> Void
    /// Fires once on the first tap; child's choice (`tapped`) is the
    /// raw label they picked; `correct` is whether it matched `target`.
    let onAnswer: (_ tapped: String, _ correct: Bool) -> Void

    @State private var hasAnswered = false
    @State private var revealed: String? = nil

    /// The three buttons in a stable order — target included exactly
    /// once, plus the two distractors. Shuffled on first appear so the
    /// child can't memorise position.
    @State private var options: [String] = []

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()

            VStack(spacing: 28) {
                Text("Welchen Buchstaben hörst du?")
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)

                // Audio cue — re-tap allowed until the child answers.
                Button {
                    onPlayAudio()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 22))
                        Text("Hören")
                            .font(.title3.weight(.semibold))
                    }
                    .foregroundStyle(Color(red: 0.22, green: 0.30, blue: 0.75))
                    .padding(.horizontal, 28).padding(.vertical, 12)
                    .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(hasAnswered)
                .accessibilityLabel("Buchstaben anhören")
                .accessibilityHint("Spielt den gefragten Buchstaben erneut ab.")

                HStack(spacing: 18) {
                    ForEach(options, id: \.self) { option in
                        choiceButton(option)
                    }
                }
            }
            .padding(36)
            .frame(maxWidth: 480)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.36, green: 0.55, blue: 0.94),
                        Color(red: 0.55, green: 0.39, blue: 0.91)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 28, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.35), lineWidth: 1.5)
            )
            .shadow(color: .black.opacity(0.30), radius: 24, y: 6)
        }
        .onAppear {
            // Shuffle once per appearance so the child can't anticipate
            // the target by position.
            options = ([target] + distractors).shuffled()
            // Spoken instruction first for non-readers, then the cue.
            vm.prompts.play(.retrievalQuestion,
                            fallbackText: ChildSpeechLibrary.retrievalQuestion)
            onPlayAudio()
        }
    }

    @ViewBuilder
    private func choiceButton(_ letter: String) -> some View {
        let isRevealed = revealed == letter
        let isCorrect = letter == target
        let baseFill: Color = {
            if hasAnswered, isRevealed {
                return isCorrect ? Color.green.opacity(0.85)
                                 : Color.red.opacity(0.78)
            }
            return Color.white
        }()
        let textColor: Color = (hasAnswered && isRevealed) ? .white
            : Color(red: 0.22, green: 0.30, blue: 0.75)

        Button {
            guard !hasAnswered else { return }
            hasAnswered = true
            revealed = letter
            onAnswer(letter, isCorrect)
        } label: {
            Text(letter)
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .foregroundStyle(textColor)
                .frame(width: 92, height: 96)
                .background(baseFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.55), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Buchstabe \(letter)")
        .accessibilityHint(hasAnswered
                            ? (isCorrect ? "Richtig" : "Falsch")
                            : "Tippen, um diese Antwort zu wählen.")
    }
}
#endif
