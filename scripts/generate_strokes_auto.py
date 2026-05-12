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
# Pedagogical anchor specs. Each `StrokeSpec` is `{"path": [anchor, ...]}` with
# 2+ anchors. The bake resolves each anchor to a font-specific pixel position
# and synthesises the centerline between consecutive anchors via Dijkstra over
# the ink distance transform.
#
# Anchor names are font-independent — adding a new font requires zero per-
# letter tweaking. The bake aborts with an explicit error if any anchor fails
# to resolve (e.g. `UPPER_TOUCH` on a letter without a closed bowl).

StrokeSpec = dict  # {"path": list[str]}

LETTERS: dict[str, list[StrokeSpec]] = {
    "N": [
        {"path": ["TL", "BL"]},
        {"path": ["TL", "BR"]},
        {"path": ["TR", "BR"]},
    ],
    "V": [
        {"path": ["TL", "BC", "TR"]},
    ],
    "M": [
        {"path": ["BL", "TL", "BC", "TR", "BR"]},
    ],
    "W": [
        {"path": ["TL", "BL", "TC", "BR", "TR"]},
    ],
    "b": [
        {"path": ["T", "B"]},
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


def resolve_anchor(name: str, mask: np.ndarray,
                   bbox: tuple[int, int, int, int]) -> tuple[int, int]:
    """Dispatch to the appropriate resolver. Raises `KeyError` on an
    unknown anchor name, `ValueError` on a resolution failure (e.g.
    `UPPER_TOUCH` on a non-bowl letter)."""
    if name in {"TL", "TR", "BL", "BR"}:
        return _corner_anchor(mask, bbox, name)
    if name == "T":
        return _topmost_or_bottommost(mask, bbox, top=True)
    if name == "B":
        return _topmost_or_bottommost(mask, bbox, top=False)
    if name == "TC":
        return _column_extremum_near_center(mask, bbox, top=True)
    if name == "BC":
        return _column_extremum_near_center(mask, bbox, top=False)
    if name == "ML":
        return _midline_extremum(mask, bbox, "left")
    if name == "MR":
        return _midline_extremum(mask, bbox, "right")
    if name == "LEFT_MID":
        return _x_extreme_centered(mask, bbox, "left")
    if name == "RIGHT_MID":
        return _x_extreme_centered(mask, bbox, "right")
    if name == "UPPER_TOUCH":
        return _bowl_stem_touch(mask, bbox, upper=True)
    if name == "LOWER_TOUCH":
        return _bowl_stem_touch(mask, bbox, upper=False)
    raise KeyError(f"Unknown anchor name: {name!r}")


# -----------------------------------------------------------------------------
# Centerline path synthesis
# -----------------------------------------------------------------------------

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

    stroke_pixel_chains: list[list[tuple[int, int]]] = []
    json_strokes: list[dict] = []
    resolved_anchors: list[list[tuple[str, tuple[int, int]]]] = []

    for i, spec in enumerate(specs, start=1):
        path = spec.get("path") or []
        if len(path) < 2:
            raise ValueError(f"{letter} stroke {i}: path needs ≥2 anchors, "
                             f"got {path!r}")
        anchors: list[tuple[int, int]] = []
        labelled: list[tuple[str, tuple[int, int]]] = []
        for name in path:
            try:
                pos = resolve_anchor(name, mask, bbox)
            except (KeyError, ValueError) as e:
                raise ValueError(
                    f"{letter} stroke {i}: anchor {name!r} failed — {e}"
                    ) from e
            anchors.append(pos)
            labelled.append((name, pos))
        resolved_anchors.append(labelled)

        chain: list[tuple[int, int]] = []
        for si in range(len(anchors) - 1):
            seg = centerline_path(anchors[si], anchors[si + 1], mask, dt)
            for col, row in seg:
                if not mask[row, col]:
                    raise AssertionError(
                        f"{letter} stroke {i} segment {si}: Dijkstra returned "
                        f"off-ink pixel ({col}, {row})")
            if chain and seg and chain[-1] == seg[0]:
                seg = seg[1:]
            chain.extend(seg)
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
        "bbox": bbox,
        "stroke_chains": stroke_pixel_chains,
        "resolved_anchors": resolved_anchors,
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
