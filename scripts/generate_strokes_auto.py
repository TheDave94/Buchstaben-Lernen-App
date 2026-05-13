"""Anchor-spec stroke generator for Primae.

Each letter is authored as a list of `StrokeSpec` dicts where each spec
holds a sequence of pedagogical anchor names. At bake time, anchors
resolve to font-specific pixel positions on the rasterised glyph and a
Dijkstra-on-distance-transform walker synthesises the centerline path
between consecutive anchors. The centerline stays inside the ink and
follows the deepest column of the stroke.

Why anchor specs over hand-authored tuples: anchor names are
font-independent. Adding a second font requires no per-letter tuning —
the bake re-resolves each anchor against the new font's ink. The
medial-axis pipeline had geometry mismatches with pedagogical stroke
decomposition; the polyline-tuple pipeline solved that but required
per-font re-eyeballing. Anchor specs combine the clean pedagogical
decomposition of polylines with deterministic font portability.

The rasteriser also centers the glyph by its **optical outline bbox**
(via fonttools `BoundsPen`) rather than Pillow's layout bbox (which
includes asymmetric side bearings). This matches iPad's
`CTFontGetBoundingRectsForGlyphs` placement and prevents the
side-bearing drift that shifted glyphs 5–16 px between Python and iPad
in the polyline-era bake.

Pipeline per letter:

  1. Rasterise the glyph, centering by optical bbox so the ink mask is
     positioned where iPad will render it. Compute the path bbox.
  2. Resolve every anchor name in the spec to a (col, row) raster
     pixel. Anchor resolution rules — see `ANCHOR_RESOLVERS`.
  3. Compute the Euclidean distance transform of the ink mask once.
  4. For each consecutive anchor pair: Dijkstra shortest path with
     edge weight = step_length / (dt[pixel] + 1). Deep-ink pixels are
     cheaper, so the path tracks the medial axis.
  5. Concatenate per-segment paths into one stroke pixel chain.
  6. Resample uniformly to `CHECKPOINT_COUNT`; convert to bbox-relative.
  7. Skeleton = deduplicated union of all stroke pixels; skeletonAdj =
     8-connected adjacency on those pixels.
  8. Emit strokes.json — schema unchanged from the medial-axis era.

Anchor name vocabulary (font-independent):

  TL TR BL BR     bbox corners; step from corner toward ink centroid
                  until hitting an ink pixel.
  T B             topmost / bottommost ink pixel anywhere in the
                  glyph; ties broken by proximity to bbox x-center.
  TC BC           column-wise top / bottom extremum closest to bbox
                  x-center. Picks a local feature (M's valley, V's
                  apex, W's top peak) instead of an absolute extremum
                  that lands on a corner / serif.
  ML MR           midline left / right — ink pixel at the bbox y-center
                  row, leftmost / rightmost.
  LEFT_MID        leftmost ink pixel, vertically centered (closest y to
                  bbox y-center).
  RIGHT_MID       rightmost ink pixel, vertically centered.
  UPPER_TOUCH     upper / lower contact points where a bowl meets a
  LOWER_TOUCH     stem (b, p, d, q, etc.). Resolved by skeletonising
                  the ink, finding degree-≥3 junction clusters in the
                  left third of bbox, then sorting by y.

If an anchor doesn't resolve (e.g. `UPPER_TOUCH` on `N`), the bake
raises a `ValueError` naming the offending letter / spec / anchor.

Usage:
    pip install Pillow numpy scipy scikit-image fonttools
    python scripts/generate_strokes_auto.py            # all authored
    python scripts/generate_strokes_auto.py N V M      # subset
    python scripts/generate_strokes_auto.py --debug N  # save PNG
"""
from __future__ import annotations

import argparse
import hashlib
import heapq
import json
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from fontTools.pens.boundsPen import BoundsPen
from fontTools.ttLib import TTFont
from scipy.ndimage import distance_transform_edt
import skimage.morphology as morph

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_FONT = REPO_ROOT / "design-system/fonts/Primae-Regular.otf"
OUTPUT_BASE = REPO_ROOT / "PrimaeNative/Resources/Letters"

SIZE = 1024
PAD = 0.10
DEFAULT_RADIUS = 0.05
CHECKPOINT_COUNT = 40

NEIGHBOURS_8 = ((-1, -1), (-1, 0), (-1, 1),
                ( 0, -1),          ( 0, 1),
                ( 1, -1), ( 1, 0), ( 1, 1))

LOWERCASE_SUFFIX = "_l"


# -----------------------------------------------------------------------------
# Hand-authored stroke decompositions
# -----------------------------------------------------------------------------
#
# Two stroke formats coexist:
#
#   {"kind": "line", "anchors": [...]}   straight Bresenham polyline through
#                                         the resolved anchors. Phase 1: used
#                                         for N/V/M/W. Anchors land on the
#                                         visual corner (no tip extension);
#                                         the pen-stroke is a chord, no ink
#                                         traversal.
#
#   {"path": [...]}                       Dijkstra-on-DT centerline through
#                                         the ink. Used for curved strokes
#                                         where straight chords would cut
#                                         whitespace (b's bowl). Tip-anchor
#                                         entries get DT-gradient extension
#                                         before routing.
#
# Anchor names are font-independent — adding a new font requires zero per-
# letter tweaking. The bake aborts with an explicit error if any anchor fails
# to resolve (e.g. `UPPER_TOUCH` on a letter without a closed bowl).

StrokeSpec = dict  # {"kind": "line", "anchors": [...]} | {"path": [...]}

LETTERS: dict[str, list[StrokeSpec]] = {
    "N": [
        {"kind": "line", "anchors": ["BL", "TL", "BR", "TR"]},
    ],
    "V": [
        {"kind": "line", "anchors": ["TL", "BC", "TR"]},
    ],
    "M": [
        {"kind": "line", "anchors": ["BL", "TL", "BC", "TR", "BR"]},
    ],
    "W": [
        {"kind": "line", "anchors": ["TL", "BL", "TC", "BR", "TR"]},
    ],
    "b": [
        {"path": ["T", "LOWER_TOUCH"]},
        {"path": ["UPPER_TOUCH", "RIGHT_MID", "LOWER_TOUCH"]},
    ],
}

ALL_LETTERS = tuple(LETTERS.keys())


# -----------------------------------------------------------------------------
# Font geometry: optical outline bbox via fonttools
# -----------------------------------------------------------------------------

_TT_CACHE: dict[str, TTFont] = {}


def _tt(font_path: Path) -> TTFont:
    """Load and memoise a TTFont. The bake opens the same font dozens of
    times across letters; cold-load is ~80 ms on Primae-Regular."""
    key = str(font_path)
    if key not in _TT_CACHE:
        _TT_CACHE[key] = TTFont(str(font_path))
    return _TT_CACHE[key]


def optical_bbox_font_units(letter: str, font_path: Path
                            ) -> tuple[float, float, float, float]:
    """Return the glyph's optical outline bbox `(x_min, y_min, x_max,
    y_max)` in font units, baseline-anchored (y increases upward). Uses
    fonttools' `BoundsPen` which samples Bezier curves to get the tight
    outline rect — matching CoreText's `CTFontGetBoundingRectsForGlyphs`
    with `.default` orientation."""
    tt = _tt(font_path)
    cmap = tt.getBestCmap()
    if ord(letter) not in cmap:
        raise ValueError(f"No glyph for {letter!r} in font")
    glyph_set = tt.getGlyphSet()
    glyph = glyph_set[cmap[ord(letter)]]
    pen = BoundsPen(glyph_set)
    glyph.draw(pen)
    if pen.bounds is None:
        raise ValueError(f"Empty outline for {letter!r}")
    return pen.bounds


# -----------------------------------------------------------------------------
# Rasterisation
# -----------------------------------------------------------------------------

def rasterize(letter: str, font_path: Path,
              features: list[str] | None = None) -> np.ndarray:
    """Render `letter` to a SIZE×SIZE binary mask. The glyph is centered
    horizontally by its **optical outline bbox** (via fonttools), not by
    Pillow's `font.getbbox` layout bbox — matching iPad's
    `CTFontGetBoundingRectsForGlyphs` placement so the rendered ink
    lands at the same canvas position on both sides. Asymmetric side
    bearings would otherwise shift the optical glyph by 5–16 px between
    Python and iPad."""
    avail = int(SIZE * (1 - 2 * PAD))
    probe_size = 1000
    probe = ImageFont.truetype(str(font_path), probe_size)
    probe_ascent, probe_descent = probe.getmetrics()
    em = probe_ascent + probe_descent
    if em <= 0:
        raise ValueError(f"Bad font metrics for {letter!r}")
    target_size = int(round(probe_size * avail / em))
    font = ImageFont.truetype(str(font_path), target_size)
    ascent, _ = font.getmetrics()

    tt = _tt(font_path)
    units_per_em = tt['head'].unitsPerEm
    gx_min, gy_min, gx_max, gy_max = optical_bbox_font_units(letter, font_path)
    scale = target_size / units_per_em
    optical_w_pixels = (gx_max - gx_min) * scale
    optical_left_canvas = (SIZE - optical_w_pixels) / 2

    # Pillow's text() with anchor "ls" places the text at the given
    # (x, baseline_y) with x being the LEFT SIDE BEARING start. The
    # optical outline starts at x + gx_min*scale. To land the optical
    # outline's left at `optical_left_canvas`, set x = canvas_left -
    # gx_min*scale.
    x = int(round(optical_left_canvas - gx_min * scale))
    baseline_y = int(SIZE * PAD + ascent)
    img = Image.new("L", (SIZE, SIZE), 255)
    text_kwargs = {"font": font, "fill": 0, "anchor": "ls"}
    if features:
        text_kwargs["features"] = features
    ImageDraw.Draw(img).text((x, baseline_y), letter, **text_kwargs)
    return np.array(img) < 128


def bbox_from_mask(mask: np.ndarray) -> tuple[int, int, int, int]:
    """Return the rendered glyph's bbox `(x_min, y_min, x_max, y_max)`
    in raster coords. After `rasterize` centers by optical outline this
    is the optical-bbox itself (rounded to pixel grid)."""
    rows, cols = np.where(mask)
    if rows.size == 0:
        raise ValueError("Empty ink mask")
    return (int(cols.min()), int(rows.min()),
            int(cols.max()), int(rows.max()))


# -----------------------------------------------------------------------------
# Coordinate conversion
# -----------------------------------------------------------------------------

def pixel_to_rel(p: tuple[int, int],
                 bbox: tuple[int, int, int, int]) -> tuple[float, float]:
    """Raster `(col, row)` → bbox-relative `(rx, ry)` in [0, 1]."""
    x_min, y_min, x_max, y_max = bbox
    bw = max(1, x_max - x_min)
    bh = max(1, y_max - y_min)
    return ((p[0] - x_min) / bw, (p[1] - y_min) / bh)


# -----------------------------------------------------------------------------
# Anchor resolution
# -----------------------------------------------------------------------------

def _ink_centroid(mask: np.ndarray) -> tuple[float, float]:
    """Return the (col, row) centroid of all ink pixels."""
    rows, cols = np.where(mask)
    return float(cols.mean()), float(rows.mean())


def _corner_anchor(mask: np.ndarray, bbox: tuple[int, int, int, int],
                   name: str) -> tuple[int, int]:
    """Resolve a corner anchor by finding the extremal ink in the
    corresponding quadrant: TL → topmost-then-leftmost ink in the
    top-left half-by-half region of bbox, etc. This gives the corner
    proper for letters that fill the corner (N, M) and the natural
    "first valley" for letters whose corner quadrant ink stops short
    of the bbox corner (W's BL valley is the bottommost ink in the
    bottom-left quadrant, NOT the bbox-corner-stepped ray)."""
    x_min, y_min, x_max, y_max = bbox
    bw, bh = x_max - x_min, y_max - y_min
    if name in {"TL", "BL"}:
        x_lo, x_hi = x_min, x_min + bw // 2
        left = True
    else:
        x_lo, x_hi = x_max - bw // 2, x_max
        left = False
    if name in {"TL", "TR"}:
        y_lo, y_hi = y_min, y_min + bh // 2
        top = True
    else:
        y_lo, y_hi = y_max - bh // 2, y_max
        top = False
    rows, cols = np.where(mask)
    band = ((cols >= x_lo) & (cols <= x_hi)
            & (rows >= y_lo) & (rows <= y_hi))
    if not band.any():
        # Fallback: nearest ink to the actual bbox corner.
        corner_x = x_min if left else x_max
        corner_y = y_min if top else y_max
        d = np.hypot(cols - corner_x, rows - corner_y)
        idx = int(np.argmin(d))
        return int(cols[idx]), int(rows[idx])
    bcols, brows = cols[band], rows[band]
    target_row = int(brows.min()) if top else int(brows.max())
    candidate_cols = bcols[brows == target_row]
    idx = (int(np.argmin(candidate_cols)) if left
           else int(np.argmax(candidate_cols)))
    return int(candidate_cols[idx]), target_row


def _topmost_or_bottommost(mask: np.ndarray,
                           bbox: tuple[int, int, int, int],
                           top: bool) -> tuple[int, int]:
    """Topmost (or bottommost) ink pixel; ties broken by proximity to
    bbox x-center. Used by T / B."""
    rows, cols = np.where(mask)
    target_row = int(rows.min()) if top else int(rows.max())
    candidate_cols = cols[rows == target_row]
    cx = (bbox[0] + bbox[2]) / 2
    idx = int(np.argmin(np.abs(candidate_cols - cx)))
    return int(candidate_cols[idx]), target_row


def _column_extremum_near_center(mask: np.ndarray,
                                 bbox: tuple[int, int, int, int],
                                 top: bool, window: int = 8
                                 ) -> tuple[int, int]:
    """For each ink column, build the topmost-row (top=True) or
    bottommost-row (top=False) profile, then return the column with a
    local extremum closest to bbox x-center. Used by TC / BC where the
    pedagogical anchor sits on a central feature (M's valley, V's apex,
    W's top peak) — the absolute extremum row would land on a
    corner / serif instead. `window` is the half-width (in columns) of
    the local-extremum neighbourhood."""
    x_min, _, x_max, _ = bbox
    cx = (x_min + x_max) / 2
    h, w = mask.shape
    rows, cols = np.where(mask)
    if rows.size == 0:
        raise ValueError("No ink")
    sentinel = h if top else -1
    profile = np.full(w, sentinel, dtype=np.int64)
    for c, r in zip(cols.tolist(), rows.tolist()):
        if top:
            if r < profile[c]:
                profile[c] = r
        else:
            if r > profile[c]:
                profile[c] = r
    valid_cols = np.where(profile != sentinel)[0]
    extrema: list[tuple[int, int]] = []
    for c in valid_cols:
        p = profile[c]
        is_extremum = True
        for dc in range(-window, window + 1):
            if dc == 0:
                continue
            nc = c + dc
            if 0 <= nc < w and profile[nc] != sentinel:
                if (top and profile[nc] < p) or (not top and profile[nc] > p):
                    is_extremum = False
                    break
        if is_extremum:
            extrema.append((int(c), int(p)))
    if not extrema:
        idx = (int(np.argmin(profile[valid_cols])) if top
               else int(np.argmax(profile[valid_cols])))
        c = int(valid_cols[idx])
        return c, int(profile[c])
    extrema.sort(key=lambda e: abs(e[0] - cx))
    return extrema[0]


def _midline_extremum(mask: np.ndarray, bbox: tuple[int, int, int, int],
                      side: str) -> tuple[int, int]:
    """Leftmost (or rightmost) ink pixel at the bbox y-center row. Used
    by ML / MR. Falls back to a 10-row band when the exact center row
    has no ink (e.g. open shapes where the midline crosses interior)."""
    x_min, y_min, x_max, y_max = bbox
    cy = int(round((y_min + y_max) / 2))
    h, _w = mask.shape
    if 0 <= cy < h:
        cols = np.where(mask[cy])[0]
        if cols.size:
            target = int(cols.min()) if side == "left" else int(cols.max())
            return target, cy
    rows, cols = np.where(mask)
    band = np.abs(rows - cy) <= 10
    if not band.any():
        raise ValueError(f"No ink within ±10 rows of bbox y-center {cy}")
    bcols, brows = cols[band], rows[band]
    idx = int(np.argmin(bcols) if side == "left" else np.argmax(bcols))
    return int(bcols[idx]), int(brows[idx])


def _x_extreme_centered(mask: np.ndarray,
                        bbox: tuple[int, int, int, int],
                        side: str) -> tuple[int, int]:
    """Extremal ink pixel at the bbox x-extreme, vertically centered.
    Used by LEFT_MID / RIGHT_MID."""
    rows, cols = np.where(mask)
    x_target = int(cols.max()) if side == "right" else int(cols.min())
    candidate_rows = rows[cols == x_target]
    cy = (bbox[1] + bbox[3]) / 2
    idx = int(np.argmin(np.abs(candidate_rows - cy)))
    return x_target, int(candidate_rows[idx])


def _cluster_pixels(pts: list[tuple[int, int]], radius: int
                    ) -> list[list[tuple[int, int]]]:
    """Cluster pixels into 8-radius-connected groups."""
    visited: set[tuple[int, int]] = set()
    out: list[list[tuple[int, int]]] = []
    pts_set = set(pts)
    for p in pts:
        if p in visited:
            continue
        cluster = []
        stack = [p]
        while stack:
            cur = stack.pop()
            if cur in visited:
                continue
            visited.add(cur)
            cluster.append(cur)
            for other in pts_set:
                if other in visited:
                    continue
                if (abs(other[0] - cur[0]) <= radius
                        and abs(other[1] - cur[1]) <= radius):
                    stack.append(other)
        out.append(cluster)
    return out


def _row_ink_runs(mask: np.ndarray, y: int) -> list[tuple[int, int]]:
    """Return inclusive `(col_start, col_end)` runs of contiguous ink
    pixels in row `y` (gaps of ≥2 separate runs)."""
    cols = np.where(mask[y])[0]
    if cols.size == 0:
        return []
    diffs = np.diff(cols)
    starts = [0] + (np.where(diffs > 1)[0] + 1).tolist()
    runs: list[tuple[int, int]] = []
    for i, s in enumerate(starts):
        e = starts[i + 1] if i + 1 < len(starts) else len(cols)
        runs.append((int(cols[s]), int(cols[e - 1])))
    return runs


def _bowl_stem_touch(mask: np.ndarray, bbox: tuple[int, int, int, int],
                     upper: bool) -> tuple[int, int]:
    """Resolve UPPER_TOUCH / LOWER_TOUCH by scanning rows top-to-bottom
    for the y where two horizontal ink runs merge into one. For a bowl
    attached to a stem (b, p, d, q), the stem and bowl-left wall are
    separate runs in the bowl interior region, and merge at two rows:
    the upper touch (above the bowl, where 3 runs collapse to 2 or 2
    collapse to 1) and the lower touch (below the bowl, 2→1). The
    touch column is the midpoint of the closing gap measured one row
    above the merge — the bowl medial-axis collapses this to a single
    junction, but the run-count signal preserves both touches."""
    y_min, y_max = bbox[1], bbox[3]
    transitions: list[tuple[int, list[tuple[int, int]], list[tuple[int, int]]]] = []
    prev = _row_ink_runs(mask, y_min)
    for y in range(y_min + 1, y_max + 1):
        runs = _row_ink_runs(mask, y)
        if len(runs) != len(prev):
            transitions.append((y, prev, runs))
        prev = runs

    if upper:
        candidates = [t for t in transitions
                      if len(t[1]) > len(t[2]) and len(t[1]) >= 2]
        if not candidates:
            raise ValueError("UPPER_TOUCH: no run-count merge transition")
        merge_y, before, _ = candidates[0]
    else:
        candidates = [t for t in transitions
                      if len(t[1]) >= 2 and len(t[2]) == 1]
        if not candidates:
            raise ValueError("LOWER_TOUCH: no merge-to-1 transition")
        merge_y, before, _ = candidates[-1]

    if len(before) < 2:
        raise ValueError(f"Touch row {merge_y}: pre-merge had <2 runs")
    run0_right = before[0][1]
    run1_left = before[1][0]
    col = (run0_right + run1_left) // 2
    if not bool(mask[merge_y, col]):
        # Fall back to the nearest ink pixel in the merge row.
        cols = np.where(mask[merge_y])[0]
        if cols.size == 0:
            raise ValueError(f"Touch row {merge_y} has no ink")
        idx = int(np.argmin(np.abs(cols - col)))
        col = int(cols[idx])
    return col, merge_y


# Tip-like anchors sit at the geometric extremum of a stroke and a raw
# Dijkstra path starting there picks up a "hook" along the apex curl.
# Walking inward along the DT gradient before routing lands the anchor
# on the stroke's centerline body. Interior anchors (ML / MR / *_MID /
# *_TOUCH) already sit on the centerline and must not be perturbed.
TIP_ANCHORS = frozenset({"TL", "TR", "BL", "BR", "T", "B", "TC", "BC"})


def extend_tip_inward(pixel: tuple[int, int], dt: np.ndarray,
                      mask: np.ndarray, max_steps: int = 8
                      ) -> tuple[int, int]:
    """Walk from a tip anchor inward along the DT gradient until the
    gradient stabilises (best step Δ < 1.0) or `max_steps` is hit. The
    result sits on the stroke's centerline body rather than at the
    geometric tip — eliminates the apex-curl hooks Dijkstra otherwise
    picks up when routing from a corner pixel.

    Superseded by `snap_to_medial_axis` for line-kind anchors (clean
    centerline lookup with no DT-gradient drift). Still used in the
    curve / legacy path-kind branch where the tip needs to sit on the
    Dijkstra-routable ink body; kept in case we ever need to revert."""
    col, row = pixel
    h, w = mask.shape
    for _ in range(max_steps):
        best_delta = 0.0
        best_n: tuple[int, int] | None = None
        cur_dt = float(dt[row, col])
        for dr, dc in NEIGHBOURS_8:
            nc, nr = col + dc, row + dr
            if not (0 <= nr < h and 0 <= nc < w):
                continue
            if not mask[nr, nc]:
                continue
            delta = float(dt[nr, nc]) - cur_dt
            if delta > best_delta:
                best_delta = delta
                best_n = (nc, nr)
        if best_n is None or best_delta < 1.0:
            break
        col, row = best_n
    return col, row


def resolve_anchor(name: str, mask: np.ndarray,
                   bbox: tuple[int, int, int, int],
                   dt: np.ndarray | None = None) -> tuple[int, int]:
    """Dispatch to the appropriate resolver, then walk tip-like anchors
    inward along the DT gradient when `dt` is supplied. Raises
    `KeyError` on an unknown name, `ValueError` on a resolution failure
    (e.g. `UPPER_TOUCH` on a non-bowl letter)."""
    if name in {"TL", "TR", "BL", "BR"}:
        pos = _corner_anchor(mask, bbox, name)
    elif name == "T":
        pos = _topmost_or_bottommost(mask, bbox, top=True)
    elif name == "B":
        pos = _topmost_or_bottommost(mask, bbox, top=False)
    elif name == "TC":
        pos = _column_extremum_near_center(mask, bbox, top=True)
    elif name == "BC":
        pos = _column_extremum_near_center(mask, bbox, top=False)
    elif name == "ML":
        pos = _midline_extremum(mask, bbox, "left")
    elif name == "MR":
        pos = _midline_extremum(mask, bbox, "right")
    elif name == "LEFT_MID":
        pos = _x_extreme_centered(mask, bbox, "left")
    elif name == "RIGHT_MID":
        pos = _x_extreme_centered(mask, bbox, "right")
    elif name == "UPPER_TOUCH":
        pos = _bowl_stem_touch(mask, bbox, upper=True)
    elif name == "LOWER_TOUCH":
        pos = _bowl_stem_touch(mask, bbox, upper=False)
    else:
        raise KeyError(f"Unknown anchor name: {name!r}")
    if dt is not None and name in TIP_ANCHORS:
        pos = extend_tip_inward(pos, dt, mask)
    return pos


# -----------------------------------------------------------------------------
# Centerline path synthesis
# -----------------------------------------------------------------------------

def line_sampler(anchors: list[tuple[int, int]],
                 spacing: float = 1.0) -> list[tuple[int, int]]:
    """Linearly interpolate along the polyline through `anchors`,
    sampling at `spacing`-pixel arc-length intervals. Returns a list
    of integer `(col, row)` pixels with both endpoints included
    exactly; output format matches `centerline_path` so downstream
    serialisation is identical."""
    if len(anchors) < 2:
        return [(int(round(a[0])), int(round(a[1]))) for a in anchors]
    points: list[tuple[int, int]] = []
    for i in range(len(anchors) - 1):
        a = anchors[i]
        b = anchors[i + 1]
        dx = b[0] - a[0]
        dy = b[1] - a[1]
        length = math.hypot(dx, dy)
        if length < 1e-9:
            if i == 0:
                points.append((int(round(a[0])), int(round(a[1]))))
            continue
        n_steps = max(1, int(round(length / spacing)))
        start_k = 0 if i == 0 else 1  # skip the joint (= prev segment's end)
        for k in range(start_k, n_steps + 1):
            t = k / n_steps
            points.append((int(round(a[0] + t * dx)),
                           int(round(a[1] + t * dy))))
    return points


def fillet_arc(p_prev: tuple[float, float],
               p_joint: tuple[float, float],
               p_next: tuple[float, float],
               radius: float) -> list[tuple[float, float]]:
    """Sample the circular fillet arc that rounds the corner at
    `p_joint`, tangent to segments `p_prev→p_joint` and `p_joint→p_next`
    with the given `radius`. Returns the arc as a list of `(x, y)`
    floats sampled at ~1 px arc-length spacing, with both tangent points
    included exactly as the first and last elements. Returns `[p_joint]`
    on a near-straight (≈π) or degenerate (≈0) corner."""
    jx, jy = float(p_joint[0]), float(p_joint[1])
    v1 = (float(p_prev[0]) - jx, float(p_prev[1]) - jy)
    v2 = (float(p_next[0]) - jx, float(p_next[1]) - jy)
    L1 = math.hypot(v1[0], v1[1])
    L2 = math.hypot(v2[0], v2[1])
    if L1 < 1e-9 or L2 < 1e-9:
        return [(jx, jy)]
    u1 = (v1[0] / L1, v1[1] / L1)
    u2 = (v2[0] / L2, v2[1] / L2)
    cos_full = max(-1.0, min(1.0, u1[0] * u2[0] + u1[1] * u2[1]))
    full_angle = math.acos(cos_full)
    if full_angle > math.pi - 1e-3:
        return [(jx, jy)]
    if full_angle < 1e-3:
        print(f"  warning: fillet_arc fold-back at ({jx:.1f}, {jy:.1f}); "
              f"leaving joint sharp")
        return [(jx, jy)]

    half_angle = full_angle / 2.0
    tan_dist = radius / math.tan(half_angle)
    center_dist = radius / math.sin(half_angle)

    t_prev = (jx + u1[0] * tan_dist, jy + u1[1] * tan_dist)
    t_next = (jx + u2[0] * tan_dist, jy + u2[1] * tan_dist)

    bx = u1[0] + u2[0]
    by = u1[1] + u2[1]
    bl = math.hypot(bx, by)
    if bl < 1e-9:
        return [(jx, jy)]
    bx /= bl; by /= bl
    cx = jx + bx * center_dist
    cy = jy + by * center_dist

    a_start = math.atan2(t_prev[1] - cy, t_prev[0] - cx)
    a_end = math.atan2(t_next[1] - cy, t_next[0] - cx)
    sweep = a_end - a_start
    # Normalise sweep to [-π, π] so we always take the short arc between
    # the two tangent points (sweep magnitude = π - full_angle).
    while sweep > math.pi:
        sweep -= 2.0 * math.pi
    while sweep < -math.pi:
        sweep += 2.0 * math.pi

    n_samples = max(2, int(round(abs(sweep) * radius)))
    out: list[tuple[float, float]] = []
    for k in range(n_samples + 1):
        t = k / n_samples
        a = a_start + sweep * t
        out.append((cx + math.cos(a) * radius, cy + math.sin(a) * radius))
    return out


def polyline_with_filleted_joints(
        positions: list[tuple[float, float]],
        radii: list[float]) -> list[tuple[int, int]]:
    """Build a 1-px-spaced integer polyline through `positions`, with
    each interior joint replaced by a tangent circular arc whose radius
    is taken from `radii` (which must have `len(positions) - 2` entries,
    one per interior joint). Straight portions are line-sampled; arcs
    arrive pre-sampled at ~1 px from `fillet_arc`.

    With anchors at the glyph's visible outer corners (Phase 2.1), the
    inscribed fillet at each interior joint places its arc right at the
    corner's rounded outline — radius = local stroke half-width matches
    Prima's outer-corner rounding radius.

    Per-joint radius is capped down so each tangent point sits at most
    45 % of the way along its adjoining segment — prevents an arc from
    swallowing an entire short segment when the chord runs are tight
    (e.g. M's narrow valley). A capping event prints an info line. A
    joint with radius 0 / degenerate geometry stays sharp."""
    n = len(positions)
    if n < 2:
        return [(int(round(p[0])), int(round(p[1]))) for p in positions]
    if n == 2:
        return line_sampler(
            [(int(round(p[0])), int(round(p[1]))) for p in positions])

    arcs: list[list[tuple[float, float]] | None] = []
    for i in range(1, n - 1):
        p_prev = positions[i - 1]
        p_joint = positions[i]
        p_next = positions[i + 1]
        r = radii[i - 1]
        if r <= 0.0:
            print(f"  warning: radius=0 at joint {i} {p_joint} — sharp vertex")
            arcs.append(None)
            continue
        v1 = (p_prev[0] - p_joint[0], p_prev[1] - p_joint[1])
        v2 = (p_next[0] - p_joint[0], p_next[1] - p_joint[1])
        L1 = math.hypot(v1[0], v1[1]); L2 = math.hypot(v2[0], v2[1])
        if L1 < 1e-9 or L2 < 1e-9:
            arcs.append(None)
            continue
        cos_full = max(-1.0, min(1.0,
                                  (v1[0] * v2[0] + v1[1] * v2[1]) / (L1 * L2)))
        full_angle = math.acos(cos_full)
        if full_angle > math.pi - 1e-3 or full_angle < 1e-3:
            arcs.append(None)
            continue
        half_angle = full_angle / 2.0
        tan_dist = r / math.tan(half_angle)
        max_tan_dist = 0.45 * min(L1, L2)
        if tan_dist > max_tan_dist:
            new_r = max_tan_dist * math.tan(half_angle)
            print(f"  info: joint {i} radius capped {r:.1f}→{new_r:.1f}")
            r = new_r
        arc = fillet_arc(p_prev, p_joint, p_next, r)
        arcs.append(arc if len(arc) >= 2 else None)

    out: list[tuple[int, int]] = []

    def append_line(p: tuple[float, float], q: tuple[float, float]) -> None:
        p_int = (int(round(p[0])), int(round(p[1])))
        q_int = (int(round(q[0])), int(round(q[1])))
        if p_int == q_int:
            if not out:
                out.append(p_int)
            return
        pts = line_sampler([p_int, q_int])
        start = 1 if out and out[-1] == pts[0] else 0
        out.extend(pts[start:])

    def append_arc(arc: list[tuple[float, float]]) -> None:
        pts = [(int(round(p[0])), int(round(p[1]))) for p in arc]
        start = 1 if out and out[-1] == pts[0] else 0
        out.extend(pts[start:])

    for i in range(n - 1):
        seg_start = (positions[0] if i == 0
                     else (arcs[i - 1][-1] if arcs[i - 1] is not None
                           else positions[i]))
        seg_end = (positions[-1] if i == n - 2
                   else (arcs[i][0] if arcs[i] is not None
                         else positions[i + 1]))
        append_line(seg_start, seg_end)
        if i < n - 2:
            arc = arcs[i]
            if arc is None:
                v = positions[i + 1]
                v_int = (int(round(v[0])), int(round(v[1])))
                if not out or out[-1] != v_int:
                    out.append(v_int)
            else:
                append_arc(arc)
    return out


def snap_to_medial_axis(point: tuple[int, int], mask: np.ndarray,
                        dt: np.ndarray, skeleton: np.ndarray,
                        letter: str = "?",
                        anchor_name: str = "?") -> tuple[int, int]:
    """Snap a boundary-resolved anchor onto the nearest medial-axis
    pixel. Used as a centerline-positioning lookup only — the medial
    axis is NOT traversed (that pipeline produced Y-bifurcation
    artefacts at junctions). Walking from outer boundary to centerline
    here is fine because we only consume the destination pixel.

    Search radius scales with the local stroke half-width (1.5× the max
    DT in a 60×60 window around the point, floor 15 px). If no skeleton
    pixel lies within radius, returns `point` unchanged and emits a
    warning naming `letter` / `anchor_name` so the caller's PNG review
    can spot the unsnapped anchor."""
    col, row = int(round(point[0])), int(round(point[1]))
    h, w = mask.shape

    r0 = max(0, row - 30); r1 = min(h, row + 31)
    c0 = max(0, col - 30); c1 = min(w, col + 31)
    if r1 <= r0 or c1 <= c0:
        local_max_dt = 0.0
    else:
        local_max_dt = float(dt[r0:r1, c0:c1].max())
    radius = max(15, int(round(local_max_dt * 1.5)))

    rr0 = max(0, row - radius); rr1 = min(h, row + radius + 1)
    cc0 = max(0, col - radius); cc1 = min(w, col + radius + 1)
    region = skeleton[rr0:rr1, cc0:cc1]
    sk_rows, sk_cols = np.where(region)
    if sk_rows.size == 0:
        print(f"  warning: {letter}/{anchor_name} at {point} — no "
              f"medial-axis pixel within {radius} px "
              f"(local max DT {local_max_dt:.1f}); leaving unsnapped")
        return col, row
    abs_rows = sk_rows + rr0
    abs_cols = sk_cols + cc0
    dx = abs_cols - col
    dy = abs_rows - row
    d2 = dx * dx + dy * dy
    within = d2 <= radius * radius
    if not np.any(within):
        print(f"  warning: {letter}/{anchor_name} at {point} — no "
              f"medial-axis pixel within {radius} px "
              f"(local max DT {local_max_dt:.1f}); leaving unsnapped")
        return col, row
    abs_rows = abs_rows[within]; abs_cols = abs_cols[within]
    d2 = d2[within]
    min_d2 = d2.min()
    # Tie-break by (y, x) for determinism across font / library updates.
    candidates = np.where(d2 == min_d2)[0]
    order = sorted(candidates.tolist(),
                   key=lambda i: (int(abs_rows[i]), int(abs_cols[i])))
    pick = order[0]
    return int(abs_cols[pick]), int(abs_rows[pick])


def extend_to_boundary(point: tuple[int, int],
                       direction: tuple[float, float],
                       mask: np.ndarray,
                       dt: np.ndarray,
                       max_steps: int = 200,
                       letter: str = "?",
                       anchor_name: str = "?") -> tuple[int, int]:
    """Walk outward from `point` along the unit `direction` in 1-px
    steps, then continue one local stroke half-width past the optical
    ink boundary so the returned point lands at the rounded-cap visual
    terminus. iPad draws round caps that extend outside the optical
    glyph bbox by the cap radius (≈ stroke half-width); stopping at the
    last in-ink pixel leaves the trace ~half-stroke-width short of the
    visible cap end. The returned point sits in empty space at the cap
    centerline terminus.

    Superseded — not called by the bake. The centerline-as-polyline
    rendering model already terminates at half-stroke-width inset from
    the visual corner (the gameplay renderer adds the cap). Kept in
    case a future rendering mode (calibrator diagnostic overlay, etc.)
    needs an explicit "extend to cap edge" geometry. Same disposition
    as `extend_tip_inward`.

    `point` must already lie on ink; otherwise returns it unchanged and
    warns naming `letter` / `anchor_name`. If `max_steps` is exhausted
    without exiting the mask, warns and returns the last in-ink pixel
    (indicates the direction never crosses an ink boundary)."""
    col, row = int(round(point[0])), int(round(point[1]))
    h, w = mask.shape
    if not (0 <= row < h and 0 <= col < w and mask[row, col]):
        print(f"  warning: {letter}/{anchor_name} extend_to_boundary "
              f"start {point} not in ink — extension skipped")
        return col, row
    last_in = (col, row)
    last_in_step = 0
    exited_at_step: int | None = None
    for step in range(1, max_steps + 1):
        cf = point[0] + direction[0] * step
        rf = point[1] + direction[1] * step
        c = int(round(cf))
        r = int(round(rf))
        if not (0 <= r < h and 0 <= c < w) or not mask[r, c]:
            exited_at_step = step
            break
        last_in = (c, r)
        last_in_step = step
    if exited_at_step is None:
        print(f"  warning: {letter}/{anchor_name} extend_to_boundary "
              f"hit max_steps={max_steps} without exiting ink "
              f"from {point} dir=({direction[0]:.3f},{direction[1]:.3f})")
        return last_in
    # Compute the cap extension distance from the local stroke half-
    # width at the last in-ink pixel (max DT in a 30×30 window). Project
    # that many additional pixels along `direction` past `last_in`.
    lc, lr = last_in
    r0 = max(0, lr - 15); r1 = min(h, lr + 16)
    c0 = max(0, lc - 15); c1 = min(w, lc + 16)
    cap_extension = 0.0
    if r1 > r0 and c1 > c0:
        cap_extension = float(dt[r0:r1, c0:c1].max())
    if cap_extension <= 0.0:
        return last_in
    final_step = last_in_step + cap_extension
    cf = point[0] + direction[0] * final_step
    rf = point[1] + direction[1] * final_step
    return int(round(cf)), int(round(rf))


def sample_quadratic_bezier(p0: tuple[float, float],
                            c1: tuple[float, float],
                            p2: tuple[float, float]
                            ) -> list[tuple[float, float]]:
    """Sample a quadratic Bezier B(t) = (1−t)² P0 + 2(1−t)t C1 + t² P2
    at ~1 px arc-length spacing. Length estimated by 16 uniform-t
    samples; resampled with N = max(8, ceil(length)) segments. P0
    first, P2 last."""
    def _b(t: float) -> tuple[float, float]:
        u = 1.0 - t
        u2 = u * u; t2 = t * t
        return (u2 * p0[0] + 2.0 * u * t * c1[0] + t2 * p2[0],
                u2 * p0[1] + 2.0 * u * t * c1[1] + t2 * p2[1])
    pts16 = [_b(i / 16.0) for i in range(17)]
    arc_len = sum(math.hypot(pts16[i + 1][0] - pts16[i][0],
                             pts16[i + 1][1] - pts16[i][1])
                  for i in range(16))
    n = max(8, int(math.ceil(arc_len)))
    return [_b(i / n) for i in range(n + 1)]


def sample_cubic_bezier(p0: tuple[float, float],
                        c1: tuple[float, float],
                        c2: tuple[float, float],
                        p3: tuple[float, float]
                        ) -> list[tuple[float, float]]:
    """Sample a cubic Bezier B(t) = (1−t)³ P0 + 3(1−t)²t C1 + 3(1−t)t² C2
    + t³ P3 at ~1 px arc-length spacing. First estimates length via 16
    uniform-t samples, then re-samples with N = ceil(length) segments
    (at least 8). P0 first, P3 last."""
    def _b(t: float) -> tuple[float, float]:
        u = 1.0 - t
        u2 = u * u; u3 = u2 * u
        t2 = t * t; t3 = t2 * t
        return (u3 * p0[0] + 3.0 * u2 * t * c1[0]
                + 3.0 * u * t2 * c2[0] + t3 * p3[0],
                u3 * p0[1] + 3.0 * u2 * t * c1[1]
                + 3.0 * u * t2 * c2[1] + t3 * p3[1])
    pts16 = [_b(i / 16.0) for i in range(17)]
    arc_len = sum(math.hypot(pts16[i + 1][0] - pts16[i][0],
                             pts16[i + 1][1] - pts16[i][1])
                  for i in range(16))
    n = max(8, int(math.ceil(arc_len)))
    return [_b(i / n) for i in range(n + 1)]


def walk_arm_to_plateau(outer: tuple[int, int],
                        target: tuple[int, int],
                        mask: np.ndarray,
                        dt: np.ndarray,
                        max_steps: int = 300) -> tuple[int, int] | None:
    """Sample the chord from `outer` toward `target` at 1-pixel
    intervals, tracking dt at each step. Returns the first position
    where dt reaches 95 % of the walk's running max (smoothed over a
    ±2-step window) — the point where the cap rounding ends and the
    arm's constant-width section begins.

    The chord-from-outer formulation (instead of walking the medial-
    axis graph) keeps each P1/P2 walk inside ONE arm by construction:
    the chord direction toward a specific neighbour anchor stays
    within that arm's band even when the medial axis is locally
    merged at the cap. Returns `None` if the chord is too short, exits
    the ink immediately, or fails to plateau."""
    h, w = mask.shape
    dx = target[0] - outer[0]
    dy = target[1] - outer[1]
    L = math.hypot(dx, dy)
    if L < 1e-9:
        return None
    ux, uy = dx / L, dy / L
    n_steps = min(int(round(L)), max_steps)
    if n_steps < 10:
        return None
    path: list[tuple[int, int]] = []
    dt_values: list[float] = []
    for step in range(n_steps + 1):
        cf = outer[0] + ux * step
        rf = outer[1] + uy * step
        c = int(round(cf)); r = int(round(rf))
        if not (0 <= r < h and 0 <= c < w):
            break
        if not mask[r, c]:
            if step < 3:
                continue  # at the cap boundary, may step off briefly
            break
        path.append((c, r))
        dt_values.append(float(dt[r, c]))
    if len(path) < 5:
        return None
    # Derivative-based knee detection. In the cap rounding region dt
    # rises sharply (~1 px / step). Once the chord crosses into the
    # constant-width arm, dt growth slows abruptly. The cap-to-arm
    # transition is the first step where the smoothed forward delta
    # over a 5-step window drops below SLOPE_THRESHOLD. Pure 95-%-of-
    # max plateau detection misses this because dt keeps drifting up
    # along the arm when the chord direction isn't exactly along the
    # arm's medial axis.
    SLOPE_THRESHOLD = 0.20  # px of dt per px of chord
    WINDOW = 5
    if len(dt_values) <= WINDOW + 2:
        return None
    smoothed_slope: list[float] = []
    for i in range(len(dt_values) - WINDOW):
        smoothed_slope.append((dt_values[i + WINDOW] - dt_values[i]) / WINDOW)
    for k in range(3, len(smoothed_slope)):
        if smoothed_slope[k] < SLOPE_THRESHOLD:
            return path[k]
    return path[-1]


def circle_through_three(p1: tuple[float, float],
                         p2: tuple[float, float],
                         p3: tuple[float, float]
                         ) -> tuple[float, float, float] | None:
    """Solve for the unique circle through three points. Returns
    `(center_x, center_y, radius)` or `None` if the points are
    collinear (determinant ≈ 0)."""
    ax, ay = p1; bx, by = p2; cx, cy = p3
    d = 2.0 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
    if abs(d) < 1e-9:
        return None
    a2 = ax * ax + ay * ay
    b2 = bx * bx + by * by
    c2 = cx * cx + cy * cy
    ux = (a2 * (by - cy) + b2 * (cy - ay) + c2 * (ay - by)) / d
    uy = (a2 * (cx - bx) + b2 * (ax - cx) + c2 * (bx - ax)) / d
    r = math.hypot(ux - ax, uy - ay)
    return (ux, uy, r)


def sample_arc_p1_p3_p2(p1: tuple[float, float],
                        p3: tuple[float, float],
                        p2: tuple[float, float],
                        center: tuple[float, float],
                        radius: float) -> list[tuple[float, float]]:
    """Sample the circular arc from p1 to p2 that passes through p3.
    Sweep direction is the one whose angular sweep from p1 to p2 also
    crosses p3 (ensures arc goes through the apex, not around the back
    of the circle). Samples at ~1-pixel arc-length spacing, p1 first
    and p2 last."""
    cx, cy = center
    a1 = math.atan2(p1[1] - cy, p1[0] - cx)
    a2 = math.atan2(p2[1] - cy, p2[0] - cx)
    a3 = math.atan2(p3[1] - cy, p3[0] - cx)
    two_pi = 2.0 * math.pi

    def _ccw(angle: float) -> float:
        a = (angle - a1) % two_pi
        return a

    a3_ccw = _ccw(a3)
    a2_ccw = _ccw(a2)
    if a3_ccw <= a2_ccw:
        sweep = a2_ccw           # CCW from p1 to p2 passes through p3
    else:
        sweep = a2_ccw - two_pi  # CW (negative sweep)
    n_samples = max(2, int(round(abs(sweep) * radius)))
    out: list[tuple[float, float]] = []
    for k in range(n_samples + 1):
        t = k / n_samples
        a = a1 + sweep * t
        out.append((cx + math.cos(a) * radius, cy + math.sin(a) * radius))
    return out


def centerline_path(start: tuple[int, int], end: tuple[int, int],
                    mask: np.ndarray, dt: np.ndarray
                    ) -> list[tuple[int, int]]:
    """Dijkstra shortest path between two anchor pixels through ink,
    with edge cost `step_length / (dt[neighbour] + 1)`. Deep-ink pixels
    are cheaper, so the path tracks the medial axis. Raises if the two
    anchors aren't on ink or are in disconnected ink components."""
    h, w = mask.shape
    if not (0 <= start[1] < h and 0 <= start[0] < w and mask[start[1], start[0]]):
        raise ValueError(f"start {start} not in ink")
    if not (0 <= end[1] < h and 0 <= end[0] < w and mask[end[1], end[0]]):
        raise ValueError(f"end {end} not in ink")
    if start == end:
        return [start]
    sqrt2 = math.sqrt(2.0)
    dist: dict[tuple[int, int], float] = {start: 0.0}
    prev: dict[tuple[int, int], tuple[int, int]] = {}
    heap: list[tuple[float, tuple[int, int]]] = [(0.0, start)]
    found = False
    while heap:
        d, (c, r) = heapq.heappop(heap)
        if (c, r) == end:
            found = True
            break
        if d > dist.get((c, r), math.inf):
            continue
        for dr, dc in NEIGHBOURS_8:
            nc, nr = c + dc, r + dr
            if not (0 <= nc < w and 0 <= nr < h):
                continue
            if not mask[nr, nc]:
                continue
            step = sqrt2 if (dc != 0 and dr != 0) else 1.0
            edge = step / (float(dt[nr, nc]) + 1.0)
            nd = d + edge
            if nd < dist.get((nc, nr), math.inf):
                dist[(nc, nr)] = nd
                prev[(nc, nr)] = (c, r)
                heapq.heappush(heap, (nd, (nc, nr)))
    if not found:
        raise ValueError(f"No ink path from {start} to {end}")
    path = [end]
    cur = end
    while cur in prev:
        cur = prev[cur]
        path.append(cur)
    path.reverse()
    return path


# -----------------------------------------------------------------------------
# Validation + resampling
# -----------------------------------------------------------------------------

def resample_uniform(pixels: list[tuple[int, int]],
                     n: int) -> list[tuple[int, int]]:
    """Resample a dense pixel chain to exactly `n` points by linear
    interpolation along arc length."""
    if n <= 0 or not pixels:
        return []
    if len(pixels) == 1:
        return [pixels[0]] * n
    arc = [0.0]
    for i in range(1, len(pixels)):
        ax, ay = pixels[i - 1]
        bx, by = pixels[i]
        arc.append(arc[-1] + ((bx - ax) ** 2 + (by - ay) ** 2) ** 0.5)
    total = arc[-1]
    if total <= 0:
        return [pixels[0]] * n
    out: list[tuple[int, int]] = []
    j = 0
    for k in range(n):
        target = total * k / (n - 1)
        while j + 1 < len(arc) and arc[j + 1] < target:
            j += 1
        if j + 1 >= len(arc):
            out.append(pixels[-1])
            continue
        span = arc[j + 1] - arc[j]
        t = 0.0 if span <= 0 else (target - arc[j]) / span
        ax, ay = pixels[j]
        bx, by = pixels[j + 1]
        out.append((int(round(ax + (bx - ax) * t)),
                    int(round(ay + (by - ay) * t))))
    return out


# -----------------------------------------------------------------------------
# Skeleton field assembly
# -----------------------------------------------------------------------------

def build_skeleton_and_adj(stroke_pixel_chains: list[list[tuple[int, int]]],
                           bbox: tuple[int, int, int, int]
                           ) -> tuple[list[dict], list[list[int]]]:
    """Union all stroke pixel chains into a deduplicated skeleton with
    8-connected adjacency. Output matches the strokes.json `skeleton` /
    `skeletonAdj` fields the iOS calibrator reads."""
    pixel_to_idx: dict[tuple[int, int], int] = {}
    ordered_pixels: list[tuple[int, int]] = []
    for chain in stroke_pixel_chains:
        for p in chain:
            if p not in pixel_to_idx:
                pixel_to_idx[p] = len(ordered_pixels)
                ordered_pixels.append(p)
    skeleton_pts = [
        {"x": round(pixel_to_rel(p, bbox)[0], 4),
         "y": round(pixel_to_rel(p, bbox)[1], 4)}
        for p in ordered_pixels
    ]
    skeleton_adj: list[list[int]] = []
    for col, row in ordered_pixels:
        nbrs = [pixel_to_idx[(col + dc, row + dr)]
                for dr, dc in NEIGHBOURS_8
                if (col + dc, row + dr) in pixel_to_idx]
        skeleton_adj.append(nbrs)
    return skeleton_pts, skeleton_adj


# -----------------------------------------------------------------------------
# Arm and joint construction primitives
# -----------------------------------------------------------------------------
#
# Line-kind strokes are built by composing one arm primitive (per arm) with
# one joint primitive (per interior corner). The default pairing —
# `arm_smoothed_medial_axis` + `joint_cubic_bezier_clamped` with
# `max_handle=70` — is what M/V/W/N currently ship. Authoring a new letter
# can override per-arm or per-joint via the StrokeSpec keys `"arms"` and
# `"joints"` (parallel arrays; entries are either a strategy name string or
# `{"strategy": "name", "<param>": <value>, ...}`).

def _bfs_skeleton_path(a: tuple[int, int], b: tuple[int, int],
                       skeleton: np.ndarray
                       ) -> list[tuple[int, int]] | None:
    """Deterministic BFS path on the skeleton from `a` to `b`. Returns
    the ordered list of (col, row) pixels, or `None` if either endpoint
    is off-skeleton or unreachable."""
    h_, w_ = skeleton.shape
    ax, ay = a; bx, by = b
    if not (0 <= ay < h_ and 0 <= ax < w_ and skeleton[ay, ax]):
        return None
    if not (0 <= by < h_ and 0 <= bx < w_ and skeleton[by, bx]):
        return None
    from collections import deque
    parent: dict[tuple[int, int], tuple[int, int] | None] = {(ay, ax): None}
    q = deque([(ax, ay)])
    found = False
    while q:
        cc, cr = q.popleft()
        if (cc, cr) == (bx, by):
            found = True
            break
        for dr, dc in NEIGHBOURS_8:
            nc, nr = cc + dc, cr + dr
            if not (0 <= nr < h_ and 0 <= nc < w_):
                continue
            if not skeleton[nr, nc]:
                continue
            if (nr, nc) in parent:
                continue
            parent[(nr, nc)] = (cr, cc)
            q.append((nc, nr))
    if not found:
        return None
    pts: list[tuple[int, int]] = []
    cur: tuple[int, int] | None = (by, bx)
    while cur is not None:
        pts.append((cur[1], cur[0]))
        cur = parent[cur]
    pts.reverse()
    return pts


def _smooth_path(pts: list[tuple[int, int]],
                 left_trim_pct: float, right_trim_pct: float,
                 window: int = 5
                 ) -> list[tuple[float, float]] | None:
    """Trim `left_trim_pct` from the front and `right_trim_pct` from the
    back, then moving-average smooth with the given odd window. Returns
    `None` if the trimmed path is too short."""
    if len(pts) < 10:
        return None
    left = int(len(pts) * left_trim_pct)
    right = int(len(pts) * right_trim_pct)
    trimmed = pts[left:len(pts) - right] if right > 0 else pts[left:]
    if len(trimmed) < 5:
        return None
    half = window // 2
    smoothed: list[tuple[float, float]] = []
    for i in range(len(trimmed)):
        lo = max(0, i - half); hi = min(len(trimmed), i + half + 1)
        sx = sum(p[0] for p in trimmed[lo:hi]) / (hi - lo)
        sy = sum(p[1] for p in trimmed[lo:hi]) / (hi - lo)
        smoothed.append((sx, sy))
    return smoothed


def _arm_endpoint_tangents(arm_prev: list[tuple[float, float]],
                           arm_next: list[tuple[float, float]],
                           lookback: int = 5, lookahead: int = 5
                           ) -> tuple[tuple[float, float],
                                       tuple[float, float]] | None:
    """Unit tangent at arm_prev's last point pointing INTO the joint
    (direction of travel arriving at P_end), and at arm_next's first
    point pointing AWAY (direction of travel leaving P_start). Returns
    `(tangent_prev, tangent_next)` or `None` if any vector is degenerate."""
    if len(arm_prev) < lookback + 1 or len(arm_next) < lookahead + 1:
        return None
    P_end = arm_prev[-1]
    back_idx = max(0, len(arm_prev) - lookback - 1)
    tpx = P_end[0] - arm_prev[back_idx][0]
    tpy = P_end[1] - arm_prev[back_idx][1]
    tp_len = math.hypot(tpx, tpy)
    if tp_len < 1e-6:
        return None
    P_start = arm_next[0]
    fwd_idx = min(len(arm_next) - 1, lookahead)
    tnx = arm_next[fwd_idx][0] - P_start[0]
    tny = arm_next[fwd_idx][1] - P_start[1]
    tn_len = math.hypot(tnx, tny)
    if tn_len < 1e-6:
        return None
    return ((tpx / tp_len, tpy / tp_len), (tnx / tn_len, tny / tn_len))


# --- Arm primitives ---------------------------------------------------------

def arm_chord(rough_a: tuple[int, int], rough_b: tuple[int, int],
              k: int, n_arms: int, *,
              mask: np.ndarray, dt: np.ndarray, skeleton: np.ndarray,
              ) -> list[tuple[float, float]]:
    """Straight chord between rough_a and rough_b — 2-point polyline."""
    return [(float(rough_a[0]), float(rough_a[1])),
            (float(rough_b[0]), float(rough_b[1]))]


def arm_bfs_raw(rough_a: tuple[int, int], rough_b: tuple[int, int],
                k: int, n_arms: int, *,
                mask: np.ndarray, dt: np.ndarray, skeleton: np.ndarray,
                ) -> list[tuple[float, float]] | None:
    """BFS skeleton path from rough_a to rough_b, cast to float, no
    smoothing or trimming. Returns `None` if BFS fails."""
    pts = _bfs_skeleton_path(rough_a, rough_b, skeleton)
    if pts is None:
        return None
    return [(float(c), float(r)) for c, r in pts]


def arm_lsq_line(rough_a: tuple[int, int], rough_b: tuple[int, int],
                 k: int, n_arms: int, *,
                 mask: np.ndarray, dt: np.ndarray, skeleton: np.ndarray,
                 trim_pct: float = 0.20,
                 ) -> list[tuple[float, float]] | None:
    """Total-least-squares (SVD) line through BFS skeleton pixels between
    rough_a and rough_b, with `trim_pct` trimmed from each end before
    fitting. Endpoints are rough_a and rough_b projected onto the fitted
    line. Returns a 2-point polyline `[proj_a, proj_b]`, or `None` if
    the BFS or SVD can't be computed. Construction from bf3273a."""
    pts = _bfs_skeleton_path(rough_a, rough_b, skeleton)
    if pts is None or len(pts) < 10:
        return None
    trim = int(len(pts) * trim_pct)
    sample = pts[trim:len(pts) - trim] if trim > 0 else pts
    if len(sample) < 5:
        return None
    arr = np.array(sample, dtype=float)
    centroid = arr.mean(axis=0)
    _, _, vt = np.linalg.svd(arr - centroid, full_matrices=False)
    direction = vt[0]
    ox, oy = float(centroid[0]), float(centroid[1])
    dx, dy = float(direction[0]), float(direction[1])
    def _proj(p: tuple[int, int]) -> tuple[float, float]:
        vx = p[0] - ox; vy = p[1] - oy
        t = vx * dx + vy * dy
        return (ox + t * dx, oy + t * dy)
    return [_proj(rough_a), _proj(rough_b)]


def arm_smoothed_medial_axis(rough_a: tuple[int, int],
                             rough_b: tuple[int, int],
                             k: int, n_arms: int, *,
                             mask: np.ndarray, dt: np.ndarray,
                             skeleton: np.ndarray,
                             trim_pct: float = 0.20,
                             window: int = 5,
                             ) -> list[tuple[float, float]] | None:
    """BFS skeleton path, trimmed `trim_pct` on the joint-adjacent side(s)
    only (no trim on endpoint-adjacent sides for arm 0 / last arm), then
    moving-average smoothed with the given window. The construction
    shipping on M/V/W/N at 6cf5740."""
    pts = _bfs_skeleton_path(rough_a, rough_b, skeleton)
    if pts is None:
        return None
    left_pct = 0.0 if k == 0 else trim_pct
    right_pct = 0.0 if k == n_arms - 1 else trim_pct
    return _smooth_path(pts, left_pct, right_pct, window=window)


# --- Joint primitives -------------------------------------------------------

def joint_sharp(arm_prev: list[tuple[float, float]],
                arm_next: list[tuple[float, float]], *,
                mask: np.ndarray, dt: np.ndarray,
                anchor: tuple[int, int],
                ) -> dict:
    """No curve — line-sampled bridge from P_end straight to P_start."""
    P_end = arm_prev[-1]
    P_start = arm_next[0]
    a = (int(round(P_end[0])), int(round(P_end[1])))
    b = (int(round(P_start[0])), int(round(P_start[1])))
    if a == b:
        samples: list[tuple[float, float]] = [P_end]
    else:
        samples = [(float(c), float(r)) for c, r in line_sampler([a, b])]
    return {"type": "line", "P_end": P_end, "P_start": P_start,
            "samples": samples}


def joint_family_a_fillet(arm_prev: list[tuple[float, float]],
                          arm_next: list[tuple[float, float]], *,
                          mask: np.ndarray, dt: np.ndarray,
                          anchor: tuple[int, int],
                          apex_offset: float = 4.0,
                          ) -> dict | None:
    """Family-A band-side inscribed fillet at the medial-axis joint.
    Tangent points T1/T2 sit back along the band-side arms, apex on the
    band-side chord bisector at `apex_offset · sin(α/2)` from the joint
    position. Construction from 4d6c286. Returns `None` if geometry is
    degenerate or any sample falls outside the mask."""
    tt = _arm_endpoint_tangents(arm_prev, arm_next)
    if tt is None:
        return None
    tangent_prev, tangent_next = tt
    # `u1_in` and `u2_in` here are the BACK / FORWARD chord directions
    # used by the original Family-A construction: u1_in points away
    # from the joint along arm_prev, u2_in points away along arm_next.
    u1_in = (-tangent_prev[0], -tangent_prev[1])
    u2_in = tangent_next
    P_end = arm_prev[-1]
    P_start = arm_next[0]
    bb_x = u1_in[0] + u2_in[0]
    bb_y = u1_in[1] + u2_in[1]
    bb_len = math.hypot(bb_x, bb_y)
    if bb_len < 1e-6:
        return None
    band_bisector = (bb_x / bb_len, bb_y / bb_len)
    mh, mw = mask.shape
    oc, or_ = int(anchor[0]), int(anchor[1])
    r0 = max(0, or_ - 30); r1 = min(mh, or_ + 31)
    c0 = max(0, oc - 30); c1 = min(mw, oc + 31)
    if r1 <= r0 or c1 <= c0:
        return None
    h_target = float(dt[r0:r1, c0:c1].max())
    if h_target < 4.0:
        return None
    jx = float(anchor[0]) + band_bisector[0] * h_target
    jy = float(anchor[1]) + band_bisector[1] * h_target
    jc = int(round(jx)); jr = int(round(jy))
    if not (0 <= jr < mh and 0 <= jc < mw and mask[jr, jc]):
        return None
    joint_pos = (jx, jy)
    cos_half = max(-1.0, min(1.0,
                              u1_in[0] * band_bisector[0]
                              + u1_in[1] * band_bisector[1]))
    half_angle = math.acos(cos_half)
    min_deg = math.radians(1.0); max_deg = math.radians(89.0)
    if half_angle < min_deg or half_angle > max_deg:
        return None
    sin_h = math.sin(half_angle)
    if sin_h < 1e-6 or (1.0 - sin_h) < 1e-6:
        return None
    apex_target = apex_offset * sin_h
    r = apex_target * sin_h / (1.0 - sin_h)
    tan_dist = r / math.tan(half_angle)
    if tan_dist > 0.5 * min(len(arm_prev), len(arm_next)):
        return None
    T1 = (P_end[0] + u1_in[0] * tan_dist,
          P_end[1] + u1_in[1] * tan_dist)
    T2 = (P_start[0] + u2_in[0] * tan_dist,
          P_start[1] + u2_in[1] * tan_dist)
    apex = (joint_pos[0] + band_bisector[0] * apex_target,
            joint_pos[1] + band_bisector[1] * apex_target)
    t1c, t1r = int(round(T1[0])), int(round(T1[1]))
    t2c, t2r = int(round(T2[0])), int(round(T2[1]))
    apc, apr = int(round(apex[0])), int(round(apex[1]))
    if not (0 <= t1r < mh and 0 <= t1c < mw
            and 0 <= t2r < mh and 0 <= t2c < mw
            and 0 <= apr < mh and 0 <= apc < mw
            and mask[t1r, t1c] and mask[t2r, t2c] and mask[apr, apc]):
        return None
    circle = circle_through_three(T1, apex, T2)
    if circle is None:
        return None
    arc_pts = sample_arc_p1_p3_p2(T1, apex, T2,
                                  (circle[0], circle[1]), circle[2])
    # Pre-/post-line segments so chain emission can directly _emit_pts.
    samples: list[tuple[float, float]] = []
    pa = (int(round(P_end[0])), int(round(P_end[1])))
    pb = (int(round(T1[0])), int(round(T1[1])))
    if pa != pb:
        samples.extend((float(c), float(r))
                       for c, r in line_sampler([pa, pb]))
    else:
        samples.append(P_end)
    samples.extend(arc_pts)
    pa = (int(round(T2[0])), int(round(T2[1])))
    pb = (int(round(P_start[0])), int(round(P_start[1])))
    if pa != pb:
        samples.extend((float(c), float(r))
                       for c, r in line_sampler([pa, pb]))
    else:
        samples.append(P_start)
    return {"type": "arc", "P_end": P_end, "P_start": P_start,
            "T1": T1, "T2": T2, "apex": apex,
            "joint_pos": joint_pos, "h_target": h_target,
            "half_angle": half_angle, "tan_dist": tan_dist,
            "apex_target": apex_target,
            "band_bisector": band_bisector, "samples": samples}


def _joint_tangent_intersection(arm_prev: list[tuple[float, float]],
                                arm_next: list[tuple[float, float]]
                                ) -> dict | None:
    """Shared geometry used by both Bézier joint primitives: tangent
    vectors at P_end / P_start, intersection point V of their forward
    extensions, signed handle lengths `s_v` / `s_v_alt`. Returns `None`
    on degeneracy or unstable intersection."""
    tt = _arm_endpoint_tangents(arm_prev, arm_next)
    if tt is None:
        return None
    tangent_prev, tangent_next = tt
    cross = (tangent_prev[0] * tangent_next[1]
             - tangent_prev[1] * tangent_next[0])
    if abs(cross) < 1e-3:
        return None
    P_end = arm_prev[-1]; P_start = arm_next[0]
    dx_ = P_start[0] - P_end[0]
    dy_ = P_start[1] - P_end[1]
    chord_len = math.hypot(dx_, dy_)
    s_param = (dx_ * tangent_next[1] - dy_ * tangent_next[0]) / cross
    V = (P_end[0] + s_param * tangent_prev[0],
         P_end[1] + s_param * tangent_prev[1])
    s_v = ((V[0] - P_end[0]) * tangent_prev[0]
           + (V[1] - P_end[1]) * tangent_prev[1])
    s_v_alt = ((P_start[0] - V[0]) * tangent_next[0]
               + (P_start[1] - V[1]) * tangent_next[1])
    if s_v <= 0.0 or s_v_alt <= 0.0:
        return None
    d_v_end = math.hypot(V[0] - P_end[0], V[1] - P_end[1])
    d_v_start = math.hypot(V[0] - P_start[0], V[1] - P_start[1])
    if chord_len > 1e-6 and (d_v_end > 5.0 * chord_len
                              or d_v_start > 5.0 * chord_len):
        return None
    return {"P_end": P_end, "P_start": P_start, "V": V,
            "tangent_prev": tangent_prev, "tangent_next": tangent_next,
            "s_v": s_v, "s_v_alt": s_v_alt, "chord_len": chord_len}


def joint_quadratic_bezier_at_V(arm_prev: list[tuple[float, float]],
                                arm_next: list[tuple[float, float]], *,
                                mask: np.ndarray, dt: np.ndarray,
                                anchor: tuple[int, int],
                                ) -> dict | None:
    """Quadratic Bézier with control point V at the intersection of the
    two arm tangent lines. Tangent continuity at both seams is exact by
    Bézier algebra (B'(0) ∝ V − P_end, B'(1) ∝ P_start − V).
    Construction from 5592b63."""
    g = _joint_tangent_intersection(arm_prev, arm_next)
    if g is None:
        return None
    samples = sample_quadratic_bezier(g["P_end"], g["V"], g["P_start"])
    return {"type": "qbez", "P_end": g["P_end"], "P_start": g["P_start"],
            "V": g["V"], "tangent_prev": g["tangent_prev"],
            "tangent_next": g["tangent_next"],
            "samples": samples}


def joint_cubic_bezier_clamped(arm_prev: list[tuple[float, float]],
                               arm_next: list[tuple[float, float]], *,
                               mask: np.ndarray, dt: np.ndarray,
                               anchor: tuple[int, int],
                               max_handle: float = 70.0,
                               ) -> dict | None:
    """Cubic Bézier with two independent control points along the arm
    tangent lines, each handle clamped to `max_handle`. Tangent
    continuity at both seams is exact (B'(0) ∝ C1 − P_end, B'(1) ∝
    P_start − C2). Construction shipping at 6cf5740."""
    g = _joint_tangent_intersection(arm_prev, arm_next)
    if g is None:
        return None
    tp = g["tangent_prev"]; tn = g["tangent_next"]
    h1 = min(g["s_v"], max_handle)
    h2 = min(g["s_v_alt"], max_handle)
    P_end = g["P_end"]; P_start = g["P_start"]
    C1 = (P_end[0] + tp[0] * h1, P_end[1] + tp[1] * h1)
    C2 = (P_start[0] - tn[0] * h2, P_start[1] - tn[1] * h2)
    samples = sample_cubic_bezier(P_end, C1, C2, P_start)
    return {"type": "cbez", "P_end": P_end, "P_start": P_start,
            "V": g["V"], "C1": C1, "C2": C2,
            "tangent_prev": tp, "tangent_next": tn,
            "s_v": g["s_v"], "s_v_alt": g["s_v_alt"],
            "h1": h1, "h2": h2, "samples": samples}


def joint_sharp_meeting(arm_prev: list[tuple[float, float]],
                        arm_next: list[tuple[float, float]], *,
                        mask: np.ndarray, dt: np.ndarray,
                        anchor: tuple[int, int],
                        depth_factor: float = 1.0,
                        ) -> dict | None:
    """True angular meeting at a design apex. The polyline runs
    P_end → apex → P_start with line_sampler segments — tangent
    continuity is INTENTIONALLY violated at `apex` (that's the point;
    Prima's Druckschrift documentation specifies sharp inner corners).

    `apex` is placed on the angle bisector from V (tangent-line
    intersection) toward `anchor`, at distance `depth_factor *
    h_target` past V, where h_target is the maximum dt in a 60×60
    window centred on `anchor` (≈ half-stroke-width at the meeting).
    `depth_factor=1.0` places apex one half-width inside the cap
    outline; `0` leaves it at V; `>1` pushes deeper into the band.

    Returns `None` if the tangent geometry is degenerate, the bisector
    is degenerate, or apex falls outside the mask."""
    g = _joint_tangent_intersection(arm_prev, arm_next)
    if g is None:
        return None
    P_end = g["P_end"]; P_start = g["P_start"]; V = g["V"]
    tp = g["tangent_prev"]; tn = g["tangent_next"]
    mh, mw = mask.shape
    oc, or_ = int(anchor[0]), int(anchor[1])
    r0 = max(0, or_ - 30); r1 = min(mh, or_ + 31)
    c0 = max(0, oc - 30); c1 = min(mw, oc + 31)
    if r1 <= r0 or c1 <= c0:
        return None
    h_target = float(dt[r0:r1, c0:c1].max())
    bx = float(anchor[0]) - V[0]
    by = float(anchor[1]) - V[1]
    bl = math.hypot(bx, by)
    if bl < 1e-6:
        return None
    bisector = (bx / bl, by / bl)
    step = depth_factor * h_target
    apex = (V[0] + bisector[0] * step, V[1] + bisector[1] * step)
    apr = int(round(apex[1])); apc = int(round(apex[0]))
    if not (0 <= apr < mh and 0 <= apc < mw and mask[apr, apc]):
        return None
    a = (int(round(P_end[0])), int(round(P_end[1])))
    b = (apc, apr)
    c = (int(round(P_start[0])), int(round(P_start[1])))
    samples: list[tuple[float, float]] = []
    if a != b:
        samples.extend((float(cc), float(rr))
                       for cc, rr in line_sampler([a, b]))
    else:
        samples.append(P_end)
    if b != c:
        seg = [(float(cc), float(rr))
               for cc, rr in line_sampler([b, c])]
        # Skip the duplicate apex point so consecutive line_sampler
        # segments don't double-emit b.
        if samples and seg and samples[-1] == seg[0]:
            seg = seg[1:]
        samples.extend(seg)
    else:
        samples.append(P_start)
    return {"type": "sharp_meeting",
            "P_end": P_end, "P_start": P_start,
            "V": V, "apex": apex,
            "tangent_prev": tp, "tangent_next": tn,
            "depth_factor": depth_factor, "h_target": h_target,
            "samples": samples}


# --- Registries -------------------------------------------------------------

ARM_STRATEGIES = {
    "chord": arm_chord,
    "bfs_raw": arm_bfs_raw,
    "lsq_line": arm_lsq_line,
    "smoothed_medial_axis": arm_smoothed_medial_axis,
}

JOINT_STRATEGIES = {
    "sharp": joint_sharp,
    "family_a_fillet": joint_family_a_fillet,
    "quadratic_bezier_at_V": joint_quadratic_bezier_at_V,
    "cubic_bezier_clamped": joint_cubic_bezier_clamped,
    "sharp_meeting": joint_sharp_meeting,
}

# Default pair matches the byte-identical line-kind output shipping at
# 6cf5740 — change the defaults only with a sweep + visual review.
DEFAULT_ARM_STRATEGY: tuple[str, dict] = ("smoothed_medial_axis", {})
DEFAULT_JOINT_STRATEGY: tuple[str, dict] = ("cubic_bezier_clamped",
                                            {"max_handle": 70.0})


def _resolve_strategy(entry, default: tuple[str, dict],
                       registry: dict, slot_name: str
                       ) -> tuple[str, dict]:
    """Normalise a per-slot strategy override to `(name, params)`.
    `entry` is either `None` (use default), a `str` (named strategy with
    default params), or a `dict` `{"strategy": "name", **params}`."""
    if entry is None:
        return default
    if isinstance(entry, str):
        name = entry; params: dict = {}
    elif isinstance(entry, dict):
        name = entry.get("strategy")
        if not isinstance(name, str):
            raise ValueError(f"{slot_name}: missing 'strategy' key in {entry!r}")
        params = {k: v for k, v in entry.items() if k != "strategy"}
    else:
        raise ValueError(f"{slot_name}: bad strategy entry {entry!r}")
    if name not in registry:
        raise ValueError(f"{slot_name}: unknown strategy {name!r} "
                          f"(known: {sorted(registry)})")
    return name, params


def _resolve_per_slot(spec_list, n: int, default: tuple[str, dict],
                       registry: dict, slot_name: str
                       ) -> list[tuple[str, dict]]:
    """Resolve a parallel-array strategy spec to length `n`. `spec_list`
    may be `None` (all default) or a list of length `n`."""
    if spec_list is None:
        return [default] * n
    if len(spec_list) != n:
        raise ValueError(f"{slot_name}: expected {n} entries, got "
                          f"{len(spec_list)}")
    return [_resolve_strategy(e, default, registry, f"{slot_name}[{i}]")
            for i, e in enumerate(spec_list)]


# -----------------------------------------------------------------------------
# Per-letter bake
# -----------------------------------------------------------------------------

def output_dir_for(letter: str) -> Path:
    """Resolve the per-letter resource directory honouring the
    lowercase suffix convention (APFS / HFS+ case-insensitivity)."""
    if letter.isupper() or not letter.isalpha():
        return OUTPUT_BASE / letter
    return OUTPUT_BASE / f"{letter}{LOWERCASE_SUFFIX}"


def bake_letter(letter: str, font_path: Path
                ) -> tuple[dict, dict]:
    """End-to-end bake. Returns `(json_payload, debug_info)`. Resolves
    anchors, synthesises centerlines, asserts every centerline stays in
    ink, samples to `CHECKPOINT_COUNT`, and packages into the
    strokes.json shape."""
    specs = LETTERS.get(letter)
    if not specs:
        raise KeyError(f"No spec authored for {letter!r}")
    mask = rasterize(letter, font_path)
    bbox = bbox_from_mask(mask)
    dt = distance_transform_edt(mask)
    # Deterministic 1-px-wide centerline lookup consumed by
    # snap_to_medial_axis. Treated as a boolean point-membership table
    # (never traversed); topology differences between skeletonize and
    # medial_axis don't matter for the snap.
    skeleton = morph.skeletonize(mask)

    stroke_pixel_chains: list[list[tuple[int, int]]] = []
    json_strokes: list[dict] = []
    resolved_anchors: list[list[tuple[str, tuple[int, int]]]] = []
    joint_arcs_per_stroke: list[list[dict | None]] = []
    smoothed_paths_per_stroke: list[list[list[tuple[float, float]] | None]] = []

    for i, spec in enumerate(specs, start=1):
        if "kind" in spec:
            kind = spec["kind"]
            names = spec.get("anchors") or []
        elif "path" in spec:
            kind = "curve"
            names = spec["path"]
        else:
            raise ValueError(f"{letter} stroke {i}: spec needs 'kind' "
                             f"+ 'anchors' or legacy 'path' key")
        if len(names) < 2:
            raise ValueError(f"{letter} stroke {i}: needs ≥2 anchors, "
                             f"got {names!r}")
        if kind not in ("line", "curve"):
            raise ValueError(f"{letter} stroke {i}: unknown kind {kind!r}")
        # Line endpoints land directly on the visual corner — no tip
        # extension. Curves Dijkstra-route through ink and need tips
        # inside the centerline body to avoid apex-curl hooks.
        anchor_dt = dt if kind == "curve" else None
        anchors: list[tuple[int, int]] = []
        labelled: list[tuple[str, tuple[int, int]]] = []
        for name in names:
            try:
                pos = resolve_anchor(name, mask, bbox, dt=anchor_dt)
            except (KeyError, ValueError) as e:
                raise ValueError(
                    f"{letter} stroke {i}: anchor {name!r} failed — {e}"
                    ) from e
            anchors.append(pos)
            labelled.append((name, pos))
        resolved_anchors.append(labelled)

        if kind == "line":
            # Line-kind dispatches into arm and joint primitives. The
            # default pair (arm_smoothed_medial_axis +
            # joint_cubic_bezier_clamped@70) is what M/V/W/N ship today;
            # per-arm and per-joint overrides come from spec["arms"] and
            # spec["joints"].
            rough_snapped: list[tuple[int, int]] = [
                snap_to_medial_axis(p, mask, dt, skeleton,
                                    letter=letter, anchor_name=n)
                for p, n in zip(anchors, names)
            ]
            n_arms = len(rough_snapped) - 1

            arm_strategies = _resolve_per_slot(
                spec.get("arms"), n_arms, DEFAULT_ARM_STRATEGY,
                ARM_STRATEGIES, "arms")
            joint_strategies = _resolve_per_slot(
                spec.get("joints"), max(0, n_arms - 1),
                DEFAULT_JOINT_STRATEGY, JOINT_STRATEGIES, "joints")

            arms: list[list[tuple[float, float]] | None] = []
            for k in range(n_arms):
                name, params = arm_strategies[k]
                fn = ARM_STRATEGIES[name]
                arms.append(fn(rough_snapped[k], rough_snapped[k + 1],
                               k, n_arms,
                               mask=mask, dt=dt, skeleton=skeleton,
                               **params))

            joints: list[dict | None] = []
            for j in range(n_arms - 1):
                arm_prev = arms[j]; arm_next = arms[j + 1]
                if (arm_prev is None or arm_next is None
                        or len(arm_prev) < 6 or len(arm_next) < 6):
                    joints.append(None)
                    continue
                name, params = joint_strategies[j]
                fn = JOINT_STRATEGIES[name]
                joints.append(fn(arm_prev, arm_next,
                                  mask=mask, dt=dt,
                                  anchor=anchors[j + 1], **params))

            # Chain assembly: emit each arm path, bridge with the joint's
            # pre-sampled polyline. Fall back to a straight line bridge
            # when the joint primitive returned None.
            chain: list[tuple[int, int]] = []

            def _emit_pts(pts: list[tuple[float, float]]) -> None:
                for p in pts:
                    ip = (int(round(p[0])), int(round(p[1])))
                    if not chain or chain[-1] != ip:
                        chain.append(ip)

            def _emit_line(p_start, p_end):
                a = (int(round(p_start[0])), int(round(p_start[1])))
                b = (int(round(p_end[0])), int(round(p_end[1])))
                if a == b:
                    if not chain:
                        chain.append(a)
                    return
                seg = line_sampler([a, b])
                start = 1 if chain and chain[-1] == seg[0] else 0
                chain.extend(seg[start:])

            for k in range(n_arms):
                arm_path = arms[k]
                arm_start = (arm_path[0] if arm_path is not None
                             else rough_snapped[k])
                arm_end = (arm_path[-1] if arm_path is not None
                           else rough_snapped[k + 1])
                if k > 0:
                    jd_prev = (joints[k - 1]
                               if (k - 1) < len(joints) else None)
                    if jd_prev is not None:
                        _emit_pts(jd_prev["samples"])
                    elif chain:
                        _emit_line(chain[-1], arm_start)
                if arm_path is not None:
                    _emit_pts(arm_path)
                else:
                    _emit_line(arm_start, arm_end)
            joint_arcs_per_stroke.append(joints)
            smoothed_paths_per_stroke.append(arms)
        else:
            chain = []
            for si in range(len(anchors) - 1):
                seg = centerline_path(anchors[si], anchors[si + 1], mask, dt)
                for col, row in seg:
                    if not mask[row, col]:
                        raise AssertionError(
                            f"{letter} stroke {i} segment {si}: Dijkstra "
                            f"returned off-ink pixel ({col}, {row})")
                if chain and seg and chain[-1] == seg[0]:
                    seg = seg[1:]
                chain.extend(seg)
            joint_arcs_per_stroke.append([])
            smoothed_paths_per_stroke.append([])
        stroke_pixel_chains.append(chain)

        resampled = resample_uniform(chain, CHECKPOINT_COUNT)
        json_strokes.append({
            "id": i,
            "checkpoints": [
                {"x": round(pixel_to_rel(p, bbox)[0], 4),
                 "y": round(pixel_to_rel(p, bbox)[1], 4)}
                for p in resampled
            ],
        })

    skeleton_pts, skeleton_adj = build_skeleton_and_adj(
        stroke_pixel_chains, bbox)

    data = {
        "letter": letter,
        "checkpointRadius": DEFAULT_RADIUS,
        "strokes": json_strokes,
        "skeleton": skeleton_pts,
        "skeletonAdj": skeleton_adj,
    }
    debug = {
        "mask": mask,
        "dt": dt,
        "bbox": bbox,
        "stroke_chains": stroke_pixel_chains,
        "stroke_pixel_chains": stroke_pixel_chains,
        "resolved_anchors": resolved_anchors,
        "joint_arcs_per_stroke": joint_arcs_per_stroke,
        "smoothed_paths_per_stroke": smoothed_paths_per_stroke,
    }
    return data, debug


# -----------------------------------------------------------------------------
# Debug overlay
# -----------------------------------------------------------------------------

def save_overlay(letter: str, font_path: Path, out_path: Path) -> None:
    """Save a centerline-over-ink PNG for visual review. Shows the ink
    mask, the path bbox outline, every resolved anchor (labelled), and
    the Dijkstra centerline path per stroke."""
    data, debug = bake_letter(letter, font_path)
    mask = debug["mask"]
    bbox = debug["bbox"]
    chains = debug["stroke_chains"]
    anchors = debug["resolved_anchors"]
    img = Image.fromarray(np.where(mask, 0, 230).astype(np.uint8)).convert("RGB")
    draw = ImageDraw.Draw(img)
    x_min, y_min, x_max, y_max = bbox
    draw.rectangle((x_min, y_min, x_max, y_max), outline=(0, 0, 0), width=1)
    palette = [
        (220, 30, 30), (30, 130, 30), (30, 60, 200), (220, 130, 30),
        (180, 30, 180),
    ]
    for si, chain in enumerate(chains):
        color = palette[si % len(palette)]
        for col, row in chain:
            draw.point((col, row), fill=color)
        if chain:
            sc, sr = chain[0]
            draw.ellipse((sc - 5, sr - 5, sc + 5, sr + 5),
                         fill=color, outline=(0, 0, 0))
    for si, group in enumerate(anchors):
        for name, (col, row) in group:
            draw.ellipse((col - 8, row - 8, col + 8, row + 8),
                         fill=(255, 230, 0), outline=(0, 0, 0))
            draw.text((col + 10, row - 14), name, fill=(0, 0, 0))
    img.save(str(out_path))


# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------

def write_meta(out_base: Path, font_path: Path) -> None:
    """Write `_meta.json` so consumers can detect a font swap and
    trigger a re-bake."""
    font_hash = hashlib.sha256(font_path.read_bytes()).hexdigest()
    (out_base / "_meta.json").write_text(json.dumps({
        "fontPath": str(font_path),
        "fontSha256": font_hash,
        "generator": "generate_strokes_auto.py",
    }, indent=2))
    print(f"  _meta.json: font sha256 {font_hash[:12]}…")


def main() -> int:
    """CLI entry point. Bakes one or more letters; with `--debug`,
    saves `/tmp/centerline_<L>.png` overlays."""
    parser = argparse.ArgumentParser(
        description="Bake anchor-spec strokes.json files.")
    parser.add_argument("letters", nargs="*",
                        help="Letters to bake. Default: every entry in LETTERS.")
    parser.add_argument("--font", default=str(DEFAULT_FONT),
                        help="OTF / TTF font path.")
    parser.add_argument("--out", default=None,
                        help="Output base dir. Default: PrimaeNative/Resources/Letters.")
    parser.add_argument("--no-overwrite", action="store_true",
                        help="Skip letters whose strokes.json already exists.")
    parser.add_argument("--debug", action="store_true",
                        help="Save /tmp/centerline_<L>.png overlays.")
    args = parser.parse_args()

    font_path = Path(args.font)
    if not font_path.exists():
        print(f"Font not found: {font_path}")
        return 1
    out_base = Path(args.out) if args.out else OUTPUT_BASE
    letters = args.letters or list(LETTERS.keys())

    ok = 0
    fail = 0
    for letter in letters:
        out_dir = (out_base / letter
                   if letter.isupper() or not letter.isalpha()
                   else out_base / f"{letter}{LOWERCASE_SUFFIX}")
        out_file = out_dir / "strokes.json"
        if args.no_overwrite and out_file.exists():
            print(f"  {letter}: skipped (exists)")
            continue
        try:
            data, _ = bake_letter(letter, font_path)
        except Exception as e:
            print(f"  {letter}: FAIL — {e}")
            fail += 1
            continue
        out_dir.mkdir(parents=True, exist_ok=True)
        out_file.write_text(json.dumps(data, indent=2, ensure_ascii=False))
        n_pts = sum(len(s["checkpoints"]) for s in data["strokes"])
        print(f"  {letter}: ✓ {len(data['strokes'])} strokes, {n_pts} checkpoints")
        if args.debug:
            try:
                save_overlay(letter, font_path,
                             Path(f"/tmp/centerline_{letter}.png"))
            except Exception as e:
                print(f"  {letter}: overlay FAIL — {e}")
        ok += 1
    if ok > 0:
        try:
            write_meta(out_base, font_path)
        except Exception as e:
            print(f"  _meta.json: FAIL — {e}")
    print(f"\nDone — {ok} ok, {fail} failed.")
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
