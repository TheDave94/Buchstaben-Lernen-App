// StrokeProcessMeasures.swift
// PrimaeNative
//
// THE PRIMARY accuracy outcome AND the process-level secondaries
// (stroke count, order, direction), from ONE computation (2026-09-04,
// superseding the 2026-09-03 Hausdorff-over-the-whole-trace design).
//
// WHY NOT SHAPE NORMALISATION (Procrustes rejected): scale and rotation
// are already controlled by this task's design — a fixed reference and
// a defined canvas — so normalising them buys nothing, and rotation-
// invariance is actively wrong: a letter drawn upside down is an
// error, not a nuisance parameter to fit away. The defect the
// 2026-09-03 redesign was chasing was never a shape-normalisation
// problem. Hausdorff over the whole trace was order-invariant at the
// POINT-CLOUD level, but it still let a spatially perfect letter with
// strokes in an unusual order score as well as the canonical order —
// no, wait, that's what it FIXED — the residual problem was subtler:
// neither Hausdorff-over-the-cloud nor Fréchet-over-the-concatenated-
// path ever asked "which of MY strokes corresponds to which of THE
// REFERENCE'S strokes" — one discarded stroke identity entirely, the
// other assumed trace-order == reference-order. Both are shape
// analyses; the actual invariance this study needs is stroke
// CORRESPONDENCE.
//
// THE APPROACH: match each traced stroke to its best-fitting reference
// stroke — order-invariant, because the matching decides pairing, not
// arrival order — then measure deviation WITHIN each matched pair.
// Fréchet distance (Eiter & Mannila 1994) is exactly right for that
// within-pair measurement (it stays a sequence-sensitive, single-curve
// distance); what changes is that it is never applied to a
// concatenation of strokes the reference and the child may have
// visited in different orders. The mean of the matched pairs' own
// Fréchet distances IS the order-invariant PRIMARY outcome
// (`spatialDeviation`). The recovered pairing IS the process
// secondaries: `matchedReferenceOrder` is the stroke-order measurement,
// and a stroke-COUNT mismatch (more or fewer traced strokes than the
// reference has) is the stroke-count measurement — nothing bolted on
// separately.
//
// DIRECTION REVERSAL is handled IN the pairing, not normalised away:
// for each candidate (traced stroke, reference stroke) pair, BOTH
// traversal directions are tried and the cheaper one wins — a reversed
// stroke is a process finding worth recording (`reversedStrokeCount`),
// not noise to erase from the distance.
//
// LITERATURE GROUNDING (searched 2026-09-04, per instruction: search
// handwriting-recognition / letter-formation-scoring, not morphometrics
// — Procrustes belongs to the latter and doesn't treat this problem):
// "stroke correspondence search" is the established term for exactly
// this — matching a stroke-order-free / stroke-number-free input
// against a reference character. Five representative correspondence-
// search methods are surveyed in the online-handwriting-recognition
// literature (cube search, bipartite weighted matching, individual
// correspondence decision, stable marriage, deviation-expansion) —
// Kaneko & Chen et al.'s stroke-order-free/stroke-number-free method
// (USPTO 5,796,867) and the comparative survey "Comparative performance
// analysis of stroke correspondence search methods for stroke-order
// free online multi-stroke character recognition" (Front. Comput. Sci.,
// Springer) name this exact problem. Bipartite weighted matching is the
// Hungarian (Kuhn–Munkres) assignment algorithm; unequal stroke counts
// are the linear sum assignment problem with error-correction (LSAPE)
// — insertions/deletions carry an explicit cost against a "do not
// match" option.
//
// SIMPLIFIED DELIBERATELY from that general framework, for this
// domain: bundled Latin letters have at most a handful of strokes, so
// (a) EXHAUSTIVE search over the small assignment space replaces the
// Hungarian algorithm — same optimum, no new dependency, and this runs
// once per phase completion, never per frame; (b) rather than LSAPE's
// tunable null-match cost (which would need calibration evidence this
// domain doesn't have), matching is FORCED to maximum cardinality —
// exactly `min(tracedCount, referenceCount)` pairs, always the
// cheapest such assignment. A traced stroke's "extra" or "missing"
// status therefore falls out of the COUNT difference alone (already
// exactly what `strokeCount` reports against the reference's own
// per-letter stroke count), not from a per-pair cost threshold this
// domain has no evidence to set correctly.
//
// Derived entirely from data already persisted (RawTrace's points +
// strokeStartIndices), so prior sessions remain re-derivable.

import CoreGraphics
import Foundation

/// One session's stroke-level measures against a reference: the
/// order-invariant PRIMARY spatial-deviation outcome, plus the process
/// secondaries recovered from the same stroke correspondence.
struct StrokeProcessMeasures: Equatable {
    /// PRIMARY, order-invariant accuracy outcome: the mean, over the
    /// matched stroke pairs, of each pair's own (direction-minimised)
    /// discrete Fréchet distance — in the same reference-normalised
    /// coordinate space `PhaseSessionRecord.spatialDeviation` has always
    /// used. Unmatched (extra/missing) strokes do NOT enter this
    /// average — their signal is `strokeCount`, not a distance penalty;
    /// see the file header.
    let spatialDeviation: CGFloat
    /// Number of strokes the child actually drew (pen-lift count + 1),
    /// one-sample taps included; `matchedReferenceOrder` has exactly this
    /// many entries, in trace order.
    /// The reference's own expected count is `reference.strokes.count`
    /// — a per-letter constant already in the bundle, not duplicated
    /// into every row.
    let strokeCount: Int
    /// For each traced stroke, IN TRACE ORDER, the index of its matched
    /// reference stroke, or `nil` when this traced stroke went unmatched
    /// (only possible when the child drew MORE strokes than the
    /// reference has — see the file header's "forced maximum
    /// cardinality" note). Recorded as the raw correspondence rather
    /// than a single order-conformance scalar deliberately: inversions,
    /// Kendall's tau, or exact-match can all be computed from this
    /// later, and pre-committing to one would discard information the
    /// thesis analysis might want differently.
    let matchedReferenceOrder: [Int?]
    /// Of the matched strokes, how many were traced in the reverse
    /// direction relative to the reference stroke's own checkpoint
    /// order — decided AS PART of the same cost search that chose the
    /// pairing (whichever direction gave the lower Fréchet distance for
    /// that specific matched pair), not a separate endpoint-distance
    /// heuristic pass.
    let reversedStrokeCount: Int

    /// Comma-joined `matchedReferenceOrder` for CSV/JSON export — "-"
    /// for an unmatched (extra) traced stroke, same convention
    /// `TrainedLetterSubset`'s CSV column uses for a small ordered set.
    var matchedReferenceOrderField: String {
        matchedReferenceOrder.map { $0.map(String.init) ?? "-" }.joined(separator: ",")
    }
}

enum StrokeProcessScorer {
    /// Splits `points` into per-stroke segments, finds the minimum-cost
    /// stroke correspondence against the reference's own strokes (both
    /// traversal directions considered per candidate pair), and reports
    /// the order-invariant primary distance plus count/order/direction.
    /// `points` must already be normalised into the reference's
    /// coordinate space — the same convention the rest of this scoring
    /// path uses (NOT unit-box normalised: position and scale are
    /// meaningful here, per the file header's rejection of shape
    /// normalisation). `nil` when there's nothing comparable.
    static func analyze(
        points: [CGPoint],
        strokeStartIndices: [Int],
        reference: LetterStrokes
    ) -> StrokeProcessMeasures? {
        guard !points.isEmpty, !reference.strokes.isEmpty else { return nil }

        // Positional, without matching what cannot be matched (2026-09-05):
        // every traced stroke has an entry in `matchedReferenceOrder` (a
        // one-sample tap gets nil at ITS position) and every reference
        // index is into `reference.strokes` as authored; the assignment
        // itself runs over the strokes with >= 2 points on both sides. A
        // trace with no such stroke is not a production and returns nil.
        // Known limit: a one-checkpoint reference dot (i, j, umlauts) is
        // never matched, so a dot's placement does not enter the distance.
        let allTraceStrokes = splitStrokes(points: points, strokeStartIndices: strokeStartIndices)
        let allRefStrokes = FreeWriteScorer.densifyReferenceStrokesPerStroke(reference)
        let eligibleTrace = allTraceStrokes.indices.filter { allTraceStrokes[$0].count >= 2 }
        let eligibleRef = allRefStrokes.indices.filter { allRefStrokes[$0].count >= 2 }
        guard !eligibleTrace.isEmpty, !eligibleRef.isEmpty else { return nil }
        let traceStrokes = eligibleTrace.map { allTraceStrokes[$0] }
        let refStrokes = eligibleRef.map { allRefStrokes[$0] }

        let traceCount = traceStrokes.count
        let refCount = refStrokes.count

        // Cost[i][j]: the cheaper of forward/reversed discrete Fréchet
        // distance between traced stroke i and reference stroke j, with
        // the traced stroke resampled to that reference stroke's own
        // (densified) point count first — Fréchet, unlike Hausdorff,
        // has no proven bound on cross-density inflation, so both sides
        // are matched to a common density here, the same discipline the
        // historical whole-path Fréchet computation always applied.
        var cost = Array(repeating: Array(repeating: CGFloat.greatestFiniteMagnitude, count: refCount),
                         count: traceCount)
        var reversedWins = Array(repeating: Array(repeating: false, count: refCount), count: traceCount)

        for i in 0..<traceCount {
            for j in 0..<refCount {
                let refStroke = refStrokes[j]
                let targetCount = max(refStroke.count, 8)
                let forward = FreeWriteScorer.resample(traceStrokes[i], targetCount: targetCount)
                let reversed = Array(forward.reversed())
                let forwardCost = FreeWriteScorer.discreteFrechetDistance(forward, refStroke)
                let reversedCost = FreeWriteScorer.discreteFrechetDistance(reversed, refStroke)
                if reversedCost < forwardCost {
                    cost[i][j] = reversedCost
                    reversedWins[i][j] = true
                } else {
                    cost[i][j] = forwardCost
                }
            }
        }

        let matched = bestAssignment(cost: cost, traceCount: traceCount, refCount: refCount)

        var totalDeviation: CGFloat = 0
        var matchedCount = 0
        var reversedCount = 0
        // Expand back to the ORIGINAL positions on both sides.
        var matchedAll: [Int?] = Array(repeating: nil, count: allTraceStrokes.count)
        for i in 0..<traceCount {
            guard let j = matched[i] else { continue }
            matchedAll[eligibleTrace[i]] = eligibleRef[j]
            totalDeviation += cost[i][j]
            matchedCount += 1
            if reversedWins[i][j] { reversedCount += 1 }
        }
        // Unreachable when both traceCount and refCount are > 0 (the
        // smaller side is always fully matched by construction — see
        // `bestAssignment`), guarded anyway rather than assumed.
        guard matchedCount > 0 else { return nil }

        return StrokeProcessMeasures(
            spatialDeviation: totalDeviation / CGFloat(matchedCount),
            strokeCount: allTraceStrokes.count,
            matchedReferenceOrder: matchedAll,
            reversedStrokeCount: reversedCount
        )
    }

    /// Minimum-total-cost assignment between traced-stroke indices
    /// `0..<traceCount` and reference-stroke indices `0..<refCount`,
    /// FORCED to `min(traceCount, refCount)` pairs (the smaller side is
    /// always fully matched — see the file header's "forced maximum
    /// cardinality" note). Exhaustive search: correct and fast at this
    /// domain's scale (a handful of strokes per letter), and the
    /// literature's general solution to this exact assignment problem —
    /// bipartite weighted matching / the Hungarian algorithm — would be
    /// unnecessary machinery here. Returns, for each traced-stroke index
    /// in trace order, its matched reference index or `nil`.
    private static func bestAssignment(
        cost: [[CGFloat]], traceCount: Int, refCount: Int
    ) -> [Int?] {
        guard traceCount > 0, refCount > 0 else { return Array(repeating: nil, count: traceCount) }

        if traceCount <= refCount {
            // Every traced stroke matches some distinct reference stroke.
            var usedRef = Array(repeating: false, count: refCount)
            var current = Array(repeating: Optional<Int>.none, count: traceCount)
            var best = current
            var bestTotal = CGFloat.greatestFiniteMagnitude
            func search(_ i: Int, _ total: CGFloat) {
                if total >= bestTotal { return }
                if i == traceCount { bestTotal = total; best = current; return }
                for j in 0..<refCount where !usedRef[j] {
                    usedRef[j] = true
                    current[i] = j
                    search(i + 1, total + cost[i][j])
                    usedRef[j] = false
                }
            }
            search(0, 0)
            return best
        } else {
            // Every reference stroke matches some distinct traced
            // stroke; the extra traced strokes stay unmatched.
            var usedTrace = Array(repeating: false, count: traceCount)
            var current = Array(repeating: Optional<Int>.none, count: refCount) // ref -> trace
            var best = current
            var bestTotal = CGFloat.greatestFiniteMagnitude
            func search(_ j: Int, _ total: CGFloat) {
                if total >= bestTotal { return }
                if j == refCount { bestTotal = total; best = current; return }
                for i in 0..<traceCount where !usedTrace[i] {
                    usedTrace[i] = true
                    current[j] = i
                    search(j + 1, total + cost[i][j])
                    usedTrace[i] = false
                }
            }
            search(0, 0)
            var result: [Int?] = Array(repeating: nil, count: traceCount)
            for (refIdx, traceIdx) in best.enumerated() {
                if let traceIdx { result[traceIdx] = refIdx }
            }
            return result
        }
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
