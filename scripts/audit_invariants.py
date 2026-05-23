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
