// LetterWheelPicker.swift
// PrimaeNative
//
// 4-column overlay picker shown when the child long-presses the
// current-letter pill in SchuleWorldView.
//
// COMPILED OUT OF THE STUDY BUILD. Child-reachable (its own consumer
// comment says so directly: "shown when the child long-presses"), not
// the tracing task — a free-jump navigation shortcut layered on top of
// it, not the trace itself — not proctor-facing, not a research
// surface. Letting a child jump directly to any letter in the pinned
// pool, out of `letterOrdering`'s sequence, is the same class of risk
// `schriftArt`/`letterOrdering`'s own studyMode pin exists to prevent —
// `nextLetter()`/`previousLetter()` (the bottom-bar nav arrows) remain
// as the sole, sequence-respecting way to move between letters in a
// study build. The CI identity scan asserts this via SURFACES
// (ios-build.yml).
#if !STUDY_BUILD
import SwiftUI

struct LetterWheelPicker: View {
    let letters: [String]
    let currentLetter: String
    let starCount: (String) -> Int
    let onSelect: (String) -> Void
    let onDismiss: () -> Void

    /// Dynamic-Type-scaled tile geometry — glyph + tile scale together
    /// so the letter never clips at larger accessibility sizes.
    @ScaledMetric(relativeTo: .title) private var tileSize: CGFloat = 60
    @ScaledMetric(relativeTo: .title) private var letterFontSize: CGFloat = 34

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        ZStack {
            // Sighted users tap the scrim to dismiss; VoiceOver gets an
            // explicit "Abbrechen" button so focus order stays
            // deterministic.
            Color.ink.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)
                .accessibilityHidden(true)

            VStack(spacing: 16) {
                grid
                    .padding(20)
                    .background(.ultraThinMaterial,
                                in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(Color.white.opacity(0.25), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.2), radius: 24, y: 8)

                Button("Abbrechen") { onDismiss() }
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .accessibilityHint("Schließt die Buchstabenauswahl, ohne den Buchstaben zu wechseln")
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 40)
        }
        .transition(.opacity)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(letters, id: \.self) { letter in
                    tile(for: letter)
                }
            }
            .padding(8)
        }
        .frame(maxHeight: 420)
    }

    @ViewBuilder
    private func tile(for letter: String) -> some View {
        let isCurrent = letter == currentLetter
        let stars = starCount(letter)
        Button {
            onSelect(letter)
        } label: {
            VStack(spacing: 4) {
                Text(letter)
                    .font(.system(size: letterFontSize, weight: .bold, design: .rounded))
                    .foregroundStyle(isCurrent ? Color.white : Color.ink)
                starRow(stars: stars, highlighted: isCurrent)
            }
            .frame(width: tileSize, height: tileSize)
            .background(
                isCurrent
                    ? Color.brand
                    : Color.brandSoft,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isCurrent ? Color.brand : Color.ink.opacity(0.06),
                            lineWidth: isCurrent ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Buchstabe \(letter)")
        .accessibilityValue(stars > 0 ? "\(stars) Sterne" : "Noch keine Sterne")
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func starRow(stars: Int, highlighted: Bool) -> some View {
        HStack(spacing: 1) {
            ForEach(0..<4, id: \.self) { idx in
                Image(systemName: idx < stars ? "star.fill" : "star")
                    .font(.system(size: 7))
                    .foregroundStyle(highlighted
                                      ? Color.white.opacity(idx < stars ? 1 : 0.5)
                                      : (idx < stars ? AppSurface.starGold : Color.gray.opacity(0.4)))
            }
        }
    }
}
#endif
