// PreTaskDemonstration.swift
// PrimaeNative
//
// Pre-task sound-arm demonstration, per the 2026-09-03 study-design
// instruction: both sound arms get a brief demonstration BEFORE the
// tracing task, structurally matched in duration and form, and neither
// coupled to the child's own trace.
//
// THE REASON FOR THE SYMMETRY: a demonstration can INSTALL a crossmodal
// mapping rather than reveal one already there. If only one arm got a
// pre-task demonstration, that arm's later tracing-task audio wouldn't
// just be "the arm's sound" — it would be "the arm's sound, already
// taught". That confounds the arm contrast with having been taught,
// not with what the sound itself is. So every arm gets a demonstration
// of the SAME shape; only its sound differs (or is absent) — the same
// "only audio varies" shape as pilot decision D1.
//
// Content per arm:
//   .phoneme  — a sound-letter exposure: the letter's own phoneme,
//               played once.
//   .spatial  — an axis demonstration: a scripted pitch/pan sweep
//               across the FULL canvas range, independent of any
//               specific letter's shape (a letter with a short stroke
//               would otherwise give a foreshortened, letter-dependent
//               sweep — see `axisSweep`).
//   .silent   — no audio is added. The unchanged ghost-letter animation
//               (LetterAnimationGuide / AnimationGuideController) that
//               already precedes tracing in every arm today IS the
//               silent arm's matched non-auditory equivalent: every
//               arm already gets the SAME visual demonstration of the
//               SAME duration; sound arms layer their own scripted
//               sound onto that same window, silent doesn't.
//
// NOT trace-coupled: `TracingViewModel.armPreTaskDemonstration` drives
// this from its OWN scripted timeline (`axisSweep`, or a single
// phoneme play), never from `TouchDispatcher`'s live-touch coupling —
// a structurally distinct mechanism from the tracing-task coupling
// §2.6 governs.

import CoreGraphics
import Foundation

enum PreTaskDemonstration {
    /// Total demo window, seconds. Fixed so the spatial axis sweep and
    /// the phoneme sound-letter exposure are matched in duration
    /// regardless of the phoneme clip's own natural length (phonemes
    /// are short sustained continuants / clean-burst stops — see
    /// docs/DECISIONS.md §2.6 — almost always shorter than this).
    static let duration: TimeInterval = 2.0

    /// Sample count for the scripted axis sweep, spread evenly across
    /// `duration`.
    static let sweepStepCount = 40

    /// One instant of the scripted, non-trace-coupled axis sweep: how
    /// far into the demo (seconds, monotonically increasing) and where
    /// the (silent, app-driven) sweep point sits in normalized canvas
    /// space at that instant.
    struct SweepSample: Equatable {
        let elapsed: TimeInterval
        let point: CGPoint
    }

    /// Pure — no Task, no audio, no clock, so it's directly unit-
    /// testable. One full top→bottom→top pass on Y (pitch: high → low
    /// → high) and one full left→right→left pass on X (pan), a
    /// quarter-cycle out of phase so the two axes are audible moving
    /// independently rather than only together — a clearer axis
    /// demonstration than a straight diagonal would give.
    static func axisSweep(steps: Int = Self.sweepStepCount,
                          duration: TimeInterval = Self.duration) -> [SweepSample] {
        guard steps > 1, duration > 0 else { return [] }
        return (0..<steps).map { i in
            let t = Double(i) / Double(steps - 1)
            let elapsed = t * duration
            let y = 0.5 - 0.5 * cos(2 * .pi * t)
            let x = 0.5 - 0.5 * cos(2 * .pi * t + .pi / 2)
            return SweepSample(elapsed: elapsed, point: CGPoint(x: x, y: y))
        }
    }
}
