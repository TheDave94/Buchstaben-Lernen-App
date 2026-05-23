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
