// StudyProbe.swift
// PrimaeNative
//
// The three COLD free-writing probes of the pilot (2026-09-04): a letter
// opened directly in the freeWrite phase — no observe, no direct, no
// guided, no demonstration, audio gated off — so that production is
// measured without training. Each probe stamps its kind on the phase
// row (`PhaseSessionRecord.probe`), which is what lets the analysis tell
// a pretest from a post-test from a delayed test on the same letter.
// Until this existed only the untrained-pair post-test route was built
// (H6), the pretest the thesis describes had no route for a TRAINED
// letter, and no row said which timepoint it belonged to.

import Foundation

enum StudyProbe: String, Codable, CaseIterable, Sendable {
    /// Before training: every child writes all five study letters once.
    /// The ANCOVA covariate (thesis Ch.6). Any study letter.
    case pretest
    /// After the training passes, the two UNTRAINED letters. The trained
    /// letters' post-test is the freeWrite phase of their final training
    /// pass (thesis Ch.6), so this kind refuses a trained letter.
    case posttest
    /// The delayed retention test some weeks later: all five letters,
    /// cold, on a participant whose identity was restored from the
    /// pseudonymous identifier (`ParticipantStore.restoreParticipant`).
    case delayed

    /// Which of the study letters this kind may open for a participant
    /// with the given untrained pair.
    func permits(letter: String, untrained: Set<String>, studyLetters: Set<String>) -> Bool {
        guard studyLetters.contains(letter) else { return false }
        switch self {
        case .pretest, .delayed: return true
        case .posttest:          return untrained.contains(letter)
        }
    }

    /// Proctor-facing German label.
    var displayName: String {
        switch self {
        case .pretest:  return "Vortest"
        case .posttest: return "Post-Test"
        case .delayed:  return "Nachtest (verzögert)"
        }
    }
}
