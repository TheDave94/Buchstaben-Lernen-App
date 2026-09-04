// RecognitionFeedbackView.swift
// PrimaeNative
//
// Child-friendly badge for the CoreML recognition result. Tiers:
//   • green  (correct & confident, conf > 0.7)
//   • yellow (correct & uncertain, 0.4 ≤ conf ≤ 0.7)
//   • orange (wrong & confident, conf > 0.7)
// Raw confidence below 0.4 renders nothing; auto-dismissed by
// OverlayQueueManager after 3 s, or earlier on tap.
//
// COMPILED OUT OF THE STUDY BUILD. Child-reachable, not the tracing
// task (post-freeWrite feedback ABOUT the trace, not the trace itself),
// not proctor-facing, not a research surface — decided by the recorded
// classification criteria. Both construction sites were already
// `!studyMode`-gated (PhaseTransitionCoordinator.celebrateFreeWrite's
// enqueue, and requestFreeWriteRetry which is itself only reachable
// when `!vm.studyMode`); this closes the gap between "never
// constructed" and "never compiled in", matching
// StrokeCalibrationOverlay's precedent. The CI identity scan asserts
// this via SURFACES (ios-build.yml).
#if !STUDY_BUILD
import SwiftUI

struct RecognitionFeedbackView: View {
    let result: RecognitionResult
    let expectedLetter: String
    let onDismiss: () -> Void

    var body: some View {
        Group {
            if let style = feedbackStyle {
                HStack(spacing: 12) {
                    Image(systemName: style.icon)
                        .font(.display(FontSize.lg))
                        .foregroundStyle(.white)
                    Text(style.message)
                        .font(.body(FontSize.md, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(style.tint, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                .onTapGesture { onDismiss() }
                // Auto-dismiss owned by OverlayQueueManager — don't add
                // a view-level timer here, it would race the queue.
                .accessibilityElement(children: .combine)
                .accessibilityLabel(style.message)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Tippen, um die Rückmeldung zu schließen")
            } else {
                // Confidence < 0.4 — model is unsure; show nothing.
                Color.clear.frame(height: 0)
            }
        }
    }

    // MARK: - Style selection

    private struct Style {
        let tint: Color
        let icon: String
        let message: String
    }

    private var feedbackStyle: Style? {
        let conf = result.confidence
        if conf < 0.4 { return nil }

        if result.isCorrect {
            if conf > 0.7 {
                return Style(
                    tint: .green,
                    icon: "checkmark.circle.fill",
                    message: "Du hast ein \(expectedLetter) geschrieben! 🎉"
                )
            } else {
                return Style(
                    tint: .yellow,
                    icon: "hand.thumbsup.fill",
                    message: "Das sieht aus wie ein \(expectedLetter) — gut gemacht!"
                )
            }
        }

        if conf > 0.7 {
            return Style(
                tint: .orange,
                icon: "arrow.triangle.2.circlepath",
                message: "Das sieht eher nach \(result.predictedLetter) aus — schreib nochmal ein \(expectedLetter)!"
            )
        }
        // conf in (0.4, 0.7] but wrong — too uncertain to correct.
        return nil
    }
}

#if DEBUG
#Preview("Green") {
    RecognitionFeedbackView(
        result: RecognitionResult(
            predictedLetter: "A",
            confidence: 0.92,
            topThree: [.init(letter: "A", confidence: 0.92)],
            isCorrect: true
        ),
        expectedLetter: "A",
        onDismiss: {}
    )
    .padding()
}

#Preview("Yellow") {
    RecognitionFeedbackView(
        result: RecognitionResult(
            predictedLetter: "A",
            confidence: 0.55,
            topThree: [.init(letter: "A", confidence: 0.55)],
            isCorrect: true
        ),
        expectedLetter: "A",
        onDismiss: {}
    )
    .padding()
}

#Preview("Orange") {
    RecognitionFeedbackView(
        result: RecognitionResult(
            predictedLetter: "O",
            confidence: 0.82,
            topThree: [.init(letter: "O", confidence: 0.82)],
            isCorrect: false
        ),
        expectedLetter: "A",
        onDismiss: {}
    )
    .padding()
}
#endif
#endif
