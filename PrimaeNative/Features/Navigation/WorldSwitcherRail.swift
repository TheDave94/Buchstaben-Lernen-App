// WorldSwitcherRail.swift
// PrimaeNative
//
// 64pt vertical rail. Three world icons; gear at the bottom opens
// `ParentAreaView` after a 2-second long press so a 5-year-old can't
// reach it by accident.

import SwiftUI

struct WorldSwitcherRail: View {
    @Environment(TracingViewModel.self) private var vm
    @Binding var activeWorld: AppWorld
    @Binding var showParentArea: Bool

    /// 0…1 progress of the in-flight gear long-press.
    @State private var gearHoldProgress: Double = 0
    /// Hold duration required to open the parent area.
    private let gearHoldSeconds: Double = 2.0

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 24)
            #if !STUDY_BUILD
            // One world remains in a study build, so a switcher would be a
            // button that selects what is already selected. The rail itself
            // stays: it carries the gear, which is the proctor's only route
            // into the parent area.
            worldButtons
            #endif
            Spacer()
            gearButton
                .padding(.bottom, 24)
        }
        .frame(width: 64)
        .frame(maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [AppSurface.railTop, AppSurface.railBottom],
                startPoint: .top, endPoint: .bottom
            )
        )
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.black.opacity(0.06))
                .frame(width: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Navigationsleiste")
    }

    // MARK: - World buttons
    //
    // Gated at the DECLARATION, not merely where `body` uses it: a
    // gated call site leaves the declaration compiling, and
    // `worldButton(for:)` references `.fortschritte`, which does not
    // exist in a study build.
    #if !STUDY_BUILD

    private var worldButtons: some View {
        VStack(spacing: 8) {
            ForEach(AppWorld.allCases) { world in
                worldButton(for: world)
            }
        }
    }

    @ViewBuilder
    private func worldButton(for world: AppWorld) -> some View {
        let isActive = world == activeWorld
        let accent = WorldPalette.accent(for: world)
        Button {
            activeWorld = world
        } label: {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isActive ? accent : accent.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(isActive ? accent : Color.clear,
                                          lineWidth: 2)
                    )

                VStack(spacing: 3) {
                    Image(systemName: world.icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(isActive ? Color.paper : accent)
                    Text(world.label)
                        .font(.display(10, weight: .semibold))
                        .foregroundStyle(isActive ? Color.paper : accent)
                }
                .frame(width: 44, height: 56)

                if world == .fortschritte, starTotal > 0 {
                    starBadge(count: starTotal)
                        .offset(x: 6, y: -6)
                }
            }
            .frame(width: 48, height: 56)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(world.accessibilityLabel)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    #endif

    private func starBadge(count: Int) -> some View {
        Text(badgeText(for: count))
            .font(.body(FontSize.xs, weight: .bold))
            .foregroundStyle(Color.paper)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Color.star, in: Capsule())
            .overlay(Capsule().stroke(Color.paper, lineWidth: 1))
            .accessibilityLabel("\(count) Sterne")
    }

    private func badgeText(for n: Int) -> String {
        n > 99 ? "99+" : "\(n)"
    }

    /// Sum of quality-gated star counts across letters — keeps the
    /// badge in agreement with the celebration overlay and gallery.
    private var starTotal: Int {
        vm.allProgress.values.reduce(0) { acc, prog in
            acc + LetterStars.stars(for: prog.phaseScores)
        }
    }

    // MARK: - Gear long-press

    @ViewBuilder
    private var gearButton: some View {
        ZStack {
            Circle()
                .stroke(Color.paperEdge, lineWidth: 2)
                .frame(width: 44, height: 44)
            Circle()
                .trim(from: 0, to: gearHoldProgress)
                .stroke(Color.brand, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 44, height: 44)
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.1), value: gearHoldProgress)
            Image(systemName: "gear")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.inkSoft)
        }
        // 44×44 visible ring + 4 pt invisible padding = 48 pt hit
        // area (iOS HIG primary-nav minimum).
        .frame(width: 48, height: 48)
        .contentShape(Rectangle())
        .onLongPressGesture(
            minimumDuration: gearHoldSeconds,
            maximumDistance: 40,
            perform: {
                gearHoldProgress = 0
                showParentArea = true
            },
            onPressingChanged: { pressing in
                if pressing {
                    withAnimation(.linear(duration: gearHoldSeconds)) {
                        gearHoldProgress = 1
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        gearHoldProgress = 0
                    }
                }
            }
        )
        .accessibilityLabel("Eltern-Bereich")
        .accessibilityHint("Zwei Sekunden lang gedrückt halten, um Einstellungen zu öffnen")
    }
}
