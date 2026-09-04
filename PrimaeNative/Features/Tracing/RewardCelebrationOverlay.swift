// RewardCelebrationOverlay.swift
// PrimaeNative
//
// Immediate "you just earned this" moment for an unlocked
// `RewardEvent`; the persistent badge lives in the Fortschritte
// gallery. Auto-dismissed by the OverlayQueueManager.
//
// COMPILED OUT OF THE STUDY BUILD. Child-reachable, not the tracing
// task, not proctor-facing, not a research surface — decided by the
// recorded classification criteria. Its enqueue site was already
// `!studyMode`-gated (PhaseTransitionCoordinator.commitCompletion:
// "reward systems are off so all arms are identical, audit C2"); this
// closes the gap between "never enqueued" and "never compiled in",
// matching StrokeCalibrationOverlay's precedent and the sibling
// Fortschritte gallery it feeds, which is already excluded the same
// way. The CI identity scan asserts this via SURFACES (ios-build.yml).
#if !STUDY_BUILD
import SwiftUI

struct RewardCelebrationOverlay: View {
    let event: RewardEvent

    private var emoji: String {
        switch event {
        case .firstLetter:         return "🌟"
        case .dailyGoalMet:        return "🎯"
        case .streakDay3:          return "🔥"
        case .streakWeek:          return "🏅"
        case .streakMonth:         return "🏆"
        case .allLettersComplete:  return "🎉"
        case .perfectAccuracy:     return "✨"
        case .centuryClub:         return "💯"
        }
    }

    private var label: String {
        switch event {
        case .firstLetter:         return "Erster Buchstabe!"
        case .dailyGoalMet:        return "Tagesziel geschafft!"
        case .streakDay3:          return "3 Tage in Folge!"
        case .streakWeek:          return "7 Tage in Folge!"
        case .streakMonth:         return "30 Tage in Folge!"
        case .allLettersComplete:  return "Alle Buchstaben!"
        case .perfectAccuracy:     return "Perfekt!"
        case .centuryClub:         return "100 Buchstaben!"
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 18) {
                Text(emoji)
                    .font(.system(size: 84))
                    .accessibilityHidden(true)
                Text("Auszeichnung freigeschaltet")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                Text(label)
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
            }
            .padding(36)
            .frame(maxWidth: 360)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 1.00, green: 0.78, blue: 0.20),
                        Color(red: 1.00, green: 0.55, blue: 0.05)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 28, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.45), lineWidth: 1.5)
            )
            .shadow(color: .black.opacity(0.30), radius: 22, y: 6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Auszeichnung: \(label)")
        }
    }
}
#endif
