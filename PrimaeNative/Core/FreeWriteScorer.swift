// FreeWriteScorer.swift
// PrimaeNative
//
// Scores a freehand drawn path against a reference letter definition.
// Returns a WritingAssessment with four Schreibmotorik dimensions
// (Marquardt & Söhl 2016): Form, Tempo, Druck, Rhythmus.
// Form scoring uses discrete Fréchet distance (Eiter & Mannila 1994).

import CoreGraphics
import Foundation

// MARK: - Assessment result

/// Four-dimension writing assessment per Schreibmotorik Institut (Marquardt & Söhl, 2016).
struct WritingAssessment: Codable, Equatable {
    /// Shape accuracy via discrete Fréchet distance (0–1).
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
    static func score(
        tracedPoints: [CGPoint],
        reference: LetterStrokes,
        timestamps: [CFTimeInterval] = [],
        forces: [CGFloat] = [],
        sessionStart: CFTimeInterval = 0,
        sessionEnd: CFTimeInterval = 0
    ) -> WritingAssessment {
        WritingAssessment(
            formAccuracy:     formAccuracy(tracedPoints: tracedPoints, reference: reference),
            tempoConsistency: tempoConsistency(timestamps: timestamps),
            pressureControl:  pressureControl(forces: forces),
            rhythmScore:      rhythmScore(timestamps: timestamps,
                                          sessionStart: sessionStart,
                                          sessionEnd: sessionEnd)
        )
    }

    /// Raw Fréchet distance (exposed for debug overlay and testing).
    static func rawDistance(
        tracedPoints: [CGPoint],
        reference: LetterStrokes
    ) -> CGFloat {
        let refPoints = referencePolyline(from: reference)
        guard refPoints.count >= 2, tracedPoints.count >= 2 else { return .greatestFiniteMagnitude }
        let targetCount = max(refPoints.count, 20)
        return discreteFrechetDistance(
            resample(tracedPoints, targetCount: targetCount),
            resample(refPoints, targetCount: targetCount)
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
    private static func densifyReferenceStrokes(_ reference: LetterStrokes) -> [CGPoint] {
        var result: [CGPoint] = []
        for stroke in reference.strokes {
            let pts = stroke.checkpoints.map { CGPoint(x: $0.x, y: $0.y) }
            guard pts.count >= 2 else {
                result.append(contentsOf: pts)
                continue
            }
            // ~24 samples per stroke gives smooth coverage on long
            // sloped legs without ballooning the Hausdorff cost.
            let dense = resample(pts, targetCount: max(24, pts.count))
            result.append(contentsOf: dense)
        }
        return result
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
    private static func oneSidedHausdorff(_ a: [CGPoint],
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

    /// Primary thesis Form measure (the recorded `WritingAssessment.formAccuracy`).
    ///
    /// Cross-pen-lift note (investigated 2026-06): the reference is built
    /// by `referencePolyline`, which concatenates all strokes into one
    /// polyline and resamples by arc length — bridging each lift gap with
    /// a phantom diagonal. This was found **Fréchet-SAFE**: discrete
    /// Fréchet couples the trace's gap-bridge to the reference's
    /// gap-bridge at matching arc-length fractions, so the phantom
    /// diagonal cannot inflate the score beyond the real per-stroke error
    /// (empirically ≤1.4% on real letters, 0 in most cases, always toward
    /// HIGHER scores). The genuine cross-lift "tank" the
    /// `formAccuracyShape` docstring describes was a Hausdorff concern on
    /// the freeform/Werkstatt path, which is already per-stroke-densified.
    /// No per-stroke fix to this primary measure is warranted. Replica
    /// validation covered real A/T/H/I letters + synthetic long-gap,
    /// length-mismatch, and gross-displacement regimes. See PILOT_READINESS.
    private static func formAccuracy(tracedPoints: [CGPoint], reference: LetterStrokes) -> CGFloat {
        let refPoints = referencePolyline(from: reference)
        guard refPoints.count >= 2, tracedPoints.count >= 2 else { return 0 }

        let targetCount = max(refPoints.count, 20)
        let resampledTrace = resample(tracedPoints, targetCount: targetCount)
        let resampledRef   = resample(refPoints, targetCount: targetCount)

        let distance = discreteFrechetDistance(resampledTrace, resampledRef)
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
    /// Flat array + iterative for cache and stack-safety.
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

    /// Converts a LetterStrokes definition into a single polyline of
    /// normalised points. Concatenates across pen-lifts; this is
    /// Fréchet-safe for the primary measure — see the cross-pen-lift note
    /// on `formAccuracy`.
    private static func referencePolyline(from strokes: LetterStrokes) -> [CGPoint] {
        strokes.strokes.flatMap { stroke in
            stroke.checkpoints.map { CGPoint(x: $0.x, y: $0.y) }
        }
    }

    /// Euclidean distance between two points.
    private static func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
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
