import Testing
import CoreGraphics
@testable import PrimaeNative

struct StrokeProcessMeasuresTests {

    // MARK: - Fixtures

    /// An L: vertical leg (stroke 0) then horizontal leg (stroke 1) —
    /// the canonical reference order and direction.
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

    private var verticalLineStrokes: LetterStrokes {
        LetterStrokes(
            letter: "I", checkpointRadius: 0.04,
            strokes: [StrokeDefinition(id: 1, checkpoints: [
                Checkpoint(x: 0.5, y: 0.2), Checkpoint(x: 0.5, y: 0.8),
            ])]
        )
    }

    private func denseLine(from a: CGPoint, to b: CGPoint, count: Int = 11) -> [CGPoint] {
        (0..<count).map { i in
            let t = Double(i) / Double(count - 1)
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
    }

    // MARK: - Single stroke

    @Test("single stroke, forward direction: matches, not reversed")
    func singleStrokeForward() throws {
        let trace = denseLine(from: CGPoint(x: 0.5, y: 0.2), to: CGPoint(x: 0.5, y: 0.8))
        let m = try #require(StrokeProcessScorer.analyze(
            points: trace, strokeStartIndices: [], reference: verticalLineStrokes))
        #expect(m.strokeCount == 1)
        #expect(m.matchedReferenceOrder == [0])
        #expect(m.reversedStrokeCount == 0)
    }

    @Test("single stroke, reversed direction: matches, counted reversed")
    func singleStrokeReversed() throws {
        let trace = denseLine(from: CGPoint(x: 0.5, y: 0.8), to: CGPoint(x: 0.5, y: 0.2))
        let m = try #require(StrokeProcessScorer.analyze(
            points: trace, strokeStartIndices: [], reference: verticalLineStrokes))
        #expect(m.strokeCount == 1)
        #expect(m.matchedReferenceOrder == [0])
        #expect(m.reversedStrokeCount == 1,
                "same points traversed start-to-end backwards must count as reversed")
    }

    // MARK: - Multi-stroke order

    @Test("multi-stroke, reference order: matched order is [0, 1], no leak from spatial deviation")
    func multiStrokeReferenceOrder() throws {
        let vert = denseLine(from: CGPoint(x: 0.4, y: 0.2), to: CGPoint(x: 0.4, y: 0.8))
        let horiz = denseLine(from: CGPoint(x: 0.4, y: 0.8), to: CGPoint(x: 0.8, y: 0.8))
        let trace = vert + horiz
        let m = try #require(StrokeProcessScorer.analyze(
            points: trace, strokeStartIndices: [vert.count], reference: lStrokes))
        #expect(m.strokeCount == 2)
        #expect(m.matchedReferenceOrder == [0, 1],
                "traced vertical-then-horizontal must match reference strokes in the same order")
        #expect(m.reversedStrokeCount == 0)
    }

    @Test("multi-stroke, REVERSED stroke order: matched order is [1, 0]")
    func multiStrokeReversedOrder() throws {
        // Horizontal leg drawn FIRST, vertical leg SECOND — the reverse
        // of the reference's own stroke order. This is exactly the case
        // spatialDeviation (order-invariant) can't see and this measure
        // exists to record instead.
        let horiz = denseLine(from: CGPoint(x: 0.4, y: 0.8), to: CGPoint(x: 0.8, y: 0.8))
        let vert = denseLine(from: CGPoint(x: 0.4, y: 0.2), to: CGPoint(x: 0.4, y: 0.8))
        let trace = horiz + vert
        let m = try #require(StrokeProcessScorer.analyze(
            points: trace, strokeStartIndices: [horiz.count], reference: lStrokes))
        #expect(m.strokeCount == 2)
        #expect(m.matchedReferenceOrder == [1, 0],
                "traced horizontal-then-vertical must record the reference order as reversed")
    }

    @Test("matchedReferenceOrderField comma-joins the raw correspondence")
    func matchedReferenceOrderFieldFormat() throws {
        let horiz = denseLine(from: CGPoint(x: 0.4, y: 0.8), to: CGPoint(x: 0.8, y: 0.8))
        let vert = denseLine(from: CGPoint(x: 0.4, y: 0.2), to: CGPoint(x: 0.4, y: 0.8))
        let trace = horiz + vert
        let m = try #require(StrokeProcessScorer.analyze(
            points: trace, strokeStartIndices: [horiz.count], reference: lStrokes))
        #expect(m.matchedReferenceOrderField == "1,0")
    }

    // MARK: - Edge cases

    @Test("empty trace returns nil")
    func emptyTraceReturnsNil() {
        #expect(StrokeProcessScorer.analyze(
            points: [], strokeStartIndices: [], reference: verticalLineStrokes) == nil)
    }

    @Test("empty reference returns nil")
    func emptyReferenceReturnsNil() {
        let empty = LetterStrokes(letter: "X", checkpointRadius: 0.04, strokes: [])
        let trace = denseLine(from: CGPoint(x: 0.5, y: 0.2), to: CGPoint(x: 0.5, y: 0.8))
        #expect(StrokeProcessScorer.analyze(
            points: trace, strokeStartIndices: [], reference: empty) == nil)
    }

    @Test("a single stray point (no real stroke) returns nil")
    func singleStrayPointReturnsNil() {
        #expect(StrokeProcessScorer.analyze(
            points: [CGPoint(x: 0.5, y: 0.5)], strokeStartIndices: [],
            reference: verticalLineStrokes) == nil)
    }
}
