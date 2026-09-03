// COMPILED OUT OF THE STUDY BUILD.
// Phase rates — reached only from ParentDashboardView
// The symbol must be ABSENT from the study binary, which the CI
// identity scan asserts via SURFACES. Gating the whole file rather
// than the call site is what makes that assertion meaningful.
#if !STUDY_BUILD
// PhaseRatesView.swift
// PrimaeNative
//
// Horizontal bars of per-phase completion rate (observe / direct /
// guided / freeWrite). Sourced from
// `DashboardSnapshot.phaseCompletionRates`. Distinct per-phase colors
// (blue / indigo / teal / purple) keep phase identity readable; the
// percentage label carries the magnitude.

import SwiftUI

struct PhaseRatesView: View {

    let rates: [String: Double]   // keyed by LearningPhase.rawName

    private static func color(for phase: LearningPhase) -> Color {
        switch phase {
        case .observe:   return .blue
        case .direct:    return .indigo
        case .guided:    return .teal
        case .freeWrite: return .purple
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            // Always render every phase, even with no data, so the
            // parent sees the full pedagogical arc up front.
            ForEach(LearningPhase.allCases, id: \.self) { phase in
                let value = rates[phase.rawName] ?? 0
                let color = Self.color(for: phase)
                HStack(spacing: 12) {
                    Text(phase.displayName)
                        .font(.subheadline)
                        .frame(width: 128, alignment: .leading)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(color.opacity(0.15))
                            Capsule()
                                .fill(color)
                                .frame(width: max(0, geo.size.width * CGFloat(value)))
                        }
                    }
                    .frame(height: 12)

                    Text("\(Int((value * 100).rounded())) %")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(phase.displayName) \(Int((value * 100).rounded())) Prozent abgeschlossen")
            }
        }
        .padding(.vertical, 4)
    }
}
#endif
