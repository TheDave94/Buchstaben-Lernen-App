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
    /// Same path normalised to 0–1 over the canvas — used by the KP
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
    /// Last raw discrete-Fréchet distance in reference-normalised
    /// (cell-local 0–1) units, or nil when no assessment has produced a
    /// finite one this session. SECONDARY outcome (2026-09-03: primary
    /// moved to `lastSpatialDeviation` below — Fréchet is sequence-
    /// sensitive, which made it a hybrid of a product measure and a
    /// process one). Retained exactly as it was: neither clamped nor
    /// rescaled, so it keeps discriminating above and below the
    /// `checkpointRadius * 3` band where formAccuracy saturates at 1 / 0.
    /// Lower is better. `PhaseTransitionCoordinator` records it onto the
    /// freeWrite row.
    private(set) var lastFrechetDistance: CGFloat?
    /// Last raw, ORDER-INVARIANT spatial deviation (symmetric Hausdorff)
    /// in the same reference-normalised units as `lastFrechetDistance` —
    /// the study's PRIMARY accuracy outcome (2026-09-03). See
    /// `FreeWriteScorer.rawSpatialDeviation` for why Hausdorff over
    /// Fréchet. Lower is better; nil when no assessment has produced a
    /// finite one this session.
    private(set) var lastSpatialDeviation: CGFloat?
    /// Non-optional mirror of `lastFrechetDistance` for the debug
    /// overlay, which wants a displayable number rather than a
    /// "not measured" state. 0 reads as "perfect" — never record this;
    /// record `lastFrechetDistance`.
    var lastDistance: CGFloat { lastFrechetDistance ?? 0 }
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
        lastFrechetDistance = nil
        lastSpatialDeviation = nil
        lastAssessment = nil
    }

    /// Mark that a new stroke is starting — the next `record(...)`
    /// call kicks off a fresh polyline. Call from the touch dispatcher
    /// at every `beginTouch` while in freeWrite. No-op for the very
    /// first stroke of the session (the implicit index-0 start).
    func beginStroke() {
        guard !points.isEmpty else { return }
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
        var perCellDistance: [CGFloat] = []
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
            perCell.append(FreeWriteScorer.score(
                tracedPoints: pts, reference: cell.reference,
                timestamps: ts, forces: fs,
                sessionStart: sessionStart, sessionEnd: now))
            if let d = Self.measuredDistance(pts, cell.reference) {
                perCellDistance.append(d)
            }
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
        // Word / multi-cell rows carry the mean per-cell Fréchet
        // distance. Averaging is legitimate here because every cell's
        // trace is normalised into its own cell-local 0–1 box, so the
        // per-cell distances share one scale. The pilot practises single
        // letters and never reaches this path.
        lastFrechetDistance = perCellDistance.isEmpty
            ? nil
            : perCellDistance.reduce(0, +) / CGFloat(perCellDistance.count)
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
        let assessment = FreeWriteScorer.score(
            tracedPoints: normalised,
            reference: reference,
            timestamps: timestamps,
            forces: forces,
            sessionStart: sessionStart,
            sessionEnd: now
        )
        lastAssessment = assessment
        lastFrechetDistance = Self.measuredDistance(normalised, reference)
        lastSpatialDeviation = Self.measuredSpatialDeviation(normalised, reference)
        return assessment
    }

    /// Raw discrete-Fréchet distance, or nil when the pair isn't
    /// comparable. `FreeWriteScorer.rawDistance` signals that case with a
    /// `.greatestFiniteMagnitude` sentinel (fewer than two points on
    /// either polyline) — which is `isFinite`, so it would sail into the
    /// export as a real measurement if we only checked finiteness.
    private static func measuredDistance(_ points: [CGPoint],
                                         _ reference: LetterStrokes) -> CGFloat? {
        let d = FreeWriteScorer.rawDistance(tracedPoints: points, reference: reference)
        guard d.isFinite, d < .greatestFiniteMagnitude else { return nil }
        return d
    }

    /// Raw order-invariant spatial deviation, or nil when the pair isn't
    /// comparable — same sentinel discipline as `measuredDistance`, since
    /// `rawSpatialDeviation` signals "not comparable" the same way.
    private static func measuredSpatialDeviation(_ points: [CGPoint],
                                                 _ reference: LetterStrokes) -> CGFloat? {
        let d = FreeWriteScorer.rawSpatialDeviation(tracedPoints: points, reference: reference)
        guard d.isFinite, d < .greatestFiniteMagnitude else { return nil }
        return d
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
        lastFrechetDistance = nil
        lastSpatialDeviation = nil
        lastAssessment = nil
        lastGuidedScore = nil
    }
}
