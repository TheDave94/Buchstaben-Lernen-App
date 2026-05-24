"""Helpers for SPEC-VISUAL-APPROVAL drift-from-reference gates.

Per-point asymmetry computation used as input by G1 (Threshold 1,
Pearson-vs-reference) and the Voronoi per-stroke partition shared
across multiple gates.

These helpers are spec-agnostic: they produce raw per-point
sequences and per-stroke masks. The aggregation layer (Pearson
correlation against a reference letter, threshold derivation from
the 59-letter self-correlation floor) lands in G1's commit on top
of these primitives.

Imported by future audit drivers; not invoked at bake time
(bake-time auditing is G5's domain, wired into CI via
verify_bake.sh, not into the bake pipeline itself).
"""

from __future__ import annotations

import numpy as np
from scipy.ndimage import distance_transform_edt


# Max raster pixels to walk perpendicular before giving up. Primae-Regular
# stem half-width is ~22 px on the 1024² raster; 200 covers a generous
# multiple even for letters with thick bands.
T1_MAX_WALK_STEPS = 200
# Tangent smoothing window — averages (point[i+w] − point[i−w]) for w
# in [1, smoothing_window]. Smooths jitter on dense polylines.
T1_TANGENT_SMOOTHING = 2
# Skip K samples adjacent to each stroke endpoint. In multi-stroke
# letters the endpoints are at T-junctions or shared-apex meetings;
# in continuous-walk letters (M, V, W, Z, b, m, n, r, v, w) they're
# at the natural tips. K=3 excludes the rotation-heavy region where
# the polyline tangent is dominated by junction geometry.
# Decision rationale: thesis-substance methodology decision; see
# Phase 2b round, Option A, Decision 2. Threshold 4 (tangent
# alignment) and Threshold 5 (Y-junction gap) cover what T1 skips.
T1_ENDPOINT_SKIP = 3


def _walk_to_boundary(mask: np.ndarray,
                       start: tuple[float, float],
                       direction: tuple[float, float],
                       max_steps: int = T1_MAX_WALK_STEPS) -> float:
    """Walk from `start` along unit `direction` until exiting the ink
    mask. Returns the distance traversed (raster px). Returns 0.0 if
    `start` is already outside the mask or off-canvas."""
    h, w = mask.shape
    sx, sy = start
    dx, dy = direction
    ix, iy = int(round(sx)), int(round(sy))
    if not (0 <= ix < w and 0 <= iy < h) or not mask[iy, ix]:
        return 0.0
    last_inside = 0
    for step in range(1, max_steps + 1):
        nx, ny = sx + dx * step, sy + dy * step
        cx, cy = int(round(nx)), int(round(ny))
        if not (0 <= cx < w and 0 <= cy < h):
            return float(last_inside) + 0.5  # exited canvas
        if not mask[cy, cx]:
            return float(last_inside) + 0.5  # half-step boundary refinement
        last_inside = step
    return float(max_steps)


def _asymmetry_per_point(mask: np.ndarray,
                          poly_px: list[tuple[float, float]],
                          smoothing: int = T1_TANGENT_SMOOTHING,
                          endpoint_skip: int = T1_ENDPOINT_SKIP
                          ) -> list[tuple[float, bool]]:
    """Per polyline point, return (asymmetry, included). Excluded
    points: first/last `endpoint_skip` (junction-adjacent),
    degenerate tangent, point outside `mask`."""
    n = len(poly_px)
    out: list[tuple[float, bool]] = []
    for i in range(n):
        if i < endpoint_skip or i >= n - endpoint_skip:
            out.append((0.0, False))
            continue
        ws = min(smoothing, i, n - 1 - i)
        if ws < 1:
            out.append((0.0, False))
            continue
        x0, y0 = poly_px[i - ws]
        x1, y1 = poly_px[i + ws]
        tx, ty = x1 - x0, y1 - y0
        tl = (tx * tx + ty * ty) ** 0.5
        if tl < 1e-6:
            out.append((0.0, False))
            continue
        nx, ny = -ty / tl, tx / tl
        cx, cy = poly_px[i]
        d_plus = _walk_to_boundary(mask, (cx, cy), (nx, ny))
        d_minus = _walk_to_boundary(mask, (cx, cy), (-nx, -ny))
        denom = d_plus + d_minus
        if denom < 1e-6:
            out.append((0.0, False))
            continue
        a = abs(d_plus - d_minus) / denom
        out.append((a, True))
    return out


def build_per_stroke_masks(strokes_rel: list[list[tuple[float, float]]],
                            mask: np.ndarray,
                            bbox: tuple[int, int, int, int]
                            ) -> list[np.ndarray]:
    """Voronoi partition of the letter's ink mask by polyline
    ownership.

    For each ink pixel, find the nearest polyline-point across all
    strokes; the pixel is assigned to that polyline's stroke. The
    per-stroke mask = (ink ∧ owner == stroke). For a single-stroke
    letter this reduces to the input mask.

    Decision rationale: thesis-substance methodology decision; see
    Phase 2b round, Option A, Decision 1. Voronoi (no bandwidth
    parameter, fully data-driven) over band-isolation (requires
    picking stem_width).
    """
    x_min, y_min, x_max, y_max = bbox
    bw = max(1, x_max - x_min)
    bh = max(1, y_max - y_min)
    h, w = mask.shape
    # `seed_field` is True everywhere except at polyline-point pixels;
    # DT on it gives, per pixel, the (row, col) of the nearest seed.
    seed_field = np.ones((h, w), dtype=bool)
    owner_img = np.full((h, w), -1, dtype=np.int32)
    for s_idx, stroke in enumerate(strokes_rel):
        for rx, ry in stroke:
            px = int(round(x_min + rx * bw))
            py = int(round(y_min + ry * bh))
            if 0 <= px < w and 0 <= py < h:
                seed_field[py, px] = False
                # Last-writer-wins on pixel overlap (rare; happens
                # at shared-anchor points). The K=T1_ENDPOINT_SKIP
                # exclusion downstream handles those samples anyway.
                owner_img[py, px] = s_idx
    if not np.any(~seed_field):
        # No seeds at all (empty/degenerate letter); single-mask fallback.
        return [mask.copy() for _ in strokes_rel] or [mask.copy()]
    _, indices = distance_transform_edt(seed_field, return_indices=True)
    nearest_owner = owner_img[indices[0], indices[1]]
    return [mask & (nearest_owner == s_idx)
            for s_idx in range(len(strokes_rel))]


# -----------------------------------------------------------------------------
# G1 — Threshold 1 (asymmetry-profile drift from reference)
# Design: research_data/phase2b_gates/g1_design.md
# -----------------------------------------------------------------------------

# Arc-length resample target. Section 1b: shipped bake uses 40-200 cps per
# stroke; N=100 is the geometric mean and gives ~one sample per ~10 raster
# px on a 1024² mask — fine enough to resolve asymmetry features, coarse
# enough to keep Pearson statistically meaningful.
G1_RESAMPLE_N = 100

# Below this n_measured, Pearson is noise (Section 1d). Strokes that fall
# short return vacuous pass with reason="insufficient_measured_points".
G1_MIN_MEASURED = 10

# Threshold of record, derived 2026-05-23 against the 2026-05-22 session-pair
# corpus at HEAD d90a5cd8. See research_data/phase2b_gates/g1_calibration_run.md.
G1_DEFAULT_THRESHOLD = 0.2005

# Strokes whose asymmetry sequence std is below this floor are dominated
# by sub-pixel rounding noise (typical of uniform-width stems like l, I).
# Pearson on such sequences is meaningless. Vacuous-pass with
# reason="low_variance_asymmetry".
# Empirically derived against the 2026-05-22 session corpus: cutoff sits
# in the gap between l's 0.0438 (uniform stem, edit_count=0, Pearson
# noise) and D s1's 0.0521 (legitimate closed-bowl polish, Pearson 0.49).
# See research_data/phase2b_gates/g1_calibration_run.md.
G1_MIN_ASYMMETRY_STD = 0.05


def _arc_length_resample(poly: list[tuple[float, float]],
                          n: int) -> list[tuple[float, float]]:
    """Resample `poly` to `n` arc-length-uniform points in the same
    coordinate space. Returns the input unchanged if it has fewer than 2
    points; returns n copies of the single point for an all-same-point
    polyline."""
    if len(poly) < 2 or n < 2:
        return list(poly)
    pts = np.asarray(poly, dtype=float)
    seg = np.linalg.norm(np.diff(pts, axis=0), axis=1)
    cum = np.concatenate([[0.0], np.cumsum(seg)])
    total = float(cum[-1])
    if total < 1e-9:
        return [tuple(pts[0])] * n
    targets = np.linspace(0.0, total, n)
    out_x = np.interp(targets, cum, pts[:, 0])
    out_y = np.interp(targets, cum, pts[:, 1])
    return list(zip(out_x.tolist(), out_y.tolist()))


def gate_g1_per_stroke(candidate_poly_rel: list[tuple[float, float]],
                        reference_poly_rel: list[tuple[float, float]],
                        mask: np.ndarray,
                        bbox: tuple[int, int, int, int],
                        threshold: float,
                        n_resample: int = G1_RESAMPLE_N,
                        n_min_measured: int = G1_MIN_MEASURED) -> dict:
    """Run G1 on a single (candidate, reference) stroke pair.

    Returns a per-stroke result dict (see g1_design.md Section 5).
    Vacuous-pass cases (1-cp strokes, insufficient measured points,
    constant asymmetry) return pass=True with a `reason` field.
    """
    n_cp_c = len(candidate_poly_rel)
    n_cp_r = len(reference_poly_rel)
    if n_cp_c < 2 or n_cp_r < 2:
        # 1-cp diacritic dots (Section 1c): no centerline geometry.
        return {
            "pearson": None,
            "n_measured": 0,
            "n_cp_candidate": n_cp_c,
            "n_cp_reference": n_cp_r,
            "pass": True,
            "reason": "not_applicable_too_short",
        }

    # Resample the POLYLINE to N=100, THEN compute asymmetry on the
    # resampled polyline. This is NOT equivalent to computing asymmetry
    # on the original cps and then resampling the asymmetry sequence —
    # the perpendicular walks happen at resampled cp positions. Do not
    # refactor to swap the order. (g1_design.md Redline 1.)
    x_min, y_min, x_max, y_max = bbox
    bw = max(1, x_max - x_min)
    bh = max(1, y_max - y_min)
    cand_rs = _arc_length_resample(candidate_poly_rel, n_resample)
    ref_rs = _arc_length_resample(reference_poly_rel, n_resample)
    cand_px = [(x_min + rx * bw, y_min + ry * bh) for rx, ry in cand_rs]
    ref_px = [(x_min + rx * bw, y_min + ry * bh) for rx, ry in ref_rs]
    cand_asyms = _asymmetry_per_point(mask, cand_px)
    ref_asyms = _asymmetry_per_point(mask, ref_px)

    # Index-pair only where both sequences have ok=True. The resample
    # puts both on the same arc-length grid, so index i is the same
    # fractional position along the stroke in both.
    paired = [(a, b) for (a, ok_a), (b, ok_b)
              in zip(cand_asyms, ref_asyms) if ok_a and ok_b]
    if len(paired) < n_min_measured:
        return {
            "pearson": None,
            "n_measured": len(paired),
            "n_cp_candidate": n_cp_c,
            "n_cp_reference": n_cp_r,
            "pass": True,
            "reason": "insufficient_measured_points",
        }
    arr = np.array(paired, dtype=float)
    cand_std = float(arr[:, 0].std())
    ref_std = float(arr[:, 1].std())
    if max(cand_std, ref_std) < G1_MIN_ASYMMETRY_STD:
        # Asymmetry signal is dominated by sub-pixel rounding noise;
        # Pearson is meaningless (e.g., l, I — uniform-width stems).
        return {
            "pearson": None,
            "n_measured": len(paired),
            "n_cp_candidate": n_cp_c,
            "n_cp_reference": n_cp_r,
            "pass": True,
            "reason": "low_variance_asymmetry",
        }
    if cand_std < 1e-12 or ref_std < 1e-12:
        # corrcoef of a constant sequence is NaN; no signal to compare.
        # (Strict subcase of low_variance_asymmetry, but the more
        # specific reason aids debugging.)
        return {
            "pearson": None,
            "n_measured": len(paired),
            "n_cp_candidate": n_cp_c,
            "n_cp_reference": n_cp_r,
            "pass": True,
            "reason": "constant_asymmetry_sequence",
        }
    r = float(np.corrcoef(arr[:, 0], arr[:, 1])[0, 1])
    return {
        "pearson": r,
        "n_measured": len(paired),
        "n_cp_candidate": n_cp_c,
        "n_cp_reference": n_cp_r,
        "pass": r >= threshold,
    }


def gate_g1(candidate_strokes_rel: list[list[tuple[float, float]]],
             reference_strokes_rel: list[list[tuple[float, float]]],
             mask: np.ndarray,
             bbox: tuple[int, int, int, int],
             threshold: float) -> dict:
    """Run G1 on a candidate-vs-reference letter pair.

    Letter `pass` = all paired strokes pass. Stroke-count mismatch is
    surfaced in the result (n_strokes_candidate vs n_strokes_reference)
    but is Threshold 6 / determinism's concern, not T1's — strokes
    beyond min(n_c, n_r) are not compared.
    """
    # Partition by the REFERENCE polyline ownership. The reference is
    # the canonical truth; partitioning by candidate would let a
    # regressing candidate redefine its own ownership region.
    stroke_masks = build_per_stroke_masks(reference_strokes_rel, mask, bbox)
    per_stroke: list[dict] = []
    n_pairs = min(len(candidate_strokes_rel), len(reference_strokes_rel))
    for i in range(n_pairs):
        result = gate_g1_per_stroke(candidate_strokes_rel[i],
                                     reference_strokes_rel[i],
                                     stroke_masks[i], bbox, threshold)
        result["stroke"] = i
        per_stroke.append(result)
    overall_pass = bool(per_stroke) and all(s["pass"] for s in per_stroke)
    real_pearsons = [s["pearson"] for s in per_stroke
                     if s["pearson"] is not None]
    letter_score = min(real_pearsons) if real_pearsons else None
    return {
        "per_stroke": per_stroke,
        "letter_score": letter_score,
        "n_strokes_candidate": len(candidate_strokes_rel),
        "n_strokes_reference": len(reference_strokes_rel),
        "pass": overall_pass,
    }


# -----------------------------------------------------------------------------
# G2 — Threshold 2 (turn-angle-profile drift from reference)
# Design: research_data/phase2b_gates/g2_design.md
# -----------------------------------------------------------------------------

G2_RESAMPLE_N = 100
G2_MIN_MEASURED = 10
# Skip K samples adjacent to each stroke endpoint, mirroring G1. Reasons:
# (a) turn-angle is mathematically undefined at first/last cp (no
# preceding/succeeding segment); (b) junction-snap dominates the polyline
# direction at endpoint-adjacent cps. Separate constant from
# T1_ENDPOINT_SKIP for layer-of-abstraction reasons (G2's gate could in
# principle tune independently).
G2_ENDPOINT_SKIP = 3
# Strokes whose turn-angle sequence std (radians) falls below this floor
# are dominated by sub-pixel rounding noise (uniform-width stems like
# l, I, the straight components of T E F H L). Pearson on such sequences
# is meaningless. Vacuous-pass with reason="low_variance_turn_angle".
# Value derived empirically post-calibration (see
# research_data/phase2b_gates/g2_calibration_run.md when it lands).
G2_MIN_TURN_ANGLE_STD = 0.0  # placeholder pending calibration


def _turn_angle_per_point(poly_px: list[tuple[float, float]],
                           endpoint_skip: int = G2_ENDPOINT_SKIP
                           ) -> list[tuple[float, bool]]:
    """Per polyline point, return (signed_turn_angle, included).
    Excluded points: first/last `endpoint_skip` (junction-adjacent),
    degenerate segments (near-zero length on either side)."""
    n = len(poly_px)
    out: list[tuple[float, bool]] = []
    import math
    # Turn-angle needs both neighbors; effective skip is at least 1 even
    # when the caller passes endpoint_skip=0 (test paths).
    effective_skip = max(1, endpoint_skip)
    for i in range(n):
        if i < effective_skip or i >= n - effective_skip:
            out.append((0.0, False))
            continue
        x0, y0 = poly_px[i - 1]
        x1, y1 = poly_px[i]
        x2, y2 = poly_px[i + 1]
        ax, ay = x1 - x0, y1 - y0
        bx, by = x2 - x1, y2 - y1
        la = (ax * ax + ay * ay) ** 0.5
        lb = (bx * bx + by * by) ** 0.5
        if la < 1e-9 or lb < 1e-9:
            out.append((0.0, False))
            continue
        # Signed angle convention: positive = CCW turn (left), negative =
        # CW turn (right), computed as atan2(cross, dot). The Pearson
        # comparison is only valid if BOTH candidate and reference use
        # the same sign convention. Do not refactor to a y-flip variant
        # without updating the calibration data, since flipped polylines
        # would compare differently.
        cross = ax * by - ay * bx
        dot = ax * bx + ay * by
        angle = math.atan2(cross, dot)
        out.append((angle, True))
    return out


def gate_g2_per_stroke(candidate_poly_rel: list[tuple[float, float]],
                        reference_poly_rel: list[tuple[float, float]],
                        bbox: tuple[int, int, int, int],
                        threshold: float,
                        n_resample: int = G2_RESAMPLE_N,
                        n_min_measured: int = G2_MIN_MEASURED,
                        min_turn_angle_std: float = G2_MIN_TURN_ANGLE_STD
                        ) -> dict:
    """Run G2 on a single (candidate, reference) stroke pair.

    Same return shape as gate_g1_per_stroke; vacuous-pass reasons are
    not_applicable_too_short / insufficient_measured_points /
    low_variance_turn_angle / constant_turn_angle_sequence.
    """
    n_cp_c = len(candidate_poly_rel)
    n_cp_r = len(reference_poly_rel)
    if n_cp_c < 2 or n_cp_r < 2:
        return {
            "pearson": None,
            "n_measured": 0,
            "n_cp_candidate": n_cp_c,
            "n_cp_reference": n_cp_r,
            "pass": True,
            "reason": "not_applicable_too_short",
        }

    # Resample the POLYLINE first, then compute angles on the resampled
    # polyline. Same invariant as G1 (see gate_g1_per_stroke).
    x_min, y_min, x_max, y_max = bbox
    bw = max(1, x_max - x_min)
    bh = max(1, y_max - y_min)
    cand_rs = _arc_length_resample(candidate_poly_rel, n_resample)
    ref_rs = _arc_length_resample(reference_poly_rel, n_resample)
    cand_px = [(x_min + rx * bw, y_min + ry * bh) for rx, ry in cand_rs]
    ref_px = [(x_min + rx * bw, y_min + ry * bh) for rx, ry in ref_rs]
    cand_angles = _turn_angle_per_point(cand_px)
    ref_angles = _turn_angle_per_point(ref_px)

    paired = [(a, b) for (a, ok_a), (b, ok_b)
              in zip(cand_angles, ref_angles) if ok_a and ok_b]
    if len(paired) < n_min_measured:
        return {
            "pearson": None,
            "n_measured": len(paired),
            "n_cp_candidate": n_cp_c,
            "n_cp_reference": n_cp_r,
            "pass": True,
            "reason": "insufficient_measured_points",
        }
    arr = np.array(paired, dtype=float)
    cand_std = float(arr[:, 0].std())
    ref_std = float(arr[:, 1].std())
    if max(cand_std, ref_std) < min_turn_angle_std:
        return {
            "pearson": None,
            "n_measured": len(paired),
            "n_cp_candidate": n_cp_c,
            "n_cp_reference": n_cp_r,
            "pass": True,
            "reason": "low_variance_turn_angle",
        }
    if cand_std < 1e-12 or ref_std < 1e-12:
        return {
            "pearson": None,
            "n_measured": len(paired),
            "n_cp_candidate": n_cp_c,
            "n_cp_reference": n_cp_r,
            "pass": True,
            "reason": "constant_turn_angle_sequence",
        }
    r = float(np.corrcoef(arr[:, 0], arr[:, 1])[0, 1])
    return {
        "pearson": r,
        "n_measured": len(paired),
        "n_cp_candidate": n_cp_c,
        "n_cp_reference": n_cp_r,
        "pass": r >= threshold,
    }


def gate_g2(candidate_strokes_rel: list[list[tuple[float, float]]],
             reference_strokes_rel: list[list[tuple[float, float]]],
             bbox: tuple[int, int, int, int],
             threshold: float) -> dict:
    """Run G2 on a candidate-vs-reference letter pair. Mirrors gate_g1
    but takes no mask (turn-angle is a pure polyline property)."""
    per_stroke: list[dict] = []
    n_pairs = min(len(candidate_strokes_rel), len(reference_strokes_rel))
    for i in range(n_pairs):
        result = gate_g2_per_stroke(candidate_strokes_rel[i],
                                     reference_strokes_rel[i],
                                     bbox, threshold)
        result["stroke"] = i
        per_stroke.append(result)
    overall_pass = bool(per_stroke) and all(s["pass"] for s in per_stroke)
    real_pearsons = [s["pearson"] for s in per_stroke
                     if s["pearson"] is not None]
    letter_score = min(real_pearsons) if real_pearsons else None
    return {
        "per_stroke": per_stroke,
        "letter_score": letter_score,
        "n_strokes_candidate": len(candidate_strokes_rel),
        "n_strokes_reference": len(reference_strokes_rel),
        "pass": overall_pass,
    }


# -----------------------------------------------------------------------------
# G3 — Threshold 3 (perpendicular-deviation conformance gate for straight strokes)
# Design: research_data/phase2b_gates/g3_design.md
# -----------------------------------------------------------------------------

import math as _math  # local alias; module-level math is in _turn_angle_per_point

G3_RESAMPLE_N = 100
G3_MIN_MEASURED = 10
G3_ENDPOINT_SKIP = 3
# A stroke is "straight" for G3 purposes iff its reference polyline
# passes a combined criterion: max(|per-segment angle|) below the
# sharp-corner cutoff AND p95(|per-segment angle|) below the
# sustained-curvature cutoff. The original design used max-only
# (mirroring G2's STRAIGHT-class boundary), but implementation
# revealed that smooth curves like D's bowl pass max-only (per-segment
# angles on a smoothly-curved arc at N=100 resample to ~0.03-0.14 rad,
# below the π/12 max threshold). Cumulative-sum was tried and rejected
# (noise accumulates linearly with N). The combined criterion was
# empirically derived against the 2026-05-22 corpus; see
# research_data/phase2b_gates/g3_design.md G3.1 "Caveat caught
# during implementation" for the full diagnostic.
G3_STRAIGHTNESS_MAX_ANGLE = _math.pi / 12  # ≈15°, 0.262 rad
# Sits in the 0.014-wide empirical gap between A s2's p95=0.087 and
# D s1's p95=0.101 in the 2026-05-22 corpus. If G3_RESAMPLE_N changes
# from 100, this threshold must be re-derived.
G3_STRAIGHTNESS_P95_ANGLE = 0.1  # ≈5.7°
# Empirically derived 2026-05-24 against the full 59-letter corpus
# during G5 verification. Sits in the 22.9°-wide gap between the last
# well-behaved STRAIGHT stroke (ä s1 at 4.7°) and the first offender
# (Y s1 at 27.6°). This criterion is N-invariant for the signal:
# noise has zero mean (cancels at any N); smooth curvature accumulates
# net direction change regardless of N. Unlike G3_STRAIGHTNESS_P95_ANGLE,
# this constant does NOT require re-derivation if G3_RESAMPLE_N changes.
G3_STRAIGHTNESS_SIGNED_CUM_RAD = _math.pi / 12  # ≈15°, 0.262 rad
# Percentile of per-cp perpendicular deviations reported as the
# stroke's deviation. Spec-aligned (BAKE_INVARIANTS.md §2 Threshold 3).
G3_PERCENTILE = 95
# Placeholder threshold pending empirical derivation from calibration.
# Recorded in BAKE_INVARIANTS.md §2 Threshold 3 once the calibration
# commit lands.
# Threshold of record (px on 1024² mask), derived 2026-05-23 against the
# 2026-05-22 session-pair corpus at HEAD 3c890380. See
# research_data/phase2b_gates/g3_calibration_run.md.
G3_DEFAULT_THRESHOLD = 2.05


def _perpendicular_deviation(poly_px: list[tuple[float, float]],
                              percentile: float = G3_PERCENTILE
                              ) -> tuple[float, int]:
    """Fit a least-squares line to `poly_px` and return the
    `percentile`-th percentile of per-cp perpendicular distances to
    that line, plus the number of cps actually measured.

    Caller is responsible for endpoint-skip — pass the post-skip cps.
    Returns (deviation_px, n_measured). Returns (0.0, 0) if input
    has fewer than 2 points (degenerate; no line to fit)."""
    if len(poly_px) < 2:
        return 0.0, 0
    arr = np.asarray(poly_px, dtype=float)
    # Best-fit line via PCA — first principal component is the line
    # direction; deviations are the residuals in the perpendicular
    # direction. Works for any line orientation (vertical, horizontal,
    # diagonal) without picking x or y as the independent variable.
    centroid = arr.mean(axis=0)
    centered = arr - centroid
    # SVD on the centered points; principal axis is the right-singular
    # vector with the largest singular value.
    _, _, vh = np.linalg.svd(centered, full_matrices=False)
    direction = vh[0]
    # Perpendicular unit vector (2D rotation by 90°).
    perp = np.array([-direction[1], direction[0]])
    deviations = np.abs(centered @ perp)
    return float(np.percentile(deviations, percentile)), len(poly_px)


def _stroke_angle_stats(poly_px: list[tuple[float, float]],
                          endpoint_skip: int = G3_ENDPOINT_SKIP
                          ) -> tuple[float, float, float]:
    """Return (max, p95, signed_cumulative) of per-segment turn-angles
    across the polyline, with endpoint skip applied. Used by G3's
    three-part straightness classifier. Returns (0.0, 0.0, 0.0) for
    polylines too short to compute any angle.

    - max, p95 are computed on |angle| (catch local sharp turns and
      sustained per-segment curvature)
    - signed_cumulative is the sum of signed angles (catches smooth
      long curves where per-segment angles stay small but net
      direction change accumulates — added 2026-05-24 during G5
      verification)
    """
    angles = _turn_angle_per_point(poly_px, endpoint_skip=endpoint_skip)
    real_signed = [a for a, ok in angles if ok]
    if not real_signed:
        return 0.0, 0.0, 0.0
    real_abs = [abs(a) for a in real_signed]
    max_a = max(real_abs)
    p95_a = float(np.percentile(real_abs, 95))
    signed_cum = float(sum(real_signed))
    return max_a, p95_a, signed_cum


def gate_g3_per_stroke(candidate_poly_rel: list[tuple[float, float]],
                        reference_poly_rel: list[tuple[float, float]],
                        bbox: tuple[int, int, int, int],
                        threshold: float,
                        n_resample: int = G3_RESAMPLE_N,
                        n_min_measured: int = G3_MIN_MEASURED,
                        straightness_max: float = G3_STRAIGHTNESS_MAX_ANGLE,
                        straightness_p95: float = G3_STRAIGHTNESS_P95_ANGLE,
                        straightness_signed_cum: float = G3_STRAIGHTNESS_SIGNED_CUM_RAD,
                        endpoint_skip: int = G3_ENDPOINT_SKIP,
                        percentile: float = G3_PERCENTILE
                        ) -> dict:
    """Run G3 (perpendicular-deviation conformance gate) on a single
    stroke pair.

    Returns a per-stroke result dict. Vacuous-pass reasons:
    not_applicable_too_short (1-cp), not_applicable_not_straight
    (reference fails the combined max+p95+|signed_cum| straightness
    criterion), insufficient_measured_points (post-skip cp count below
    n_min_measured).
    """
    n_cp_c = len(candidate_poly_rel)
    n_cp_r = len(reference_poly_rel)
    if n_cp_c < 2 or n_cp_r < 2:
        return {
            "deviation_px": None,
            "max_ref_angle": None,
            "p95_ref_angle": None,
            "signed_cum_ref": None,
            "n_measured": 0,
            "n_cp_candidate": n_cp_c,
            "n_cp_reference": n_cp_r,
            "pass": True,
            "reason": "not_applicable_too_short",
        }

    # Resample both polylines (mirrors G1/G2 invariant: resample then
    # measure on the resampled polyline, not the other way around).
    x_min, y_min, x_max, y_max = bbox
    bw = max(1, x_max - x_min)
    bh = max(1, y_max - y_min)
    cand_rs = _arc_length_resample(candidate_poly_rel, n_resample)
    ref_rs = _arc_length_resample(reference_poly_rel, n_resample)
    cand_px = [(x_min + rx * bw, y_min + ry * bh) for rx, ry in cand_rs]
    ref_px = [(x_min + rx * bw, y_min + ry * bh) for rx, ry in ref_rs]

    # Three-part straightness check on the reference: pass iff all of:
    #   (max < straightness_max)                — catches sharp corners
    #   (p95 < straightness_p95)                — catches sustained
    #                                             per-segment curvature
    #   (|signed_cum| < straightness_signed_cum) — catches smooth long
    #                                             curves whose net
    #                                             direction change
    #                                             accumulates (added
    #                                             2026-05-24 during G5
    #                                             verification)
    # Any single failure → non-straight → G3 vacuous-pass. See
    # g3_design.md G3.1 "Caveat caught during implementation" +
    # "Refinement caught during G5 verification" subsections.
    max_ref_angle, p95_ref_angle, signed_cum_ref = _stroke_angle_stats(
        ref_px, endpoint_skip)
    if (max_ref_angle >= straightness_max
            or p95_ref_angle >= straightness_p95
            or abs(signed_cum_ref) >= straightness_signed_cum):
        return {
            "deviation_px": None,
            "max_ref_angle": max_ref_angle,
            "p95_ref_angle": p95_ref_angle,
            "signed_cum_ref": signed_cum_ref,
            "n_measured": 0,
            "n_cp_candidate": n_cp_c,
            "n_cp_reference": n_cp_r,
            "pass": True,
            "reason": "not_applicable_not_straight",
        }

    # Endpoint-skip on the candidate before LSQ fit, so junction-
    # adjacent cps don't drag the line.
    skip = endpoint_skip
    cand_measured = cand_px[skip:len(cand_px) - skip]
    if len(cand_measured) < n_min_measured:
        return {
            "deviation_px": None,
            "max_ref_angle": max_ref_angle,
            "p95_ref_angle": p95_ref_angle,
            "signed_cum_ref": signed_cum_ref,
            "n_measured": len(cand_measured),
            "n_cp_candidate": n_cp_c,
            "n_cp_reference": n_cp_r,
            "pass": True,
            "reason": "insufficient_measured_points",
        }

    deviation_px, n_measured = _perpendicular_deviation(
        cand_measured, percentile)
    return {
        "deviation_px": deviation_px,
        "max_ref_angle": max_ref_angle,
        "p95_ref_angle": p95_ref_angle,
        "signed_cum_ref": signed_cum_ref,
        "n_measured": n_measured,
        "n_cp_candidate": n_cp_c,
        "n_cp_reference": n_cp_r,
        "pass": deviation_px <= threshold,
    }


def gate_g3(candidate_strokes_rel: list[list[tuple[float, float]]],
             reference_strokes_rel: list[list[tuple[float, float]]],
             bbox: tuple[int, int, int, int],
             threshold: float) -> dict:
    """Run G3 on a candidate-vs-reference letter pair. Mask-free
    (perpendicular deviation is a pure polyline property)."""
    per_stroke: list[dict] = []
    n_pairs = min(len(candidate_strokes_rel), len(reference_strokes_rel))
    for i in range(n_pairs):
        result = gate_g3_per_stroke(candidate_strokes_rel[i],
                                     reference_strokes_rel[i],
                                     bbox, threshold)
        result["stroke"] = i
        per_stroke.append(result)
    overall_pass = bool(per_stroke) and all(s["pass"] for s in per_stroke)
    real_devs = [s["deviation_px"] for s in per_stroke
                 if s["deviation_px"] is not None]
    letter_score = max(real_devs) if real_devs else None
    return {
        "per_stroke": per_stroke,
        "letter_score": letter_score,
        "n_strokes_candidate": len(candidate_strokes_rel),
        "n_strokes_reference": len(reference_strokes_rel),
        "pass": overall_pass,
    }


# -----------------------------------------------------------------------------
# G4 — Threshold 4 (junction-tangent-delta drift gate)
# Design: research_data/phase2b_gates/g4_design.md (operative design is the
# drift-gate redesign G4'.1–G4'.7; the original conformance design G4.1–G4.12
# is preserved in the doc as the design-hypothesis-that-needed-correction).
# -----------------------------------------------------------------------------

G4_RESAMPLE_N = 100             # mirrors G1/G2/G3
G4_ENDPOINT_SKIP = 3            # cps to skip from each endpoint
G4_TANGENT_WINDOW = 5           # cps used for LSQ tangent fit
# Junction-detection endpoint-distance threshold (raster px on 1024² mask).
# Derived empirically from a pre-implementation diagnostic 2026-05-23: the
# corpus's actual junctions all sit ≤ 10.85 px apart; the only obvious
# non-junction (R 1-2) is at 31.95 px. 15 px sits in this gap. If
# G4_RESAMPLE_N or the rendering scale changes, this must be re-derived.
G4_JUNCTION_EPSILON_PX = 15.0
# Threshold of record (degrees), derived 2026-05-23 against the
# 2026-05-22 session-pair corpus at HEAD 108c8d47. See
# research_data/phase2b_gates/g4_calibration_run.md.
G4_DEFAULT_THRESHOLD_DEG = 4.43


def _stroke_tangent_at_endpoint(poly_px: list[tuple[float, float]],
                                  at_first: bool,
                                  endpoint_skip: int = G4_ENDPOINT_SKIP,
                                  window: int = G4_TANGENT_WINDOW
                                  ) -> tuple[float, float] | None:
    """Return a unit vector pointing OUTWARD from the named endpoint
    toward the stroke interior, fit on `window` cps after
    `endpoint_skip` from that end. Returns None if too few cps for a
    reliable fit."""
    n = len(poly_px)
    if at_first:
        start, end = endpoint_skip, endpoint_skip + window
        endpoint_cp = poly_px[0]
    else:
        start, end = n - endpoint_skip - window, n - endpoint_skip
        endpoint_cp = poly_px[-1]
    if start < 0 or end > n or end - start < 2:
        return None
    window_cps = np.array(poly_px[start:end], dtype=float)
    centroid = window_cps.mean(axis=0)
    centered = window_cps - centroid
    if np.allclose(centered, 0):
        return None
    _, _, vh = np.linalg.svd(centered, full_matrices=False)
    direction = vh[0]
    # Orient outward from endpoint toward window centroid.
    outward = centroid - np.array(endpoint_cp, dtype=float)
    if float(np.dot(direction, outward)) < 0:
        direction = -direction
    norm = float(np.linalg.norm(direction))
    if norm < 1e-9:
        return None
    return (float(direction[0] / norm), float(direction[1] / norm))


def _kink_deg(tangent_a: tuple[float, float] | None,
                tangent_b: tuple[float, float] | None) -> float | None:
    """Outgoing-vs-outgoing angle (in degrees), reported as
    |180° − angle|. Semantics (see g4_design.md G4'.2):
        0°   = pen-continuation (anti-parallel outgoing tangents)
        ~90° = T-corner
        ~180° = point-meeting (parallel outgoing tangents)
    Returns None if either tangent is missing.
    """
    if tangent_a is None or tangent_b is None:
        return None
    import math
    cosv = float(np.clip(tangent_a[0] * tangent_b[0]
                           + tangent_a[1] * tangent_b[1], -1.0, 1.0))
    angle_deg = math.degrees(math.acos(cosv))
    return abs(180.0 - angle_deg)


def _detect_junctions(strokes_rel: list[list[tuple[float, float]]],
                       bbox: tuple[int, int, int, int],
                       epsilon_px: float = G4_JUNCTION_EPSILON_PX,
                       n_resample: int = G4_RESAMPLE_N,
                       min_cps: int = G4_ENDPOINT_SKIP + G4_TANGENT_WINDOW
                       ) -> list[dict]:
    """Enumerate end-to-end junctions across consecutive stroke pairs
    on the bbox-converted px-space polylines (post arc-length resample
    to `n_resample`). For each consecutive pair (i, i+1), check the
    four endpoint pairings; the minimum-distance pairing registers as
    the junction if its distance is below `epsilon_px`.

    Strokes with fewer than `min_cps` cps after resample are filtered
    before pairing (filters 1-cp diacritic dots).

    Returns a list of dicts: { i, j, pairing, dist_px, poly_a, poly_b,
    a_first, b_first } where poly_a/poly_b are the resampled px-space
    polylines and a_first/b_first are bool flags for which endpoint
    of each stroke is at the junction.
    """
    import math
    x_min, y_min, x_max, y_max = bbox
    bw = max(1, x_max - x_min)
    bh = max(1, y_max - y_min)
    polylines_px: list[list[tuple[float, float]]] = []
    for stroke in strokes_rel:
        if len(stroke) < 2:
            polylines_px.append([])
            continue
        rs = _arc_length_resample(stroke, n_resample)
        polylines_px.append([(x_min + rx * bw, y_min + ry * bh)
                              for rx, ry in rs])

    junctions: list[dict] = []
    for i in range(len(polylines_px) - 1):
        a, b = polylines_px[i], polylines_px[i + 1]
        if len(a) < min_cps or len(b) < min_cps:
            continue
        pairings = [
            ("first", "first", a[0], b[0], True, True),
            ("first", "last", a[0], b[-1], True, False),
            ("last", "first", a[-1], b[0], False, True),
            ("last", "last", a[-1], b[-1], False, False),
        ]
        best = min(pairings,
                    key=lambda p: math.hypot(p[2][0] - p[3][0],
                                              p[2][1] - p[3][1]))
        la, lb, ea, eb, a_first, b_first = best
        dist = math.hypot(ea[0] - eb[0], ea[1] - eb[1])
        if dist > epsilon_px:
            continue
        junctions.append({
            "i": i, "j": i + 1,
            "pairing": f"{la}/{lb}",
            "dist_px": dist,
            "poly_a": a, "poly_b": b,
            "a_first": a_first, "b_first": b_first,
        })
    return junctions


def gate_g4_per_junction(cand_a_rel: list[tuple[float, float]],
                          cand_b_rel: list[tuple[float, float]],
                          ref_a_rel: list[tuple[float, float]],
                          ref_b_rel: list[tuple[float, float]],
                          bbox: tuple[int, int, int, int],
                          threshold_deg: float,
                          epsilon_px: float = G4_JUNCTION_EPSILON_PX,
                          n_resample: int = G4_RESAMPLE_N,
                          endpoint_skip: int = G4_ENDPOINT_SKIP,
                          window: int = G4_TANGENT_WINDOW
                          ) -> dict:
    """Run G4 on a single (candidate, reference) stroke-pair junction.

    Detects the junction on BOTH rounds; vacuous-passes if detection
    status differs between them. Otherwise computes kink_deg on each
    round and returns the absolute drift.

    Returns a per-junction result dict with keys: kink_drift_deg,
    kink_cand_deg, kink_ref_deg, pairing, dist_cand_px, dist_ref_px,
    pass, reason?
    """
    import math
    x_min, y_min, x_max, y_max = bbox
    bw = max(1, x_max - x_min)
    bh = max(1, y_max - y_min)
    min_cps = endpoint_skip + window

    def _detect_for_pair(a_rel, b_rel):
        if len(a_rel) < 2 or len(b_rel) < 2:
            return None
        a_rs = _arc_length_resample(a_rel, n_resample)
        b_rs = _arc_length_resample(b_rel, n_resample)
        a_px = [(x_min + rx * bw, y_min + ry * bh) for rx, ry in a_rs]
        b_px = [(x_min + rx * bw, y_min + ry * bh) for rx, ry in b_rs]
        if len(a_px) < min_cps or len(b_px) < min_cps:
            return None
        pairings = [
            ("first", "first", a_px[0], b_px[0], True, True),
            ("first", "last", a_px[0], b_px[-1], True, False),
            ("last", "first", a_px[-1], b_px[0], False, True),
            ("last", "last", a_px[-1], b_px[-1], False, False),
        ]
        best = min(pairings,
                    key=lambda p: math.hypot(p[2][0] - p[3][0],
                                              p[2][1] - p[3][1]))
        la, lb, ea, eb, a_first, b_first = best
        dist = math.hypot(ea[0] - eb[0], ea[1] - eb[1])
        if dist > epsilon_px:
            return None
        return {
            "pairing": f"{la}/{lb}",
            "dist_px": dist,
            "a_px": a_px, "b_px": b_px,
            "a_first": a_first, "b_first": b_first,
        }

    cand_det = _detect_for_pair(cand_a_rel, cand_b_rel)
    ref_det = _detect_for_pair(ref_a_rel, ref_b_rel)
    if cand_det is None and ref_det is None:
        return {
            "kink_drift_deg": None,
            "kink_cand_deg": None, "kink_ref_deg": None,
            "pairing": None,
            "dist_cand_px": None, "dist_ref_px": None,
            "pass": True,
            "reason": "no_junction",
        }
    if cand_det is None or ref_det is None:
        return {
            "kink_drift_deg": None,
            "kink_cand_deg": None, "kink_ref_deg": None,
            "pairing": (ref_det or cand_det)["pairing"],
            "dist_cand_px": cand_det["dist_px"] if cand_det else None,
            "dist_ref_px": ref_det["dist_px"] if ref_det else None,
            "pass": True,
            "reason": "junction_detection_mismatch_between_rounds",
        }

    def _kink_for(det):
        t_a = _stroke_tangent_at_endpoint(det["a_px"], det["a_first"])
        t_b = _stroke_tangent_at_endpoint(det["b_px"], det["b_first"])
        return _kink_deg(t_a, t_b)

    kink_cand = _kink_for(cand_det)
    kink_ref = _kink_for(ref_det)
    if kink_cand is None or kink_ref is None:
        return {
            "kink_drift_deg": None,
            "kink_cand_deg": kink_cand, "kink_ref_deg": kink_ref,
            "pairing": ref_det["pairing"],
            "dist_cand_px": cand_det["dist_px"],
            "dist_ref_px": ref_det["dist_px"],
            "pass": True,
            "reason": "insufficient_measured_points",
        }
    # Drift metric: absolute. Signed-drift variant could distinguish
    # polish that flattens vs sharpens junctions; not used here pending
    # calibration evidence of asymmetric polish behavior.
    drift = abs(kink_cand - kink_ref)
    return {
        "kink_drift_deg": drift,
        "kink_cand_deg": kink_cand,
        "kink_ref_deg": kink_ref,
        "pairing": ref_det["pairing"],
        "dist_cand_px": cand_det["dist_px"],
        "dist_ref_px": ref_det["dist_px"],
        "pass": drift <= threshold_deg,
    }


def gate_g4(candidate_strokes_rel: list[list[tuple[float, float]]],
             reference_strokes_rel: list[list[tuple[float, float]]],
             bbox: tuple[int, int, int, int],
             threshold: float) -> dict:
    """Run G4 on a candidate-vs-reference letter pair. Mask-free
    (junction kink is a pure polyline property). Per-junction
    iteration internal; iterates over consecutive stroke-pair
    candidates and skips those that don't form a junction in EITHER
    round (vs vacuous-passing each individually)."""
    per_junction: list[dict] = []
    n_pairs = min(len(candidate_strokes_rel), len(reference_strokes_rel))
    for i in range(n_pairs - 1):
        result = gate_g4_per_junction(
            candidate_strokes_rel[i], candidate_strokes_rel[i + 1],
            reference_strokes_rel[i], reference_strokes_rel[i + 1],
            bbox, threshold)
        # Skip "no_junction" cases entirely from per_junction output —
        # they're not junctions, not vacuous-pass diagnostics worth
        # reporting per-pair. (Surfaced at letter-level via
        # n_pairs_checked vs len(per_junction).)
        if result.get("reason") == "no_junction":
            continue
        result["stroke_i"] = i
        result["stroke_j"] = i + 1
        per_junction.append(result)
    overall_pass = all(j["pass"] for j in per_junction)
    real_drifts = [j["kink_drift_deg"] for j in per_junction
                   if j["kink_drift_deg"] is not None]
    letter_score = max(real_drifts) if real_drifts else None
    # Letter-level classification per g4_design.md G4'.6:
    # - no_pairs: single-stroke letter (< 2 strokes in reference)
    # - no_junctions_detected: multi-stroke letter but zero detected
    #   junctions (potentially anomalous; surface as flag)
    if n_pairs < 2:
        letter_reason = "no_pairs"
    elif not per_junction:
        letter_reason = "no_junctions_detected"
    else:
        letter_reason = None
    return {
        "per_junction": per_junction,
        "letter_score": letter_score,
        "n_strokes_candidate": len(candidate_strokes_rel),
        "n_strokes_reference": len(reference_strokes_rel),
        "n_pairs_checked": max(0, n_pairs - 1),
        "letter_reason": letter_reason,
        "pass": overall_pass,
    }
