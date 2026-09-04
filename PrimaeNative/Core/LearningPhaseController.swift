// LearningPhaseController.swift
// PrimaeNative
//
// Manages phase transitions and per-phase scoring for a single letter session.
// Pure value type with no side effects — fully testable without mocks.

import CoreGraphics
import Foundation

/// Coordinates the four-phase learning flow for one letter.
///
/// Usage:
/// ```swift
/// var controller = LearningPhaseController()
/// controller.advance(score: 1.0)   // observe → direct
/// controller.advance(score: 1.0)   // direct → guided
/// controller.advance(score: 0.85)  // guided → freeWrite
/// controller.advance(score: 0.72)  // freeWrite → complete
/// assert(controller.isLetterSessionComplete)
/// assert(controller.starsEarned == 4)
/// ```
struct LearningPhaseController: Equatable {

    // MARK: - State

    /// The currently active learning phase.
    private(set) var currentPhase: LearningPhase = .observe

    /// Scores recorded for each completed phase (0–1).
    private(set) var phaseScores: [LearningPhase: CGFloat] = [:]

    /// True once all three phases have been completed.
    private(set) var isLetterSessionComplete = false

    /// Thesis evaluation mode. Determines which phases are active.
    let condition: ThesisCondition

    // MARK: - Init

    init(condition: ThesisCondition = .threePhase) {
        self.condition = condition
        switch condition {
        case .threePhase:
            currentPhase = .observe
        case .guidedOnly, .control:
            // Skip observe phase — start directly at guided.
            currentPhase = .guided
        }
    }

    // MARK: - Computed properties

    /// Stars earned in this letter session, 0…N where N is the number
    /// of active phases under the current thesis condition. A phase
    /// earns its star only when its recorded score clears
    /// `starThreshold(for:)`, so passing observe/direct without
    /// actually tracing caps at 2 stars rather than 4.
    var starsEarned: Int {
        phaseScores.reduce(0) { acc, entry in
            acc + (entry.value >= Self.starThreshold(for: entry.key) ? 1 : 0)
        }
    }

    /// Lowest score required to earn that phase's star. observe/direct
    /// are pass/fail (0 threshold); guided needs ≥ half the checkpoints;
    /// freeWrite needs roughly matching form (≈ 3× checkpoint radius).
    /// Exposed so UI can mirror it when explaining star counts.
    static func starThreshold(for phase: LearningPhase) -> CGFloat {
        switch phase {
        case .observe, .direct: return 0.0
        case .guided:           return 0.5
        case .freeWrite:        return 0.4
        }
    }

    /// Maximum stars achievable under the current thesis condition.
    /// The celebration overlay must show exactly this many — children
    /// in guidedOnly/control would otherwise see empty stars for a
    /// perfect session (motivational confound).
    var maxStars: Int { activePhases.count }

    /// The phases that are active under the current thesis condition.
    var activePhases: [LearningPhase] {
        switch condition {
        case .threePhase:
            return LearningPhase.allCases
        case .guidedOnly, .control:
            return [.guided]
        }
    }

    /// Overall session score — unweighted average across all completed
    /// phases' `score` values.
    ///
    /// NOT a clean accuracy signal under `.threePhase` (found
    /// 2026-09-04 — see `PhaseSessionRecord.score` and DECISIONS.md
    /// D12): `observe` and `direct` always score exactly `1.0`
    /// (completion markers, not measurements), so with all 4 phases
    /// active this average has a mathematical FLOOR of 0.5 — a child
    /// who traces nothing correctly in `guided`/`freeWrite` (both 0)
    /// still yields `overallScore` = 0.5. This value feeds
    /// `LetterProgress.bestAccuracy` and
    /// `ParentDashboardStoring.recordSession`'s `accuracy` — both
    /// systematically inflated for that condition, not merely an
    /// average of incomparable quantities. `.guidedOnly`/`.control`
    /// (single active phase) don't have this floor, since there's
    /// nothing else in the average to dilute it.
    var overallScore: CGFloat {
        guard !phaseScores.isEmpty else { return 0 }
        return phaseScores.values.reduce(0, +) / CGFloat(phaseScores.count)
    }

    /// Whether the current phase requires touch input from the child.
    var isTouchEnabled: Bool {
        switch currentPhase {
        case .observe:   return false
        case .direct:    return true   // Tap the numbered start dots
        case .guided:    return true
        case .freeWrite: return true
        }
    }

    /// Whether checkpoints should be visually rendered on the canvas.
    /// Direct phase manages its own dot overlay (DirectPhaseDotsOverlay).
    var showCheckpoints: Bool {
        switch currentPhase {
        case .observe:   return true   // Show numbered dots
        case .direct:    return false  // Overlay handles rendering
        case .guided:    return true   // Show checkpoint halos
        case .freeWrite: return false  // No visual aid
        }
    }

    /// Whether the checkpoint-matching stroke tracker gates progress.
    var useCheckpointGating: Bool {
        switch currentPhase {
        case .observe:   return false
        case .direct:    return false  // Tap-based — not stroke-gated
        case .guided:    return true
        case .freeWrite: return false  // Freehand — scored post-hoc
        }
    }

    // MARK: - Mutations

    /// Complete the current phase and advance to the next one.
    ///
    /// - Parameter score: Accuracy for the completed phase (0–1).
    /// - Returns: `true` if advanced to a new phase, `false` if the
    ///   letter session is now complete.
    @discardableResult
    mutating func advance(score: CGFloat) -> Bool {
        let clamped = max(0, min(1, score))
        phaseScores[currentPhase] = clamped

        // Determine next phase under current condition
        let nextPhase: LearningPhase?
        switch condition {
        case .threePhase:
            nextPhase = currentPhase.next
        case .guidedOnly, .control:
            // Only one phase — always complete after guided.
            nextPhase = nil
        }

        guard let next = nextPhase else {
            isLetterSessionComplete = true
            return false
        }
        currentPhase = next
        return true
    }

    /// Reset for a new letter. Clears all phase scores.
    mutating func reset() {
        switch condition {
        case .threePhase:
            currentPhase = .observe
        case .guidedOnly, .control:
            currentPhase = .guided
        }
        phaseScores = [:]
        isLetterSessionComplete = false
    }

    /// Force-set phase (for resuming from persisted state).
    mutating func resume(at phase: LearningPhase) {
        guard activePhases.contains(phase) else { return }
        currentPhase = phase
    }
}
