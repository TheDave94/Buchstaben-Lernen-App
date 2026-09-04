// COMPILED OUT OF THE STUDY BUILD.
// Child-reachable, not the tracing task, not proctor-facing, not a
// research surface — decided by the recorded classification criteria.
// Its enqueue site was already `!studyMode`-gated
// (PhaseTransitionCoordinator.recordSessionCompletion, "the overlay
// gate is load-bearing"); this closes the gap between "never
// enqueued" and "never compiled in", matching StrokeCalibrationOverlay's
// precedent. The CI identity scan asserts this via SURFACES
// (ios-build.yml).
#if !STUDY_BUILD
import SwiftUI

struct CompletionCelebrationOverlay: View {
    let starsEarned: Int
    /// Max achievable stars under the current thesis condition (1 for
    /// guidedOnly/control, 4 for threePhase) — showing 4 stars to a
    /// guidedOnly child would always reveal 3 empty placeholders.
    let maxStars: Int
    let onWeiter: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Text("🎉")
                    .font(.system(size: 58))
                    .accessibilityHidden(true)

                // Distinct from SchuleWorldView's "Nachspuren fertig"
                // praise so the child doesn't see the same line twice
                // when card + celebration both appear.
                Text("Geschafft!")
                    .font(.display(FontSize.xxl, weight: .bold))
                    .foregroundStyle(Color.paper)
                    .multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    ForEach(1...max(1, maxStars), id: \.self) { index in
                        Image(systemName: index <= starsEarned ? "star.fill" : "star")
                            .font(.system(size: 40))
                            .foregroundStyle(index <= starsEarned
                                ? AppSurface.starGold
                                : Color.paper.opacity(0.55))
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(starsEarned) von \(maxStars) Sternen")

                Button("Weiter", action: onWeiter)
                    .buttonStyle(StickerButtonStyle(tint: .paper, labelColor: .brand))
                    .accessibilityLabel("Weiter zum nächsten Buchstaben")
            }
            .padding(40)
            .background(Color.brand,
                        in: RoundedRectangle(cornerRadius: Radii.xl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radii.xl, style: .continuous)
                    .stroke(Color.paper.opacity(0.3), lineWidth: 1)
            )
            .shadow(color: Color.brand.opacity(0.35), radius: 24, y: 8)
        }
    }
}
#endif
