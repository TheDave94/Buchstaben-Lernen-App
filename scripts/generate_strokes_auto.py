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
# get one every `CURVE_SPACING_PX` (3× denser). Floor at
# `MIN_CHECKPOINTS_PER_STROKE` so even tiny dots have enough waypoints
# for the proximity tracker.
BASE_SPACING_PX = 12
CURVE_SPACING_PX = 4
CURVE_ANGLE_DEG = 15
CURVE_WINDOW_PX = 6
MIN_CHECKPOINTS_PER_STROKE = 15
MERGE_ANGLE_THRESHOLD_DEG = 35  # segments within 35° of collinear get merged

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
        {"kind": "continuous", "anchors": ["TR", "MR", "ML", "MR", "BR"]},
    ],
    "C": [
        {"kind": "walk", "from": "TR", "to": "BR"},
    ],
    "D": [
        {"kind": "walk", "from": "TL", "to": "BL"},
        {"kind": "continuous", "anchors": ["TR", "MR", "BR"]},
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
        {"kind": "continuous", "anchors": ["TR", "L", "B", "MR"]},
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
        {"kind": "continuous", "anchors": ["TL", "TR", "BR", "BC", "BL"]},
    ],
    "K": [
        {"kind": "walk", "from": "TL", "to": "BL"},
        {"kind": "walk", "from": "TR", "to": "ML"},
        {"kind": "walk", "from": "ML", "to": "BR"},
    ],
    "L": [
        {"kind": "continuous", "anchors": ["TL", "BL", "BR"]},
    ],
    "M": [
        {"kind": "continuous", "anchors": ["BL", "TL", "BC", "TR", "BR"]},
    ],
    "N": [
        {"kind": "continuous", "anchors": ["BL", "TL", "BR", "TR"]},
    ],
    "O": [
        {"kind": "loop", "start": "T", "direction": "ccw"},
    ],
    "P": [
        {"kind": "walk", "from": "TL", "to": "BL"},
        {"kind": "continuous", "anchors": ["TR", "MR", "ML"]},
    ],
    "Q": [
        {"kind": "loop", "start": "T", "direction": "ccw"},
        {"kind": "walk", "from": "C", "to": "BR"},
    ],
    "R": [
        {"kind": "walk", "from": "TL", "to": "BL"},
        {"kind": "continuous", "anchors": ["TR", "MR", "ML"]},
        {"kind": "walk", "from": "MR", "to": "BR"},
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
    ],
    "V": [
        {"kind": "continuous", "anchors": ["TL", "BC", "TR"]},
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
        {"kind": "walk", "from": "TR", "to": "C"},
        {"kind": "walk", "from": "C",  "to": "B"},
    ],
    "Z": [
        {"kind": "continuous", "anchors": ["TL", "TR", "BL", "BR"]},
    ],

    # ─── Lowercase ────────────────────────────────────────────────────
    "a": [
        {"kind": "loop", "start": "T", "direction": "ccw"},
        {"kind": "walk", "from": "TR", "to": "BR"},
    ],
    "b": [
        {"kind": "continuous", "anchors": ["TL", "BL", "BR", "MR", "ML"]},
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
        {"kind": "walk", "from": "T", "to": "B"},
        {"kind": "loop", "start": (0.5, 0.05), "direction": "ccw"},
    ],
    "j": [
        {"kind": "walk", "from": "T", "to": "BL"},
        {"kind": "loop", "start": (0.5, 0.05), "direction": "ccw"},
    ],
    "k": [
        {"kind": "walk", "from": "TL", "to": "BL"},
        {"kind": "walk", "from": "TR", "to": "ML"},
        {"kind": "walk", "from": "ML", "to": "BR"},
    ],
    "l": [
        {"kind": "walk", "from": "T", "to": "B"},
    ],
    "m": [
        {"kind": "continuous",
         "anchors": ["BL", "TL", "BC", "TC", "BR", "TR"]},
    ],
    "n": [
        {"kind": "continuous", "anchors": ["BL", "TL", "TR", "BR"]},
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
        {"kind": "walk", "from": "TL", "to": "BL"},
        {"kind": "walk", "from": "TL", "to": "TR"},
    ],
    "s": [
        {"kind": "walk", "from": "TR", "to": "BL"},
    ],
    "t": [
        {"kind": "walk", "from": "T", "to": "B"},
        {"kind": "walk", "from": "ML", "to": "MR"},
    ],
    "u": [
        {"kind": "continuous", "anchors": ["TL", "BL", "BR", "TR"]},
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
        {"kind": "walk", "from": "TL", "to": "BC"},
        {"kind": "walk", "from": "TR", "to": "BL"},
    ],
    "z": [
        {"kind": "continuous", "anchors": ["TL", "TR", "BL", "BR"]},
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
         "anchors": [(0.05, 0.18), (0.05, 0.95), (0.95, 0.95), (0.95, 0.18)]},
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
         "anchors": [(0.05, 0.30), (0.05, 0.95),
                     (0.95, 0.95), (0.95, 0.30)]},
        {"kind": "loop", "start": (0.30, 0.05), "direction": "ccw"},
        {"kind": "loop", "start": (0.70, 0.05), "direction": "ccw"},
    ],
    "ß": [
        {"kind": "continuous",
         "anchors": ["BL", "TL", "TR", "MR", "ML", "MR", "BR"]},
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

def rasterize(letter: str, font_path: Path) -> np.ndarray:
    """Render `letter` to a SIZE×SIZE binary mask using uniform
    font-metric scaling (em-square = 80 % of canvas height, baseline
    placed at `pad + ascent`). Mirrors `PrimaeLetterRenderer.glyphPath`.
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
    ImageDraw.Draw(img).text((x, baseline_y), letter, font=font,
                             fill=0, anchor="ls")
    return np.array(img) < 128


# -----------------------------------------------------------------------------
# Skeleton graph: nodes = pixels, edges = 8-connected neighbours
# -----------------------------------------------------------------------------

NEIGHBOURS_8 = [(-1, -1), (-1, 0), (-1, 1),
                (0, -1),           (0, 1),
                (1, -1),  (1, 0),  (1, 1)]


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


def _walk_cycle_ccw(seed: tuple[int, int],
                    adj: dict[tuple[int, int], list[tuple[int, int]]]
                    ) -> list[tuple[int, int]]:
    """Walk a closed skeleton cycle starting at `seed`, return the
    full path including the seed at both ends. Direction is forced to
    visual counter-clockwise (handwriting convention for O / o)."""
    if len(adj[seed]) < 2:
        return [seed]
    # Walk one direction first; reverse if it turned out clockwise.
    visited = {seed}
    cur = adj[seed][0]
    path = [seed, cur]
    visited.add(cur)
    while True:
        options = [n for n in adj[cur] if n not in visited]
        if not options:
            if seed in adj[cur] and cur != seed:
                path.append(seed)
            break
        cur = options[0]
        path.append(cur)
        visited.add(cur)

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


def resample(seg: list[tuple[int, int]],
             base: float = BASE_SPACING_PX,
             curve: float = CURVE_SPACING_PX,
             curve_angle_deg: float = CURVE_ANGLE_DEG,
             window_px: float = CURVE_WINDOW_PX,
             min_pts: int = MIN_CHECKPOINTS_PER_STROKE
             ) -> list[tuple[int, int]]:
    """Curvature-adaptive resampling. Straight runs get a checkpoint
    every `base` pixels; runs whose local angle change exceeds
    `curve_angle_deg` get one every `curve` pixels (≈ 3× density).
    Falls back to uniform sampling at `min_pts` if the adaptive walk
    yielded too few checkpoints (true for short strokes like dots)."""
    if len(seg) < 2:
        return seg
    cum = [0.0]
    for i in range(1, len(seg)):
        cum.append(cum[-1] + math.hypot(seg[i][0] - seg[i - 1][0],
                                        seg[i][1] - seg[i - 1][1]))
    total = cum[-1]
    if total <= base:
        return _uniform_resample(seg, cum, min_pts)

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
    the nearest skeleton pixel. Returns None for an empty skeleton."""
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


def bfs_path(start: tuple[int, int],
             end: tuple[int, int],
             adj: dict[tuple[int, int], list[tuple[int, int]]],
             blocked: set[tuple[int, int]] | None = None
             ) -> list[tuple[int, int]] | None:
    """Shortest path along the skeleton graph. Returns None when end is
    unreachable from start (e.g. they're in disconnected components)."""
    if blocked is None:
        blocked = set()
    if start == end:
        return [start]
    if start not in adj or end not in adj:
        return None
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
    cur: tuple[int, int] | None = end
    while cur is not None:
        path.append(cur)
        cur = parent[cur]
    path.reverse()
    return path


def walk_continuous(anchors: list,
                    adj: dict[tuple[int, int], list[tuple[int, int]]],
                    skel: np.ndarray,
                    bbox: tuple[int, int, int, int]
                    ) -> list[tuple[int, int]] | None:
    """BFS-walk through `anchors` in order, stitching shortest paths
    head-to-tail. Returns None if any leg is unreachable."""
    if not anchors:
        return None
    pixels = [resolve_anchor(a, skel, bbox) for a in anchors]
    if any(p is None for p in pixels):
        return None
    full: list[tuple[int, int]] = [pixels[0]]
    for i in range(len(pixels) - 1):
        seg = bfs_path(pixels[i], pixels[i + 1], adj)
        if seg is None or len(seg) < 2:
            return None
        full.extend(seg[1:])
    return full


def walk_loop_at(anchor,
                 direction: str,
                 adj: dict[tuple[int, int], list[tuple[int, int]]],
                 skel: np.ndarray,
                 bbox: tuple[int, int, int, int]
                 ) -> list[tuple[int, int]] | None:
    """Walk a closed cycle on the skeleton component containing the
    anchor's nearest skeleton pixel, then enforce direction (CCW = the
    Austrian writing convention for O / o). Returns None if the
    component isn't a cycle."""
    seed = resolve_anchor(anchor, skel, bbox)
    if seed is None:
        return None
    if seed not in adj or len(adj[seed]) < 2:
        return None
    path = _walk_cycle_ccw(seed, adj)
    if direction == "cw":
        path = list(reversed(path))
    return path


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
                                adj, skel, bbox)
            if path is None:
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

    sampled = [resample(s) for s in raw_strokes]

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
    # Skeleton point cloud in glyph-bbox coords + adjacency. Subsampled
    # every 2 px so the JSON stays small. iOS uses the cloud for snap
    # and the adjacency for BFS-along-skeleton between calibrator
    # anchor points.
    sk_rows_full = sk_cols_full = None
    sk_rows_full, sk_cols_full = np.where(skel)
    sk_rows = sk_rows_full.tolist()[::2]
    sk_cols = sk_cols_full.tolist()[::2]
    bbox_w = max(1, bbox[2] - bbox[0])
    bbox_h = max(1, bbox[3] - bbox[1])
    skeleton_pts = []
    for r, c in zip(sk_rows, sk_cols):
        skeleton_pts.append({
            "x": round((c - bbox[0]) / bbox_w, 4),
            "y": round((r - bbox[1]) / bbox_h, 4),
        })
    # Adjacency among subsampled points: a point's neighbours are the
    # other subsampled points within a small generator-pixel radius.
    # Three-pixel threshold matches the 2-px subsample stride plus a
    # one-pixel slack so a sample can still find its successor when
    # skeleton walks include a diagonal step.
    adj_threshold_sq = 3.5 * 3.5
    sk_xy = np.array(list(zip(sk_cols, sk_rows)), dtype=np.float64)
    skeleton_adj: list[list[int]] = []
    if len(sk_xy) > 0:
        for i in range(len(sk_xy)):
            d = sk_xy - sk_xy[i]
            d2 = (d * d).sum(axis=1)
            d2[i] = np.inf  # exclude self
            idx = np.where(d2 <= adj_threshold_sq)[0]
            skeleton_adj.append(idx.tolist())
    else:
        skeleton_adj = []

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
    print(f"\nDone — {ok} ok, {fail} failed.")
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
