// FreeWritePhaseRecorder.swift
// PrimaeNative
//
// Owns the four buffers (canvas-space points, timestamps, forces,
// normalised KP path) plus session-timing state that the freeWrite
// phase produces. The VM gates whether to record based on phase;
// the recorder owns the buffer lifecycle.

import CoreGraphics
import Foundation
import QuartzCore

@MainActor
@Observable
final class FreeWritePhaseRecorder {

    // MARK: - Tap-emitted state (read by views via VM forwarders)

    /// Canvas-space points appended during freeWrite touches.
    private(set) var points: [CGPoint] = []
    /// `CACurrentMediaTime()` for each point in `points`.
    private(set) var timestamps: [CFTimeInterval] = []
    /// Digitiser force per point (0 for finger / no pencil data).
    private(set) var forces: [CGFloat] = []
    /// Same path normalised to 0–1 over the canvas (raw points pass through when canvasSize is .zero — NaN guard) — used by the KP
    /// overlay so it can render at any geometry without re-mapping.
    private(set) var path: [CGPoint] = []
    /// Indices into `points` (and `path`) at which a fresh stroke begins
    /// after a finger-up. Lets the CoreML rasterizer break the polyline
    /// at lifts so multi-stroke letters (F / E / H) don't render with
    /// phantom diagonals that confuse the recognizer (F→P). Index 0 is
    /// implicit; only subsequent stroke starts are stored.
    private(set) var strokeStartIndices: [Int] = []
    /// `CACurrentMediaTime()` at session start. Drives `rhythmScore`.
    private(set) var sessionStart: CFTimeInterval = 0
    /// `CACurrentMediaTime()` when the active guided / freeWrite phase
    /// began. Drives `checkpointsPerSecond` automatisation tracking.
    private(set) var activePhaseStart: CFTimeInterval = 0
    /// Live checkpoints-per-second figure surfaced on the dashboard.
    private(set) var checkpointsPerSecond: CGFloat = 0
    /// Stroke count/order/direction, AND the order-invariant PRIMARY
    /// spatial-deviation outcome — one computation
    /// (`StrokeProcessScorer.analyze`, 2026-09-04) produces both; see
    /// that type's header for why. Nil when nothing comparable was
    /// traced.
    private(set) var lastStrokeProcess: StrokeProcessMeasures?
    /// The PRIMARY accuracy outcome, read off `lastStrokeProcess` — kept
    /// as its own property rather than inlined at every call site.
    /// Lower is better; nil when no assessment has produced a finite one
    /// this session.
    var lastSpatialDeviation: CGFloat? { lastStrokeProcess?.spatialDeviation }
    /// Latest 4-dimension Schreibmotorik assessment. Set by `assess`.
    private(set) var lastAssessment: WritingAssessment? = nil
    /// Captured guided-phase score so the freeWrite chrome can show a
    /// "Nachspuren fertig" feedback band during the transition. Cleared
    /// on `clearAll()`.
    var lastGuidedScore: CGFloat? = nil

    // MARK: - Derived measures

    /// Measured freeWrite span in seconds: **first sample to last
    /// sample**, end-inclusive.
    ///
    /// `record(...)` appends one timestamp per accepted touch sample, so
    /// `timestamps.last` is the last moment the child was writing — not
    /// the moment their final stroke *began*. A stroke-start-based span
    /// would drop the whole final stroke, which for the single-stroke
    /// study letters (I, and M as baked) is the entire trial.
    ///
    /// Excludes the trailing 2.0 s quiet-window auto-advance
    /// (`TouchDispatcher.freeWriteQuietSeconds`) by construction — that
    /// window opens after the last sample. Nil when fewer than two
    /// distinct samples exist, because a span needs two endpoints.
    var measuredSpanSeconds: Double? {
        guard let first = timestamps.first,
              let last = timestamps.last,
              last > first else { return nil }
        return last - first
    }

    // MARK: - Mutation API

    /// Begin a fresh recording window. Call when entering freeWrite.
    func startSession(now: CFTimeInterval = CACurrentMediaTime()) {
        path.removeAll(keepingCapacity: true)
        points.removeAll(keepingCapacity: true)
        timestamps.removeAll(keepingCapacity: true)
        forces.removeAll(keepingCapacity: true)
        strokeStartIndices.removeAll(keepingCapacity: true)
        sessionStart = now
        activePhaseStart = now
        checkpointsPerSecond = 0
        lastStrokeProcess = nil
        lastAssessment = nil
    }

    /// Mark that a new stroke is starting — the next `record(...)`
    /// call kicks off a fresh polyline. Call from the touch dispatcher
    /// at every `beginTouch` while in freeWrite. No-op for the very
    /// first stroke of the session (the implicit index-0 start).
    func beginStroke() {
        guard !points.isEmpty else { return }
        // Two boundaries at one index (an excursion out, in, out with no
        // accepted sample between) would make the trace's own count
        // disagree with `strokeCount` (review 2026-09-05).
        guard strokeStartIndices.last != points.count else { return }
        strokeStartIndices.append(points.count)
    }

    /// Begin the speed-tracking window without resetting freeWrite
    /// buffers. Used when entering guided so checkpointsPerSecond reflects
    /// the guided pass while leaving any pending freeWrite KP path
    /// untouched. (FreeWrite buffers reset via `clearAll` on letter
    /// load or via `startSession` when freeWrite itself begins.)
    func startGuidedSpeedTracking(now: CFTimeInterval = CACurrentMediaTime()) {
        activePhaseStart = now
        checkpointsPerSecond = 0
    }

    /// Append one freeWrite touch sample. Pass canvas-space `point` and
    /// the canvas size so the normalised KP `path` stays in 0–1.
    func record(point: CGPoint,
                timestamp: CFTimeInterval,
                force: CGFloat,
                canvasSize: CGSize) {
        points.append(point)
        timestamps.append(timestamp)
        forces.append(force)
        path.append(CGPoint(
            x: point.x / max(canvasSize.width, 1),
            y: point.y / max(canvasSize.height, 1)
        ))
    }

    /// Update the live checkpoints-per-second counter. Called from the
    /// VM with the integer count of completed checkpoints; the recorder
    /// owns the elapsed-time arithmetic.
    func updateSpeed(completedCheckpoints: Int,
                     now: CFTimeInterval = CACurrentMediaTime()) {
        guard activePhaseStart > 0 else { return }
        let elapsed = now - activePhaseStart
        guard elapsed > 0.1 else { return }
        checkpointsPerSecond = CGFloat(completedCheckpoints) / CGFloat(elapsed)
    }

    /// Multi-cell scoring for word mode. Splits the trace by cell frame,
    /// scores each cell against its own reference, and averages the four
    /// Schreibmotorik dimensions across cells that produced ink. Cells
    /// with fewer than two points are excluded. Falls back to single-cell
    /// scoring against the last reference if no cell collected enough
    /// samples.
    @discardableResult
    func assess(cellReferences: [(frame: CGRect, reference: LetterStrokes)],
                canvasSize: CGSize,
                now: CFTimeInterval = CACurrentMediaTime()) -> WritingAssessment {
        guard let lastCell = cellReferences.last else {
            // No cells supplied at all — synthesize a zero-score
            // assessment so the caller gets a stable shape.
            let empty = WritingAssessment(formAccuracy: 0, tempoConsistency: 0,
                                           pressureControl: 0, rhythmScore: 0)
            lastAssessment = empty
            return empty
        }
        var perCell: [WritingAssessment] = []
        for cell in cellReferences {
            var pts: [CGPoint] = []
            var ts: [CFTimeInterval] = []
            var fs: [CGFloat] = []
            for i in points.indices where cell.frame.contains(points[i]) {
                let p = points[i]
                pts.append(CGPoint(
                    x: (p.x - cell.frame.minX) / max(cell.frame.width, 1),
                    y: (p.y - cell.frame.minY) / max(cell.frame.height, 1)
                ))
                if i < timestamps.count { ts.append(timestamps[i]) }
                if i < forces.count { fs.append(forces[i]) }
            }
            guard pts.count >= 2 else { continue }
            // Per-cell stroke boundaries aren't tracked separately from
            // the whole-session `strokeStartIndices` (frame-membership
            // filtering doesn't preserve them cleanly) — passed empty,
            // which scores the cell's ink as a single stroke for
            // correspondence purposes. Acceptable here: word/pencil mode
            // isn't the pilot instrument (the pilot practises single
            // letters and never reaches this path); the per-letter
            // single-cell path below carries the real
            // `strokeStartIndices`.
            perCell.append(FreeWriteScorer.score(
                tracedPoints: pts, strokeStartIndices: [], reference: cell.reference,
                timestamps: ts, forces: fs,
                sessionStart: sessionStart, sessionEnd: now))
        }
        guard !perCell.isEmpty else {
            return assess(reference: lastCell.reference,
                          canvasSize: canvasSize,
                          cellFrame: lastCell.frame, now: now)
        }
        let n = CGFloat(perCell.count)
        let avg = WritingAssessment(
            formAccuracy:     perCell.map(\.formAccuracy).reduce(0, +) / n,
            tempoConsistency: perCell.map(\.tempoConsistency).reduce(0, +) / n,
            pressureControl:  perCell.map(\.pressureControl).reduce(0, +) / n,
            rhythmScore:      perCell.map(\.rhythmScore).reduce(0, +) / n
        )
        lastAssessment = avg
        return avg
    }

    /// Score the captured trace against `reference` strokes mapped into
    /// canvas-normalised coordinates. `cellFrame` must be supplied for
    /// multi-cell (pencil) layouts — reference strokes are in cell-local
    /// 0–1 space, so without the frame offset the score collapses to 0.
    @discardableResult
    func assess(reference: LetterStrokes,
                canvasSize: CGSize,
                cellFrame: CGRect? = nil,
                now: CFTimeInterval = CACurrentMediaTime()) -> WritingAssessment {
        let frame = cellFrame ?? CGRect(origin: .zero, size: canvasSize)
        let normalised = points.map { p in
            CGPoint(x: (p.x - frame.minX) / max(frame.width, 1),
                    y: (p.y - frame.minY) / max(frame.height, 1))
        }
        // `score` computes a stroke correspondence internally (for
        // `formAccuracy`) and this line computes one again for
        // `lastStrokeProcess` — the same analysis run twice, not once.
        // Accepted deliberately: `FreeWriteScorer.score` is a general
        // public API (tests and other callers use it standalone, with
        // no separate correspondence step), and re-running an
        // exhaustive search over a handful of strokes once per phase
        // completion costs nothing worth a more complex shared-result
        // API for. "One computation" in the design sense — one
        // MECHANISM produces both the primary and the secondaries —
        // holds; this is two calls to that one mechanism, not two
        // mechanisms.
        let assessment = FreeWriteScorer.score(
            tracedPoints: normalised,
            strokeStartIndices: strokeStartIndices,
            reference: reference,
            timestamps: timestamps,
            forces: forces,
            sessionStart: sessionStart,
            sessionEnd: now
        )
        lastAssessment = assessment
        lastStrokeProcess = StrokeProcessScorer.analyze(
            points: normalised,
            strokeStartIndices: strokeStartIndices,
            reference: reference
        )
        return assessment
    }

    /// Clear every buffer. Called on letter load and on phase
    /// transitions so stale freeWrite state can't bleed across letters.
    func clearAll() {
        points.removeAll(keepingCapacity: true)
        timestamps.removeAll(keepingCapacity: true)
        forces.removeAll(keepingCapacity: true)
        path.removeAll(keepingCapacity: true)
        strokeStartIndices.removeAll(keepingCapacity: true)
        sessionStart = 0
        activePhaseStart = 0
        checkpointsPerSecond = 0
        lastStrokeProcess = nil
        lastAssessment = nil
        lastGuidedScore = nil
    }
}
