// RetrievalScheduler.swift
// PrimaeNative
//
// Retrieval-practice scheduling layered on top of `LetterScheduler`:
// every Nth letter selection presents a brief recognition test
// before tracing (Roediger & Karpicke 2006). Outcomes persist as a
// rolling [Bool] on `LetterProgress.retrievalAttempts`.

import Foundation

@MainActor
final class RetrievalScheduler {
    /// Selection-counter modulus. `1` = retrieve every letter; `0` =
    /// disabled (always returns false).
    var interval: Int = 3
    /// Letters with fewer than this many prior completions skip
    /// retrieval. Testing on a never-seen letter is just guessing.
    var minimumPriorCompletions: Int = 1

    /// Total retrieval-eligible letter selections. Persisted in
    /// UserDefaults so the cadence survives an app relaunch.
    private(set) var selectionsSinceRetrieval: Int

    /// UserDefaults key for the rolling counter. NOT private: the
    /// new-participant reset in `ParticipantStore` must clear this exact
    /// key, and the tests must assert on it. One declaration so the
    /// three cannot drift apart on the string — the same discipline
    /// `StudyBuild.studyModeDefaultsKey` already uses.
    static let counterKey = "de.flamingistan.primae.retrievalCounter"

    init(initialCounter: Int? = nil) {
        if let v = initialCounter {
            self.selectionsSinceRetrieval = v
        } else {
            let stored = UserDefaults.standard.integer(forKey: Self.counterKey)
            self.selectionsSinceRetrieval = max(0, stored)
        }
    }

    /// Returns `true` when the next letter selection should fire a
    /// retrieval prompt. Bumps the counter regardless so subsequent
    /// non-firing selections still progress toward the next test.
    /// Returns `false` for letters with insufficient prior completions
    /// — we don't test on what the child hasn't seen.
    func shouldPrompt(for letter: String, progress: LetterProgress) -> Bool {
        guard interval > 0 else { return false }
        guard progress.completionCount >= minimumPriorCompletions else { return false }
        selectionsSinceRetrieval += 1
        let fire = selectionsSinceRetrieval >= interval
        if fire {
            selectionsSinceRetrieval = 0
        }
        UserDefaults.standard.set(selectionsSinceRetrieval, forKey: Self.counterKey)
        return fire
    }

    /// Reset the cadence counter without recording an outcome. Used
    /// by tests and by the parent's "Erinnerungstest neu starten".
    func reset() {
        selectionsSinceRetrieval = 0
        UserDefaults.standard.set(0, forKey: Self.counterKey)
    }
}
