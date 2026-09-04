// FreeWriteScorer.swift
// PrimaeNative
//
// Scores a freehand drawn path against a reference letter definition.
// Returns a WritingAssessment with four Schreibmotorik dimensions
// (Marquardt & Söhl 2016): Form, Tempo, Druck, Rhythmus.
// Form scoring (2026-09-04) is order-invariant via STROKE
// CORRESPONDENCE — matching each traced stroke to its best-fitting
// reference stroke, then measuring discrete Fréchet distance (Eiter &
// Mannila 1994) WITHIN each matched pair — see `StrokeProcessMeasures`
// for the full design and why whole-trace Hausdorff and whole-path
// Fréchet were both superseded by it. `formAccuracyShape` (freeform/
// Werkstatt, blank canvas, no fixed reference frame) is unaffected —
// its unit-box-normalised whole-trace Hausdorff is unchanged and still
// the right tool for that different problem.

import CoreGraphics
import Foundation

// MARK: - Assessment result

/// Four-dimension writing assessment per Schreibmotorik Institut (Marquardt & Söhl, 2016).
struct WritingAssessment: Codable, Equatable {
    /// Shape accuracy via order-invariant Hausdorff distance (0–1).
    let formAccuracy: CGFloat
    /// Speed consistency: 1 – normalised variance of inter-point intervals (0–1).
    let tempoConsistency: CGFloat
    /// Pressure control: 1 – normalised force variance if Apple Pencil; 1.0 for finger (0–1).
    let pressureControl: CGFloat
    /// Fluency: ratio of active-drawing time to total session time (0–1).
    let rhythmScore: CGFloat

    /// Weighted overall score: Form 40 %, Tempo 25 %, Druck 15 %, Rhythmus 20 %.
    var overallScore: CGFloat {
        formAccuracy * 0.40 + tempoConsistency * 0.25 + pressureControl * 0.15 + rhythmScore * 0.20
    }
}

// MARK: - Scorer

struct FreeWriteScorer {

    // MARK: - Public API

    /// Scores a traced path against reference strokes, returning a
    /// four-dimension assessment with each dimension in 0–1.
    /// `strokeStartIndices` feeds Form's stroke correspondence
    /// (`StrokeProcessMeasures`) — defaults to `[]` (the whole trace as
    /// one stroke), the right behaviour for a genuinely single-stroke
    /// trace and a safe simplification for a caller that doesn't track
    /// stroke boundaries at all.
    static func score(
        tracedPoints: [CGPoint],
        strokeStartIndices: [Int] = [],
        reference: LetterStrokes,
        timestamps: [CFTimeInterval] = [],
        forces: [CGFloat] = [],
        sessionStart: CFTimeInterval = 0,
        sessionEnd: CFTimeInterval = 0
    ) -> WritingAssessment {
        WritingAssessment(
            formAccuracy:     formAccuracy(tracedPoints: tracedPoints,
                                           strokeStartIndices: strokeStartIndices,
                                           reference: reference),
            tempoConsistency: tempoConsistency(timestamps: timestamps),
            pressureControl:  pressureControl(forces: forces),
            rhythmScore:      rhythmScore(timestamps: timestamps,
                                          sessionStart: sessionStart,
                                          sessionEnd: sessionEnd)
        )
    }

    // MARK: - Shape-only accuracy (freeform writing)

    /// Shape-similarity score in 0–1 for blank-canvas writing where
    /// stroke order, pen-lift count, and absolute position are all
    /// irrelevant — only "does the ink cover the glyph's footprint?".
    ///
    /// Notes:
    /// - Reference is densified per-stroke (no cross-stroke
    ///   concatenation) so phantom segments between pen-lifts can't
    ///   absorb sample points and tank the score.
    /// - Trace stays raw — touch samples are already dense and
    ///   resampling re-introduces phantom-segment bias.
    /// - Both sets normalised to a unit bounding box so position
    ///   offset doesn't add to the shape error.
    /// - Symmetric Hausdorff makes scoring stroke-order independent.
    /// - 6×checkpointRadius tolerance plus a square-root softener so
    ///   a clearly-shaped L lands in the 80s instead of capping at ~55 %.
    static func formAccuracyShape(
        tracedPoints: [CGPoint],
        reference: LetterStrokes
    ) -> CGFloat {
        let denseRef = densifyReferenceStrokes(reference)
        guard denseRef.count >= 2, tracedPoints.count >= 2 else { return 0 }

        let traceUnit = normaliseToUnitBox(tracedPoints)
        let refUnit   = normaliseToUnitBox(denseRef)

        let d1 = oneSidedHausdorff(traceUnit, refUnit)
        let d2 = oneSidedHausdorff(refUnit, traceUnit)
        let distance = max(d1, d2)

        let maxAcceptable = max(reference.checkpointRadius * 6.0, 0.001)
        let raw = max(0, min(1, 1.0 - distance / maxAcceptable))
        // Square-root softens the high end so a recognisable letter
        // lands in the 80s; the bottom only climbs a little so a
        // scribble still reads as "needs more practice".
        return CGFloat(sqrt(Double(raw)))
    }

    /// Resample each reference stroke's checkpoint polyline to a dense
    /// sequence of unit-space points without crossing pen-lift gaps.
    /// Flattened across strokes — callers that need per-stroke
    /// boundaries (stroke-to-stroke matching) use
    /// `densifyReferenceStrokesPerStroke` instead, which this wraps.
    static func densifyReferenceStrokes(_ reference: LetterStrokes) -> [CGPoint] {
        densifyReferenceStrokesPerStroke(reference).flatMap { $0 }
    }

    /// Same densification as `densifyReferenceStrokes`, kept as one
    /// dense point array PER reference stroke rather than flattened —
    /// what stroke-to-stroke matching (order/direction process measures)
    /// needs and shape/spatial-deviation scoring doesn't.
    static func densifyReferenceStrokesPerStroke(_ reference: LetterStrokes) -> [[CGPoint]] {
        reference.strokes.map { stroke in
            let pts = stroke.checkpoints.map { CGPoint(x: $0.x, y: $0.y) }
            guard pts.count >= 2 else { return pts }
            // 64 samples per stroke (found by CI, 2026-09-03, against
            // the whole-trace Hausdorff design this file used before
            // 2026-09-04's stroke-correspondence redesign — the
            // one-sided Hausdorff distance FROM a dense trace TO a
            // sparse reference is bounded below by roughly half the
            // REFERENCE's own point spacing, however dense the trace
            // gets). Still the right density for `formAccuracyShape`
            // (unchanged) and for the reference side of each
            // `StrokeProcessMeasures` pairwise Fréchet comparison, where
            // the same "match the reference's own sampling" reasoning
            // applies to the traced-stroke side via its own per-pair
            // resample (see `StrokeProcessScorer.analyze`).
            return resample(pts, targetCount: max(64, pts.count))
        }
    }

    /// Map a path so its axis-aligned bounding box fills the unit
    /// square. Degenerate paths fall back to centred 0.5 coordinates
    /// so the caller never deals with NaN.
    static func normaliseToUnitBox(_ points: [CGPoint]) -> [CGPoint] {
        guard !points.isEmpty,
              let minX = points.map(\.x).min(),
              let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(),
              let maxY = points.map(\.y).max() else { return points }
        let w = maxX - minX
        let h = maxY - minY
        return points.map { p in
            CGPoint(
                x: w > 0 ? (p.x - minX) / w : 0.5,
                y: h > 0 ? (p.y - minY) / h : 0.5
            )
        }
    }

    /// Asymmetric Hausdorff distance: the maximum, over points in `a`,
    /// of each point's distance to the nearest point in `b`. O(|a|·|b|).
    /// Not `private` — `StrokeProcessMeasures` reuses this for
    /// stroke-to-stroke matching rather than re-implementing it.
    static func oneSidedHausdorff(_ a: [CGPoint],
                                  _ b: [CGPoint]) -> CGFloat {
        var maxMin: CGFloat = 0
        for p in a {
            var minD: CGFloat = .greatestFiniteMagnitude
            for q in b {
                let d = dist(p, q)
                if d < minD { minD = d }
            }
            if minD > maxMin { maxMin = minD }
        }
        return maxMin
    }

    // MARK: - Dimension: Form accuracy

    /// The recorded `WritingAssessment.formAccuracy` — clamped, scaled
    /// companion to `PhaseSessionRecord.spatialDeviation`. Both read the
    /// SAME `StrokeProcessMeasures.spatialDeviation` (2026-09-04: stroke
    /// correspondence, order-invariant by construction — see that
    /// type's header). "Form" is a product measure — does the shape
    /// match — and should not cost a child anything for tracing a
    /// spatially correct letter in an unusual stroke order; that is a
    /// process property, recorded separately (`matchedReferenceOrder`,
    /// `reversedStrokeCount`, `strokeCount`).
    ///
    /// Same clamp convention as the historical Fréchet-based version
    /// (`checkpointRadius * 3.0`) for continuity in the UI's displayed
    /// range.
    private static func formAccuracy(tracedPoints: [CGPoint],
                                     strokeStartIndices: [Int],
                                     reference: LetterStrokes) -> CGFloat {
        guard let measures = StrokeProcessScorer.analyze(
            points: tracedPoints, strokeStartIndices: strokeStartIndices, reference: reference
        ) else { return 0 }
        let distance = measures.spatialDeviation
        guard distance.isFinite, distance < .greatestFiniteMagnitude else { return 0 }
        let maxAcceptable = reference.checkpointRadius * 3.0
        guard maxAcceptable > 0 else { return 0 }

        return CGFloat(max(0, min(1, 1.0 - distance / maxAcceptable)))
    }

    // MARK: - Dimension: Tempo consistency

    private static func tempoConsistency(timestamps: [CFTimeInterval]) -> CGFloat {
        guard timestamps.count >= 3 else { return 1.0 }

        // Collect inter-point intervals, excluding gaps > 0.5 s (pen lifts between strokes).
        var intervals: [Double] = []
        for i in 1..<timestamps.count {
            let dt = timestamps[i] - timestamps[i - 1]
            if dt > 0 && dt < 0.5 { intervals.append(dt) }
        }
        guard intervals.count >= 2 else { return 1.0 }

        let mean = intervals.reduce(0, +) / Double(intervals.count)
        guard mean > 0 else { return 1.0 }

        let variance = intervals.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
            / Double(intervals.count)
        // Coefficient of variation squared — scale-free normalisation.
        let normalised = variance / (mean * mean)
        return CGFloat(max(0, min(1, 1.0 - normalised)))
    }

    // MARK: - Dimension: Pressure control

    private static func pressureControl(forces: [CGFloat]) -> CGFloat {
        guard !forces.isEmpty else { return 1.0 }
        let active = forces.filter { $0 > 0 }
        // All-zero forces → finger input → no pressure data → perfect score.
        guard active.count >= 2 else { return 1.0 }

        let mean = active.reduce(0, +) / CGFloat(active.count)
        guard mean > 0 else { return 1.0 }

        let variance = active.reduce(0 as CGFloat) { $0 + ($1 - mean) * ($1 - mean) }
            / CGFloat(active.count)
        let normalised = variance / (mean * mean)
        return max(0, min(1, 1.0 - normalised))
    }

    // MARK: - Dimension: Rhythm / fluency

    private static func rhythmScore(timestamps: [CFTimeInterval],
                                    sessionStart: CFTimeInterval,
                                    sessionEnd: CFTimeInterval) -> CGFloat {
        let totalDuration = sessionEnd - sessionStart
        guard totalDuration > 0, !timestamps.isEmpty else { return 0 }

        // Sum intervals where the pen was actively moving (gap < 0.5 s = same stroke).
        var activeTime: CFTimeInterval = 0
        for i in 1..<timestamps.count {
            let dt = timestamps[i] - timestamps[i - 1]
            if dt < 0.5 { activeTime += dt }
        }

        return CGFloat(max(0, min(1, activeTime / totalDuration)))
    }

    // MARK: - Discrete Fréchet Distance

    /// O(nm) DP discrete Fréchet distance (Eiter & Mannila 1994).
    /// Flat array + iterative for cache and stack-safety. Not `private`
    /// — `StrokeProcessMeasures` reuses this as the WITHIN-PAIR distance
    /// for its stroke correspondence (2026-09-04) rather than
    /// re-implementing it.
    static func discreteFrechetDistance(
        _ p: [CGPoint], _ q: [CGPoint]
    ) -> CGFloat {
        let n = p.count, m = q.count
        guard n > 0, m > 0 else { return .greatestFiniteMagnitude }

        // Flat 2D array: dp[i * m + j]
        var dp = [CGFloat](repeating: 0, count: n * m)

        for i in 0..<n {
            for j in 0..<m {
                let d = dist(p[i], q[j])
                let idx = i * m + j
                if i == 0 && j == 0 {
                    dp[idx] = d
                } else if i == 0 {
                    dp[idx] = max(d, dp[j - 1])           // dp[0, j-1]
                } else if j == 0 {
                    dp[idx] = max(d, dp[(i - 1) * m])     // dp[i-1, 0]
                } else {
                    let prev = min(
                        dp[(i - 1) * m + j],           // dp[i-1, j]
                        min(dp[i * m + (j - 1)],       // dp[i, j-1]
                            dp[(i - 1) * m + (j - 1)]) // dp[i-1, j-1]
                    )
                    dp[idx] = max(d, prev)
                }
            }
        }

        return dp[n * m - 1]
    }

    // MARK: - Helpers

    /// Euclidean distance between two points. Not `private` —
    /// `StrokeProcessMeasures` reuses this rather than re-implementing it.
    static func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    /// Resamples a polyline to approximately `targetCount` equidistant
    /// points so trace density (100s of samples) matches reference
    /// density (5–16 checkpoints) before Fréchet comparison.
    static func resample(_ points: [CGPoint], targetCount: Int) -> [CGPoint] {
        guard points.count >= 2, targetCount >= 2 else { return points }

        // Compute cumulative arc lengths.
        var cumLengths = [CGFloat](repeating: 0, count: points.count)
        for i in 1..<points.count {
            cumLengths[i] = cumLengths[i - 1] + dist(points[i - 1], points[i])
        }

        let totalLength = cumLengths.last ?? 0
        guard totalLength > 0 else { return [points[0]] }

        var result = [CGPoint]()
        result.reserveCapacity(targetCount)
        result.append(points[0])

        var cursor = 1 // index into original points
        for step in 1..<(targetCount - 1) {
            let targetDist = totalLength * CGFloat(step) / CGFloat(targetCount - 1)
            while cursor < points.count - 1 && cumLengths[cursor] < targetDist {
                cursor += 1
            }
            // Linearly interpolate between points[cursor-1] and points[cursor].
            let prevDist = cumLengths[cursor - 1]
            let segLen   = cumLengths[cursor] - prevDist
            let t: CGFloat = segLen > 0 ? (targetDist - prevDist) / segLen : 0
            let interp = CGPoint(
                x: points[cursor - 1].x + t * (points[cursor].x - points[cursor - 1].x),
                y: points[cursor - 1].y + t * (points[cursor].y - points[cursor - 1].y)
            )
            result.append(interp)
        }

        // Safe unwrap: the early guard `points.count >= 2` guarantees last exists.
        if let last = points.last { result.append(last) }
        return result
    }
}
