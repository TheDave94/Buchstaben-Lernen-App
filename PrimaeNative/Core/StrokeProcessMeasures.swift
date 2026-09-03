// StrokeProcessMeasures.swift
// PrimaeNative
//
// SECONDARY, process-level outcomes (2026-09-03): stroke count, stroke
// order, and stroke direction — reported separately from the primary
// spatial-deviation outcome, per the product/process split the
// handwriting literature draws (product: form, legibility — process:
// stroke count, order, direction). Derived entirely from data already
// persisted (RawTrace's points + strokeStartIndices), so prior sessions
// remain re-derivable — the same reasoning the primary outcome's own
// change relies on. See FreeWriteScorer.rawSpatialDeviation for that
// context.

import CoreGraphics
import Foundation

/// One session's stroke-level process measures against a reference.
struct StrokeProcessMeasures: Equatable {
    /// Number of strokes the child actually drew (pen-lift count + 1).
    /// The reference's own expected count is `reference.strokes.count`
    /// — a per-letter constant already in the bundle, not duplicated
    /// into every row (the same reasoning `checkpointRadius` isn't).
    let strokeCount: Int
    /// For each traced stroke, in TRACE order, the index of its
    /// best-matching reference stroke (nearest by symmetric Hausdorff,
    /// reusing the same distance FreeWriteScorer.rawSpatialDeviation
    /// uses). Recorded as the raw correspondence rather than a single
    /// order-conformance scalar deliberately: inversions, Kendall's tau,
    /// or exact-match can all be computed from this later, and
    /// pre-committing to one would discard information the thesis
    /// analysis might want differently.
    let matchedReferenceOrder: [Int]
    /// Of the matched strokes, how many were traced in the reverse
    /// direction relative to the reference stroke's own checkpoint order
    /// (start-to-end vs end-to-start) — see `analyze` for how direction
    /// is decided.
    let reversedStrokeCount: Int

    /// Comma-joined `matchedReferenceOrder` for CSV/JSON export — same
    /// convention `TrainedLetterSubset`'s CSV column uses for a small
    /// ordered set.
    var matchedReferenceOrderField: String {
        matchedReferenceOrder.map(String.init).joined(separator: ",")
    }
}

enum StrokeProcessScorer {
    /// Splits `points` into per-stroke segments, matches each traced
    /// stroke to its nearest reference stroke, and reports count/order/
    /// direction. `points` must already be normalised into the
    /// reference's coordinate space — the same convention
    /// `FreeWriteScorer.rawSpatialDeviation` uses (NOT unit-box
    /// normalised: position and scale are meaningful here). `nil` when
    /// there's nothing comparable, matching `rawSpatialDeviation`'s own
    /// "not comparable" cases rather than reporting a misleading zero.
    static func analyze(
        points: [CGPoint],
        strokeStartIndices: [Int],
        reference: LetterStrokes
    ) -> StrokeProcessMeasures? {
        guard !points.isEmpty, !reference.strokes.isEmpty else { return nil }

        let traceStrokes = splitStrokes(points: points, strokeStartIndices: strokeStartIndices)
            .filter { $0.count >= 2 }
        guard !traceStrokes.isEmpty else { return nil }

        let refStrokesDense = FreeWriteScorer.densifyReferenceStrokesPerStroke(reference)
        guard refStrokesDense.contains(where: { $0.count >= 2 }) else { return nil }

        var matched: [Int] = []
        var reversedCount = 0

        for traceStroke in traceStrokes {
            // Nearest reference stroke by symmetric Hausdorff distance —
            // the same measure, and the same reason (order/position
            // independence within the comparison), rawSpatialDeviation
            // uses for the whole trace.
            var bestIdx: Int?
            var bestDistance = CGFloat.greatestFiniteMagnitude
            for (idx, refStroke) in refStrokesDense.enumerated() {
                guard refStroke.count >= 2 else { continue }
                let d1 = FreeWriteScorer.oneSidedHausdorff(traceStroke, refStroke)
                let d2 = FreeWriteScorer.oneSidedHausdorff(refStroke, traceStroke)
                let d = max(d1, d2)
                if d < bestDistance {
                    bestDistance = d
                    bestIdx = idx
                }
            }
            guard let bestIdx else { continue }
            matched.append(bestIdx)

            // Direction: compare the (trace-start→ref-start) +
            // (trace-end→ref-end) pairing against the swapped one;
            // whichever pairing costs less decides forward vs reversed.
            // This is endpoint-based, not a full-path direction measure
            // — deliberately simple and explainable, matching the level
            // of rigor the other process measures (a raw correspondence
            // list, a count) use rather than a heavier curve-direction
            // statistic.
            let refStroke = refStrokesDense[bestIdx]
            guard let traceStart = traceStroke.first, let traceEnd = traceStroke.last,
                  let refStart = refStroke.first, let refEnd = refStroke.last else { continue }
            let forwardCost = FreeWriteScorer.dist(traceStart, refStart)
                + FreeWriteScorer.dist(traceEnd, refEnd)
            let reversedCost = FreeWriteScorer.dist(traceStart, refEnd)
                + FreeWriteScorer.dist(traceEnd, refStart)
            if reversedCost < forwardCost {
                reversedCount += 1
            }
        }

        return StrokeProcessMeasures(
            strokeCount: traceStrokes.count,
            matchedReferenceOrder: matched,
            reversedStrokeCount: reversedCount
        )
    }

    /// Split a flat point array into per-stroke segments. Same
    /// `strokeStartIndices` convention `LetterRecognizer`'s rasteriser
    /// already uses (`[0] + strokeStartIndices.filter { $0 > 0 && $0 <
    /// points.count }`, sorted) — matched deliberately rather than
    /// re-derived, so a change to one doesn't silently diverge from the
    /// other.
    private static func splitStrokes(points: [CGPoint], strokeStartIndices: [Int]) -> [[CGPoint]] {
        guard !points.isEmpty else { return [] }
        let breaks = ([0] + strokeStartIndices.filter { $0 > 0 && $0 < points.count }).sorted()
        var result: [[CGPoint]] = []
        for (b, breakIdx) in breaks.enumerated() {
            let endIdx = (b + 1 < breaks.count) ? breaks[b + 1] : points.count
            guard breakIdx < endIdx else { continue }
            result.append(Array(points[breakIdx..<endIdx]))
        }
        return result
    }
}
