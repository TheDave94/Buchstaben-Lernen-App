// COMPILED OUT OF THE STUDY BUILD.
// Werkstatt world — child-reachable, not the tracing task (Q ruling)
// The symbol must be ABSENT from the study binary, which the CI
// identity scan asserts via SURFACES. Gating the whole file rather
// than the call site is what makes that assertion meaningful.
#if !STUDY_BUILD
// WerkstattWorldView.swift
// PrimaeNative
//
// World 2 — Schreibwerkstatt. Two-column layout: 140 pt mode-card
// panel (Buchstabe / Wort) + freeform canvas. Reuses
// `FreeformWritingView`; this view only configures `writingMode`.

import SwiftUI

struct WerkstattWorldView: View {
    @Environment(TracingViewModel.self) private var vm

    var body: some View {
        ZStack {
            WorldPalette.background(for: .werkstatt)
                .ignoresSafeArea()

            HStack(spacing: 0) {
                modePanel
                Divider()
                freeformContent
            }
        }
        .onAppear {
            // Auto-enter freeform on landing; `MainAppView` drops us
            // back to guided whenever the user leaves this world.
            if vm.writingMode != .freeform {
                vm.enterFreeformMode(subMode: .letter)
            }
        }
    }

    // MARK: - Mode panel (left 140pt)

    private var modePanel: some View {
        VStack(spacing: 14) {
            modeCard(
                subMode: .letter,
                title: "Buchstabe",
                subtitle: "Einzelner Buchstabe",
                systemImage: "character"
            )
            modeCard(
                subMode: .word,
                title: "Wort",
                subtitle: "Ganzes Wort",
                systemImage: "text.cursor"
            )
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 20)
        .frame(width: 140)
        .frame(maxHeight: .infinity)
        .background(Color.paper.opacity(0.6))
    }

    @ViewBuilder
    private func modeCard(subMode: FreeformSubMode,
                          title: String,
                          subtitle: String,
                          systemImage: String) -> some View {
        let isActive = vm.freeformSubMode == subMode
        Button {
            if subMode == .word, vm.freeformTargetWord == nil {
                vm.selectFreeformWord(
                    FreeformWordList.all.first
                        ?? FreeformWord(word: "OMA", difficulty: 1))
            } else {
                vm.freeformSubMode = subMode
                vm.clearFreeformCanvas()
            }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(isActive ? Color.paper : Color.werkstatt)
                Text(title)
                    .font(.display(FontSize.base, weight: .bold))
                    .foregroundStyle(isActive ? Color.paper : Color.ink)
                Text(subtitle)
                    .font(.body(FontSize.xs, weight: .medium))
                    .foregroundStyle(isActive
                                      ? Color.paper.opacity(0.95)
                                      : AppSurface.caption)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 120)
            .padding(.horizontal, 8)
            .background(
                isActive ? Color.werkstatt : AppSurface.card,
                in: RoundedRectangle(cornerRadius: Radii.md, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radii.md, style: .continuous)
                    .stroke(isActive ? Color.werkstatt : AppSurface.cardEdge,
                            lineWidth: isActive ? 2 : 1)
            )
            .shadow(color: Color.ink.opacity(0.06), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Freeform content (right)

    @ViewBuilder
    private var freeformContent: some View {
        if vm.writingMode == .freeform {
            FreeformWritingView()
        } else {
            // Transient state during the first-onAppear handoff —
            // canvas-paper avoids a grey flash before freeform takes over.
            Color.canvasPaper
        }
    }
}
#endif
