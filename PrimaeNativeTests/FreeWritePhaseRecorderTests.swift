// Coverage for the recorder that owns the freeWrite phase's four
// buffers (points / timestamps / forces / normalised path) plus the
// session-timing state that drives checkpointsPerSecond and rhythmScore.
// Buffer lifecycle is load-bearing — a leak between letters would
// corrupt the next freeWrite assessment.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@Suite @MainActor struct FreeWritePhaseRecorderTests {

    @Test func initialState_allBuffersEmpty() {
        let r = FreeWritePhaseRecorder()
        #expect(r.points.isEmpty)
        #expect(r.timestamps.isEmpty)
        #expect(r.forces.isEmpty)
        #expect(r.path.isEmpty)
        #expect(r.sessionStart == 0)
        #expect(r.activePhaseStart == 0)
        #expect(r.checkpointsPerSecond == 0)
        #expect(r.lastSpatialDeviation == nil)
        #expect(r.lastAssessment == nil)
        #expect(r.lastGuidedScore == nil)
    }

    @Test func startSession_resetsBuffers_andStampsClocks() {
        let r = FreeWritePhaseRecorder()
        r.record(point: .init(x: 10, y: 20), timestamp: 1, force: 0.5,
                 canvasSize: .init(width: 100, height: 100))
        #expect(r.points.count == 1)

        r.startSession(now: 42.0)
        #expect(r.points.isEmpty)
        #expect(r.timestamps.isEmpty)
        #expect(r.forces.isEmpty)
        #expect(r.path.isEmpty)
        #expect(r.sessionStart == 42.0)
        #expect(r.activePhaseStart == 42.0)
        #expect(r.checkpointsPerSecond == 0)
        #expect(r.lastSpatialDeviation == nil)
        #expect(r.lastAssessment == nil)
    }

    @Test func record_appendsToAllParallelBuffers() {
        let r = FreeWritePhaseRecorder()
        r.startSession(now: 0)
        r.record(point: .init(x: 50, y: 25), timestamp: 1, force: 0.7,
                 canvasSize: .init(width: 100, height: 50))
        r.record(point: .init(x: 0, y: 0), timestamp: 2, force: 0,
                 canvasSize: .init(width: 100, height: 50))

        #expect(r.points == [CGPoint(x: 50, y: 25), CGPoint(x: 0, y: 0)])
        #expect(r.timestamps == [1, 2])
        #expect(r.forces == [0.7, 0])
        // path is canvas-normalised: 50/100 = 0.5, 25/50 = 0.5
        #expect(r.path[0].x == 0.5)
        #expect(r.path[0].y == 0.5)
        #expect(r.path[1].x == 0)
        #expect(r.path[1].y == 0)
    }

    @Test func record_zeroSizedCanvas_doesNotDivideByZero() {
        // The recorder uses max(canvasSize.{width,height}, 1) before
        // dividing — pin the contract so a zero-sized canvas (briefly
        // possible during view setup) never propagates a NaN into the
        // KP overlay.
        let r = FreeWritePhaseRecorder()
        r.startSession(now: 0)
        r.record(point: .init(x: 5, y: 5), timestamp: 0, force: 0,
                 canvasSize: .zero)
        #expect(r.path[0].x == 5)
        #expect(r.path[0].y == 5)
        #expect(r.path[0].x.isFinite)
        #expect(r.path[0].y.isFinite)
    }

    @Test func updateSpeed_computesCheckpointsPerSecond() {
        let r = FreeWritePhaseRecorder()
        r.startSession(now: 100)
        r.updateSpeed(completedCheckpoints: 8, now: 102)
        // 8 checkpoints in 2 s → 4 per second.
        #expect(abs(r.checkpointsPerSecond - 4) < 1e-9)
    }

    @Test func updateSpeed_withTinyElapsed_isIgnored() {
        // Sub-100ms elapsed throws away the live-rate display rather
        // than dividing by ~0 and surfacing a wildly inflated number.
        let r = FreeWritePhaseRecorder()
        r.startSession(now: 100)
        r.updateSpeed(completedCheckpoints: 5, now: 100.05)
        #expect(r.checkpointsPerSecond == 0)
    }

    @Test func updateSpeed_beforeSessionStart_isIgnored() {
        let r = FreeWritePhaseRecorder()
        // No startSession — activePhaseStart is 0.
        r.updateSpeed(completedCheckpoints: 10, now: 5)
        #expect(r.checkpointsPerSecond == 0)
    }

    @Test func startGuidedSpeedTracking_resetsTimingButPreservesBuffers() {
        let r = FreeWritePhaseRecorder()
        r.startSession(now: 100)
        r.record(point: .init(x: 1, y: 1), timestamp: 100.5, force: 0.5,
                 canvasSize: .init(width: 10, height: 10))
        let pointsBefore = r.points
        let pathBefore   = r.path

        r.startGuidedSpeedTracking(now: 200)
        // Buffers preserved …
        #expect(r.points == pointsBefore)
        #expect(r.path == pathBefore)
        // … but the speed-tracking window is rebased.
        #expect(r.activePhaseStart == 200)
        #expect(r.checkpointsPerSecond == 0)
        // sessionStart is untouched (kept at 100).
        #expect(r.sessionStart == 100)
    }

    // MARK: - Multi-cell scoring

    /// `assess(cellReferences:)` splits a freeWrite trace by cell frame
    /// and averages per-letter scores. The empty-cell-list fallback
    /// returns a zero assessment without crashing or recursing into the
    /// single-cell overload.
    @Test func assess_multiCell_emptyReferencesReturnsZero() {
        let r = FreeWritePhaseRecorder()
        r.startSession(now: 100)
        let result = r.assess(cellReferences: [],
                              canvasSize: .init(width: 100, height: 100),
                              now: 101)
        #expect(result.formAccuracy == 0)
        #expect(result.tempoConsistency == 0)
        #expect(result.pressureControl == 0)
        #expect(result.rhythmScore == 0)
        #expect(r.lastAssessment == result)
    }

    /// A point that doesn't fall inside any provided cell frame should
    /// be filtered out — the per-cell loop only collects samples whose
    /// x/y land inside `cell.frame.contains(...)`.
    @Test func assess_multiCell_filtersPointsByCellFrame() {
        let r = FreeWritePhaseRecorder()
        r.startSession(now: 100)
        // Two cells side-by-side in canvas-pixel space.
        let cellLeft  = CGRect(x: 0,   y: 0, width: 100, height: 100)
        let cellRight = CGRect(x: 100, y: 0, width: 100, height: 100)
        // 10 points in the left cell, 10 in the right cell, 1 outside.
        for i in 0..<10 {
            r.record(point: .init(x: 10 + Double(i) * 5, y: 50),
                     timestamp: 100 + Double(i) * 0.05, force: 0,
                     canvasSize: .init(width: 200, height: 100))
        }
        for i in 0..<10 {
            r.record(point: .init(x: 110 + Double(i) * 5, y: 50),
                     timestamp: 101 + Double(i) * 0.05, force: 0,
                     canvasSize: .init(width: 200, height: 100))
        }
        // Outlier outside both cells (negative y) — should be filtered.
        r.record(point: .init(x: -50, y: -50),
                 timestamp: 102, force: 0,
                 canvasSize: .init(width: 200, height: 100))

        let stroke = StrokeDefinition(id: 1, checkpoints: [
            .init(x: 0.1, y: 0.5), .init(x: 0.9, y: 0.5)
        ])
        let strokes = LetterStrokes(letter: "I", checkpointRadius: 0.05,
                                     strokes: [stroke])
        let result = r.assess(
            cellReferences: [(cellLeft, strokes), (cellRight, strokes)],
            canvasSize: .init(width: 200, height: 100),
            now: 103
        )
        // Both cells produced valid sub-traces; result is the average
        // of two non-zero per-cell assessments. We don't assert exact
        // numerics — the contract is: doesn't crash, returns a
        // populated WritingAssessment, and stores it on `lastAssessment`.
        #expect(r.lastAssessment != nil)
        #expect(result.formAccuracy >= 0 && result.formAccuracy <= 1)
        #expect(result.rhythmScore >= 0 && result.rhythmScore <= 1)
    }

    @Test func clearAll_emptiesEverythingIncludingGuidedScore() {
        let r = FreeWritePhaseRecorder()
        r.startSession(now: 100)
        r.record(point: .init(x: 1, y: 1), timestamp: 100, force: 0.5,
                 canvasSize: .init(width: 10, height: 10))
        r.lastGuidedScore = 0.75
        r.updateSpeed(completedCheckpoints: 4, now: 102)

        r.clearAll()

        #expect(r.points.isEmpty)
        #expect(r.timestamps.isEmpty)
        #expect(r.forces.isEmpty)
        #expect(r.path.isEmpty)
        #expect(r.sessionStart == 0)
        #expect(r.activePhaseStart == 0)
        #expect(r.checkpointsPerSecond == 0)
        #expect(r.lastSpatialDeviation == nil)
        #expect(r.lastAssessment == nil)
        #expect(r.lastGuidedScore == nil)
    }
}
