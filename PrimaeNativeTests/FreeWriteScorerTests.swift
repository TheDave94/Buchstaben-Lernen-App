import Testing
import CoreGraphics
@testable import PrimaeNative

struct FreeWriteScorerTests {

    // MARK: - Fixtures

    private var verticalLineStrokes: LetterStrokes {
        LetterStrokes(
            letter: "I", checkpointRadius: 0.04,
            strokes: [StrokeDefinition(id: 1, checkpoints: [
                Checkpoint(x: 0.5, y: 0.2),  Checkpoint(x: 0.5, y: 0.35),
                Checkpoint(x: 0.5, y: 0.5),  Checkpoint(x: 0.5, y: 0.65),
                Checkpoint(x: 0.5, y: 0.8),
            ])]
        )
    }

    private var lStrokes: LetterStrokes {
        LetterStrokes(
            letter: "L", checkpointRadius: 0.04,
            strokes: [
                StrokeDefinition(id: 1, checkpoints: [
                    Checkpoint(x: 0.4, y: 0.2), Checkpoint(x: 0.4, y: 0.5), Checkpoint(x: 0.4, y: 0.8),
                ]),
                StrokeDefinition(id: 2, checkpoints: [
                    Checkpoint(x: 0.4, y: 0.8), Checkpoint(x: 0.6, y: 0.8), Checkpoint(x: 0.8, y: 0.8),
                ]),
            ]
        )
    }

    // MARK: - Scoring

    // (2026-09-03, superseded 2026-09-04 by stroke correspondence — see
    // StrokeProcessMeasures) formAccuracy switched from whole-path
    // Fréchet to whole-trace Hausdorff, whose one-sided components are
    // independently density-sensitive. The old 5-point fixture matched
    // Fréchet's own internal resampling but is sparser than real touch
    // sampling (60-120 Hz); CI caught it. Densified to match what a real
    // touch trace actually looks like, not to dodge the finding — kept
    // densified under the current design too, for the same reason.
    @Test("Perfect trace scores above 0.9")
    func perfectTrace() {
        let traced = (0...60).map { CGPoint(x: 0.5, y: 0.2 + 0.6 * Double($0) / 60) }
        let assessment = FreeWriteScorer.score(tracedPoints: traced, reference: verticalLineStrokes)
        #expect(assessment.formAccuracy > 0.9)
    }

    @Test("Near-perfect trace scores above 0.8")
    func nearPerfectTrace() {
        let traced = (0...60).map { i -> CGPoint in
            let t = Double(i) / 60
            // Small alternating jitter around x = 0.5, same shape the
            // original 5-point fixture used, just densified.
            let jitter = (i % 2 == 0) ? 0.01 : -0.01
            return CGPoint(x: 0.5 + jitter, y: 0.2 + 0.6 * t)
        }
        let assessment = FreeWriteScorer.score(tracedPoints: traced, reference: verticalLineStrokes)
        #expect(assessment.formAccuracy > 0.8)
    }

    @Test("Completely off-path scores below 0.3")
    func offPath() {
        let traced: [CGPoint] = [
            CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.15, y: 0.15),
            CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.1, y: 0.3),
            CGPoint(x: 0.05, y: 0.1),
        ]
        let assessment = FreeWriteScorer.score(tracedPoints: traced, reference: verticalLineStrokes)
        #expect(assessment.formAccuracy < 0.3)
    }

    // (2026-09-03) formAccuracy is now order-invariant (Hausdorff, not
    // Fréchet) — this used to assert the OPPOSITE of what's below: that a
    // reversed trace scored below 0.5. That was the exact defect the
    // primary-outcome change fixes: a spatially perfect letter written in
    // an unusual stroke order should not cost Form accuracy, because
    // direction/sequence is a process property, not a product one.
    @Test("Reversed trace does NOT penalise formAccuracy — order-invariant by design")
    func reversedTraceDoesNotPenaliseFormAccuracy() {
        let forward = (0...60).map { CGPoint(x: 0.5, y: 0.2 + 0.6 * Double($0) / 60) }
        let reversed = forward.reversed().map { $0 }
        let s1 = FreeWriteScorer.score(tracedPoints: forward, reference: verticalLineStrokes).formAccuracy
        let s2 = FreeWriteScorer.score(tracedPoints: reversed, reference: verticalLineStrokes).formAccuracy
        #expect(abs(s1 - s2) < 1e-6,
                "formAccuracy must be order-invariant; forward=\(s1) reversed=\(s2)")
        #expect(s2 > 0.9, "a reversed but spatially perfect trace must still score high")
    }

    // (2026-09-04) The reversal-penalises-distance property this test
    // used to check (via the now-removed whole-path `rawDistance`) no
    // longer exists BY DESIGN: reversal is handled in the stroke
    // pairing (orientation is chosen to minimise cost), not left to
    // inflate a distance. The process signal it used to approximate is
    // `StrokeProcessMeasures.reversedStrokeCount` now — see
    // `StrokeProcessMeasuresTests.singleStrokeReversed`.

    @Test("Multi-stroke L-shape scores well")
    func multiStroke() {
        // Densified for the same reason perfectTrace was — see the note
        // above reversedTraceDoesNotPenaliseFormAccuracy. strokeStartIndices
        // marks the L's pen-lift so stroke correspondence can match each
        // leg to its own reference stroke rather than treating the whole
        // L as one continuous stroke.
        let vertical = (0...30).map { CGPoint(x: 0.4, y: 0.2 + 0.6 * Double($0) / 30) }
        let horizontal = (0...30).map { CGPoint(x: 0.4 + 0.4 * Double($0) / 30, y: 0.8) }
        let traced = vertical + horizontal
        let assessment = FreeWriteScorer.score(
            tracedPoints: traced, strokeStartIndices: [vertical.count], reference: lStrokes)
        #expect(assessment.formAccuracy > 0.7)
    }

    // MARK: - Edge cases

    @Test("Empty input returns zero",
          arguments: [
            ([] as [CGPoint], true),
            ([CGPoint(x: 0.5, y: 0.5)], true),
          ])
    func emptyOrSingleInput(points: [CGPoint], expectZero: Bool) {
        let assessment = FreeWriteScorer.score(tracedPoints: points, reference: verticalLineStrokes)
        if expectZero { #expect(assessment.formAccuracy == 0) }
    }

    @Test("Empty reference returns zero")
    func emptyReference() {
        let empty = LetterStrokes(letter: "X", checkpointRadius: 0.04, strokes: [])
        let traced = [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.5, y: 0.6)]
        #expect(FreeWriteScorer.score(tracedPoints: traced, reference: empty).formAccuracy == 0)
    }

    @Test("Zero radius returns zero")
    func zeroRadius() {
        let strokes = LetterStrokes(
            letter: "I", checkpointRadius: 0,
            strokes: [StrokeDefinition(id: 1, checkpoints: [
                Checkpoint(x: 0.5, y: 0.2), Checkpoint(x: 0.5, y: 0.8),
            ])]
        )
        let traced = [CGPoint(x: 0.5, y: 0.2), CGPoint(x: 0.5, y: 0.8)]
        #expect(FreeWriteScorer.score(tracedPoints: traced, reference: strokes).formAccuracy == 0)
    }

    // MARK: - formAccuracyShape

    /// `formAccuracyShape` is the freeform-mode scorer (blank canvas:
    /// stroke order, pen-lift count, absolute position all irrelevant).
    /// The order-free Hausdorff guarantee is the meaningful contract.
    @Test("formAccuracyShape: identical trace and reference scores high")
    func formAccuracyShapeIdentical() {
        let strokes = LetterStrokes(letter: "I", checkpointRadius: 0.05, strokes: [
            StrokeDefinition(id: 1, checkpoints: [
                Checkpoint(x: 0.5, y: 0.2), Checkpoint(x: 0.5, y: 0.8)
            ])
        ])
        let traced = (0...20).map { CGPoint(x: 0.5, y: 0.2 + 0.6 * Double($0) / 20) }
        #expect(FreeWriteScorer.formAccuracyShape(tracedPoints: traced, reference: strokes) > 0.85)
    }

    @Test("formAccuracyShape: scribble far from reference scores near zero")
    func formAccuracyShapeScribble() {
        let strokes = LetterStrokes(letter: "I", checkpointRadius: 0.05, strokes: [
            StrokeDefinition(id: 1, checkpoints: [
                Checkpoint(x: 0.5, y: 0.2), Checkpoint(x: 0.5, y: 0.8)
            ])
        ])
        // Random clump in upper-left corner with no relation to the I.
        let traced = (0...20).map { i -> CGPoint in
            let t = Double(i) / 20
            return CGPoint(x: 0.05 + 0.05 * t, y: 0.05 + 0.05 * sin(t * 6))
        }
        #expect(FreeWriteScorer.formAccuracyShape(tracedPoints: traced, reference: strokes) < 0.5)
    }

    @Test("formAccuracyShape: order-free — reversed trace scores the same")
    func formAccuracyShapeOrderFree() {
        let strokes = LetterStrokes(letter: "I", checkpointRadius: 0.05, strokes: [
            StrokeDefinition(id: 1, checkpoints: [
                Checkpoint(x: 0.5, y: 0.2), Checkpoint(x: 0.5, y: 0.8)
            ])
        ])
        let forward = (0...20).map { CGPoint(x: 0.5, y: 0.2 + 0.6 * Double($0) / 20) }
        let reversed = forward.reversed().map { $0 }
        let s1 = FreeWriteScorer.formAccuracyShape(tracedPoints: forward, reference: strokes)
        let s2 = FreeWriteScorer.formAccuracyShape(tracedPoints: reversed, reference: strokes)
        #expect(abs(s1 - s2) < 1e-6, "Hausdorff is order-free; reversed trace must score identically")
    }

    @Test("formAccuracyShape: empty inputs return zero")
    func formAccuracyShapeEmpty() {
        let strokes = LetterStrokes(letter: "I", checkpointRadius: 0.05, strokes: [
            StrokeDefinition(id: 1, checkpoints: [
                Checkpoint(x: 0.5, y: 0.2), Checkpoint(x: 0.5, y: 0.8)
            ])
        ])
        #expect(FreeWriteScorer.formAccuracyShape(tracedPoints: [], reference: strokes) == 0)
        let emptyRef = LetterStrokes(letter: "X", checkpointRadius: 0.04, strokes: [])
        let traced = [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.5, y: 0.6)]
        #expect(FreeWriteScorer.formAccuracyShape(tracedPoints: traced, reference: emptyRef) == 0)
    }

    // (2026-09-04) The former "Spatial deviation (order-invariant
    // PRIMARY outcome)" section tested `rawSpatialDeviation`, which is
    // retired — the primary outcome is now
    // `StrokeProcessMeasures.spatialDeviation` via stroke
    // correspondence. Equivalent coverage (identical/off-path/order-
    // free/multi-stroke/empty-input) now lives in
    // `StrokeProcessMeasuresTests.swift`, on the type that actually
    // computes it.

    // MARK: - Fréchet distance

    @Test("Identical curves have zero Fréchet distance")
    func frechetIdentical() {
        let p = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 2, y: 0)]
        #expect(FreeWriteScorer.discreteFrechetDistance(p, p) < 1e-10)
    }

    @Test("Parallel lines have distance equal to offset")
    func frechetParallel() {
        let p = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0)]
        let q = [CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)]
        #expect(abs(FreeWriteScorer.discreteFrechetDistance(p, q) - 1.0) < 1e-10)
    }

    @Test("Single points: distance is Euclidean")
    func frechetSinglePoints() {
        let p = [CGPoint(x: 0, y: 0)]
        let q = [CGPoint(x: 3, y: 4)]
        #expect(abs(FreeWriteScorer.discreteFrechetDistance(p, q) - 5.0) < 1e-10)
    }

    // MARK: - Resampling

    @Test("Resample preserves endpoints")
    func resampleEndpoints() {
        let input = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 2, y: 0)]
        let resampled = FreeWriteScorer.resample(input, targetCount: 5)
        #expect(resampled.count == 5)
        #expect(abs(resampled.first!.x) < 1e-10)
        #expect(abs(resampled.last!.x - 2.0) < 1e-10)
    }

    @Test("Resample midpoint is correct")
    func resampleMidpoint() {
        let input = [CGPoint(x: 0, y: 0), CGPoint(x: 4, y: 0)]
        let resampled = FreeWriteScorer.resample(input, targetCount: 3)
        #expect(resampled.count == 3)
        #expect(abs(resampled[1].x - 2.0) < 1e-10)
    }

    // MARK: - Symmetry (Eiter & Mannila 1994 — discrete Fréchet is symmetric)

    @Test("Discrete Fréchet distance is symmetric")
    func frechetSymmetric() {
        let p: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 0)]
        let q: [CGPoint] = [CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 0),
                            CGPoint(x: 2, y: 1), CGPoint(x: 3, y: 0)]
        let d1 = FreeWriteScorer.discreteFrechetDistance(p, q)
        let d2 = FreeWriteScorer.discreteFrechetDistance(q, p)
        #expect(abs(d1 - d2) < 1e-10,
                "discreteFrechetDistance(p,q) = \(d1) but (q,p) = \(d2) — must be symmetric")
    }

    @Test("Identical curves produce zero distance")
    func frechetZeroForIdentical() {
        let p: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 2, y: 0)]
        #expect(FreeWriteScorer.discreteFrechetDistance(p, p) == 0)
    }

    @Test("Single-point curves produce Euclidean distance")
    func frechetSinglePoint() {
        let a: [CGPoint] = [CGPoint(x: 0, y: 0)]
        let b: [CGPoint] = [CGPoint(x: 3, y: 4)]
        let d = FreeWriteScorer.discreteFrechetDistance(a, b)
        #expect(abs(d - 5.0) < 1e-10,
                "Single-point discrete Fréchet should equal Euclidean (3-4-5), got \(d)")
    }

    // MARK: - resample corner cases (2026-09-05)

    @Test("resample honours targetCount for a single point, for targetCount 1, and for a zero-length polyline")
    func resampleCornerCases() {
        let one = [CGPoint(x: 0.3, y: 0.3)]
        #expect(FreeWriteScorer.resample(one, targetCount: 8).count == 8, "a single point is replicated to the requested density")
        let line = (0..<20).map { CGPoint(x: CGFloat($0) / 19, y: 0.5) }
        #expect(FreeWriteScorer.resample(line, targetCount: 1).count == 1)
        let still = Array(repeating: CGPoint(x: 0.2, y: 0.2), count: 5)
        let r = FreeWriteScorer.resample(still, targetCount: 6)
        #expect(r.count == 6 && r.allSatisfy { $0 == CGPoint(x: 0.2, y: 0.2) })
    }

}
