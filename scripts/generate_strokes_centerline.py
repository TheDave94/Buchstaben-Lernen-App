#!/usr/bin/env python3
"""
Generate strokes.json files with checkpoints centered on the rendered glyph.

Per-stroke spec is just (start, end), with optional `via` waypoints to
disambiguate paths through closed loops or where two strokes share their
endpoints (e.g., D's vertical and arc both run from top-left to bottom-left
of the glyph; the arc needs a `via` near its rightmost point).

Algorithm
---------
1. Rasterize the letter from `Primae-Regular.otf` at 512×512 with 10% pad
   (matches what the app actually renders via PrimaeLetterRenderer).
2. Skeletonize the glyph mask (Zhang-Suen via scikit-image).
3. For each stroke spec: BFS along the skeleton from the nearest skeleton
   pixel to `start`, through each `via`, to the nearest pixel to `end`.
4. Sample N evenly-spaced checkpoints along that pixel path and write
   them to `strokes.json` as normalized [0, 1] coordinates.

Endpoints in the JSON keep the user-supplied normalized coords exactly
(they often sit just off the skeleton — e.g., F's serifs — and we want
the start dot to render where the spec says, not at the snapped skeleton
pixel).

Usage
-----
    pip install Pillow numpy scikit-image
    python scripts/generate_strokes_centerline.py            # all letters
    python scripts/generate_strokes_centerline.py A E O      # subset
    python scripts/generate_strokes_centerline.py --no-overwrite  # skip existing

Edit `LETTER_SPECS` below to change a stroke shape. Add `via` waypoints
when the BFS picks the wrong path; add `count` to override the auto-
derived checkpoint count.
"""
from __future__ import annotations

import argparse
import json
from collections import deque
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from skimage.measure import label as cc_label
from skimage.morphology import skeletonize


REPO_ROOT = Path(__file__).resolve().parent.parent
FONT_PATH = REPO_ROOT / "design-system/fonts/Primae-Regular.otf"
OUTPUT_BASE = REPO_ROOT / "PrimaeNative/Resources/Letters"

# Raster size of the rendered glyph used for skeleton extraction.
SIZE = 512
PAD = 0.10
DEFAULT_RADIUS = 0.06


# Per-stroke spec.
#   start, end:  required, normalized [0, 1] (x→right, y→down).
#   via:         optional list of waypoints to route through (in order).
#                Use when start+end alone don't pick the right skeleton path
#                (closed loops like O, or two strokes that share endpoints
#                like D's | and arc).
#   count:       optional explicit checkpoint count. Default auto-derives
#                from path length (~1 cp per 50 px, clamped 3..12).
#   comment:     optional human-readable note copied through to the JSON.
LETTER_SPECS: dict[str, list[dict]] = {
    "A": [
        # Worksheet: ↑ at bottom-left of left leg → start at the
        # bottom and go UP to the apex. The right leg then leaves
        # the apex going down-right; crossbar last, left to right.
        {"start": [0.06, 0.96], "end": [0.58, 0.04], "via": [[0.34, 0.44]], "comment": "Left leg: bottom-left up to apex"},
        {"start": [0.58, 0.04], "end": [0.94, 0.96], "via": [[0.76, 0.50]], "comment": "Right leg: apex down-right"},
        {"start": [0.25, 0.60], "end": [0.80, 0.60], "comment": "Crossbar: left to right"},
    ],
    "B": [
        {"start": [0.35, 0.15], "end": [0.35, 0.85], "comment": "Vertical spine"},
        {"start": [0.35, 0.15], "end": [0.35, 0.50], "via": [[0.62, 0.28]], "comment": "Top bowl"},
        {"start": [0.35, 0.50], "end": [0.35, 0.85], "via": [[0.65, 0.65]], "comment": "Bottom bowl"},
    ],
    "C": [
        {"start": [0.72, 0.28], "end": [0.72, 0.75], "via": [[0.20, 0.50]], "comment": "Open arc (CCW)"},
    ],
    "D": [
        {"start": [0.35, 0.15], "end": [0.35, 0.85], "comment": "Vertical spine"},
        {"start": [0.35, 0.15], "end": [0.35, 0.85], "via": [[0.70, 0.50]], "comment": "Right arc"},
    ],
    "E": [
        # Worksheet stroke order: spine first (top→bottom), then
        # top / mid / bottom horizontals each drawn left → right.
        {"start": [0.35, 0.15], "end": [0.35, 0.85], "comment": "Vertical spine"},
        {"start": [0.35, 0.15], "end": [0.65, 0.15], "comment": "Top bar"},
        {"start": [0.35, 0.50], "end": [0.60, 0.50], "comment": "Mid bar"},
        {"start": [0.35, 0.85], "end": [0.65, 0.85], "comment": "Bottom bar"},
    ],
    "F": [
        {"start": [0.19, 0.04], "end": [0.08, 0.96], "via": [[0.11, 0.66]], "comment": "Spine: top to bottom"},
        {"start": [0.19, 0.04], "end": [0.96, 0.04], "comment": "Top bar: left to right"},
        {"start": [0.14, 0.48], "end": [0.78, 0.48], "comment": "Mid bar: left to right"},
    ],
    "G": [
        {"start": [0.72, 0.28], "end": [0.52, 0.55], "via": [[0.22, 0.65], [0.72, 0.55]], "comment": "Arc + inner bar"},
    ],
    "H": [
        {"start": [0.30, 0.15], "end": [0.30, 0.85], "comment": "Left spine"},
        {"start": [0.30, 0.50], "end": [0.70, 0.50], "comment": "Crossbar"},
        {"start": [0.70, 0.15], "end": [0.70, 0.85], "comment": "Right spine"},
    ],
    "I": [
        {"start": [0.70, 0.04], "end": [0.26, 0.97], "via": [[0.50, 0.50]], "comment": "Stem (italic)"},
    ],
    "J": [
        {"start": [0.60, 0.15], "end": [0.28, 0.72], "via": [[0.45, 0.85]], "comment": "Stem with hook"},
    ],
    "K": [
        # Worksheet: spine first, then upper arm comes IN to the
        # spine from the top-right (down-left), and the lower arm
        # leaves the spine going down-right.
        {"start": [0.16, 0.04], "end": [0.07, 0.95], "via": [[0.10, 0.64]], "comment": "Spine: top to bottom"},
        {"start": [0.93, 0.04], "end": [0.27, 0.48], "via": [[0.62, 0.24]], "comment": "Upper arm: top-right down to spine"},
        {"start": [0.27, 0.48], "end": [0.85, 0.95], "via": [[0.51, 0.69]], "comment": "Lower arm"},
    ],
    "L": [
        {"start": [0.21, 0.05], "end": [0.09, 0.95], "via": [[0.13, 0.62]], "comment": "Spine"},
        {"start": [0.10, 0.95], "end": [0.95, 0.95], "comment": "Foot"},
    ],
    "M": [
        # Worksheet: ↑ at bottom-left, no other arrows — drawn as
        # ONE continuous stroke from bottom-left up to top-left,
        # down to the mid valley, up to top-right, and back down to
        # the bottom-right.
        {"start": [0.04, 0.97], "end": [0.95, 0.95],
         "via": [[0.20, 0.05], [0.49, 0.91], [0.91, 0.04]],
         "comment": "Continuous M (BL ↑ TL → mid-V → TR → BR)"},
    ],
    "N": [
        # Worksheet: ↑ at bottom-left only — ONE continuous stroke
        # from bottom-left up to top-left, diagonally down to
        # bottom-right, then up to top-right.
        {"start": [0.28, 0.85], "end": [0.70, 0.15],
         "via": [[0.28, 0.15], [0.70, 0.85]],
         "comment": "Continuous N (BL ↑ TL → BR → TR)"},
    ],
    "O": [
        # Worksheet: ← at the top → start at top-centre, go LEFT
        # first (counter-clockwise). Routing the BFS via the LEFT
        # side anchor forces the start→via leg to take the
        # upper-left arc, producing a CCW traversal.
        {"start": [0.50, 0.10], "end": [0.50, 0.10], "via": [[0.18, 0.50]], "comment": "Oval (CCW from top via left)"},
    ],
    "P": [
        {"start": [0.33, 0.15], "end": [0.33, 0.85], "comment": "Vertical spine"},
        {"start": [0.33, 0.15], "end": [0.33, 0.50], "via": [[0.65, 0.40]], "comment": "Top bowl"},
    ],
    "R": [
        {"start": [0.33, 0.15], "end": [0.33, 0.85], "comment": "Vertical spine"},
        {"start": [0.33, 0.15], "end": [0.33, 0.50], "via": [[0.65, 0.40]], "comment": "Top bowl"},
        {"start": [0.33, 0.50], "end": [0.65, 0.85], "comment": "Diagonal leg"},
    ],
    "S": [
        {"start": [0.68, 0.25], "end": [0.25, 0.75], "via": [[0.50, 0.50]], "comment": "S-curve"},
    ],
    "T": [
        {"start": [0.25, 0.15], "end": [0.75, 0.15], "comment": "Top bar"},
        {"start": [0.50, 0.15], "end": [0.50, 0.85], "comment": "Stem"},
    ],
    "U": [
        {"start": [0.28, 0.15], "end": [0.72, 0.15], "via": [[0.55, 0.87]], "comment": "U-bend"},
    ],
    "V": [
        # Worksheet: ↓ at top-left only — ONE continuous stroke
        # from top-left down to the apex and up to top-right.
        {"start": [0.28, 0.15], "end": [0.72, 0.15],
         "via": [[0.50, 0.85]],
         "comment": "Continuous V (TL → apex → TR)"},
    ],
    "W": [
        # Worksheet: ↓ at top-left only — ONE continuous stroke
        # tracing the full M-shape from top-left down to the first
        # valley, up to the mid peak, down to the second valley,
        # up to the top-right.
        {"start": [0.18, 0.15], "end": [0.82, 0.15],
         "via": [[0.30, 0.85], [0.50, 0.45], [0.70, 0.85]],
         "comment": "Continuous W (TL → V₁ → mid → V₂ → TR)"},
    ],
    "X": [
        {"start": [0.25, 0.15], "end": [0.75, 0.85], "comment": "TL→BR diagonal"},
        {"start": [0.75, 0.15], "end": [0.25, 0.85], "comment": "TR→BL diagonal"},
    ],
    "Y": [
        # Worksheet: ↓ at top-left, ↓ at top-right (down-left into
        # junction), ↓ at junction. Left arm comes IN to the
        # junction from the top-left, right arm comes IN from
        # top-right, then the stem heads down.
        {"start": [0.25, 0.15], "end": [0.50, 0.50], "comment": "Left arm: top-left down to junction"},
        {"start": [0.75, 0.15], "end": [0.50, 0.50], "comment": "Right arm: top-right down to junction"},
        {"start": [0.50, 0.50], "end": [0.50, 0.85], "comment": "Stem: junction down"},
    ],
    "Z": [
        {"start": [0.25, 0.15], "end": [0.75, 0.15], "comment": "Top bar"},
        {"start": [0.75, 0.15], "end": [0.25, 0.85], "comment": "Diagonal"},
        {"start": [0.25, 0.85], "end": [0.75, 0.85], "comment": "Bottom bar"},
    ],
    "Q": [
        # Worksheet: ← at the top → CCW oval starting at top-centre
        # going LEFT first, like O. Routing the BFS via the LEFT-
        # side body skeleton forces the start→via leg to take the
        # upper-left arc.
        {"start": [0.50, 0.10], "end": [0.50, 0.10], "via": [[0.20, 0.50]], "comment": "Oval body (CCW from top via left)"},
        {"start": [0.55, 0.65], "end": [0.85, 0.95], "comment": "Tail"},
    ],
    # Austrian uppercase umlauts: 2 dots + base letter body. The base
    # letter is rendered smaller to make room for the dots, so its
    # normalized coords are pushed down vs. the standalone uppercase.
    "Ä": [
        {"start": [0.45, 0.14], "end": [0.45, 0.14], "comment": "Left dot"},
        {"start": [0.61, 0.14], "end": [0.61, 0.14], "comment": "Right dot"},
        {"start": [0.50, 0.30], "end": [0.28, 0.87], "via": [[0.39, 0.60]], "comment": "Left leg"},
        {"start": [0.50, 0.30], "end": [0.67, 0.87], "via": [[0.58, 0.60]], "comment": "Right leg"},
        {"start": [0.34, 0.68], "end": [0.61, 0.68], "comment": "Crossbar"},
    ],
    "Ö": [
        {"start": [0.46, 0.14], "end": [0.46, 0.14], "comment": "Left dot"},
        {"start": [0.62, 0.14], "end": [0.62, 0.14], "comment": "Right dot"},
        {"start": [0.40, 0.30], "end": [0.40, 0.30], "via": [[0.65, 0.85]], "comment": "Oval body"},
    ],
    "Ü": [
        {"start": [0.45, 0.14], "end": [0.45, 0.14], "comment": "Left dot"},
        {"start": [0.61, 0.14], "end": [0.61, 0.14], "comment": "Right dot"},
        {"start": [0.34, 0.30], "end": [0.66, 0.30], "via": [[0.50, 0.85]], "comment": "U-bend"},
    ],
    "ß": [
        {"start": [0.40, 0.14], "end": [0.40, 0.86], "comment": "Vertical spine"},
        {"start": [0.40, 0.14], "end": [0.40, 0.50], "via": [[0.65, 0.30]], "comment": "Top bowl"},
        {"start": [0.40, 0.50], "end": [0.55, 0.86], "via": [[0.66, 0.70]], "comment": "Bottom curve"},
    ],
    # Lowercase. Coordinates are normalized within each glyph's own
    # rendered bounding box (so 0.0..1.0 covers the full rasterized
    # glyph including ascenders / descenders, not the x-height alone).
    "a": [
        {"start": [0.70, 0.40], "end": [0.70, 0.80], "via": [[0.30, 0.55], [0.55, 0.80]], "comment": "Bowl + tail (one stroke)"},
    ],
    "b": [
        {"start": [0.40, 0.16], "end": [0.40, 0.85], "comment": "Vertical spine"},
        {"start": [0.40, 0.45], "end": [0.40, 0.85], "via": [[0.65, 0.65]], "comment": "Bowl"},
    ],
    "c": [
        {"start": [0.72, 0.30], "end": [0.72, 0.75], "via": [[0.30, 0.50]], "comment": "Open arc"},
    ],
    "d": [
        {"start": [0.45, 0.45], "end": [0.45, 0.85], "via": [[0.35, 0.65]], "comment": "Bowl"},
        {"start": [0.65, 0.16], "end": [0.65, 0.85], "comment": "Vertical spine"},
    ],
    "e": [
        {"start": [0.30, 0.55], "end": [0.70, 0.55], "comment": "Mid bar"},
        {"start": [0.70, 0.55], "end": [0.70, 0.75], "via": [[0.30, 0.45], [0.30, 0.75]], "comment": "Arc + tail"},
    ],
    "f": [
        {"start": [0.62, 0.16], "end": [0.45, 0.85], "via": [[0.50, 0.55]], "comment": "Spine (with hook)"},
        {"start": [0.40, 0.42], "end": [0.62, 0.42], "comment": "Crossbar"},
    ],
    "g": [
        {"start": [0.65, 0.40], "end": [0.65, 0.65], "via": [[0.35, 0.55]], "comment": "Bowl"},
        {"start": [0.65, 0.40], "end": [0.40, 0.86], "via": [[0.55, 0.85]], "comment": "Descender"},
    ],
    "h": [
        {"start": [0.40, 0.16], "end": [0.40, 0.85], "comment": "Vertical spine"},
        {"start": [0.40, 0.50], "end": [0.65, 0.85], "via": [[0.60, 0.45]], "comment": "Arch"},
    ],
    "i": [
        {"start": [0.50, 0.40], "end": [0.50, 0.85], "comment": "Stem"},
        {"start": [0.50, 0.16], "end": [0.50, 0.16], "comment": "Dot"},
    ],
    "j": [
        {"start": [0.55, 0.30], "end": [0.40, 0.86], "via": [[0.50, 0.85]], "comment": "Stem with descender hook"},
        {"start": [0.55, 0.14], "end": [0.55, 0.14], "comment": "Dot"},
    ],
    "k": [
        {"start": [0.40, 0.14], "end": [0.40, 0.85], "comment": "Vertical spine"},
        {"start": [0.40, 0.55], "end": [0.66, 0.50], "comment": "Upper arm"},
        {"start": [0.46, 0.65], "end": [0.65, 0.85], "comment": "Lower arm"},
    ],
    "l": [
        {"start": [0.50, 0.14], "end": [0.50, 0.85], "comment": "Stem"},
    ],
    "m": [
        {"start": [0.22, 0.32], "end": [0.22, 0.70], "comment": "Left stem"},
        {"start": [0.22, 0.35], "end": [0.50, 0.70], "via": [[0.45, 0.32]], "comment": "Left arch"},
        {"start": [0.50, 0.35], "end": [0.78, 0.70], "via": [[0.72, 0.32]], "comment": "Right arch"},
    ],
    "n": [
        {"start": [0.27, 0.20], "end": [0.27, 0.80], "comment": "Left stem"},
        {"start": [0.27, 0.25], "end": [0.72, 0.80], "via": [[0.65, 0.22]], "comment": "Arch"},
    ],
    "o": [
        {"start": [0.30, 0.20], "end": [0.30, 0.20], "via": [[0.70, 0.80]], "comment": "Closed loop"},
    ],
    "p": [
        {"start": [0.40, 0.30], "end": [0.40, 0.86], "comment": "Vertical with descender"},
        {"start": [0.40, 0.30], "end": [0.40, 0.65], "via": [[0.65, 0.45]], "comment": "Bowl"},
    ],
    "q": [
        {"start": [0.65, 0.30], "end": [0.65, 0.65], "via": [[0.35, 0.45]], "comment": "Bowl"},
        {"start": [0.65, 0.30], "end": [0.65, 0.86], "comment": "Vertical with descender"},
    ],
    "r": [
        {"start": [0.40, 0.20], "end": [0.40, 0.80], "comment": "Stem"},
        {"start": [0.40, 0.30], "end": [0.70, 0.30], "comment": "Flag"},
    ],
    "s": [
        {"start": [0.65, 0.25], "end": [0.30, 0.75], "via": [[0.45, 0.50]], "comment": "S-curve"},
    ],
    "t": [
        {"start": [0.50, 0.16], "end": [0.50, 0.85], "comment": "Stem"},
        {"start": [0.38, 0.40], "end": [0.62, 0.40], "comment": "Crossbar"},
    ],
    "u": [
        {"start": [0.30, 0.25], "end": [0.70, 0.25], "via": [[0.50, 0.78]], "comment": "U-bend"},
        {"start": [0.70, 0.25], "end": [0.70, 0.80], "comment": "Right stem"},
    ],
    "v": [
        # ONE continuous stroke matching uppercase V.
        {"start": [0.30, 0.20], "end": [0.70, 0.20],
         "via": [[0.50, 0.80]],
         "comment": "Continuous v (TL → apex → TR)"},
    ],
    "w": [
        # ONE continuous stroke matching uppercase W.
        {"start": [0.22, 0.30], "end": [0.78, 0.30],
         "via": [[0.35, 0.70], [0.50, 0.45], [0.65, 0.70]],
         "comment": "Continuous w (TL → V₁ → mid → V₂ → TR)"},
    ],
    "x": [
        {"start": [0.25, 0.20], "end": [0.75, 0.80], "comment": "TL→BR"},
        {"start": [0.75, 0.20], "end": [0.25, 0.80], "comment": "TR→BL"},
    ],
    "y": [
        {"start": [0.35, 0.25], "end": [0.55, 0.65], "comment": "Left arm"},
        {"start": [0.65, 0.25], "end": [0.40, 0.86], "via": [[0.50, 0.85]], "comment": "Right arm with descender"},
    ],
    "z": [
        {"start": [0.30, 0.25], "end": [0.70, 0.25], "comment": "Top bar"},
        {"start": [0.70, 0.25], "end": [0.30, 0.75], "comment": "Diagonal"},
        {"start": [0.30, 0.75], "end": [0.70, 0.75], "comment": "Bottom bar"},
    ],
    "ä": [
        {"start": [0.45, 0.16], "end": [0.45, 0.16], "comment": "Left dot"},
        {"start": [0.64, 0.16], "end": [0.64, 0.16], "comment": "Right dot"},
        {"start": [0.70, 0.50], "end": [0.70, 0.82], "via": [[0.35, 0.62], [0.55, 0.82]], "comment": "Bowl + tail"},
    ],
    "ö": [
        {"start": [0.45, 0.16], "end": [0.45, 0.16], "comment": "Left dot"},
        {"start": [0.63, 0.16], "end": [0.63, 0.16], "comment": "Right dot"},
        {"start": [0.35, 0.40], "end": [0.35, 0.40], "via": [[0.65, 0.82]], "comment": "Closed loop"},
    ],
    "ü": [
        {"start": [0.43, 0.16], "end": [0.43, 0.16], "comment": "Left dot"},
        {"start": [0.62, 0.16], "end": [0.62, 0.16], "comment": "Right dot"},
        {"start": [0.32, 0.42], "end": [0.68, 0.42], "via": [[0.50, 0.83]], "comment": "U-bend"},
        {"start": [0.68, 0.42], "end": [0.68, 0.82], "comment": "Right stem"},
    ],
}


def rasterize(letter: str) -> np.ndarray:
    """Render `letter` to a SIZE × SIZE binary mask (True = glyph pixel).

    Uses uniform font-metric scaling so every glyph in the font shares
    the same em-square: lowercase 'a' is naturally smaller than 'A'
    instead of being scaled up to fill the canvas. The em-square
    (ascent + descent) is fitted into the avail region; each glyph
    is centered horizontally and rendered with its baseline anchored
    at `pad + scaled_ascent` — same scaling rule the iOS renderer
    uses, so the strokes generated here line up with the on-device
    ghost path.
    """
    avail = int(SIZE * (1 - 2 * PAD))
    # Probe at a large size so the ascent / descent metrics are precise,
    # then derive a target font size whose em-square fits `avail`.
    probe_size = 1000
    probe_font = ImageFont.truetype(str(FONT_PATH), probe_size)
    probe_ascent, probe_descent = probe_font.getmetrics()
    em_height = probe_ascent + probe_descent
    if em_height <= 0:
        raise ValueError(f"Bad font metrics for {letter!r}")
    target_size = int(round(probe_size * avail / em_height))
    font = ImageFont.truetype(str(FONT_PATH), target_size)
    ascent, _ = font.getmetrics()
    bbox = font.getbbox(letter)
    w = bbox[2] - bbox[0]
    if w <= 0:
        raise ValueError(f"Empty glyph for {letter!r}")
    # Center horizontally; place the baseline at `pad + ascent` so
    # the ascender area sits inside the top pad and any descender
    # extends into the bottom pad.
    x = (SIZE - w) // 2 - bbox[0]
    baseline_y = int(SIZE * PAD + ascent)
    img = Image.new("L", (SIZE, SIZE), 255)
    ImageDraw.Draw(img).text((x, baseline_y), letter, font=font, fill=0, anchor="ls")
    return np.array(img) < 128


def to_pixel(pt: list[float]) -> tuple[int, int]:
    return (int(round(pt[0] * (SIZE - 1))), int(round(pt[1] * (SIZE - 1))))


def to_normalized(col: int, row: int) -> tuple[float, float]:
    return (col / (SIZE - 1), row / (SIZE - 1))


def nearest_skeleton_pixel(skel: np.ndarray, target: tuple[int, int],
                           mask: np.ndarray | None = None) -> tuple[int, int]:
    """Nearest skeleton pixel to `target`. When `mask` is supplied,
    restrict the search to pixels where mask is True (used for
    component-aware anchor snapping in letters like K whose spine and
    arms skeletonize into separate connected components)."""
    src = mask if mask is not None else skel
    rows, cols = np.where(src)
    if rows.size == 0:
        raise ValueError("Skeleton (or mask) is empty")
    tcol, trow = target
    d2 = (rows - trow) ** 2 + (cols - tcol) ** 2
    i = int(np.argmin(d2))
    return (int(cols[i]), int(rows[i]))


def bfs_segment(skel: np.ndarray, start: tuple[int, int], end: tuple[int, int],
                blocked: set[tuple[int, int]] | None = None) -> list[tuple[int, int]]:
    """8-connected BFS shortest path on the skeleton.

    `blocked` is a set of pixels we may not revisit — used by the loop
    routing in `route_path` so that a segment from start back to start
    (closed-loop letters) doesn't immediately stop at the start node.
    """
    h, w = skel.shape
    sc, sr = start
    ec, er = end
    if not skel[sr, sc] or not skel[er, ec]:
        raise ValueError(f"Endpoints {start}, {end} must lie on the skeleton")
    came_from: dict[tuple[int, int], tuple[int, int] | None] = {start: None}
    queue: deque[tuple[int, int]] = deque([start])
    found = False
    while queue:
        c, r = queue.popleft()
        if (c, r) == end:
            found = True
            break
        for dr in (-1, 0, 1):
            for dc in (-1, 0, 1):
                if dr == 0 and dc == 0:
                    continue
                nc, nr = c + dc, r + dr
                if not (0 <= nc < w and 0 <= nr < h):
                    continue
                if not skel[nr, nc]:
                    continue
                if (nc, nr) in came_from:
                    continue
                if blocked and (nc, nr) in blocked:
                    continue
                came_from[(nc, nr)] = (c, r)
                queue.append((nc, nr))
    if not found:
        raise ValueError(f"No skeleton path between {start} and {end}")
    path: list[tuple[int, int]] = []
    cur: tuple[int, int] | None = end
    while cur is not None:
        path.append(cur)
        cur = came_from[cur]
    path.reverse()
    return path


def route_path(skel: np.ndarray, anchors: list[tuple[int, int]]) -> list[tuple[int, int]]:
    """Concatenate BFS segments through the ordered anchors.

    For closed loops (anchors[0] == anchors[-1]) we forbid revisiting the
    final segment's already-walked pixels (except the endpoint itself) so
    BFS doesn't immediately collapse start→end into a zero-length path.
    """
    if len(anchors) < 2:
        raise ValueError("Need at least start + end")
    full: list[tuple[int, int]] = []
    closed = anchors[0] == anchors[-1]
    for i in range(len(anchors) - 1):
        is_closing = closed and i == len(anchors) - 2
        blocked: set[tuple[int, int]] | None = None
        if is_closing and full:
            # Forbid revisiting the walked interior so BFS goes the
            # OTHER way around the loop, but keep the destination
            # reachable (it's the same pixel as anchors[0], which is
            # in `full`).
            blocked = set(full) - {anchors[i + 1]}
        seg = bfs_segment(skel, anchors[i], anchors[i + 1], blocked=blocked)
        if i == 0:
            full.extend(seg)
        else:
            full.extend(seg[1:])  # skip duplicate join pixel
    return full


def auto_count(path_length: int) -> int:
    return max(3, min(12, path_length // 50))


def sample_evenly(path: list[tuple[int, int]], count: int) -> list[tuple[int, int]]:
    if count < 2 or len(path) <= count:
        return path
    idx = np.linspace(0, len(path) - 1, count).round().astype(int)
    return [path[i] for i in idx]


def generate_for_letter(letter: str, specs: list[dict],
                        radius: float = DEFAULT_RADIUS) -> dict:
    mask = rasterize(letter)
    skel = skeletonize(mask)
    labels = cc_label(skel)
    out_strokes: list[dict] = []
    for i, spec in enumerate(specs, start=1):
        start_n = spec["start"]
        end_n = spec["end"]
        via_n = spec.get("via", [])
        anchors_n = [start_n, *via_n, end_n]
        # Pick a target connected component by majority vote: each
        # anchor's globally-nearest skeleton pixel reports its
        # component, the most-popular component wins, and all anchors
        # snap into THAT component. Without this, K's arm strokes
        # snap their `start` (which sits visually at the spine
        # junction) to the spine — a different component from the
        # arm's via — and BFS can't find a path between disjoint
        # components.
        comp_votes: dict[int, int] = {}
        for pt in anchors_n:
            sk = nearest_skeleton_pixel(skel, to_pixel(pt))
            cid = int(labels[sk[1], sk[0]])
            comp_votes[cid] = comp_votes.get(cid, 0) + 1
        chosen_comp = max(comp_votes.items(), key=lambda kv: kv[1])[0]
        comp_mask = (labels == chosen_comp)
        anchors_px = [nearest_skeleton_pixel(skel, to_pixel(p), mask=comp_mask)
                      for p in anchors_n]
        path = route_path(skel, anchors_px)
        count = spec.get("count") or auto_count(len(path))
        sampled = sample_evenly(path, count)
        # Use the skeleton-snapped pixel positions for every
        # checkpoint, including start and end. The earlier version
        # wrote `start_n` and `end_n` verbatim so serif tips could
        # render on their own coord — but those spec coords are
        # hand-guessed and frequently land *inside* the rendered
        # glyph rather than on the visible ink, leaving the start
        # dot floating off the stroke. Snapping every point keeps
        # the rendered checkpoints on the glyph centerline.
        cps: list[dict] = []
        for col, row in sampled:
            x, y = to_normalized(col, row)
            cps.append({"x": round(x, 3), "y": round(y, 3)})
        stroke: dict = {"id": i}
        if "comment" in spec:
            stroke["comment"] = spec["comment"]
        stroke["checkpoints"] = cps
        out_strokes.append(stroke)
    return {"letter": letter, "checkpointRadius": radius, "strokes": out_strokes}


def main() -> int:
    ap = argparse.ArgumentParser(description="Centerline-aligned strokes.json generator.")
    ap.add_argument("letters", nargs="*", help="Letters to (re)generate. Default: all in spec.")
    ap.add_argument("--out", default=str(OUTPUT_BASE), help="Output base directory")
    ap.add_argument("--no-overwrite", action="store_true",
                    help="Skip letters whose strokes.json already exists")
    args = ap.parse_args()

    targets = args.letters or sorted(LETTER_SPECS.keys())
    out_base = Path(args.out)
    failures = 0
    for letter in targets:
        if letter not in LETTER_SPECS:
            print(f"  {letter}: no spec — skipping")
            continue
        # Lowercase folders carry a `_l` suffix so their JSON files
        # don't collide with their uppercase counterparts on case-
        # insensitive filesystems (macOS / iOS APFS). Uppercase and
        # special characters keep their bare name.
        is_lower = letter == letter.lower() and letter != letter.upper()
        folder_name = f"{letter}_l" if is_lower else letter
        out_file = out_base / folder_name / "strokes.json"
        if args.no_overwrite and out_file.exists():
            print(f"  {letter}: exists (skipped)")
            continue
        try:
            data = generate_for_letter(letter, LETTER_SPECS[letter])
        except Exception as e:
            print(f"  {letter}: FAILED — {e}")
            failures += 1
            continue
        out_file.parent.mkdir(parents=True, exist_ok=True)
        out_file.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
        cp_count = sum(len(s["checkpoints"]) for s in data["strokes"])
        print(f"  {letter}: ✓ {len(data['strokes'])} strokes, {cp_count} checkpoints")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
