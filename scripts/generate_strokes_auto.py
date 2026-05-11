"""Per-font stroke generator with worksheet ground-truth overrides.

Two modes per letter:

1. **Override** (LETTER_OVERRIDES): the Wiener Bildungsserver
   "Arbeitsblätter Druckschrift" worksheet specifies stroke count,
   start anchor and direction for every letter. When an override
   exists, we resolve each anchor against the rasterised skeleton
   and BFS-walk between them. This pins the OUTPUT order and shape
   to what's taught in Austrian Volksschule 1. Klasse, regardless
   of how the font's skeleton happens to branch.

2. **Auto fallback**: skeletonise, walk every connected component,
   split at branches and merge collinear/2-incidents corners,
   order by component centroid. Used when no override exists OR
   when the override walker fails (e.g. an anchor is unreachable
   on this particular font's geometry).

Coordinates are glyph-bbox-relative ([0, 1] within the rendered
glyph's bounding rect). The iOS renderer maps them through
`normalizedGlyphRect` so cell aspect ratio and orientation don't
affect alignment.

Usage:
    pip install Pillow numpy scipy scikit-image
    python scripts/generate_strokes_auto.py            # all letters
    python scripts/generate_strokes_auto.py A E O      # subset
    python scripts/generate_strokes_auto.py --font /path/to/Other.otf
    python scripts/generate_strokes_auto.py --debug A  # save overlay PNG
"""
from __future__ import annotations

import argparse
import hashlib
import heapq
import json
import math
from collections import defaultdict, deque
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont
import skimage.morphology as morph
import skimage.measure as measure

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_FONT = REPO_ROOT / "design-system/fonts/Primae-Regular.otf"
OUTPUT_BASE = REPO_ROOT / "PrimaeNative/Resources/Letters"

SIZE = 1024
PAD = 0.10
DEFAULT_RADIUS = 0.05
# Curvature-adaptive sampling. Straights get a checkpoint every
# `BASE_SPACING_PX`; curves (local angle change > `CURVE_ANGLE_DEG`)
# get one every `CURVE_SPACING_PX` (3× denser). Paths shorter than
# `DOT_LENGTH_THRESHOLD_PX` collapse to a single checkpoint at the
# midpoint — i / j dots and umlaut dots are tap-targets, not traced
# strokes, so 15 waypoints over 5 px of skeleton was overkill.
BASE_SPACING_PX = 12
CURVE_SPACING_PX = 4
CURVE_ANGLE_DEG = 15
CURVE_WINDOW_PX = 6
MIN_CHECKPOINTS_PER_STROKE = 3
DOT_LENGTH_THRESHOLD_PX = 30
MERGE_ANGLE_THRESHOLD_DEG = 35  # segments within 35° of collinear get merged

NEIGHBOURS_8 = ((-1, -1), (-1, 0), (-1, 1),
                ( 0, -1),          ( 0, 1),
                ( 1, -1), ( 1, 0), ( 1, 1))

# Spur-pruning post-process for the baked skeleton.
# morph.skeletonize produces small T-junction branches at thick-stroke
# meeting points (visible on M, A in the Primae font). The Swift runtime
# uses 8 nodes at 256² (~32 px equivalent at 1024²); we use 24 here as
# a conservative threshold confirmed by empirical calibration to cleanly
# remove M's 10/20/21-px artifacts and A's 20-px artifact while leaving
# Q's 95-px tail, F's 158-px crossbar, t's 51-px crossbar, and i/j/ä
# tittle components untouched.
MAX_SPUR_LENGTH = 24

# Tip-extension parameters. Mirror of the Swift runtime's
# extendTipsToOutline. 60 raster pixels at 1024² is the practical
# cap — empirically no in-the-bundle tip extension reaches it, so
# it's a runaway-walk guard rather than a routine limit. Tangent
# window 8 smooths the direction estimate over the 4× higher
# resolution; Swift used 1-back which would be jitter-sensitive at
# 1024².
MAX_TIP_EXTENSION = 60
TANGENT_WINDOW = 8

# Lowercase folder suffix dodges APFS / HFS+ case-insensitive collision
# with their uppercase counterparts.
LOWERCASE_SUFFIX = "_l"


# -----------------------------------------------------------------------------
# Worksheet ground-truth overrides
# -----------------------------------------------------------------------------
#
# Encodes the stroke count, start anchor, and direction taught in the
# Wiener Bildungsserver "Arbeitsblätter Druckschrift" PDF. Each entry
# is a list of strokes in writing order. Three primitives:
#
#   {"kind": "walk", "from": ANCHOR, "to": ANCHOR}
#     → BFS-shortest path along the skeleton between two anchors.
#
#   {"kind": "continuous", "anchors": [ANCHOR, ...]}
#     → Chain of BFS walks through anchors in order. Used for letters
#       written as one continuous zigzag (M, N, V, W, Z, U).
#
#   {"kind": "loop", "start": ANCHOR, "direction": "ccw"|"cw"}
#     → Walk a closed cycle starting at the anchor's nearest skeleton
#       pixel. Direction is enforced via shoelace sign.
#
# ANCHOR is one of:
#   "TL" "TR" "BL" "BR"      bbox corners
#   "TC"="T" "BC"="B"        top/bottom centre
#   "ML"="L" "MR"="R"        mid-left / mid-right
#   "C"                      bbox centre
#   (x, y)                   normalised tuple in [0, 1] of bbox
#
# Conventions captured (Austrian-specific where they differ):
#   • A: bottom-left UP to apex first, then apex DOWN to BR, then crossbar
#   • M, N, V, W, Z: single continuous zigzag starting at BL (or TL for V)
#   • E, F: spine first, then horizontals top-to-bottom
#   • H: left vertical, right vertical, crossbar (3 strokes)
#   • h, n, m: arch starts at the bottom-right of the arch going UP
#   • J: top cap then descending hook (2 strokes)
#   • U: single continuous bowl
#   • Ä Ö Ü ä ö ü: body strokes first, then dots left-to-right

LETTER_OVERRIDES: dict[str, list[dict]] = {
    # ─── Uppercase ────────────────────────────────────────────────────
    "A": [
        {"kind": "walk", "from": "BL", "to": "TC"},
        {"kind": "walk", "from": "TC", "to": "BR"},
        {"kind": "walk", "from": "ML", "to": "MR"},
    ],
    "B": [
        {"kind": "walk", "from": "TL", "to": "BL"},
        {"kind": "continuous", "anchors": ["TL", "TR", "MR", "ML"]},
        {"kind": "continuous", "anchors": ["ML", "MR", "BR", "BL"]},
    ],
    "C": [
        {"kind": "walk", "from": "TR", "to": "BR"},
    ],
    "D": [
        {"kind": "walk", "from": "TL", "to": "BL"},
        {"kind": "continuous", "anchors": ["TL", "MR", "BL"]},
    ],
    "E": [
        {"kind": "walk", "from": "TL", "to": "BL"},
        {"kind": "walk", "from": "TL", "to": "TR"},
        {"kind": "walk", "from": "ML", "to": "MR"},
        {"kind": "walk", "from": "BL", "to": "BR"},
    ],
    "F": [
        {"kind": "walk", "from": "TL", "to": "BL"},
        {"kind": "walk", "from": "TL", "to": "TR"},
        {"kind": "walk", "from": "ML", "to": "MR"},
    ],
    "G": [
        {"kind": "continuous", "anchors": ["TR", "L", "B", "BR"]},
        {"kind": "walk", "from": "BR", "to": "MR"},
        {"kind": "walk", "from": "MR", "to": "C"},
    ],
    "H": [
        {"kind": "walk", "from": "TL", "to": "BL"},
        {"kind": "walk", "from": "TR", "to": "BR"},
        {"kind": "walk", "from": "ML", "to": "MR"},
    ],
    "I": [
        {"kind": "walk", "from": "T", "to": "B"},
    ],
    "J": [
        {"kind": "walk", "from": "TL", "to": "TR"},
        {"kind": "continuous", "anchors": ["TR", "BR", "BC", "BL"]},
    ],
    "K": [
        {"kind": "walk", "from": "TL", "to": "BL"},
        # K's diagonals are a separate skeleton component from the
        # vertical (ML lands on the vertical component, breaking BFS
        # bridge). Anchor the junction directly via a tuple inside the
        # diagonals component.
        {"kind": "walk", "from": "TR", "to": (0.30, 0.50)},
        {"kind": "walk", "from": (0.30, 0.50), "to": "BR"},
    ],
    "L": [
        {"kind": "continuous", "anchors": ["TL", "BL", "BR"]},
    ],
    "M": [
        {"kind": "continuous", "anchors": ["BL", "TL", "BC", "TR", "BR"]},
    ],
    "N": [
        # Phase 3 starter. Each stroke's CENTERLINE covers only its
        # own arm; the meeting corners are filled by stroke-width
        # overlap at iPad render time, not by shared centerline pixels.
        # Diagonal is inset 8 % at each end so its centerline doesn't
        # share endpoints with the verticals (which would draw a "Y stem"
        # in the corner region from the overlapping centerlines).
        # All anchors verified in-ink at raster resolution.
        {"kind": "through", "from": (0.14, 0.00), "to": (0.05, 1.00)},
        {"kind": "through", "from": (0.22, 0.08), "to": (0.78, 0.92)},
        {"kind": "through", "from": (0.95, 0.00), "to": (0.86, 1.00)},
    ],
    "O": [
        {"kind": "loop", "start": "T", "direction": "ccw"},
    ],
    "P": [
        {"kind": "walk", "from": "TL", "to": "BL"},
        {"kind": "continuous", "anchors": ["TL", "TR", "MR", "ML"]},
    ],
    "Q": [
        {"kind": "loop", "start": "T", "direction": "ccw"},
        {"kind": "walk", "from": "C", "to": "BR"},
    ],
    "R": [
        {"kind": "walk", "from": "TL", "to": "BL"},
        {"kind": "continuous", "anchors": ["TL", "TR", "MR", "ML"]},
        {"kind": "walk", "from": "ML", "to": "BR"},
    ],
    "S": [
        {"kind": "walk", "from": "TR", "to": "BL"},
    ],
    "T": [
        {"kind": "walk", "from": "TL", "to": "TR"},
        {"kind": "walk", "from": "T", "to": "B"},
    ],
    "U": [
        {"kind": "continuous", "anchors": ["TL", "BL", "BR", "TR"]},
        {"kind": "walk", "from": "TR", "to": "BR"},
    ],
    "V": [
        # Phase 3 starter. Both diagonals end ABOVE the apex; the
        # unstroked region between the stroke ends and the apex is
        # filled by stroke-width overlap at render time. Endpoints
        # land in distinct arms (no shared pixel ⇒ no "Y stem").
        # x of the right endpoint is 0.46, not symmetric 0.58: this
        # font's V is asymmetric (right arm has steeper slope), so the
        # right arm's centerline at y=0.84 is at rel x ≈ 0.50, not 0.58.
        # y=0.84 is the lowest row where the two arms are still
        # separated (~7 px gap); at y=0.88 they've merged into one ink
        # column. All anchors verified in-ink.
        {"kind": "through", "from": (0.08, 0.00), "to": (0.42, 0.84)},
        {"kind": "through", "from": (0.93, 0.00), "to": (0.46, 0.84)},
    ],
    "W": [
        {"kind": "continuous", "anchors": ["TL", "BL", "TC", "BR", "TR"]},
    ],
    "X": [
        {"kind": "walk", "from": "TL", "to": "BR"},
        {"kind": "walk", "from": "TR", "to": "BL"},
    ],
    "Y": [
        {"kind": "walk", "from": "TL", "to": "C"},
        {"kind": "continuous", "anchors": ["TR", "C", "B"]},
    ],
    "Z": [
        {"kind": "walk", "from": "TL", "to": "TR"},
        {"kind": "walk", "from": "TR", "to": "BL"},
        {"kind": "walk", "from": "BL", "to": "BR"},
    ],

    # ─── Lowercase ────────────────────────────────────────────────────
    "a": [
        {"kind": "loop", "start": "T", "direction": "ccw"},
        {"kind": "walk", "from": "TR", "to": "BR"},
    ],
    "b": [
        # Phase 3 starter. Stem traces a strict-tangent vertical from
        # stem-top centerline (rel x=0.19, raster x=444 — well inside
        # the stem ink at y=0) down to (0.18, 0.66), terminating at
        # the bowl/stem junction row. "T" cannot be used here because
        # `through` resolves anchors raw against the bbox: "T" = (0.5, 0)
        # would land at the bbox-center-top (518, 221), in the
        # whitespace above the bowl. Lateral correction handles the
        # stem's ~7 px leftward lean at the foot.
        # Bowl is one closed medial-axis loop attached to the stem at
        # a single 4-way junction; the bowl stroke starts/ends on the
        # bowl arc itself (deg-2 pixels ~10 px along each branch from
        # the junction). (0.4, 0.45) is the upper-left arc waypoint
        # that forces leg 1 to traverse the upper-left arc rather than
        # detouring.
        {"kind": "through", "from": (0.19, 0.00), "to": (0.18, 0.66),
         "tangent": (0, 1)},
        {"kind": "continuous",
         "anchors": [(0.159, 0.650),  # upper bowl-arc, ~10 px from junction
                     (0.4, 0.45),     # upper-left bowl arc waypoint
                     "MR",            # right of bowl
                     "BC",            # bottom-center of bowl
                     (0.100, 0.685)]},  # lower bowl-arc, ~10 px from junction
    ],
    "c": [
        {"kind": "walk", "from": "TR", "to": "BR"},
    ],
    "d": [
        {"kind": "loop", "start": "T", "direction": "ccw"},
        {"kind": "walk", "from": "TR", "to": "BR"},
    ],
    "e": [
        {"kind": "continuous", "anchors": ["ML", "MR", "T", "L", "B", "BR"]},
    ],
    "f": [
        {"kind": "continuous", "anchors": ["TR", "TC", "TL", "BL"]},
        {"kind": "walk", "from": "ML", "to": "MR"},
    ],
    "g": [
        {"kind": "loop", "start": "T", "direction": "ccw"},
        {"kind": "walk", "from": "TR", "to": "BL"},
    ],
    "h": [
        {"kind": "walk", "from": "TL", "to": "BL"},
        {"kind": "walk", "from": "BR", "to": "ML"},
    ],
    "i": [
        # Body starts below the dot (~y=0.3); using "T" lands on the
        # dot, which is a separate skeleton component from the body.
        {"kind": "walk", "from": (0.50, 0.30), "to": "B"},
        {"kind": "loop", "start": (0.5, 0.05), "direction": "ccw"},
    ],
    "j": [
        # Same dot/body component-bridge issue as i.
        {"kind": "walk", "from": (0.50, 0.30), "to": "BL"},
        {"kind": "loop", "start": (0.5, 0.05), "direction": "ccw"},
    ],
    "k": [
        {"kind": "walk", "from": "TL", "to": "BL"},
        # Lowercase k's diagonals are a separate skeleton component
        # from the vertical descender, so we anchor the upper-diagonal
        # tip + junction directly via tuples to keep the BFS within
        # the diagonal component.
        {"kind": "walk", "from": (0.90, 0.45), "to": (0.40, 0.50)},
        {"kind": "walk", "from": (0.40, 0.50), "to": "BR"},
    ],
    "l": [
        {"kind": "walk", "from": "T", "to": "BR"},
    ],
    "m": [
        # Worksheet shows the start arrow at TL going down — the BFS
        # walks down the left vertical, then up-arch-down to BC, then
        # up-arch-down to BR.
        {"kind": "continuous", "anchors": ["TL", "BL", "BC", "BR"]},
    ],
    "n": [
        # Same as m: start at TL going down, then up-arch-down to BR.
        {"kind": "continuous", "anchors": ["TL", "BL", "BR"]},
    ],
    "o": [
        {"kind": "loop", "start": "T", "direction": "ccw"},
    ],
    "p": [
        {"kind": "walk", "from": "TL", "to": "BL"},
        {"kind": "continuous", "anchors": ["TL", "TR", "MR", "ML"]},
    ],
    "q": [
        {"kind": "loop", "start": "T", "direction": "ccw"},
        {"kind": "walk", "from": "TR", "to": "BR"},
    ],
    "r": [
        # One continuous stroke: down the vertical, retrace up, hook
        # right. BFS handles the retrace as the shortest path on the
        # skeleton.
        {"kind": "continuous", "anchors": ["TL", "BL", "TR"]},
    ],
    "s": [
        {"kind": "walk", "from": "TR", "to": "BL"},
    ],
    "t": [
        {"kind": "walk", "from": "T", "to": "BR"},
        {"kind": "walk", "from": "ML", "to": "MR"},
    ],
    "u": [
        {"kind": "continuous", "anchors": ["TL", "BL", "BR", "TR"]},
        {"kind": "walk", "from": "TR", "to": "BR"},
    ],
    "v": [
        {"kind": "continuous", "anchors": ["TL", "BC", "TR"]},
    ],
    "w": [
        {"kind": "continuous", "anchors": ["TL", "BL", "TC", "BR", "TR"]},
    ],
    "x": [
        {"kind": "walk", "from": "TL", "to": "BR"},
        {"kind": "walk", "from": "TR", "to": "BL"},
    ],
    "y": [
        {"kind": "walk", "from": "TL", "to": "C"},
        {"kind": "walk", "from": "TR", "to": "BL"},
    ],
    "z": [
        {"kind": "walk", "from": "TL", "to": "TR"},
        {"kind": "walk", "from": "TR", "to": "BL"},
        {"kind": "walk", "from": "BL", "to": "BR"},
    ],

    # ─── Diaeresis & ß ────────────────────────────────────────────────
    # Body strokes first (matching base letter), then left dot, right dot.
    "Ä": [
        {"kind": "walk", "from": "BL", "to": (0.5, 0.18)},
        {"kind": "walk", "from": (0.5, 0.18), "to": "BR"},
        {"kind": "walk", "from": (0.10, 0.55), "to": (0.90, 0.55)},
        {"kind": "loop", "start": (0.30, 0.05), "direction": "ccw"},
        {"kind": "loop", "start": (0.70, 0.05), "direction": "ccw"},
    ],
    "Ö": [
        {"kind": "loop", "start": (0.5, 0.18), "direction": "ccw"},
        {"kind": "loop", "start": (0.30, 0.05), "direction": "ccw"},
        {"kind": "loop", "start": (0.70, 0.05), "direction": "ccw"},
    ],
    "Ü": [
        {"kind": "continuous",
         "anchors": [(0.05, 0.18), (0.05, 0.95), (0.95, 0.95)]},
        {"kind": "walk", "from": (0.95, 0.18), "to": (0.95, 0.95)},
        {"kind": "loop", "start": (0.30, 0.05), "direction": "ccw"},
        {"kind": "loop", "start": (0.70, 0.05), "direction": "ccw"},
    ],
    "ä": [
        {"kind": "loop", "start": (0.5, 0.30), "direction": "ccw"},
        {"kind": "walk", "from": (0.95, 0.30), "to": (0.95, 0.95)},
        {"kind": "loop", "start": (0.30, 0.05), "direction": "ccw"},
        {"kind": "loop", "start": (0.70, 0.05), "direction": "ccw"},
    ],
    "ö": [
        {"kind": "loop", "start": (0.5, 0.30), "direction": "ccw"},
        {"kind": "loop", "start": (0.30, 0.05), "direction": "ccw"},
        {"kind": "loop", "start": (0.70, 0.05), "direction": "ccw"},
    ],
    "ü": [
        {"kind": "continuous",
         "anchors": [(0.05, 0.30), (0.05, 0.95), (0.95, 0.95)]},
        {"kind": "walk", "from": (0.95, 0.30), "to": (0.95, 0.95)},
        {"kind": "loop", "start": (0.30, 0.05), "direction": "ccw"},
        {"kind": "loop", "start": (0.70, 0.05), "direction": "ccw"},
    ],
    "ß": [
        {"kind": "continuous",
         "anchors": ["BL", "TL", "TR", "MR", "ML", "MR", "BC"]},
    ],
}


ANCHOR_POSITIONS: dict[str, tuple[float, float]] = {
    "TL": (0.0, 0.0), "TR": (1.0, 0.0),
    "BL": (0.0, 1.0), "BR": (1.0, 1.0),
    "T":  (0.5, 0.0), "TC": (0.5, 0.0),
    "B":  (0.5, 1.0), "BC": (0.5, 1.0),
    "L":  (0.0, 0.5), "ML": (0.0, 0.5),
    "R":  (1.0, 0.5), "MR": (1.0, 0.5),
    "C":  (0.5, 0.5),
}

# All 59 letters in the Primae demo set: 26 caps + 26 lowercase + Ää Öö Üü ß.
ALL_LETTERS = (
    list("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    + list("abcdefghijklmnopqrstuvwxyz")
    + list("ÄÖÜßäöü")
)


# -----------------------------------------------------------------------------
# Rasterisation
# -----------------------------------------------------------------------------

def rasterize(letter: str, font_path: Path,
              features: list[str] | None = None) -> np.ndarray:
    """Render `letter` to a SIZE×SIZE binary mask using uniform
    font-metric scaling (em-square = 80 % of canvas height, baseline
    placed at `pad + ascent`). Mirrors `PrimaeLetterRenderer.glyphPath`.
    `features` is an optional list of OpenType feature tags (e.g.
    `["ss02"]`) to enable alternate glyphs — used for k's curled
    variant.
    """
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
    bbox = font.getbbox(letter)
    w = bbox[2] - bbox[0]
    if w <= 0:
        raise ValueError(f"Empty glyph for {letter!r}")
    x = (SIZE - w) // 2 - bbox[0]
    baseline_y = int(SIZE * PAD + ascent)
    img = Image.new("L", (SIZE, SIZE), 255)
    text_kwargs = {"font": font, "fill": 0, "anchor": "ls"}
    if features:
        text_kwargs["features"] = features
    ImageDraw.Draw(img).text((x, baseline_y), letter, **text_kwargs)
    return np.array(img) < 128


# -----------------------------------------------------------------------------
# Skeleton graph: nodes = pixels, edges = 8-connected neighbours
# -----------------------------------------------------------------------------


def build_adjacency(skel_pixels: set[tuple[int, int]]
                    ) -> dict[tuple[int, int], list[tuple[int, int]]]:
    """Map each (col, row) skeleton pixel to its 8-connected neighbours
    that are also on the skeleton."""
    adj: dict[tuple[int, int], list[tuple[int, int]]] = {}
    for (c, r) in skel_pixels:
        nbrs = []
        for dr, dc in NEIGHBOURS_8:
            n = (c + dc, r + dr)
            if n in skel_pixels:
                nbrs.append(n)
        adj[(c, r)] = nbrs
    return adj


def prune_skeleton_spurs(skel_mask: np.ndarray,
                         max_spur_length: int = MAX_SPUR_LENGTH
                         ) -> np.ndarray:
    """Remove tip-to-junction chains of length ≤ `max_spur_length`
    pixels. Iterative — re-runs until no chains qualify. Isolated
    components (degree-1 → degree-2 chain → degree-1, no junction)
    are never pruned, so i/j tittles and umlaut dots survive."""
    mask = skel_mask.copy()
    while True:
        rows, cols = np.where(mask)
        if len(rows) == 0:
            return mask
        pixels = set(zip(rows.tolist(), cols.tolist()))
        deg: dict[tuple[int, int], int] = {}
        for (r, c) in pixels:
            d = 0
            for dr, dc in NEIGHBOURS_8:
                if (r + dr, c + dc) in pixels:
                    d += 1
            deg[(r, c)] = d

        to_remove: set[tuple[int, int]] = set()
        for tip in pixels:
            if deg[tip] != 1:
                continue
            if tip in to_remove:
                continue
            chain: list[tuple[int, int]] = []
            prev = None
            cur = tip
            while len(chain) < max_spur_length:
                chain.append(cur)
                nbrs = [
                    (cur[0] + dr, cur[1] + dc)
                    for dr, dc in NEIGHBOURS_8
                    if (cur[0] + dr, cur[1] + dc) in pixels
                ]
                if prev is None:
                    nbrs_excl = nbrs
                else:
                    nbrs_excl = [n for n in nbrs if n != prev]
                if len(nbrs_excl) != 1:
                    break
                nxt = nbrs_excl[0]
                if deg[nxt] >= 3:
                    to_remove.update(chain)
                    break
                prev = cur
                cur = nxt

        if not to_remove:
            return mask
        for (r, c) in to_remove:
            mask[r, c] = False


def extend_tips_to_outline(skel_mask: np.ndarray,
                           ink_mask: np.ndarray,
                           max_extension: int = MAX_TIP_EXTENSION,
                           tangent_window: int = TANGENT_WINDOW
                           ) -> np.ndarray:
    """Walk each degree-1 tip toward the ink boundary along its local
    tangent. Tangent = (tip - back-pixel) where back-pixel is the
    tangent_window-th chain pixel back from the tip; the walk stops
    earlier if a junction (deg≥3) is reached. Chebyshev-normalised
    tangent so each forward step adds exactly 1 pixel.

    Isolation-skip guard: tips on chains that never reach a junction
    are skipped entirely. Preserves i/j tittles, umlaut dots, and any
    isolated linear component (I, L) — all degree-1-to-degree-1.
    """
    mask = skel_mask.copy()
    if mask.size == 0:
        return mask
    rows_max, cols_max = mask.shape

    pa = np.where(mask)
    pixels = set(zip(pa[0].tolist(), pa[1].tolist()))
    if not pixels:
        return mask

    deg: dict[tuple[int, int], int] = {}
    for (r, c) in pixels:
        d = 0
        for dr, dc in NEIGHBOURS_8:
            if (r + dr, c + dc) in pixels:
                d += 1
        deg[(r, c)] = d

    extensions: list[tuple[tuple[int, int], float, float]] = []

    for tip in pixels:
        if deg[tip] != 1:
            continue

        chain = [tip]
        prev = None
        cur = tip
        is_isolated = False
        junction_hit = False

        for _ in range(tangent_window):
            cands = [(cur[0] + dr, cur[1] + dc) for dr, dc in NEIGHBOURS_8]
            nbrs = [n for n in cands if n in pixels and n != prev]
            if len(nbrs) == 0:
                is_isolated = True
                break
            if len(nbrs) > 1:
                junction_hit = True
                break
            prev = cur
            cur = nbrs[0]
            chain.append(cur)

        # Continue walking until we hit a junction or another tip.
        # No safety cap: a degree-2 chain on a 1-pixel skeleton can't
        # loop (the walk has one non-prev neighbour at every step;
        # cycles require a junction which terminates the walk), and
        # the chain length is bounded by raster size. Earlier 200-step
        # cap fired on Z's ~267-px bars and incorrectly defaulted them
        # to isolated, suppressing extension on Z/z/T/t tips.
        if not is_isolated and not junction_hit:
            while True:
                cands = [(cur[0] + dr, cur[1] + dc) for dr, dc in NEIGHBOURS_8]
                nbrs = [n for n in cands if n in pixels and n != prev]
                if len(nbrs) == 0:
                    is_isolated = True
                    break
                if len(nbrs) > 1:
                    junction_hit = True
                    break
                prev = cur
                cur = nbrs[0]

        if is_isolated:
            continue

        back = chain[-1]
        if back == tip:
            continue
        tdr = tip[0] - back[0]
        tdc = tip[1] - back[1]
        chev = max(abs(tdr), abs(tdc))
        if chev == 0:
            continue
        tdr_step = tdr / chev
        tdc_step = tdc / chev
        extensions.append((tip, tdr_step, tdc_step))

    for (tip, tdr_step, tdc_step) in extensions:
        rf = float(tip[0]) + 0.5
        cf = float(tip[1]) + 0.5
        prev_pos = tip
        steps_added = 0
        for _ in range(max_extension * 2):
            if steps_added >= max_extension:
                break
            rf += tdr_step
            cf += tdc_step
            ri, ci = int(rf), int(cf)
            if (ri, ci) == prev_pos:
                continue
            if not (0 <= ri < rows_max and 0 <= ci < cols_max):
                break
            if not ink_mask[ri, ci]:
                break
            mask[ri, ci] = True
            prev_pos = (ri, ci)
            steps_added += 1

    return mask


def _walk_cycle_ccw(seed: tuple[int, int],
                    adj: dict[tuple[int, int], list[tuple[int, int]]]
                    ) -> list[tuple[int, int]]:
    """Walk a closed skeleton cycle starting at `seed`, return the
    full path including the seed at both ends. Direction is forced to
    visual counter-clockwise (handwriting convention for O / o).
    Tries both starting neighbours and picks the longer walk — a 1-px
    dangling skeletonisation stub adjacent to the seed would otherwise
    dead-end the walker after a single step (seen on lowercase d's
    bowl)."""
    if len(adj[seed]) < 2:
        return [seed]
    candidate_paths: list[list[tuple[int, int]]] = []
    for start in adj[seed][:2]:
        visited = {seed, start}
        path = [seed, start]
        cur = start
        while True:
            options = [n for n in adj[cur] if n not in visited]
            if not options:
                if seed in adj[cur] and cur != seed:
                    path.append(seed)
                break
            cur = options[0]
            path.append(cur)
            visited.add(cur)
        candidate_paths.append(path)
    path = max(candidate_paths, key=len)

    # Image-coord shoelace: positive sign = clockwise visually.
    s = 0.0
    for i in range(len(path) - 1):
        x1, y1 = path[i]
        x2, y2 = path[i + 1]
        s += (x2 - x1) * (y2 + y1)
    if s > 0:
        path = list(reversed(path))
    return path


def split_into_segments(
    component_pixels: set[tuple[int, int]],
    adj: dict[tuple[int, int], list[tuple[int, int]]],
) -> list[list[tuple[int, int]]]:
    """Cut a skeleton component at every endpoint and branch point,
    returning each maximal degree-2 chain between two boundary
    pixels. Pure cycles (no boundary) become a single CCW-oriented
    closed segment."""
    boundary = {p for p in component_pixels if len(adj[p]) != 2}
    segments: list[list[tuple[int, int]]] = []

    if not boundary:
        seed = min(component_pixels, key=lambda p: (p[1], p[0]))
        return [_walk_cycle_ccw(seed, adj)]

    # Walk every (boundary, neighbour) starting edge once. The visited
    # set is on EDGES not nodes, because a branch point is shared by
    # multiple segments.
    used_edges: set[tuple[tuple[int, int], tuple[int, int]]] = set()

    def edge_key(a, b):
        return (a, b) if a < b else (b, a)

    for bp in boundary:
        for first_step in adj[bp]:
            ek = edge_key(bp, first_step)
            if ek in used_edges:
                continue
            used_edges.add(ek)
            path = [bp, first_step]
            cur = first_step
            prev = bp
            while cur not in boundary:
                nxts = [n for n in adj[cur] if n != prev]
                if not nxts:
                    break
                nxt = nxts[0]
                used_edges.add(edge_key(cur, nxt))
                path.append(nxt)
                prev, cur = cur, nxt
            segments.append(path)
    return segments


# -----------------------------------------------------------------------------
# Merge collinear segments at branch points
# -----------------------------------------------------------------------------

def segment_tangent(seg: list[tuple[int, int]], at_start: bool,
                    span_frac: float = 0.30,
                    min_span: int = 8,
                    max_span: int = 60) -> tuple[float, float]:
    """Unit vector along the segment at one end. Sampling reaches into
    the segment by `span_frac` of its pixel length (clamped to
    `min_span..max_span`) so the result tracks the segment's overall
    heading instead of any single-pixel jog where skeleton thinning
    wraps around a thick branch joint."""
    n_pix = len(seg)
    if n_pix < 2:
        return (0.0, 0.0)
    span = max(min_span, min(max_span, int(round(span_frac * n_pix))))
    span = min(span, n_pix - 1)
    if at_start:
        a = seg[0]
        b = seg[span]
    else:
        a = seg[-1]
        b = seg[n_pix - 1 - span]
    dx = a[0] - b[0]
    dy = a[1] - b[1]
    n = math.hypot(dx, dy)
    if n == 0:
        return (0.0, 0.0)
    return (dx / n, dy / n)


def _path_length(seg: list[tuple[int, int]]) -> float:
    return sum(math.hypot(seg[i][0] - seg[i - 1][0],
                          seg[i][1] - seg[i - 1][1])
               for i in range(1, len(seg)))


def merge_segments_at_branches(segments: list[list[tuple[int, int]]],
                               threshold_deg: float = MERGE_ANGLE_THRESHOLD_DEG,
                               stub_min_length_px: float = 30.0,
                               ) -> list[list[tuple[int, int]]]:
    """At each branch point, pair up any two incoming segments whose
    tangents are nearly opposite (i.e. the segments form a near-straight
    line through the branch) and merge them. Crossbars and arches stay
    as their own strokes; the two halves of an H-vertical merge back
    into one stroke."""
    # Drop pixel-stub segments emitted at branch points. Stubs come
    # from skeletonisation jitter (an extra 1–3 px outcrop where a
    # crossbar meets a vertical) and have no useful tangent — leaving
    # them in poisons the collinear-pair selection at the branch. But
    # if a component produced ONE segment (an isolated dot, the i tittle,
    # umlaut dots), keep it whatever its length.
    if len(segments) > 1:
        segments = [s for s in segments
                    if len(s) >= 2 and _path_length(s) >= stub_min_length_px]
    else:
        segments = [s for s in segments if len(s) >= 2]

    # Branches in the skeleton are not always one pixel wide — they
    # can be a 2×2 cluster of degree-3+ pixels. After stub removal the
    # remaining segments end at distinct pixels of the same conceptual
    # branch. Snap nearby endpoints (within `snap_radius` px) to a
    # shared centroid so the incidence map sees them as one node.
    snap_radius = 5.0
    eps = list({p for s in segments for p in (s[0], s[-1])})
    parent_ep = {p: p for p in eps}

    def _ep_find(p):
        while parent_ep[p] != p:
            parent_ep[p] = parent_ep[parent_ep[p]]
            p = parent_ep[p]
        return p

    for i in range(len(eps)):
        for j in range(i + 1, len(eps)):
            if math.hypot(eps[i][0] - eps[j][0],
                          eps[i][1] - eps[j][1]) <= snap_radius:
                ra, rb = _ep_find(eps[i]), _ep_find(eps[j])
                if ra != rb:
                    parent_ep[rb] = ra

    snap: dict[tuple[int, int], tuple[int, int]] = {}
    cluster_members: dict[tuple[int, int], list[tuple[int, int]]] = defaultdict(list)
    for p in eps:
        cluster_members[_ep_find(p)].append(p)
    for root, members in cluster_members.items():
        if len(members) == 1:
            snap[members[0]] = members[0]
            continue
        cx = round(sum(p[0] for p in members) / len(members))
        cy = round(sum(p[1] for p in members) / len(members))
        for p in members:
            snap[p] = (cx, cy)

    snapped: list[list[tuple[int, int]]] = []
    for s in segments:
        new_first = snap.get(s[0], s[0])
        new_last = snap.get(s[-1], s[-1])
        body = s[1:-1] if len(s) > 2 else []
        snapped.append([new_first] + body + [new_last])
    segments = snapped

    incidence: dict[tuple[int, int], list[tuple[int, bool]]] = defaultdict(list)
    for i, seg in enumerate(segments):
        if len(seg) < 2:
            continue
        incidence[seg[0]].append((i, True))
        incidence[seg[-1]].append((i, False))

    # union-find over segment indices
    parent = list(range(len(segments)))

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[rb] = ra

    cos_thr = math.cos(math.radians(180 - threshold_deg))

    for bp, incident in incidence.items():
        if len(incident) < 2:
            continue
        # Special case: exactly 2 incidents. After stub filtering this
        # is just a corner — merge unconditionally so M / N / V / W
        # zigzag together as one continuous stroke instead of one
        # piece per arm.
        if len(incident) == 2:
            union(incident[0][0], incident[1][0])
            continue
        # 3+ incidents: real junction. Greedy-pair the two segments
        # with most-opposed tangents (most collinear) and merge them
        # if they meet the threshold; repeat for any remaining pair.
        tangents = [segment_tangent(segments[idx], at_start)
                    for (idx, at_start) in incident]
        used = [False] * len(incident)
        while True:
            best = None
            best_cos = cos_thr
            for i in range(len(incident)):
                if used[i]:
                    continue
                for j in range(i + 1, len(incident)):
                    if used[j]:
                        continue
                    dp = tangents[i][0] * tangents[j][0] + tangents[i][1] * tangents[j][1]
                    if dp < best_cos:
                        best_cos = dp
                        best = (i, j)
            if best is None:
                break
            i, j = best
            used[i] = used[j] = True
            union(incident[i][0], incident[j][0])

    # Build merged segments by walking each union-find group.
    groups: dict[int, list[int]] = defaultdict(list)
    for i in range(len(segments)):
        groups[find(i)].append(i)

    merged: list[list[tuple[int, int]]] = []
    for member_ids in groups.values():
        if len(member_ids) == 1:
            merged.append(segments[member_ids[0]])
            continue
        # Stitch members head-to-tail by matching shared endpoints.
        remaining = list(member_ids)
        seq = list(segments[remaining.pop(0)])
        progress = True
        while remaining and progress:
            progress = False
            for k, idx in enumerate(remaining):
                seg = segments[idx]
                if seg[0] == seq[-1]:
                    seq.extend(seg[1:])
                    remaining.pop(k)
                    progress = True
                    break
                if seg[-1] == seq[-1]:
                    seq.extend(reversed(seg[:-1]))
                    remaining.pop(k)
                    progress = True
                    break
                if seg[0] == seq[0]:
                    seq[:0] = list(reversed(seg[1:]))
                    remaining.pop(k)
                    progress = True
                    break
                if seg[-1] == seq[0]:
                    seq[:0] = seg[:-1]
                    remaining.pop(k)
                    progress = True
                    break
        merged.append(seq)
        # Stragglers that didn't connect (shouldn't happen for a clean
        # skeleton but emit them rather than silently drop) become
        # separate merged entries.
        for idx in remaining:
            merged.append(segments[idx])
    return merged


# -----------------------------------------------------------------------------
# Stroke ordering and orientation
# -----------------------------------------------------------------------------

def stroke_orientation(seg: list[tuple[int, int]]) -> str:
    """Classify a stroke as 'v' (vertical), 'h' (horizontal), 'l'
    (closed loop), or 'd' (diagonal/curve) by comparing endpoints
    and bounding box aspect."""
    if len(seg) >= 3 and seg[0] == seg[-1]:
        return "l"
    xs = [p[0] for p in seg]
    ys = [p[1] for p in seg]
    dx = max(xs) - min(xs)
    dy = max(ys) - min(ys)
    if dy > 1.8 * dx:
        return "v"
    if dx > 1.8 * dy:
        return "h"
    return "d"


def order_stroke(seg: list[tuple[int, int]]) -> list[tuple[int, int]]:
    """Open strokes are oriented topmost-endpoint first; on a tie in
    y, leftmost first. Closed loops are left untouched (their CCW
    direction was already enforced by `_walk_cycle_ccw`)."""
    if len(seg) < 2 or seg[0] == seg[-1]:
        return seg
    a, b = seg[0], seg[-1]
    if (a[1], a[0]) > (b[1], b[0]):
        return list(reversed(seg))
    return seg


def order_strokes(strokes: list[list[tuple[int, int]]]
                  ) -> list[list[tuple[int, int]]]:
    """Sort strokes by component-centroid: top-to-bottom by centroid
    y (binned into bands so a stroke a few pixels lower doesn't lose
    priority), then left-to-right by centroid x within a band."""
    def key(seg):
        n = len(seg)
        cx = sum(p[0] for p in seg) / n
        cy = sum(p[1] for p in seg) / n
        band_h = SIZE // 12
        return (int(cy // band_h), cx)
    return sorted(strokes, key=key)


# -----------------------------------------------------------------------------
# Resampling to dense waypoints
# -----------------------------------------------------------------------------

def _interp_pixel(seg: list[tuple[int, int]],
                  cum: list[float],
                  target: float) -> tuple[int, int]:
    """Linear interpolation along a polyline at arc length `target`."""
    if target <= 0:
        return seg[0]
    if target >= cum[-1]:
        return seg[-1]
    lo, hi = 0, len(cum) - 1
    while lo + 1 < hi:
        mid = (lo + hi) // 2
        if cum[mid] <= target:
            lo = mid
        else:
            hi = mid
    if cum[hi] == cum[lo]:
        return seg[lo]
    t = (target - cum[lo]) / (cum[hi] - cum[lo])
    return (round(seg[lo][0] + t * (seg[hi][0] - seg[lo][0])),
            round(seg[lo][1] + t * (seg[hi][1] - seg[lo][1])))


def _uniform_resample(seg: list[tuple[int, int]],
                      cum: list[float], n: int
                      ) -> list[tuple[int, int]]:
    if n < 2:
        return [seg[0]]
    total = cum[-1]
    return [_interp_pixel(seg, cum, total * k / (n - 1)) for k in range(n)]


def trim_lead_in(seg: list[tuple[int, int]],
                 max_off_axis_deg: float = 60.0
                 ) -> list[tuple[int, int]]:
    """Trim the first checkpoints whose direction differs by more
    than `max_off_axis_deg` from the path's overall direction.

    BFS legs that start on the wrong skeleton branch (e.g. an `ML`
    anchor for a horizontal crossbar resolves to the left vertical
    pixel rather than the bar itself) produce a perpendicular
    "lead-in" before the path enters the intended segment. The first
    checkpoint reads as a sharp upward step before the trace turns
    horizontal — a child can't advance through it.
    """
    if len(seg) < 3:
        return seg
    overall_dx = seg[-1][0] - seg[0][0]
    overall_dy = seg[-1][1] - seg[0][1]
    overall_len = math.hypot(overall_dx, overall_dy)
    if overall_len < 1:
        return seg
    overall_ux = overall_dx / overall_len
    overall_uy = overall_dy / overall_len
    cos_thr = math.cos(math.radians(max_off_axis_deg))
    drop = 0
    for i in range(min(3, len(seg) - 2)):
        dx = seg[i + 1][0] - seg[i][0]
        dy = seg[i + 1][1] - seg[i][1]
        n = math.hypot(dx, dy)
        if n < 1:
            continue
        cos_a = (dx * overall_ux + dy * overall_uy) / n
        if cos_a < cos_thr:
            drop = i + 1
        else:
            break
    if drop == 0:
        return seg
    return seg[drop:]


def prune_retraces(seg: list[tuple[int, int]],
                   near_thr_px: float = 4.0
                   ) -> list[tuple[int, int]]:
    """Detect and elide out-and-back excursions in a sampled path.

    BFS through skeleton branches with stubs of more than one pixel
    can produce a multi-pixel detour: the path goes out to a peak and
    retraces nearly identical positions on the way back. Single-point
    spike pruning misses these because each consecutive triple has a
    valid sub-150° angle. Here we walk forward and, whenever a later
    point is within `near_thr_px` of an earlier one, drop everything
    strictly between them.

    Closed-loop paths (start == end, e.g. O bowl) are passed through
    unchanged — every closed cycle would otherwise collapse to its
    two endpoints.
    """
    if len(seg) < 4:
        return seg
    closed_loop = (
        math.hypot(seg[-1][0] - seg[0][0], seg[-1][1] - seg[0][1])
        < near_thr_px
    )
    if closed_loop:
        return seg
    keep = [True] * len(seg)
    i = 0
    while i < len(seg) - 2:
        if not keep[i]:
            i += 1
            continue
        match_j = -1
        for j in range(i + 2, len(seg)):
            if not keep[j]:
                continue
            dx = seg[j][0] - seg[i][0]
            dy = seg[j][1] - seg[i][1]
            if math.hypot(dx, dy) < near_thr_px:
                match_j = j
        if match_j > i + 1:
            for k in range(i + 1, match_j):
                keep[k] = False
            i = match_j
        else:
            i += 1
    return [seg[k] for k in range(len(seg)) if keep[k]]


def prune_spikes(seg: list[tuple[int, int]],
                 angle_deg: float = 150.0,
                 max_iters: int = 6
                 ) -> list[tuple[int, int]]:
    """Iteratively drop checkpoints that form a near-180° kink with
    their neighbours. Skeleton spurs at sharp corners (M valley, V
    apex, B bump-stem junction, …) leave multi-pixel out-and-back
    chains; pruning one tip exposes another. Up to `max_iters`
    passes converge in practice for the bundled strokes.
    """
    cos_thr = math.cos(math.radians(angle_deg))
    cur = seg
    for _ in range(max_iters):
        if len(cur) < 3:
            return cur
        out = [cur[0]]
        for i in range(1, len(cur) - 1):
            ax, ay = cur[i - 1]
            bx, by = cur[i]
            cx, cy = cur[i + 1]
            v1x, v1y = bx - ax, by - ay
            v2x, v2y = cx - bx, cy - by
            n1 = math.hypot(v1x, v1y)
            n2 = math.hypot(v2x, v2y)
            if n1 == 0 or n2 == 0:
                continue
            cos_a = (v1x * v2x + v1y * v2y) / (n1 * n2)
            if cos_a < cos_thr:
                continue
            out.append(cur[i])
        out.append(cur[-1])
        if len(out) == len(cur):
            return out
        cur = out
    return cur


def resample(seg: list[tuple[int, int]],
             base: float = BASE_SPACING_PX,
             curve: float = CURVE_SPACING_PX,
             curve_angle_deg: float = CURVE_ANGLE_DEG,
             window_px: float = CURVE_WINDOW_PX,
             min_pts: int = MIN_CHECKPOINTS_PER_STROKE,
             dot_threshold_px: float = DOT_LENGTH_THRESHOLD_PX
             ) -> list[tuple[int, int]]:
    """Curvature-adaptive resampling. Three regimes by total length:

    * `total <= dot_threshold_px` (umlaut dots, i/j dots): a single
      checkpoint at the midpoint — the proximity tracker treats it as
      a tap target.
    * `dot_threshold_px < total <= base`: short bar; 2 checkpoints
      (start, end) so the tracker has a direction.
    * `total > base`: full curvature-adaptive walk; straights get a
      checkpoint every `base` px, curves every `curve` px (~3× denser).

    `min_pts` only floors the long-path output so a barely-curved
    moderate stroke still has enough waypoints to register hits.
    """
    if len(seg) < 2:
        return seg
    cum = [0.0]
    for i in range(1, len(seg)):
        cum.append(cum[-1] + math.hypot(seg[i][0] - seg[i - 1][0],
                                        seg[i][1] - seg[i - 1][1]))
    total = cum[-1]
    if total <= dot_threshold_px:
        mid = _interp_pixel(seg, cum, total / 2)
        return [mid]
    if total <= base:
        return [seg[0], seg[-1]]

    angle_thr = math.radians(curve_angle_deg)
    out = [seg[0]]
    last_dist = 0.0
    target = base
    while target < total:
        # Probe ±window_px around the target arc length to detect
        # whether we're on a curve.
        a = _interp_pixel(seg, cum, max(0.0, target - window_px))
        b = _interp_pixel(seg, cum, target)
        c = _interp_pixel(seg, cum, min(total, target + window_px))
        v1 = (b[0] - a[0], b[1] - a[1])
        v2 = (c[0] - b[0], c[1] - b[1])
        n1 = math.hypot(*v1)
        n2 = math.hypot(*v2)
        on_curve = False
        if n1 > 0 and n2 > 0:
            cos_a = max(-1.0, min(1.0,
                (v1[0] * v2[0] + v1[1] * v2[1]) / (n1 * n2)))
            ang = math.acos(cos_a)
            if ang >= angle_thr:
                on_curve = True
        out.append(b)
        last_dist = target
        target += curve if on_curve else base

    if out[-1] != seg[-1]:
        out.append(seg[-1])

    if len(out) < min_pts:
        out = _uniform_resample(seg, cum, min_pts)
    return out


# -----------------------------------------------------------------------------
# Bbox-relative coordinate conversion
# -----------------------------------------------------------------------------

def to_bbox_relative(seg: list[tuple[int, int]],
                     bbox: tuple[int, int, int, int]
                     ) -> list[tuple[float, float]]:
    """Convert pixel coords to (x, y) in [0, 1] of the glyph's bounding
    rect. iOS multiplies these against `normalizedGlyphRect` to land
    on the on-screen ghost regardless of cell aspect ratio."""
    x_min, y_min, x_max, y_max = bbox
    w = max(1, x_max - x_min)
    h = max(1, y_max - y_min)
    return [((c - x_min) / w, (r - y_min) / h) for (c, r) in seg]


# -----------------------------------------------------------------------------
# Worksheet-override walker
# -----------------------------------------------------------------------------

def resolve_anchor(anchor,
                   skel: np.ndarray,
                   bbox: tuple[int, int, int, int]
                   ) -> tuple[int, int] | None:
    """Map an anchor (string name or (x, y) tuple in [0, 1] of bbox) to
    the nearest skeleton pixel. Returns None for an empty skeleton.
    Used by `walk`, `continuous`, and `loop` — primitives whose paths
    follow the medial axis."""
    x_min, y_min, x_max, y_max = bbox
    w = max(1, x_max - x_min)
    h = max(1, y_max - y_min)
    if isinstance(anchor, str):
        if anchor not in ANCHOR_POSITIONS:
            raise ValueError(f"Unknown anchor name: {anchor!r}")
        ax, ay = ANCHOR_POSITIONS[anchor]
    else:
        ax, ay = anchor
    target_x = x_min + ax * w
    target_y = y_min + ay * h
    rows, cols = np.where(skel)
    if len(rows) == 0:
        return None
    dx = cols.astype(np.float64) - target_x
    dy = rows.astype(np.float64) - target_y
    i = int(np.argmin(dx * dx + dy * dy))
    return (int(cols[i]), int(rows[i]))


def resolve_anchor_raw(anchor,
                       bbox: tuple[int, int, int, int]
                       ) -> tuple[int, int]:
    """Map an anchor directly to a raster pixel via the bbox — no
    skeleton snap. Used by `through`, whose path is synthesised across
    the ink mask and shouldn't be biased toward the medial axis. The
    override author is responsible for picking anchors that land inside
    the ink mask; out-of-ink starts/ends cause the synth to terminate
    immediately and the override to fall through."""
    x_min, y_min, x_max, y_max = bbox
    w = max(1, x_max - x_min)
    h = max(1, y_max - y_min)
    if isinstance(anchor, str):
        if anchor not in ANCHOR_POSITIONS:
            raise ValueError(f"Unknown anchor name: {anchor!r}")
        ax, ay = ANCHOR_POSITIONS[anchor]
    else:
        ax, ay = anchor
    return (int(round(x_min + ax * w)), int(round(y_min + ay * h)))


# Angle-penalty weight for tangent-aware Dijkstra in bfs_path. Higher
# values make the walker prefer "straight ahead" more strongly at
# junctions; 5.0 is the Phase 3 starting point, tuned on N's diagonal.
TANGENT_ANGLE_WEIGHT = 5.0


def bfs_path(start: tuple[int, int],
             end: tuple[int, int],
             adj: dict[tuple[int, int], list[tuple[int, int]]],
             blocked: set[tuple[int, int]] | None = None,
             inbound_tangent: tuple[float, float] | None = None,
             angle_weight: float = TANGENT_ANGLE_WEIGHT,
             ) -> list[tuple[int, int]] | None:
    """Shortest path along the skeleton graph. Returns None when `end`
    is unreachable from `start`.

    `inbound_tangent` is the direction the walker is moving on arrival
    at `start`. When None, classic FIFO BFS (shortest by pixel count)
    — existing callers are unchanged. When set, Dijkstra with edge cost
    `1 + angle_weight * (1 - cos(theta)) / 2`, where theta is the angle
    between consecutive edges. At degree-2 chain pixels the penalty is
    near zero; at junctions the most-aligned exit wins."""
    if blocked is None:
        blocked = set()
    if start == end:
        return [start]
    if start not in adj or end not in adj:
        return None

    if inbound_tangent is None:
        # FIFO BFS — existing behaviour preserved bit-for-bit.
        parent: dict[tuple[int, int], tuple[int, int] | None] = {start: None}
        q: deque[tuple[int, int]] = deque([start])
        while q:
            cur = q.popleft()
            if cur == end:
                break
            for n in adj.get(cur, []):
                if n not in parent and n not in blocked:
                    parent[n] = cur
                    q.append(n)
        if end not in parent:
            return None
        path: list[tuple[int, int]] = []
        cur_p: tuple[int, int] | None = end
        while cur_p is not None:
            path.append(cur_p)
            cur_p = parent[cur_p]
        path.reverse()
        return path

    # Tangent-aware Dijkstra. State is (cur_pixel, prev_pixel); the
    # predecessor is required because the edge cost depends on the angle
    # between the prev→cur edge and the cur→nxt edge. Bootstrap with a
    # virtual predecessor offset by -inbound_tangent so the first edge's
    # angle is measured against the requested arrival direction.
    tdx, tdy = inbound_tangent
    tnorm = math.hypot(tdx, tdy)
    if tnorm < 1e-9:
        return bfs_path(start, end, adj, blocked=blocked,
                        inbound_tangent=None)
    tdx /= tnorm
    tdy /= tnorm
    init_prev: tuple[float, float] = (start[0] - tdx, start[1] - tdy)

    def step_cost(prev, cur, nxt) -> float:
        ax = cur[0] - prev[0]
        ay = cur[1] - prev[1]
        bx = nxt[0] - cur[0]
        by = nxt[1] - cur[1]
        an = math.hypot(ax, ay)
        bn = math.hypot(bx, by)
        if an < 1e-9 or bn < 1e-9:
            return 1.0
        cos_t = (ax * bx + ay * by) / (an * bn)
        cos_t = max(-1.0, min(1.0, cos_t))
        return 1.0 + angle_weight * (1.0 - cos_t) / 2.0

    dist: dict[tuple, float] = {}
    parent_state: dict[tuple, tuple] = {}
    start_state = (start, init_prev)
    dist[start_state] = 0.0
    heap: list[tuple[float, int, tuple]] = [(0.0, 0, start_state)]
    counter = 1
    end_state: tuple | None = None
    while heap:
        cost, _, st = heapq.heappop(heap)
        if cost > dist.get(st, float("inf")):
            continue
        cur, prev = st
        if cur == end:
            end_state = st
            break
        for n in adj.get(cur, []):
            if n in blocked:
                continue
            new_cost = cost + step_cost(prev, cur, n)
            new_st = (n, cur)
            if new_cost < dist.get(new_st, float("inf")):
                dist[new_st] = new_cost
                parent_state[new_st] = st
                heapq.heappush(heap, (new_cost, counter, new_st))
                counter += 1
    if end_state is None:
        return None
    path = []
    st_p: tuple | None = end_state
    while st_p is not None:
        path.append(st_p[0])
        st_p = parent_state.get(st_p)
    path.reverse()
    return path


def walk_continuous(anchors: list,
                    adj: dict[tuple[int, int], list[tuple[int, int]]],
                    skel: np.ndarray,
                    bbox: tuple[int, int, int, int],
                    initial_tangent: tuple[float, float] | None = None,
                    ) -> list[tuple[int, int]] | None:
    """BFS-walk through `anchors` in order, stitching shortest paths
    head-to-tail. Returns None if any leg is unreachable.

    Tangent threading (Phase 3): each leg after the first is routed
    with `inbound_tangent` set to the direction of the previous leg's
    final edge. This carries direction across junctions so a chain of
    legs holds its tangent through multi-stroke meeting points. The
    first leg uses `initial_tangent` (None = unbiased BFS)."""
    if not anchors:
        return None
    pixels = [resolve_anchor(a, skel, bbox) for a in anchors]
    if any(p is None for p in pixels):
        return None
    full: list[tuple[int, int]] = [pixels[0]]
    tangent = initial_tangent
    for i in range(len(pixels) - 1):
        seg = bfs_path(pixels[i], pixels[i + 1], adj,
                       inbound_tangent=tangent)
        if seg is None or len(seg) < 2:
            return None
        full.extend(seg[1:])
        a, b = seg[-2], seg[-1]
        tangent = (float(b[0] - a[0]), float(b[1] - a[1]))
    return full


def walk_loop_at(anchor,
                 direction: str,
                 adj: dict[tuple[int, int], list[tuple[int, int]]],
                 skel: np.ndarray,
                 bbox: tuple[int, int, int, int],
                 stop_at=None,
                 ) -> list[tuple[int, int]] | None:
    """Walk a closed cycle on the skeleton component containing the
    anchor's nearest skeleton pixel, then enforce direction (CCW = the
    Austrian writing convention for O / o). Falls back to a chain walk
    (endpoint-to-endpoint) when the component is a degenerate non-loop
    — i/j dots skeletonize to a 3–5 px line rather than a true cycle,
    so requiring a closed cycle would drop the dot entirely.

    `stop_at` is an optional anchor; when provided, the cycle walk
    truncates at the path pixel nearest to `stop_at`'s resolved
    skeleton pixel, rather than returning to `anchor`. Used for
    bowl-with-attached-stem letters (b/d/g/p/q) where the closed
    cycle reachable from the bowl includes a stem traversal — the
    stop anchor terminates the bowl walk at the bowl/stem junction."""
    seed = resolve_anchor(anchor, skel, bbox)
    if seed is None:
        return None
    if seed not in adj:
        return None
    if len(adj[seed]) >= 2:
        path = _walk_cycle_ccw(seed, adj)
        if direction == "cw":
            path = list(reversed(path))
        if stop_at is not None:
            stop_pix = resolve_anchor(stop_at, skel, bbox)
            if stop_pix is None:
                return None
            best_i = None
            best_d2 = None
            for i, p in enumerate(path):
                if i == 0:
                    continue  # don't accept seed itself as the stop
                d2 = (p[0] - stop_pix[0]) ** 2 + (p[1] - stop_pix[1]) ** 2
                if best_d2 is None or d2 < best_d2:
                    best_d2 = d2
                    best_i = i
            if best_i is None or best_i < 1:
                return None
            path = path[:best_i + 1]
        return path
    # Non-cycle (degree-1 endpoint): walk the whole connected chain
    # by collecting the component, then return endpoint-to-endpoint.
    component: set[tuple[int, int]] = {seed}
    stack = [seed]
    while stack:
        cur = stack.pop()
        for n in adj[cur]:
            if n not in component:
                component.add(n)
                stack.append(n)
    endpoints = [p for p in component if len(adj[p]) == 1]
    if len(endpoints) < 2:
        return [seed]
    path = bfs_path(endpoints[0], endpoints[1], adj)
    return path if path else [seed]


# Phase 3 — `through` primitive helpers.
#
# `through` is "straight tangent line through the ink, with lateral
# correction." The medial axis is ignored entirely: from/to anchors
# resolve only to seed/terminate positions, and the path is synthesised
# pixel by pixel along the requested tangent direction, with lateral
# drift to track gentle font curvature. This is the workhorse for every
# letter where the medial axis snaps to merged-center at multi-stroke
# meeting points — N's verticals/diagonal, V's diagonals, b/d/p/q's
# stem, etc. Earlier revisions wrapped this in an on-skeleton Dijkstra
# attempt with an acceptance gate; the gate's heuristics were too
# fragile to be worth the complexity (the gate had to trigger for b's
# stem-bow case and not trigger for plausible-looking-but-wrong
# skeleton paths). Skipping the skeleton entirely is the simpler
# semantics and produces the same result for every case we care about.


def synthesize_off_skeleton(start_pix: tuple[int, int],
                            end_pix: tuple[int, int],
                            tangent: tuple[float, float],
                            ink_mask: np.ndarray,
                            max_steps: int = 4000,
                            terminate_radius_px: float = 6.0,
                            ) -> list[tuple[int, int]] | None:
    """Walk in `tangent` direction along ink-mask pixels from
    `start_pix` toward `end_pix`, synthesising one path pixel per
    step. Terminates when:
    - all three candidate pixels (straight-ahead and the two ±1
      perpendicular drifts) are out of the ink mask;
    - the walker comes within `terminate_radius_px` of `end_pix`
      (snaps final pixel to `end_pix` and returns).

    Lateral correction. The walker prefers the straight-ahead candidate
    (current + tangent). When that pixel is out of ink, it tries the
    two pixels offset ±1 in the direction perpendicular to the tangent;
    if either is in ink, it takes that one (when both are in ink, it
    prefers the one whose perpendicular distance to the centerline
    through `start_pix` is smaller, pulling the walk back toward the
    original line). The tangent vector itself doesn't change — only the
    accumulated float position drifts. This lets the synth track gentle
    font curvature (e.g. b's stem leaning leftward at the foot) without
    abandoning the straight-tangent intent.

    Used by the `through` primitive's off-skeleton fallback to draw a
    stroke's natural path through a multi-stroke merge zone where the
    medial axis snaps to the merged-center (e.g. b/d/p/q's stem-meets-
    bowl junction)."""
    dx, dy = tangent
    n = math.hypot(dx, dy)
    if n < 1e-9:
        return None
    dx /= n
    dy /= n
    # Perpendicular unit vector (tangent rotated 90° CCW).
    perp_x = -dy
    perp_y = dx
    h, w = ink_mask.shape
    sx, sy = float(start_pix[0]), float(start_pix[1])
    x, y = sx, sy
    path: list[tuple[int, int]] = [(int(round(x)), int(round(y)))]

    def in_ink(ic: int, ir: int) -> bool:
        return 0 <= ir < h and 0 <= ic < w and bool(ink_mask[ir, ic])

    def perp_offset(fx: float, fy: float) -> float:
        """Signed perp distance from candidate (fx, fy) to the centerline
        through start_pix along the tangent direction."""
        return (fx - sx) * perp_x + (fy - sy) * perp_y

    for _ in range(max_steps):
        # Straight-ahead candidate.
        ax = x + dx
        ay = y + dy
        a_ic, a_ir = int(round(ax)), int(round(ay))
        if in_ink(a_ic, a_ir):
            x, y, ic, ir = ax, ay, a_ic, a_ir
        else:
            # Lateral drift candidates: straight-ahead ±1 perpendicular.
            plus_x = ax + perp_x
            plus_y = ay + perp_y
            minus_x = ax - perp_x
            minus_y = ay - perp_y
            plus_ic, plus_ir = int(round(plus_x)), int(round(plus_y))
            minus_ic, minus_ir = int(round(minus_x)), int(round(minus_y))
            plus_ok = in_ink(plus_ic, plus_ir)
            minus_ok = in_ink(minus_ic, minus_ir)
            if not plus_ok and not minus_ok:
                break
            if plus_ok and not minus_ok:
                x, y, ic, ir = plus_x, plus_y, plus_ic, plus_ir
            elif minus_ok and not plus_ok:
                x, y, ic, ir = minus_x, minus_y, minus_ic, minus_ir
            else:
                # Both viable — pick the one closer to the centerline.
                if abs(perp_offset(plus_x, plus_y)) <= abs(perp_offset(minus_x, minus_y)):
                    x, y, ic, ir = plus_x, plus_y, plus_ic, plus_ir
                else:
                    x, y, ic, ir = minus_x, minus_y, minus_ic, minus_ir
        if (ic, ir) != path[-1]:
            path.append((ic, ir))
        if math.hypot(ic - end_pix[0], ir - end_pix[1]) <= terminate_radius_px:
            if (end_pix[0], end_pix[1]) != path[-1]:
                path.append((end_pix[0], end_pix[1]))
            return path
    return path if len(path) >= 2 else None


def strokes_from_override(letter: str,
                          mask: np.ndarray,
                          skel: np.ndarray,
                          bbox: tuple[int, int, int, int]
                          ) -> list[list[tuple[int, int]]] | None:
    """Build strokes from the LETTER_OVERRIDES spec. Returns None when
    the override doesn't exist or any walk fails (e.g. an anchor is
    unreachable on this font's specific geometry); the caller falls
    back to auto-extraction in that case."""
    spec = LETTER_OVERRIDES.get(letter)
    if not spec:
        return None
    rows, cols = np.where(skel)
    skel_pixels = set(zip(cols.tolist(), rows.tolist()))
    adj = build_adjacency(skel_pixels)
    out: list[list[tuple[int, int]]] = []
    for stroke_spec in spec:
        kind = stroke_spec["kind"]
        if kind == "walk":
            start = resolve_anchor(stroke_spec["from"], skel, bbox)
            end = resolve_anchor(stroke_spec["to"], skel, bbox)
            if start is None or end is None:
                return None
            path = bfs_path(start, end, adj)
            if path is None or len(path) < 2:
                return None
            out.append(path)
        elif kind == "continuous":
            path = walk_continuous(stroke_spec["anchors"], adj, skel, bbox)
            if path is None:
                return None
            out.append(path)
        elif kind == "loop":
            path = walk_loop_at(stroke_spec["start"],
                                stroke_spec.get("direction", "ccw"),
                                adj, skel, bbox,
                                stop_at=stroke_spec.get("stop_at"))
            if path is None:
                return None
            out.append(path)
        elif kind == "through":
            start = resolve_anchor_raw(stroke_spec["from"], bbox)
            end = resolve_anchor_raw(stroke_spec["to"], bbox)
            tangent = stroke_spec.get("tangent")
            if tangent is None:
                tangent = (float(end[0] - start[0]),
                           float(end[1] - start[1]))
            path = synthesize_off_skeleton(start, end, tangent, mask)
            if path is None or len(path) < 2:
                return None
            out.append(path)
        else:
            raise ValueError(f"Unknown override kind: {kind!r}")
    return out


def strokes_auto(skel: np.ndarray) -> list[list[tuple[int, int]]]:
    """Fallback per-component extraction (split + merge + walk). Used
    when a letter has no override entry or the override walker fails."""
    labels = measure.label(skel, connectivity=2)
    n_components = labels.max()
    out: list[list[tuple[int, int]]] = []
    for lbl in range(1, n_components + 1):
        comp_mask = labels == lbl
        rs, cs = np.where(comp_mask)
        comp_pixels = set(zip(cs.tolist(), rs.tolist()))
        if not comp_pixels:
            continue
        adj = build_adjacency(comp_pixels)
        segments = split_into_segments(comp_pixels, adj)
        merged = merge_segments_at_branches(segments)
        for s in merged:
            if len(s) >= 2:
                out.append(s)
    return out


# -----------------------------------------------------------------------------
# Top-level letter pipeline
# -----------------------------------------------------------------------------

def generate_for_letter(letter: str, font_path: Path,
                        ) -> tuple[dict, dict]:
    """Returns (json_data, debug_info) for one letter. Tries the
    worksheet override first; falls back to auto-extraction when the
    override is absent or its walker fails on this font's geometry."""
    mask = rasterize(letter, font_path)
    skel = morph.skeletonize(mask)
    skel = extend_tips_to_outline(skel, ink_mask=mask,
                                  max_extension=MAX_TIP_EXTENSION,
                                  tangent_window=TANGENT_WINDOW)
    skel = prune_skeleton_spurs(skel, max_spur_length=MAX_SPUR_LENGTH)

    rows, cols = np.where(mask)
    if len(rows) == 0:
        raise ValueError(f"Empty glyph for {letter!r}")
    bbox = (int(cols.min()), int(rows.min()),
            int(cols.max()), int(rows.max()))

    used_override = False
    raw_strokes = strokes_from_override(letter, mask, skel, bbox)
    if raw_strokes is not None and raw_strokes:
        used_override = True
    else:
        raw_strokes = strokes_auto(skel)
        # Auto extraction owns ordering and direction; overrides
        # already encode both, so we only re-run the orderer for the
        # auto path.
        raw_strokes = order_strokes(raw_strokes)
        raw_strokes = [order_stroke(s) for s in raw_strokes]

    sampled = [trim_lead_in(prune_spikes(prune_retraces(resample(s))))
               for s in raw_strokes]

    json_strokes = []
    for i, s in enumerate(sampled, start=1):
        rel = to_bbox_relative(s, bbox)
        comment = ("worksheet" if used_override
                   else f"auto-{stroke_orientation(s)}")
        json_strokes.append({
            "id": i,
            "checkpoints": [{"x": round(x, 4), "y": round(y, 4)}
                            for (x, y) in rel],
            "comment": comment,
        })
    # 8-neighbour adjacency, no subsample. The previous bake used [::2]
    # subsampling + a 3.5-px all-pairs adjacency; on letters with parallel
    # stroke arms close together (M, V, W, Ä, etc.) this cross-linked the
    # medial-axis chains, producing degree-5/6 nodes that BFS could shortcut
    # through stroke boundaries. Strict 8-neighbour preserves true chain
    # topology and matches the convention the iOS-side calibrator's runtime
    # fallback already uses.
    sk_rows_full, sk_cols_full = np.where(skel)
    bbox_w = max(1, bbox[2] - bbox[0])
    bbox_h = max(1, bbox[3] - bbox[1])
    skeleton_pts = []
    pixel_to_idx: dict[tuple[int, int], int] = {}
    for i, (r, c) in enumerate(zip(sk_rows_full.tolist(),
                                   sk_cols_full.tolist())):
        skeleton_pts.append({
            "x": round((c - bbox[0]) / bbox_w, 4),
            "y": round((r - bbox[1]) / bbox_h, 4),
        })
        pixel_to_idx[(r, c)] = i
    skeleton_adj: list[list[int]] = []
    for r, c in zip(sk_rows_full.tolist(), sk_cols_full.tolist()):
        nbrs = [pixel_to_idx[(r + dr, c + dc)]
                for dr, dc in NEIGHBOURS_8
                if (r + dr, c + dc) in pixel_to_idx]
        skeleton_adj.append(nbrs)

    data = {
        "letter": letter,
        "checkpointRadius": DEFAULT_RADIUS,
        "strokes": json_strokes,
        "skeleton": skeleton_pts,
        "skeletonAdj": skeleton_adj,
    }
    debug = {
        "mask": mask,
        "skel": skel,
        "bbox": bbox,
        "raw_strokes": sampled,
        "used_override": used_override,
    }
    return data, debug


# -----------------------------------------------------------------------------
# Debug overlay
# -----------------------------------------------------------------------------

def debug_overlay(letter: str, debug: dict, out_path: Path) -> None:
    mask = debug["mask"]
    img = Image.fromarray(np.where(mask, 0, 230).astype(np.uint8)).convert("RGB")
    draw = ImageDraw.Draw(img)
    palette = [
        (220, 30, 30), (30, 130, 30), (30, 60, 200), (220, 130, 30),
        (180, 30, 180), (30, 180, 200), (200, 200, 30), (130, 30, 130),
    ]
    for i, seg in enumerate(debug["raw_strokes"]):
        color = palette[i % len(palette)]
        if len(seg) >= 2:
            draw.line([(c, r) for (c, r) in seg], fill=color, width=4)
        if seg:
            c, r = seg[0]
            draw.ellipse((c - 12, r - 12, c + 12, r + 12), fill=color)
    img.save(str(out_path))


# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------

def output_dir_for(letter: str) -> Path:
    if letter.isupper() or not letter.isalpha():
        return OUTPUT_BASE / letter
    return OUTPUT_BASE / f"{letter}{LOWERCASE_SUFFIX}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("letters", nargs="*",
                        help="Letters to generate. Default: all 59.")
    parser.add_argument("--font", default=str(DEFAULT_FONT),
                        help="OTF / TTF font path. Default: Primae-Regular.")
    parser.add_argument("--out", default=None,
                        help="Output base dir. Default: PrimaeNative/Resources/Letters.")
    parser.add_argument("--no-overwrite", action="store_true",
                        help="Skip letters whose strokes.json already exists.")
    parser.add_argument("--debug", action="store_true",
                        help="Save /tmp/auto_<L>.png debug overlay per letter.")
    args = parser.parse_args()

    font_path = Path(args.font)
    if not font_path.exists():
        print(f"Font not found: {font_path}")
        return 1
    out_base = Path(args.out) if args.out else OUTPUT_BASE
    letters = args.letters or ALL_LETTERS

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
            data, debug = generate_for_letter(letter, font_path)
        except Exception as e:
            print(f"  {letter}: FAIL — {e}")
            fail += 1
            continue
        out_dir.mkdir(parents=True, exist_ok=True)
        out_file.write_text(json.dumps(data, indent=2, ensure_ascii=False))
        n_pts = sum(len(s["checkpoints"]) for s in data["strokes"])
        print(f"  {letter}: ✓ {len(data['strokes'])} strokes, {n_pts} checkpoints")
        if args.debug:
            debug_overlay(letter, debug, Path(f"/tmp/auto_{letter}.png"))
        ok += 1
    if ok > 0:
        manifest = out_base / "_meta.json"
        try:
            font_hash = hashlib.sha256(font_path.read_bytes()).hexdigest()
            manifest.write_text(json.dumps({
                "fontPath": str(font_path),
                "fontSha256": font_hash,
                "generator": "generate_strokes_auto.py",
            }, indent=2))
            print(f"  _meta.json: font sha256 {font_hash[:12]}…")
        except Exception as e:
            print(f"  _meta.json: FAIL — {e}")
    print(f"\nDone — {ok} ok, {fail} failed.")
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
