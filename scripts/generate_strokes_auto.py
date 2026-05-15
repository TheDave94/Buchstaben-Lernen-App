"""Anchor-spec stroke generator for Primae.

Architecture (four stages, applied to closed-bowl walker letters):
  1. Walker primitive (walk/continuous/loop) produces a candidate
     polyline by BFS-walking the letter's skimage skeleton between
     cardinal anchors. Extracted from commit 77f1c220.
  2. Per-stroke mask isolation builds a boolean mask containing only
     that stroke's ink (thick-line band for STRAIGHT walks; full-mask-
     minus-straight-masks with shared-anchor row-split for CURVED).
  3. Medial-axis snap pulls every polyline checkpoint to the local
     distance-transform maximum of its stroke's isolated mask.
  4. Static-artifact escape hatch for letters where stages 1-3 don't
     produce a clean polyline. The iPad debug calibrator
     (PrimaeNative/Features/Tracing/StrokeCalibrationOverlay.swift)
     lets a human drag-edit checkpoint positions on the rendered
     glyph and export the result as JSON. The exported strokes.json
     is committed verbatim; the letter is added to
     SHIPPED_AS_STATIC_ARTIFACT and the bake pipeline skips it.

Non-walker letters (M, V, W, A, etc.) use the existing line-kind
primitive architecture (straight_line + fillets/sharp joints). They
shipped clean from an earlier pipeline and are byte-identical
across pipeline changes.

See `docs/INVARIANTS.md` for the permanent centerline rules — every
bake must satisfy centerline location, centerline shape, stroke type
purity, and junction continuity. Apply to every letter, every weight.

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
from collections import deque
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from fontTools.pens.boundsPen import BoundsPen
from fontTools.ttLib import TTFont
from scipy.ndimage import distance_transform_edt
import skimage.morphology as morph

REPO_ROOT = Path(__file__).resolve().parent.parent
FONTS = {
    "regular": REPO_ROOT / "design-system/fonts/Primae-Regular.otf",
    "light":   REPO_ROOT / "design-system/fonts/Primae-Light.otf",
}
DEFAULT_FONT = FONTS["regular"]
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
# Tuning constants
# -----------------------------------------------------------------------------
#
# These were inlined literals scattered through the arm + joint primitive
# implementations. Pulled to a single block so a sweep over any of them has
# one place to change. Any change here is gated by `scripts/verify_bake.sh`
# (byte-identity vs HEAD); only sweep + commit if every shipped letter
# survives or every regenerated letter has been visually reviewed.

# Arm primitives — `arm_lsq_line`, `arm_smoothed_medial_axis`,
# `arm_straight_line` trim this fraction of the segment from the
# joint-adjacent end(s) before sampling. Endpoint-adjacent sides
# (arm 0's start, last arm's end) are NOT trimmed.
DEFAULT_ARM_TRIM_PCT = 0.20

# `arm_smoothed_medial_axis` moving-average window over the BFS path.
DEFAULT_SMOOTHING_WINDOW = 5

# `joint_cubic_bezier_clamped` — handle length is `min(s_v, MAX_HANDLE)`
# per side, where s_v is the natural tangent-intersection distance.
# Caps the arc depth so neighbouring joints don't pull arms past each
# other on narrow geometry.
DEFAULT_CBEZ_MAX_HANDLE = 70.0

# `joint_family_a_fillet` — tangent-intersection distance is clamped to
# this fraction of the shorter adjacent arm before the fillet radius is
# recomputed. Prevents the fillet from eating more than half of either
# arm.
FAMILY_A_FILLET_MAX_TAN_FRACTION = 0.45

# `walk_arm_to_plateau` declares "arrived at the cap interior" when the
# 5-step moving-average slope of dt-along-the-chord drops below this
# (px of dt per px of chord). Lower = walks deeper into the cap before
# stopping.
WALK_PLATEAU_SLOPE_THRESHOLD = 0.20

# `joint_fillet_at_intersection` — bridge from natural arm endpoint to
# trim point must point in the same direction as the arm tangent
# (signed projection ≥ this). Negative (-0.5 px) tolerates rounding
# wobble at the natural arm endpoint without rejecting the joint as a
# reversal. More negative = more permissive.
FILLET_BRIDGE_REVERSAL_TOLERANCE = -0.5

# BRANCH_T overlap. After the curvature detector finds the hook→stem
# transition pixel, walk this many pixels further along the skeleton
# toward DESC_HOOK_L before returning. Puts the seam between the
# hook stroke and the stem stroke in established-vertical territory
# so the visual handoff is kink-free. 0 = land at the first vertical
# pixel; higher = deeper into the stem section.
BRANCH_OVERLAP_PX = 15


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
    "A": [
        {"kind": "line", "anchors": ["BL", "T"],
         "arms": ["straight_line"]},
        {"kind": "line", "anchors": ["BR", "T"],
         "arms": ["straight_line"]},
        {"kind": "line", "anchors": ["ML", "MR"],
         "arms": [{"strategy": "straight_line",
                    "t_junction_start": 0,  # crossbar left meets stroke 0 (BL→T)
                    "t_junction_end": 1}]},  # crossbar right meets stroke 1 (BR→T)
    ],
    "E": [
        # All three horizontal bars terminate at dt=5 from the right
        # outline (≈ stroke half-radius), so each tip sits just inside
        # its own cap rounding without bulging past it. Without
        # `end_distance_from_outline`, LSQ projection of TR/MR/BR onto
        # each bar's fitted line lands at varying x positions
        # (col 627 vs 574 vs 587 on the M-letter family at 1024×1024).
        {"kind": "line", "anchors": ["TL", "BL"],
         "arms": ["straight_line"]},
        {"kind": "line", "anchors": ["TL", "TR"],
         "arms": [{"strategy": "straight_line",
                    "t_junction_start": 0,
                    "end_distance_from_outline": 5.0}]},
        {"kind": "line", "anchors": ["ML", "MR"],
         "arms": [{"strategy": "straight_line",
                    "t_junction_start": 0,
                    "end_distance_from_outline": 5.0}]},
        {"kind": "line", "anchors": ["BL", "BR"],
         "arms": [{"strategy": "straight_line",
                    "t_junction_start": 0,
                    "end_distance_from_outline": 5.0}]},
    ],
    "F": [
        {"kind": "line", "anchors": ["TL", "BL"],
         "arms": ["straight_line"]},
        {"kind": "line", "anchors": ["TL", "TR"],
         "arms": [{"strategy": "straight_line",
                    "end_distance_from_outline": 5.0}]},
        {"kind": "line", "anchors": ["ML", "MR"],
         "arms": [{"strategy": "straight_line", "t_junction_start": 0,
                    "end_distance_from_outline": 5.0}]},
    ],
    "H": [
        {"kind": "line", "anchors": ["TL", "BL"],
         "arms": ["straight_line"]},
        {"kind": "line", "anchors": ["TR", "BR"],
         "arms": ["straight_line"]},
        {"kind": "line", "anchors": ["ML", "MR"],
         "arms": [{"strategy": "straight_line",
                    "t_junction_start": 0,
                    "t_junction_end": 1}]},
    ],
    "I": [
        {"kind": "line", "anchors": ["TC", "BC"],
         "arms": ["straight_line"]},
    ],
    "L": [
        {"kind": "line", "anchors": ["TL", "BL"],
         "arms": ["straight_line"]},
        {"kind": "line", "anchors": ["BL", "BR"],
         "arms": [{"strategy": "straight_line",
                    "t_junction_start": 0,
                    "end_distance_from_outline": 5.0}]},
    ],
    "N": [
        {"kind": "line", "anchors": ["BL", "TL", "BR", "TR"],
         "arms": ["straight_line", "straight_line", "straight_line"],
         "joints": [
             "sharp_meeting_at_intersection",  # TL inner corner
             "sharp_meeting_at_intersection",  # BR inner corner
         ]},
    ],
    "T": [
        {"kind": "line", "anchors": ["TL", "TR"],
         "arms": ["straight_line"]},
        {"kind": "line", "anchors": ["TC", "BC"],
         "arms": [{"strategy": "straight_line", "t_junction_start": 0}]},
    ],
    "V": [
        {"kind": "line", "anchors": ["TL", "BC", "TR"],
         "arms": ["straight_line", "straight_line"],
         "joints": [
             "sharp_meeting_at_intersection",  # BC valley
         ]},
    ],
    "X": [
        {"kind": "line", "anchors": ["TL", "BR"],
         "arms": ["straight_line"]},
        {"kind": "line", "anchors": ["TR", "BL"],
         "arms": ["straight_line"]},
    ],
    # Y deferred — TC interior-anchor-on-one-stroke /
    # endpoint-on-another isn't supported by the shared-apex
    # pre-compute (endpoint-anchor only). Reopen with either:
    # (a) extend shared-apex resolution to interior anchors, or
    # (b) introduce a curve workstream so the trailing stem can
    # round into the descender baseline as Prima's design shows.
    "Z": [
        {"kind": "line", "anchors": ["TL", "TR", "BL", "BR"],
         "arms": ["straight_line", "straight_line", "straight_line"],
         "joints": [
             "sharp_meeting_at_intersection",
             "sharp_meeting_at_intersection",
         ]},
    ],
    "M": [
        {"kind": "line", "anchors": ["BL", "TL", "BC", "TR", "BR"],
         "arms": ["straight_line"] * 4,
         "joints": [
             "sharp_meeting_at_intersection",  # TL peak (V clamped to cap top)
             "sharp_meeting_at_intersection",  # BC valley
             "sharp_meeting_at_intersection",  # TR peak (V clamped to cap top)
         ]},
    ],
    "W": [
        {"kind": "line", "anchors": ["TL", "BL", "TC", "BR", "TR"],
         "arms": ["straight_line"] * 4,
         "joints": [
             "sharp_meeting_at_intersection",  # BL valley
             "sharp_meeting_at_intersection",  # TC peak (V clamped to cap top)
             "sharp_meeting_at_intersection",  # BR valley
         ]},
    ],
    # l deferred — structurally a straight stem plus a small curved
    # foot at the baseline. Line-kind primitives can only approximate
    # the curl by routing the polyline through a low-dt valley region,
    # which traces visually wrong. l belongs in the curve workstream
    # alongside t f j r (all of which share the "mostly straight +
    # small curve at one end" architecture). i landed first as the
    # warmup (no curl, just stem + dot).
    "i": [
        # Stem and dot are disconnected ink components — TC/BC would
        # span the bbox including the dot. STEM_T / STEM_B target the
        # largest mask component only, so the stem polyline starts at
        # the actual stem top (just below the dot) and ends at the
        # baseline. DOT_C is the centroid of the disconnected component
        # above the main body.
        {"kind": "line", "anchors": ["STEM_T", "STEM_B"],
         "arms": ["straight_line"]},
        {"kind": "dot", "anchor": "DOT_C"},
    ],
    "l": [
        # Stem-then-curl as a single smoothed-medial-axis stroke. The
        # BFS skeleton walk from STEM_T (ascender top cap apex) to
        # CURL_TIP_R (skeleton endpoint at the foot curl, bottom-right
        # of the glyph) traces the natural medial axis through the
        # bend; arm_smoothed_medial_axis adds moving-average smoothing
        # over the staircase quantisation. No analytic curve primitive
        # needed — the medial axis already has the right shape per the
        # SWEEP 2 visual review (skeleton-smooth was the clear winner
        # over cubic Bézier and quadratic Bézier variants).
        {"kind": "line", "anchors": ["STEM_T", "CURL_TIP_R"],
         "arms": ["smoothed_medial_axis"]},
    ],
    "r": [
        # Two strokes: a vertical stem and a hook curve that joins
        # back onto the stem. ASC_TOP / DESC_HOOK_L are used in lieu
        # of STEM_T / STEM_B because the column-extremum resolvers
        # don't work for r's off-center stem (STEM_T lands on the
        # arm top at (556, 418), STEM_B on the arm-side bulge at
        # (582, 508)). The skeleton-endpoint resolvers correctly pick
        # the stem's two skeleton terminals at (450, 438) and
        # (432, 687). Stem uses straight_line so the LSQ fit absorbs
        # any BFS detour through the branch junction. Hook walks the
        # medial axis from ARM_TIP_R back to BRANCH_R (the rightmost
        # mid-row skeleton junction — where the hook joins the stem).
        {"kind": "line", "anchors": ["ASC_TOP", "DESC_HOOK_L"],
         "arms": ["straight_line"]},
        {"kind": "line", "anchors": ["ARM_TIP_R", "BRANCH_R"],
         "arms": ["smoothed_medial_axis"]},
    ],
    "f": [
        # Three strokes: ascender hook + straight stem + crossbar.
        # The hook walks ASC_TOP → BRANCH_T via smoothed_medial_axis;
        # BRANCH_T is curvature-detected as the first skeleton pixel
        # where the medial axis settles into vertical motion (col-band
        # ≤ 2 over a 10-px ancestor window). For f this lands at
        # ~(488, 293), just below the ascender hook curl. The stem
        # walks BRANCH_T → DESC_HOOK_L via straight_line — LSQ-fits
        # the BFS path which detours through the crossbar T-junction
        # (would dip with smoothed_medial_axis; arm_straight_line
        # absorbs it). DESC_HOOK_L = descender bottom skeleton
        # endpoint at (442, 890); STEM_B's column-extremum lands
        # mid-stem and doesn't work for f. Crossbar at x-height,
        # same construction as t.
        {"kind": "line", "anchors": ["ASC_TOP", "BRANCH_T"],
         "arms": ["smoothed_medial_axis"]},
        {"kind": "line", "anchors": ["BRANCH_T", "DESC_HOOK_L"],
         "arms": ["straight_line"]},
        {"kind": "line", "anchors": ["XBAR_L", "XBAR_R"],
         "arms": ["straight_line"]},
    ],
    "j": [
        # Stem + descender hook as one smoothed_medial_axis stroke. The
        # main component skeleton walks from the stem-top cap apex
        # (snap_to_medial_axis maps STEM_T to the nearby skeleton
        # endpoint at row 440) down through the baseline into the
        # descender, and bends left at the hook to terminate at
        # DESC_HOOK_L. Plus a dot stroke for the tittle above
        # x-height. Same architecture as i (separated dot via DOT_C)
        # combined with the curve pattern from l.
        {"kind": "line", "anchors": ["STEM_T", "DESC_HOOK_L"],
         "arms": ["smoothed_medial_axis"]},
        {"kind": "dot", "anchor": "DOT_C"},
    ],
    "t": [
        # Stem-then-curl as one continuous smoothed-medial-axis stroke
        # (same pattern as l), plus a separate straight crossbar. The
        # stem+curl BFS walk from STEM_T to CURL_TIP_R passes through
        # the stem-crossbar T-junction and continues to the curl —
        # BFS picks the shortest path, no crossbar detour. The
        # crossbar uses arm_straight_line so the LSQ fit produces a
        # truly horizontal segment; the BFS path between XBAR_L and
        # XBAR_R has a small junction-detour kink (72° max-turn when
        # walked raw via smoothed_medial_axis) which LSQ-fitting
        # naturally absorbs.
        {"kind": "line", "anchors": ["STEM_T", "CURL_TIP_R"],
         "arms": ["smoothed_medial_axis"]},
        {"kind": "line", "anchors": ["XBAR_L", "XBAR_R"],
         "arms": ["straight_line"]},
    ],
    "v": [
        # Plain straight_line arms — LSQ fit through the natural medial
        # axis gives the diagonal direction without LSQ-trim tilt; the
        # fillet joint owns apex placement. Math intersection V sits ~7px
        # below the visible v-tip outline (the arms extrapolate past the
        # cap rounding); trim_back=24 lands the Bézier arc apex ~3px
        # above the v-tip outline (apex_dt ≈ 3, in target 1-3 range).
        {"kind": "line", "anchors": ["TL", "BC", "TR"],
         "arms": ["straight_line", "straight_line"],
         "joints": [{"strategy": "fillet_at_intersection",
                      "trim_back": 24.0}]},
    ],
    "w": [
        # Plain straight_line arms; fillet joint trim_back=40 uniform at
        # all three joints (BL valley, TC inner peak, BR valley). The
        # valleys are deeper than v's so V sits 7-10px below the outline
        # and a larger trim_back is needed to push the arc apex up
        # through the cap rounding. Prima's rendered w glyph is slightly
        # asymmetric (BR valley deeper than BL): at tb=40 BL lands +4 and
        # BR +1 above outline — accepted as good-enough given the glyph
        # asymmetry. TC's V sits INSIDE the cap (convex peak case), so
        # the same trim_back produces an arc apex at mid-stroke dt that
        # traces the inner peak smoothly.
        {"kind": "line", "anchors": ["TL", "BL", "TC", "BR", "TR"],
         "arms": ["straight_line"] * 4,
         "joints": [{"strategy": "fillet_at_intersection",
                      "trim_back": 40.0}] * 3},
    ],
    "x": [
        {"kind": "line", "anchors": ["TL", "BR"],
         "arms": ["straight_line"]},
        {"kind": "line", "anchors": ["TR", "BL"],
         "arms": ["straight_line"]},
    ],
    "Y": [
        # Three straight strokes meeting at a single shared apex — the
        # diagonals enter the stem at BRANCH_R (lowest-row mid-row
        # skeleton junction, here the only junction at (491, 488)).
        # STEM_B reaches the column-extremum bottom of the glyph just
        # past the skeleton terminus. ARM_TIP_TL / ARM_TIP_TR pick the
        # upper-half min-col / max-col endpoints; existing ASC_TOP
        # would pick min-row + max-col which falls on the left tip
        # for Y (mins on row) and on the right tip for y (mins on
        # row), so the resolver is inconsistent — the explicit *_TL /
        # *_TR resolvers are stable across both.
        {"kind": "line", "anchors": ["ARM_TIP_TL", "BRANCH_R"],
         "arms": ["straight_line"]},
        {"kind": "line", "anchors": ["ARM_TIP_TR", "BRANCH_R"],
         "arms": ["straight_line"]},
        {"kind": "line", "anchors": ["BRANCH_R", "STEM_B"],
         "arms": ["straight_line"]},
    ],
    "y": [
        # Same V-arms-meet-stem decomposition as Y, but the stem is a
        # descender that slants left from the join to DESC_HOOK_L. The
        # diagonals are straight; the descender follows the medial
        # axis (slight curve toward the hook bottom). BRANCH_R lands
        # at the diagonals-descender junction (496, 685) — the
        # criterion ignores the top-tip cluster artifacts because
        # they're skeletonization burr near the rounded caps, not
        # the lowest mid-row branch.
        {"kind": "line", "anchors": ["ARM_TIP_TL", "BRANCH_R"],
         "arms": ["straight_line"]},
        {"kind": "line", "anchors": ["ARM_TIP_TR", "BRANCH_R"],
         "arms": ["straight_line"]},
        {"kind": "line", "anchors": ["BRANCH_R", "DESC_HOOK_L"],
         "arms": ["smoothed_medial_axis"]},
    ],
    "K": [
        # Prima's K is two disjoint components: a vertical stem (left)
        # and a V-arms shape (right) — they don't touch in the raster.
        # The arms' skeleton is a single path from upper-right tip
        # through a left vertex down to lower-right tip; the vertex
        # is the V-meeting-point at the leftmost-col skeleton pixel
        # of the right component. Stem via LSTEM_T / LSTEM_B (top /
        # bottom endpoints of left component's skeleton); arms via
        # RTIP_T → RVERTEX → RTIP_B as two straight segments.
        {"kind": "line", "anchors": ["LSTEM_T", "LSTEM_B"],
         "arms": ["straight_line"]},
        {"kind": "line", "anchors": ["RTIP_T", "RVERTEX"],
         "arms": ["straight_line"]},
        {"kind": "line", "anchors": ["RVERTEX", "RTIP_B"],
         "arms": ["straight_line"]},
    ],
    "k": [
        # Same disjoint-component structure as K. Stem extends from
        # ascender top (row 245) down to baseline, V-arms sit at
        # x-height (rows 418-712) — both as separate components.
        # Identical decomposition: stem + upper diagonal + lower
        # diagonal, anchored via LSTEM_* and RTIP_* / RVERTEX.
        {"kind": "line", "anchors": ["LSTEM_T", "LSTEM_B"],
         "arms": ["straight_line"]},
        {"kind": "line", "anchors": ["RTIP_T", "RVERTEX"],
         "arms": ["straight_line"]},
        {"kind": "line", "anchors": ["RVERTEX", "RTIP_B"],
         "arms": ["straight_line"]},
    ],
    "z": [
        {"kind": "line", "anchors": ["TL", "TR", "BL", "BR"],
         "arms": ["straight_line"] * 3,
         "joints": ["sharp_meeting_at_intersection"] * 2},
    ],
    # ß deferred — Druckschrift design has a compound left vertical
    # plus right-side double-bowl that doesn't decompose cleanly into
    # the current line/curve primitives. Reopen with a dedicated
    # curve-kind authoring once Prima reference is consulted.
    # b ships as a STATIC ARTIFACT (restored from commit a803d9d
    # hand-tuned firewall). Not produced by this pipeline — the
    # bake_letter call for "b" is intentionally absent from LETTERS
    # so attempting to re-bake raises a clear error. See
    # SHIPPED_AS_STATIC_ARTIFACT below for the documented list.
    # p ships as a STATIC ARTIFACT (restored from commit 77f1c220).
    # Lowercase bowl-stem junction at the inner edge resists every
    # algorithmic bake we tried (walker only, walker + mask, walker +
    # mask + snap + smooth). See SHIPPED_AS_STATIC_ARTIFACT.
    "P": [
        # Walker spec (77f1c220 architecture).
        {"kind": "walker", "primitive": "walk",
         "from": "TL", "to": "BL"},
        {"kind": "walker", "primitive": "continuous",
         "anchors": ["TL", "TR", "MR", "ML"]},
    ],
    "R": [
        # Walker spec: stem + bowl + diagonal leg.
        {"kind": "walker", "primitive": "walk",
         "from": "TL", "to": "BL"},
        {"kind": "walker", "primitive": "continuous",
         "anchors": ["TL", "TR", "MR", "ML"]},
        {"kind": "walker", "primitive": "walk",
         "from": "ML", "to": "BR"},
    ],
    "D": [
        # Walker spec: stem + continuous bowl arc through 3 anchors.
        {"kind": "walker", "primitive": "walk",
         "from": "TL", "to": "BL"},
        {"kind": "walker", "primitive": "continuous",
         "anchors": ["TL", "MR", "BL"]},
    ],
}


# NOTE: For Druckschrift Regular, all 59 letters are hand-tuned via
# the iPad calibrator and committed verbatim. The bake pipeline is
# retained for future letters (Schreibschrift, Druckschrift Light via
# template warping, future fonts) but produces no shipped output for
# Druckschrift Regular. LETTERS dict and primitives stay in place as
# starting points for those future flows.
SHIPPED_AS_STATIC_ARTIFACT: frozenset[str] = frozenset({
    # Uppercase
    "A", "B", "C", "D", "E", "F", "G", "H", "I", "J",
    "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T",
    "U", "V", "W", "X", "Y", "Z",
    # Lowercase
    "a", "b", "c", "d", "e", "f", "g", "h", "i", "j",
    "k", "l", "m", "n", "o", "p", "q", "r", "s", "t",
    "u", "v", "w", "x", "y", "z",
    # Umlauts + ß
    "Ä", "Ö", "Ü", "ä", "ö", "ü", "ß",
})

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


def _mask_components(mask: np.ndarray) -> list[np.ndarray]:
    """Return masks of every 4-connected ink component, largest first."""
    from scipy.ndimage import label
    labelled, n = label(mask)
    if n == 0:
        return []
    comps = [(labelled == lbl) for lbl in range(1, n + 1)]
    comps.sort(key=lambda c: int(c.sum()), reverse=True)
    return comps


def _largest_component_bbox(mask: np.ndarray
                            ) -> tuple[np.ndarray, tuple[int, int, int, int]]:
    """Return (mask of largest connected component, its bbox). Used to
    exclude disconnected tittles (i / j dot) from anchor resolution."""
    comps = _mask_components(mask)
    if not comps:
        raise ValueError("No ink")
    main = comps[0]
    return main, bbox_from_mask(main)


def _stem_extremum(mask: np.ndarray, top: bool) -> tuple[int, int]:
    """STEM_T / STEM_B — like TC / BC but only over the largest connected
    component (drops disconnected tittles). For i / j the dot is a
    separate component and must not contribute to the stem top."""
    main, main_bbox = _largest_component_bbox(mask)
    return _column_extremum_near_center(main, main_bbox, top=top)


def _dot_centroid_above(mask: np.ndarray) -> tuple[int, int]:
    """DOT_C — centroid of the smaller-than-main disconnected component
    whose centroid sits above the largest component's centroid.
    Defined for i and j. Raises ValueError if no qualifying dot found."""
    comps = _mask_components(mask)
    if len(comps) < 2:
        raise ValueError("No disconnected dot component")
    main = comps[0]
    mrows, mcols = np.where(main)
    main_cy = float(mrows.mean())
    for comp in comps[1:]:
        rows, cols = np.where(comp)
        cy = float(rows.mean())
        cx = float(cols.mean())
        if cy < main_cy:
            return int(round(cx)), int(round(cy))
    raise ValueError("No tittle component above main body")


def _main_skeleton_endpoints(mask: np.ndarray
                              ) -> list[tuple[int, int]]:
    """Return (col, row) skeleton endpoints (degree ≤ 1 pixels) on the
    largest connected mask component. Used by curve-letter anchors
    that target specific medial-axis terminations (curl tips, arm
    tips, ascender hook). Tittles / disconnected components are
    excluded — they have their own DOT_C resolver."""
    main, _ = _largest_component_bbox(mask)
    skel = morph.skeletonize(main)
    H, W = skel.shape
    eps: list[tuple[int, int]] = []
    for r in range(H):
        for c in range(W):
            if not skel[r, c]:
                continue
            n = 0
            for dr in (-1, 0, 1):
                for dc in (-1, 0, 1):
                    if dr == 0 and dc == 0:
                        continue
                    rr, cc = r + dr, c + dc
                    if (0 <= rr < H and 0 <= cc < W
                            and skel[rr, cc]):
                        n += 1
            if n <= 1:
                eps.append((c, r))
    if not eps:
        raise ValueError("Main skeleton has no endpoints")
    return eps


def _curl_tip_r(mask: np.ndarray) -> tuple[int, int]:
    """CURL_TIP_R — skeleton endpoint maximising row + col (i.e. the
    most bottom-right termination). Used for l, t — letters whose
    foot curl ends at the lower-right of the glyph. Tie-break by max
    col then max row."""
    eps = _main_skeleton_endpoints(mask)
    return max(eps, key=lambda p: (p[0] + p[1], p[0], p[1]))


def _desc_hook_l(mask: np.ndarray) -> tuple[int, int]:
    """DESC_HOOK_L — skeleton endpoint in the lower half of the main
    bbox, picking the maximum row, then the minimum col (i.e. the
    descender-hook termination going down and left). Used for j."""
    eps = _main_skeleton_endpoints(mask)
    _, mbbox = _largest_component_bbox(mask)
    rmin, rmax = mbbox[1], mbbox[3]
    mid = (rmin + rmax) / 2
    bottom = [p for p in eps if p[1] > mid]
    if not bottom:
        raise ValueError("No skeleton endpoint in lower half")
    return min(bottom, key=lambda p: (-p[1], p[0]))


def _mid_row_endpoints(mask: np.ndarray) -> list[tuple[int, int]]:
    """Helper: skeleton endpoints excluding the lowest-row and
    highest-row entries. Shared by ARM_TIP_R, XBAR_L, XBAR_R — all
    three pick a "mid-row" endpoint by some column criterion."""
    eps = _main_skeleton_endpoints(mask)
    if len(eps) < 3:
        raise ValueError("Mid-row endpoints need ≥ 3 skeleton endpoints, "
                          f"main component has {len(eps)}")
    top_ep = min(eps, key=lambda p: (p[1], p[0]))
    bot_ep = max(eps, key=lambda p: (p[1], -p[0]))
    mid = [p for p in eps if p != top_ep and p != bot_ep]
    if not mid:
        raise ValueError("No mid-row skeleton endpoint")
    return mid


def _arm_tip_r(mask: np.ndarray) -> tuple[int, int]:
    """ARM_TIP_R — skeleton endpoint with maximum col among "middle-row"
    endpoints (excluding the lowest-row and highest-row endpoints).
    Used for r — the arm at the shoulder."""
    return max(_mid_row_endpoints(mask), key=lambda p: (p[0], -p[1]))


def _xbar_l(mask: np.ndarray) -> tuple[int, int]:
    """XBAR_L — minimum-col mid-row endpoint. Used for t's crossbar
    left tip. Same "mid-row" set as ARM_TIP_R, mirror column criterion."""
    return min(_mid_row_endpoints(mask), key=lambda p: (p[0], -p[1]))


def _xbar_r(mask: np.ndarray) -> tuple[int, int]:
    """XBAR_R — maximum-col mid-row endpoint. Used for t's crossbar
    right tip. Functionally identical to ARM_TIP_R but named for
    crossbar semantics; the author picks whichever name reads better
    at the letter spec site."""
    return max(_mid_row_endpoints(mask), key=lambda p: (p[0], -p[1]))


def _top_tip_l(mask: np.ndarray) -> tuple[int, int]:
    """ARM_TIP_TL — skeleton endpoint in the upper half of the main
    bbox with minimum col; tie-break by minimum row. Lands at the
    top-left arm tip for Y / y (mirror of ARM_TIP_TR). Differs from
    ASC_TOP (which picks min-row + max-col) and from ARM_TIP_R (which
    needs ≥ 3 mid-row endpoints — Y/y's top tips are at the bbox top,
    not mid-row)."""
    eps = _main_skeleton_endpoints(mask)
    _, mbbox = _largest_component_bbox(mask)
    rmin, rmax = mbbox[1], mbbox[3]
    mid = (rmin + rmax) / 2
    top = [p for p in eps if p[1] < mid]
    if not top:
        raise ValueError("No skeleton endpoint in upper half")
    return min(top, key=lambda p: (p[0], p[1]))


def _top_tip_r(mask: np.ndarray) -> tuple[int, int]:
    """ARM_TIP_TR — skeleton endpoint in the upper half of the main
    bbox with maximum col; tie-break by minimum row. Lands at the
    top-right arm tip for Y / y."""
    eps = _main_skeleton_endpoints(mask)
    _, mbbox = _largest_component_bbox(mask)
    rmin, rmax = mbbox[1], mbbox[3]
    mid = (rmin + rmax) / 2
    top = [p for p in eps if p[1] < mid]
    if not top:
        raise ValueError("No skeleton endpoint in upper half")
    return max(top, key=lambda p: (p[0], -p[1]))


def _components_by_centroid_col(mask: np.ndarray) -> list[np.ndarray]:
    """Return all 4-connected ink components sorted by centroid col
    (left-to-right). Used by letters with disjoint stem + arm
    components (K, k — stem and V-arms don't touch in Prima)."""
    comps = _mask_components(mask)
    def cx(comp: np.ndarray) -> float:
        _, cols = np.where(comp)
        return float(cols.mean()) if cols.size else 0.0
    return sorted(comps, key=cx)


def _skel_endpoints_of(comp: np.ndarray) -> list[tuple[int, int]]:
    """Endpoint pixels (degree ≤ 1) of the skeleton of a single
    component mask. Shared by L* / R* resolvers."""
    skel = morph.skeletonize(comp)
    H, W = skel.shape
    eps: list[tuple[int, int]] = []
    for r in range(H):
        for c in range(W):
            if not skel[r, c]:
                continue
            n = 0
            for dr in (-1, 0, 1):
                for dc in (-1, 0, 1):
                    if dr == 0 and dc == 0:
                        continue
                    rr, cc = r + dr, c + dc
                    if (0 <= rr < H and 0 <= cc < W
                            and skel[rr, cc]):
                        n += 1
            if n <= 1:
                eps.append((c, r))
    return eps


def _lstem_t(mask: np.ndarray) -> tuple[int, int]:
    """LSTEM_T — top skeleton endpoint of the LEFTMOST component
    (sorted by centroid col). Used for K / k whose stem and V-arms
    are disjoint in Prima — the stem is a separate component sitting
    left of the arms. For single-component letters this falls back
    to the main skeleton's top endpoint."""
    comps = _components_by_centroid_col(mask)
    if not comps:
        raise ValueError("No ink")
    eps = _skel_endpoints_of(comps[0])
    if not eps:
        raise ValueError("Left component has no skeleton endpoints")
    return min(eps, key=lambda p: (p[1], p[0]))


def _lstem_b(mask: np.ndarray) -> tuple[int, int]:
    """LSTEM_B — bottom skeleton endpoint of the LEFTMOST component.
    Counterpart to LSTEM_T."""
    comps = _components_by_centroid_col(mask)
    if not comps:
        raise ValueError("No ink")
    eps = _skel_endpoints_of(comps[0])
    if not eps:
        raise ValueError("Left component has no skeleton endpoints")
    return max(eps, key=lambda p: (p[1], -p[0]))


def _rtip_t(mask: np.ndarray) -> tuple[int, int]:
    """RTIP_T — top skeleton endpoint of the RIGHTMOST component.
    Used for K / k upper arm tip (the V-arms component sits right
    of the stem in Prima)."""
    comps = _components_by_centroid_col(mask)
    if not comps:
        raise ValueError("No ink")
    eps = _skel_endpoints_of(comps[-1])
    if not eps:
        raise ValueError("Right component has no skeleton endpoints")
    return min(eps, key=lambda p: (p[1], p[0]))


def _rtip_b(mask: np.ndarray) -> tuple[int, int]:
    """RTIP_B — bottom skeleton endpoint of the RIGHTMOST component.
    Used for K / k lower arm tip."""
    comps = _components_by_centroid_col(mask)
    if not comps:
        raise ValueError("No ink")
    eps = _skel_endpoints_of(comps[-1])
    if not eps:
        raise ValueError("Right component has no skeleton endpoints")
    return max(eps, key=lambda p: (p[1], -p[0]))


def _rvertex(mask: np.ndarray) -> tuple[int, int]:
    """RVERTEX — leftmost-col skeleton pixel of the RIGHTMOST component.
    Used for K / k arm join — the V-arms component traces a single
    skeleton path from upper-right tip through this vertex to lower-
    right tip; the vertex is the point at which the two arms meet."""
    comps = _components_by_centroid_col(mask)
    if not comps:
        raise ValueError("No ink")
    skel = morph.skeletonize(comps[-1])
    rows, cols = np.where(skel)
    if rows.size == 0:
        raise ValueError("Right component has empty skeleton")
    idx = int(cols.argmin())
    return int(cols[idx]), int(rows[idx])


def _asc_top(mask: np.ndarray) -> tuple[int, int]:
    """ASC_TOP — skeleton endpoint in the upper half of the main bbox,
    picking the minimum row, then the maximum col (i.e. the
    ascender-hook termination going up and right). Used for f. Also
    used as r's stem-top because the skeleton endpoint at (450, 438)
    matches this selection — same upper-half-min-row-max-col rule;
    "ascender" is a misnomer for r but the geometry is identical."""
    eps = _main_skeleton_endpoints(mask)
    _, mbbox = _largest_component_bbox(mask)
    rmin, rmax = mbbox[1], mbbox[3]
    mid = (rmin + rmax) / 2
    top = [p for p in eps if p[1] < mid]
    if not top:
        raise ValueError("No skeleton endpoint in upper half")
    return min(top, key=lambda p: (p[1], -p[0]))


def _skel_junctions(mask: np.ndarray) -> list[tuple[int, int]]:
    """All skeleton pixels with degree ≥ 3 on the main connected
    component. Used by BRANCH_R / BRANCH_T resolvers."""
    main, _ = _largest_component_bbox(mask)
    skel = morph.skeletonize(main)
    H, W = skel.shape
    junctions: list[tuple[int, int]] = []
    for r in range(H):
        for c in range(W):
            if not skel[r, c]:
                continue
            n = 0
            for dr in (-1, 0, 1):
                for dc in (-1, 0, 1):
                    if dr == 0 and dc == 0:
                        continue
                    rr, cc = r + dr, c + dc
                    if 0 <= rr < H and 0 <= cc < W and skel[rr, cc]:
                        n += 1
            if n >= 3:
                junctions.append((c, r))
    return junctions


def _branch_r(mask: np.ndarray) -> tuple[int, int]:
    """BRANCH_R — lowest-row skeleton branch pixel (degree ≥ 3) in the
    mid-row range (strictly between the top-most and bottom-most
    skeleton endpoint rows). Lands at the lower edge of the
    merge-region between an entering stroke and a continuous stem,
    i.e. where the stem returns to single-line skeleton width below
    the merge. Used as the termination anchor for r's hook stroke.

    Generalises to U / u (and any letter with the same pattern: a
    continuous stem with a secondary stroke entering it and a stem
    continuation past the merge to a bottom terminal). Justification:
    a wide merge produces a vertical cluster of branch pixels in the
    skeleton; the topmost branch is where the entering ink first
    touches the stem, the bottom-most is where the stem returns to
    single-line width — visually the latter is where the entering
    stroke "ends" on the stem."""
    try:
        eps = _main_skeleton_endpoints(mask)
    except ValueError:
        eps = []
    _, mbbox = _largest_component_bbox(mask)
    if (len(eps) >= 2 and
            (max(e[1] for e in eps) - min(e[1] for e in eps))
            > 0.5 * (mbbox[3] - mbbox[1])):
        top_row = min(e[1] for e in eps)
        bot_row = max(e[1] for e in eps)
    else:
        top_row, bot_row = mbbox[1], mbbox[3]
    junctions = [(c, r) for (c, r) in _skel_junctions(mask)
                  if top_row < r < bot_row]
    if not junctions:
        raise ValueError("No mid-row skeleton junction")
    return max(junctions, key=lambda p: (p[1], -p[0]))


def _left_edge_endpoints(mask: np.ndarray
                          ) -> tuple[tuple[int, int], tuple[int, int]]:
    """Helper: locate the leftmost column whose ink SPANS at least
    70% of the glyph height (top-to-bottom vertical reach, not total
    row count). 70% is tight enough to filter out artifact pixels
    and cap-rounded outer cols whose ink is confined to the middle
    of the glyph, loose enough that Primae-Light's rounder caps
    (where max column span tops out at ~76% for P) still qualify.
    Returns ((col, top_row), (col, bot_row)) at that column's
    topmost and bottommost ink rows. Shared by LEFT_TOP / LEFT_BOT.

    For closed-bowl letters with a vertical stem on the left
    (b / B / D / P / R), this lands on the stem-edge top and bottom
    — the leftmost col that touches both the cap and the foot of
    the stem. Distinct from K / k's LSTEM_T / LSTEM_B which select
    a whole component (those have disjoint stem + arm pieces; these
    closed-bowl letters have the stem fused into one component with
    the bowl)."""
    H, W = mask.shape
    rows, cols = np.where(mask)
    if rows.size == 0:
        raise ValueError("No ink")
    glyph_top = int(rows.min())
    glyph_bot = int(rows.max())
    glyph_h = glyph_bot - glyph_top + 1
    threshold = 0.7 * glyph_h
    for c in range(W):
        col_rows = rows[cols == c]
        if col_rows.size == 0:
            continue
        top = int(col_rows.min())
        bot = int(col_rows.max())
        if (bot - top + 1) >= threshold:
            return ((c, top), (c, bot))
    raise ValueError("No column spans ≥ 70% of glyph height")


def _max_span_column(mask: np.ndarray) -> tuple[int, int, int]:
    """Return (col, top_row, bot_row) for the stem-center column.
    Among columns with span ≥ 70% of glyph height AND ink density ≥
    85% (filters out bowl-outline cols that touch only the top and
    bottom but cross the bowl interior void), picks the MEDIAN col
    by index — lands in the INTERIOR of the stem rather than at the
    right edge where the stem-bowl 2-run boundary fluctuates ±1 col.
    Falls back to unfiltered max-span if no col qualifies."""
    H, W = mask.shape
    rows, cols = np.where(mask)
    if rows.size == 0:
        raise ValueError("No ink")
    glyph_h = int(rows.max() - rows.min() + 1)
    span_min = 0.7 * glyph_h
    density_min = 0.85
    qualifying: list[tuple[int, int, int]] = []  # (col, top, bot)
    fallback_col = -1
    fallback_span = -1
    fallback_top = -1
    fallback_bot = -1
    for c in range(W):
        col_rows = rows[cols == c]
        if col_rows.size == 0:
            continue
        top = int(col_rows.min())
        bot = int(col_rows.max())
        span = bot - top + 1
        if span > fallback_span:
            fallback_span = span
            fallback_col = c
            fallback_top = top
            fallback_bot = bot
        density = col_rows.size / span
        if span >= span_min and density >= density_min:
            qualifying.append((c, top, bot))
    if qualifying:
        qualifying.sort()
        col, top, bot = qualifying[len(qualifying) // 2]
        return col, top, bot
    return fallback_col, fallback_top, fallback_bot


def _stem_width_at_col(mask: np.ndarray, stem_col: int) -> int:
    """Maximum width across all rows of the ink run containing
    stem_col. Used by _stem_center_t/b to set the ≥60% threshold
    for "stem has widened past the apex"."""
    rows, _ = np.where(mask)
    glyph_top = int(rows.min())
    glyph_bot = int(rows.max())
    max_w = 0
    for r in range(glyph_top, glyph_bot + 1):
        for s, e in _row_runs(mask, r):
            if s <= stem_col <= e:
                w = e - s + 1
                if w > max_w:
                    max_w = w
                break
    return max_w


STEM_CAP_OFFSET = 2  # px in from literal cap/foot apex


def _stem_center_t(mask: np.ndarray) -> tuple[int, int]:
    """STEM_CENTER_T — top row of the stem polyline at the stem-center
    column, offset STEM_CAP_OFFSET pixels in from the literal topmost
    ink row at that column. The offset steps past the single-pixel
    cap apex to where the stem reads as full-width, matching David's
    reference drawings."""
    col, top, _ = _max_span_column(mask)
    rows, _ = np.where(mask)
    glyph_bot = int(rows.max())
    return col, min(top + STEM_CAP_OFFSET, glyph_bot)


def _stem_center_b(mask: np.ndarray) -> tuple[int, int]:
    """STEM_CENTER_B — bottom row of the stem polyline at the
    stem-center column, offset STEM_CAP_OFFSET pixels up from the
    literal bottommost ink row."""
    col, _, bot = _max_span_column(mask)
    rows, _ = np.where(mask)
    glyph_top = int(rows.min())
    return col, max(bot - STEM_CAP_OFFSET, glyph_top)


def _row_runs(mask: np.ndarray, row: int) -> list[tuple[int, int]]:
    """List of (start_col, end_col) contiguous ink runs in one row."""
    cols = np.where(mask[row])[0]
    if cols.size == 0:
        return []
    runs: list[tuple[int, int]] = []
    start = int(cols[0])
    prev = int(cols[0])
    for c in cols[1:]:
        c = int(c)
        if c == prev + 1:
            prev = c
        else:
            runs.append((start, prev))
            start = c
            prev = c
    runs.append((start, prev))
    return runs


def _stem_on_left(mask: np.ndarray) -> bool:
    """True when the stem's central column sits left of the bbox
    center (bowl on right). False when stem is on the right (q)."""
    rows, cols = np.where(mask)
    bbox_cx = (int(cols.min()) + int(cols.max())) / 2
    stem_col, _, _ = _max_span_column(mask)
    return stem_col < bbox_cx


def _bowl_top_touch(mask: np.ndarray) -> tuple[int, int]:
    """BOWL_TOP_TOUCH — first row from glyph top where the row has
    ≥ 2 ink runs (the bowl is now separable from the stem). Anchor at
    the stem-run's edge facing the bowl: for left-stem letters
    (b / p / B / D / P / R) the stem-run's RIGHT edge; for right-stem
    letters (q) the stem-run's LEFT edge. Replaces UPPER_TOUCH /
    UPPER_BRANCH for bowls where those anchors sat too far inside
    the stem ink, causing the bowl polyline to dog-leg out of the
    stem to reach the bowl curve."""
    rows, _ = np.where(mask)
    if rows.size == 0:
        raise ValueError("No ink")
    glyph_top = int(rows.min())
    glyph_bot = int(rows.max())
    left = _stem_on_left(mask)
    for r in range(glyph_top, glyph_bot + 1):
        runs = _row_runs(mask, r)
        if len(runs) >= 2:
            if left:
                return runs[0][1], r       # right edge of leftmost (stem) run
            else:
                return runs[-1][0], r      # left edge of rightmost (stem) run
    raise ValueError("No 2-run row for BOWL_TOP_TOUCH")


def _bowl_bot_touch(mask: np.ndarray) -> tuple[int, int]:
    """BOWL_BOT_TOUCH — last row from glyph top where the row has
    ≥ 2 ink runs (counterpart to BOWL_TOP_TOUCH at the bowl's bottom
    end on the stem)."""
    rows, _ = np.where(mask)
    if rows.size == 0:
        raise ValueError("No ink")
    glyph_top = int(rows.min())
    glyph_bot = int(rows.max())
    left = _stem_on_left(mask)
    for r in range(glyph_bot, glyph_top - 1, -1):
        runs = _row_runs(mask, r)
        if len(runs) >= 2:
            if left:
                return runs[0][1], r
            else:
                return runs[-1][0], r
    raise ValueError("No 2-run row for BOWL_BOT_TOUCH")


def _stem_bowl_bands(mask: np.ndarray) -> list[tuple[int, int]]:
    """Return contiguous bands of rows where the row has ≥ 2 ink runs
    AND the stem-center column is inside one of the runs. Each band
    is (start_row, end_row). For single-bowl letters there is one
    band (the bowl interior). For B (stacked bowls) there are two
    bands separated by the waist row. For R the second band is the
    leg ink; for p / q the second band is the descender foot curl."""
    stem_col, _, _ = _max_span_column(mask)
    rows, _ = np.where(mask)
    if rows.size == 0:
        return []
    glyph_top = int(rows.min())
    glyph_bot = int(rows.max())
    bands: list[tuple[int, int]] = []
    in_band = False
    band_start = -1
    last_band_row = -1
    for r in range(glyph_top, glyph_bot + 1):
        runs = _row_runs(mask, r)
        is_2run = (len(runs) >= 2
                    and any(s <= stem_col <= e for s, e in runs))
        if is_2run:
            if not in_band:
                in_band = True
                band_start = r
            last_band_row = r
        else:
            if in_band:
                bands.append((band_start, last_band_row))
                in_band = False
    if in_band:
        bands.append((band_start, last_band_row))
    return bands


def _stem_bowl_top(mask: np.ndarray) -> tuple[int, int]:
    """STEM_BOWL_TOP — anchor at (stem_center_col, start_of_first_2-run_
    band). The first band is the (only) bowl for b / D / P / p / q,
    and the upper bowl for B. Anchor lies ON the stem polyline."""
    stem_col, _, _ = _max_span_column(mask)
    bands = _stem_bowl_bands(mask)
    if not bands:
        raise ValueError("No 2-run band at stem-center column")
    return stem_col, bands[0][0]


def _stem_bowl_bot(mask: np.ndarray) -> tuple[int, int]:
    """STEM_BOWL_BOT — anchor at (stem_center_col, end_of_first_2-run_
    band). End-of-FIRST-band (not last-band-from-bottom-up) so the
    leg of R and the descender foot curl of p / q (which form a
    second 2-run band) don't pollute the bowl close."""
    stem_col, _, _ = _max_span_column(mask)
    bands = _stem_bowl_bands(mask)
    if not bands:
        raise ValueError("No 2-run band at stem-center column")
    return stem_col, bands[0][1]


def _stem_bowl_top_upper(mask: np.ndarray) -> tuple[int, int]:
    """STEM_BOWL_TOP_UPPER — same as STEM_BOWL_TOP for now; B's upper
    bowl is the first band so this resolver matches STEM_BOWL_TOP.
    Named separately to make B's spec readable."""
    return _stem_bowl_top(mask)


def _branch_t_on_stem(mask: np.ndarray) -> tuple[int, int]:
    """BRANCH_T_ON_STEM — UPPER_BRANCH's row at the stem-center
    column. For letters whose bowl produces clear skeleton branches
    at the top and bottom of the bowl-stem merge (p, q), this gives
    a bowl-top anchor that lies ON the stem polyline. Band detection
    is unreliable for these letters because the bowl-stem outlines
    cross the stem-center column at row ranges that don't line up
    with the visible bowl junctions."""
    _, r = _upper_branch(mask)
    stem_col, _, _ = _max_span_column(mask)
    return stem_col, r


def _branch_b_on_stem(mask: np.ndarray) -> tuple[int, int]:
    """BRANCH_B_ON_STEM — BRANCH_R's row (lowest mid-row branch)
    at the stem-center column. Bowl-bottom-on-stem anchor for
    P / R / p / q where the bowl close registers as a skeleton
    branch at the stem."""
    _, r = _branch_r(mask)
    stem_col, _, _ = _max_span_column(mask)
    return stem_col, r


def _stem_bowl_bot_lower(mask: np.ndarray) -> tuple[int, int]:
    """STEM_BOWL_BOT_LOWER — anchor at the end of the SECOND 2-run
    band at the stem-center column. For B this lands at the lower
    bowl's foot-bowl closure on the stem; the first band's end is
    the waist (= upper bowl close)."""
    stem_col, _, _ = _max_span_column(mask)
    bands = _stem_bowl_bands(mask)
    if len(bands) < 2:
        raise ValueError("STEM_BOWL_BOT_LOWER needs ≥ 2 stem-col 2-run bands")
    return stem_col, bands[1][1]


def _top_bowl_peak_upper(mask: np.ndarray) -> tuple[int, int]:
    """TOP_BOWL_PEAK_UPPER — rightmost ink column within the top
    quarter of glyph rows. Used by B's upper-bowl path to force the
    BFS through the cap-top apex; without it, BFS on B's figure-8
    skeleton takes a shortcut and produces a 177° U-turn."""
    rows, cols = np.where(mask)
    if rows.size == 0:
        raise ValueError("No ink")
    glyph_top = int(rows.min())
    glyph_bot = int(rows.max())
    quarter = glyph_top + (glyph_bot - glyph_top + 1) // 4
    band_mask = (rows >= glyph_top) & (rows <= quarter)
    rb = rows[band_mask]
    cb = cols[band_mask]
    if cb.size == 0:
        raise ValueError("No ink in top quarter")
    max_col = int(cb.max())
    rows_at_max = rb[cb == max_col]
    cy = (glyph_top + quarter) / 2
    idx = int(np.argmin(np.abs(rows_at_max - cy)))
    return max_col, int(rows_at_max[idx])


def _left_top(mask: np.ndarray) -> tuple[int, int]:
    """LEFT_TOP — top endpoint of the leftmost sustained-ink column.
    Lands at the stem's visible top edge for closed-bowl letters."""
    return _left_edge_endpoints(mask)[0]


def _left_bot(mask: np.ndarray) -> tuple[int, int]:
    """LEFT_BOT — bottom endpoint of the leftmost sustained-ink column.
    Counterpart to LEFT_TOP, lands at the stem's visible bottom edge."""
    return _left_edge_endpoints(mask)[1]


def _waist(mask: np.ndarray) -> tuple[int, int]:
    """WAIST — anchor on the stem polyline at the row where the two
    bowls of a stacked-bowl letter (B) meet the stem. The ROW comes
    from the leftmost mid-row skeleton branch (distinguishes the
    stem-side waist from the bowl-interior cluster); the COLUMN is
    the stem-center column so the anchor sits on the stem polyline
    and the upper-bowl + lower-bowl polylines visibly meet the stem
    polyline at the waist. Mid-row filter falls back to the bbox
    when the skeleton has no endpoints (B / D have closed-loop
    skeletons) or fewer than 2 (P / R have a single stem-bottom
    endpoint)."""
    try:
        eps = _main_skeleton_endpoints(mask)
    except ValueError:
        eps = []
    if len(eps) >= 2:
        top_row = min(e[1] for e in eps)
        bot_row = max(e[1] for e in eps)
    else:
        _, mbbox = _largest_component_bbox(mask)
        top_row, bot_row = mbbox[1], mbbox[3]
    junctions = [(c, r) for (c, r) in _skel_junctions(mask)
                  if top_row < r < bot_row]
    if not junctions:
        raise ValueError("No mid-row skeleton junction for WAIST")
    _, waist_row = min(junctions, key=lambda p: (p[0], p[1]))
    stem_col, _, _ = _max_span_column(mask)
    return stem_col, waist_row


def _right_mid_band(mask: np.ndarray, top_row: int,
                    bot_row: int) -> tuple[int, int]:
    """Helper: rightmost ink column within rows [top_row, bot_row],
    returning the row in that band closest to the band's center."""
    if top_row >= bot_row:
        raise ValueError(f"Invalid band rows: top={top_row} bot={bot_row}")
    band = mask[top_row:bot_row + 1]
    rb, cb = np.where(band)
    if cb.size == 0:
        raise ValueError(f"No ink in row band {top_row}..{bot_row}")
    max_col = int(cb.max())
    rows_at_max = rb[cb == max_col]
    cy = (top_row + bot_row) / 2
    idx = int(np.argmin(np.abs(rows_at_max + top_row - cy)))
    return max_col, int(rows_at_max[idx] + top_row)


def _right_mid_upper(mask: np.ndarray) -> tuple[int, int]:
    """RIGHT_MID_UPPER — rightmost ink column within the upper bowl
    region of a two-bowl letter (B). Upper-bowl span is LEFT_TOP row
    to WAIST row."""
    top = _left_top(mask)[1]
    waist = _waist(mask)[1]
    return _right_mid_band(mask, top, waist)


def _right_mid_lower(mask: np.ndarray) -> tuple[int, int]:
    """RIGHT_MID_LOWER — rightmost ink column within the lower bowl
    region. Lower-bowl span is WAIST row to LEFT_BOT row."""
    waist = _waist(mask)[1]
    bot = _left_bot(mask)[1]
    return _right_mid_band(mask, waist, bot)


def _upper_branch(mask: np.ndarray) -> tuple[int, int]:
    """UPPER_BRANCH — highest-row mid-row skeleton branch pixel
    (mirror of BRANCH_R's lowest-row). Lands at the TOP of a bowl-
    stem merge region for letters whose bowl skeleton joins the
    stem at two distinct branch rows (p, q, B). Tie-break by max
    col."""
    try:
        eps = _main_skeleton_endpoints(mask)
    except ValueError:
        eps = []
    _, mbbox = _largest_component_bbox(mask)
    if (len(eps) >= 2 and
            (max(e[1] for e in eps) - min(e[1] for e in eps))
            > 0.5 * (mbbox[3] - mbbox[1])):
        top_row = min(e[1] for e in eps)
        bot_row = max(e[1] for e in eps)
    else:
        top_row, bot_row = mbbox[1], mbbox[3]
    junctions = [(c, r) for (c, r) in _skel_junctions(mask)
                  if top_row < r < bot_row]
    if not junctions:
        raise ValueError("No mid-row skeleton junction")
    return min(junctions, key=lambda p: (p[1], -p[0]))


def _branch_t(mask: np.ndarray) -> tuple[int, int]:
    """BRANCH_T — skeleton pixel marking the transition from a curved
    hook to a vertical stem section. Walks BFS along the main-component
    skeleton starting at ASC_TOP, and returns the first pixel whose
    last 10 ancestors all sit within a 2-px column band (i.e. the
    medial axis has settled into purely vertical motion). For f this
    lands just below the ascender hook where the stem starts; for
    letters whose hook is short or absent, falls back to the first
    skeleton junction encountered. Geometry-driven because not every
    hook→stem transition produces a skeleton branch point."""
    main, _ = _largest_component_bbox(mask)
    skel = morph.skeletonize(main)
    H, W = skel.shape
    asc = _asc_top(mask)

    from collections import deque
    parent: dict[tuple[int, int], tuple[int, int] | None] = {asc: None}
    q = deque([asc])
    order: list[tuple[int, int]] = [asc]
    junctions = set(_skel_junctions(mask))
    while q:
        x, y = q.popleft()
        for dr in (-1, 0, 1):
            for dc in (-1, 0, 1):
                if dr == 0 and dc == 0:
                    continue
                rr, cc = y + dr, x + dc
                if (0 <= rr < H and 0 <= cc < W and skel[rr, cc]
                        and (cc, rr) not in parent):
                    parent[(cc, rr)] = (x, y)
                    order.append((cc, rr))
                    q.append((cc, rr))

    WINDOW = 10
    COL_BAND = 2

    def ancestors(p, n):
        out = [p]
        cur = parent.get(p)
        while cur is not None and len(out) < n:
            out.append(cur)
            cur = parent.get(cur)
        return out

    # Walk in BFS order (skipping ASC_TOP itself); find first pixel
    # whose 10-ancestor column-band ≤ COL_BAND — that's where the
    # medial axis first settles into vertical motion.
    transition = None
    for p in order[WINDOW:]:
        anc = ancestors(p, WINDOW)
        if len(anc) < WINDOW:
            continue
        cols = [a[0] for a in anc]
        if max(cols) - min(cols) <= COL_BAND:
            transition = p
            break
    if transition is None:
        # Fallback: first junction encountered in BFS order (= crossbar
        # T-junction for f). Better than failing the bake outright.
        for p in order:
            if p in junctions and p != asc:
                return p
        raise ValueError("Could not locate hook-to-stem transition")
    # Overlap shift: walk further down the skeleton toward
    # DESC_HOOK_L so the seam between the hook stroke and the stem
    # stroke lands in established-vertical territory rather than at
    # the first vertical pixel (avoids visible kinks where the hook
    # is still slightly curving).
    if BRANCH_OVERLAP_PX > 0:
        try:
            desc = _desc_hook_l(mask)
        except ValueError:
            return transition
        stem_path = _bfs_skeleton_path(transition, desc, skel)
        if stem_path is not None and len(stem_path) > BRANCH_OVERLAP_PX:
            return stem_path[BRANCH_OVERLAP_PX]
    return transition


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
    elif name == "STEM_T":
        pos = _stem_extremum(mask, top=True)
    elif name == "STEM_B":
        pos = _stem_extremum(mask, top=False)
    elif name == "DOT_C":
        pos = _dot_centroid_above(mask)
    elif name == "CURL_TIP_R":
        pos = _curl_tip_r(mask)
    elif name == "DESC_HOOK_L":
        pos = _desc_hook_l(mask)
    elif name == "ARM_TIP_R":
        pos = _arm_tip_r(mask)
    elif name == "XBAR_L":
        pos = _xbar_l(mask)
    elif name == "XBAR_R":
        pos = _xbar_r(mask)
    elif name == "ASC_TOP":
        pos = _asc_top(mask)
    elif name == "BRANCH_R":
        pos = _branch_r(mask)
    elif name == "BRANCH_T":
        pos = _branch_t(mask)
    elif name == "UPPER_BRANCH":
        pos = _upper_branch(mask)
    elif name == "LEFT_TOP":
        pos = _left_top(mask)
    elif name == "LEFT_BOT":
        pos = _left_bot(mask)
    elif name == "WAIST":
        pos = _waist(mask)
    elif name == "RIGHT_MID_UPPER":
        pos = _right_mid_upper(mask)
    elif name == "RIGHT_MID_LOWER":
        pos = _right_mid_lower(mask)
    elif name == "STEM_CENTER_T":
        pos = _stem_center_t(mask)
    elif name == "STEM_CENTER_B":
        pos = _stem_center_b(mask)
    elif name == "BOWL_TOP_TOUCH":
        pos = _bowl_top_touch(mask)
    elif name == "BOWL_BOT_TOUCH":
        pos = _bowl_bot_touch(mask)
    elif name == "TOP_BOWL_PEAK_UPPER":
        pos = _top_bowl_peak_upper(mask)
    elif name == "STEM_BOWL_TOP":
        pos = _stem_bowl_top(mask)
    elif name == "STEM_BOWL_BOT":
        pos = _stem_bowl_bot(mask)
    elif name == "STEM_BOWL_TOP_UPPER":
        pos = _stem_bowl_top_upper(mask)
    elif name == "STEM_BOWL_BOT_LOWER":
        pos = _stem_bowl_bot_lower(mask)
    elif name == "BRANCH_T_ON_STEM":
        pos = _branch_t_on_stem(mask)
    elif name == "BRANCH_B_ON_STEM":
        pos = _branch_b_on_stem(mask)
    elif name == "ARM_TIP_TL":
        pos = _top_tip_l(mask)
    elif name == "ARM_TIP_TR":
        pos = _top_tip_r(mask)
    elif name == "LSTEM_T":
        pos = _lstem_t(mask)
    elif name == "LSTEM_B":
        pos = _lstem_b(mask)
    elif name == "RTIP_T":
        pos = _rtip_t(mask)
    elif name == "RTIP_B":
        pos = _rtip_b(mask)
    elif name == "RVERTEX":
        pos = _rvertex(mask)
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
        max_tan_dist = FAMILY_A_FILLET_MAX_TAN_FRACTION * min(L1, L2)
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
    SLOPE_THRESHOLD = WALK_PLATEAU_SLOPE_THRESHOLD
    WINDOW = DEFAULT_SMOOTHING_WINDOW
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


def _trim_bfs_to_on_axis(bfs_pts: list[tuple[int, int]],
                          a_raw: tuple[int, int],
                          b_raw: tuple[int, int],
                          angle_threshold_deg: float = 30.0
                          ) -> list[tuple[int, int]]:
    """Trim the BFS skeleton path to its longest contiguous run whose
    per-segment tangent is within ±`angle_threshold_deg` of the
    anchor-pair direction (`a_raw` → `b_raw`).

    Motivation: when an arm's bbox-relative anchors snap onto adjacent
    strokes' skeletons (A's ML/MR snap to the diagonals, not the
    crossbar's medial ridge), the BFS path between snapped endpoints is
    L-shaped — descend a perpendicular leg, traverse the on-axis ridge,
    ascend the other leg. SVD over the full path averages the legs into
    the fit, drifting the resulting line off the true centerline.

    For paths whose every segment is already on-axis (most letters),
    the trim is benign — the longest contiguous run is the full path.

    Falls back to the input unchanged when:
    - the path is too short (<5 segments) to detect direction reliably,
    - the anchor-pair direction is degenerate (zero length),
    - or the on-axis run is shorter than 4 segments after trimming."""
    if len(bfs_pts) < 5:
        return bfs_pts
    dxp = float(b_raw[0] - a_raw[0])
    dyp = float(b_raw[1] - a_raw[1])
    Lp = math.hypot(dxp, dyp)
    if Lp < 1e-6:
        return bfs_pts
    ux, uy = dxp / Lp, dyp / Lp
    cos_thresh = math.cos(math.radians(angle_threshold_deg))
    on_axis: list[bool] = []
    for i in range(len(bfs_pts) - 1):
        sx = float(bfs_pts[i + 1][0] - bfs_pts[i][0])
        sy = float(bfs_pts[i + 1][1] - bfs_pts[i][1])
        sL = math.hypot(sx, sy)
        if sL == 0.0:
            on_axis.append(False)
            continue
        cos_a = abs((sx * ux + sy * uy) / sL)
        on_axis.append(cos_a >= cos_thresh)
    best_start, best_len = 0, 0
    cur_start, cur_len = -1, 0
    for i, ok in enumerate(on_axis):
        if ok:
            if cur_start < 0:
                cur_start = i
            cur_len += 1
            if cur_len > best_len:
                best_len = cur_len
                best_start = cur_start
        else:
            cur_start = -1
            cur_len = 0
    if best_len < 4:
        return bfs_pts
    return bfs_pts[best_start:best_start + best_len + 1]


def _smooth_path(pts: list[tuple[int, int]],
                 left_trim_pct: float, right_trim_pct: float,
                 window: int = DEFAULT_SMOOTHING_WINDOW
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
                 trim_pct: float = DEFAULT_ARM_TRIM_PCT,
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
                             trim_pct: float = DEFAULT_ARM_TRIM_PCT,
                             window: int = DEFAULT_SMOOTHING_WINDOW,
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


def arm_straight_line(rough_a: tuple[int, int],
                      rough_b: tuple[int, int],
                      k: int, n_arms: int, *,
                      mask: np.ndarray, dt: np.ndarray,
                      skeleton: np.ndarray,
                      trim_pct: float = DEFAULT_ARM_TRIM_PCT,
                      fit_trim_start_pct: float = 0.0,
                      fit_trim_end_pct: float = 0.0,
                      start_pixel: tuple[float, float] | None = None,
                      end_pixel: tuple[float, float] | None = None,
                      end_distance_from_outline: float | None = None,
                      ) -> list[tuple[float, float]] | None:
    """Pure analytical line sampling from `rough_a` to `rough_b`. No
    skeleton walk, no LSQ fit — the polyline is the straight segment
    between the two anchors, sampled at 1-px spacing by
    `line_sampler`. For a stem-like band of constant width centred on
    its medial axis this passes through the middle of the ink at
    every checkpoint.

    `start_pixel` / `end_pixel`: optional float pixel overrides for
    the segment endpoints. Used by the shared-apex / T-junction
    pre-computes to force two strokes' meeting endpoint onto the
    same pixel.

    `end_distance_from_outline`: optional target dt value at the end.
    When set, walk from `a` along the segment direction and stop at
    the last pixel where dt > target. Used by group-aligned bars
    (E's three horizontals, F / L) so they all terminate at the same
    distance from the right outline.

    `trim_pct`: fraction of segment length to chop on each
    joint-adjacent side (no trim on free-end side for arm 0 / last
    arm). The fit_trim_start_pct / fit_trim_end_pct params are
    obsolete with no LSQ; kept in the signature for back-compat but
    ignored.

    The arm's polyline endpoints are the (trimmed) segment endpoints
    — downstream joint primitives recover the line direction from
    `arm[0]` / `arm[-1]`."""
    a0 = (float(rough_a[0]), float(rough_a[1]))
    b0 = (float(rough_b[0]), float(rough_b[1]))
    if start_pixel is not None:
        a0 = (float(start_pixel[0]), float(start_pixel[1]))
    if end_pixel is not None:
        b0 = (float(end_pixel[0]), float(end_pixel[1]))
    seg_dx = b0[0] - a0[0]
    seg_dy = b0[1] - a0[1]
    L = math.hypot(seg_dx, seg_dy)
    if L < 1e-6:
        return None
    ux, uy = seg_dx / L, seg_dy / L
    left_pct = 0.0 if k == 0 else trim_pct
    right_pct = 0.0 if k == n_arms - 1 else trim_pct
    a_trim = (a0[0] + ux * L * left_pct,
              a0[1] + uy * L * left_pct)
    b_trim = (b0[0] - ux * L * right_pct,
              b0[1] - uy * L * right_pct)
    if (end_pixel is None and end_distance_from_outline is not None):
        target = float(end_distance_from_outline)
        H_, W_ = dt.shape
        last_in: tuple[float, float] | None = None
        step = 0
        max_steps = max(H_, W_) * 2
        while step < max_steps:
            fx = a_trim[0] + step * ux
            fy = a_trim[1] + step * uy
            ic = int(round(fx)); ir = int(round(fy))
            if not (0 <= ir < H_ and 0 <= ic < W_):
                break
            d = float(dt[ir, ic])
            if d > target:
                last_in = (fx, fy)
            elif d == 0.0:
                break
            step += 1
        if last_in is not None:
            b_trim = last_in
    ia = (int(round(a_trim[0])), int(round(a_trim[1])))
    ib = (int(round(b_trim[0])), int(round(b_trim[1])))
    if ia == ib:
        return [(float(ia[0]), float(ia[1]))]
    seg = line_sampler([ia, ib])
    return [(float(c), float(r)) for c, r in seg]


def arm_analytical_line_stem(rough_a: tuple[int, int],
                              rough_b: tuple[int, int],
                              k: int, n_arms: int, *,
                              mask: np.ndarray, dt: np.ndarray,
                              skeleton: np.ndarray,
                              trim_pct: float = DEFAULT_ARM_TRIM_PCT,
                              ) -> list[tuple[float, float]] | None:
    """Least-squares line through per-row stem-run midpoints.

    For each row between rough_a and rough_b: interpolate the
    analytical column at that row, find the ink run that contains
    (or is closest to) that column, take its midpoint as a sample.
    Rows where the run is wider than stem_width × 1.1 are skipped —
    those are bowl/leg-fused rows where the stem ink merges with a
    crossing stroke. LSQ-fit a line through the surviving (row,
    midpoint) pairs and sample between the projected anchors.

    For perfectly upright stems this returns the analytical-vertical
    result. For slanted stems it tracks the actual stem midline.
    No tube construction, no medial_axis call, no bowl-subtract."""
    a0 = (float(rough_a[0]), float(rough_a[1]))
    b0 = (float(rough_b[0]), float(rough_b[1]))
    seg_dx0 = b0[0] - a0[0]
    seg_dy0 = b0[1] - a0[1]
    L0 = math.hypot(seg_dx0, seg_dy0)
    if L0 < 5.0:
        return None
    H_, W_ = mask.shape

    # Stem half-width estimate via dt along the analytical line.
    samples_dt: list[float] = []
    for tt in (0.15, 0.35, 0.5, 0.65, 0.85):
        cx_ = int(round(a0[0] + seg_dx0 * tt))
        cy_ = int(round(a0[1] + seg_dy0 * tt))
        if 0 <= cy_ < H_ and 0 <= cx_ < W_:
            samples_dt.append(float(dt[cy_, cx_]))
    half_w = max(samples_dt) if samples_dt else 0.0
    stem_width_est = max(int(round(half_w * 2.0)), 15)
    fused_thresh = stem_width_est * 1.1

    row_major = abs(seg_dy0) >= abs(seg_dx0)
    pure_x: list[float] = []
    pure_y: list[float] = []

    def _run_containing(coords: np.ndarray, target: float) -> (
            tuple[int, int] | None):
        """Find the contiguous run of `coords` (sorted ink columns or
        rows) containing `target`. If no run contains it, return the
        run closest to it. Returns (start, end) inclusive."""
        if coords.size == 0:
            return None
        target_i = int(round(target))
        # Find the index of the closest coord; expand outward to find
        # the contiguous run boundaries.
        idx = int(np.searchsorted(coords, target_i))
        if idx >= coords.size:
            idx = coords.size - 1
        if idx > 0 and abs(int(coords[idx - 1]) - target_i) < abs(int(coords[idx]) - target_i):
            idx -= 1
        # Walk left and right while consecutive.
        lo = idx
        while lo > 0 and int(coords[lo]) - int(coords[lo - 1]) == 1:
            lo -= 1
        hi = idx
        while hi < coords.size - 1 and int(coords[hi + 1]) - int(coords[hi]) == 1:
            hi += 1
        return (int(coords[lo]), int(coords[hi]))

    if row_major:
        r_lo = int(min(a0[1], b0[1]))
        r_hi = int(max(a0[1], b0[1]))
        slope_along = seg_dx0 / seg_dy0 if abs(seg_dy0) > 1e-6 else 0.0
        for rr in range(max(0, r_lo), min(H_, r_hi + 1)):
            cols_in_row = np.where(mask[rr])[0]
            if cols_in_row.size == 0:
                continue
            analytical_x = a0[0] + slope_along * (rr - a0[1])
            run = _run_containing(cols_in_row, analytical_x)
            if run is None:
                continue
            run_w = run[1] - run[0] + 1
            if run_w > fused_thresh:
                continue
            pure_y.append(float(rr))
            pure_x.append((run[0] + run[1]) / 2.0)
    else:
        c_lo = int(min(a0[0], b0[0]))
        c_hi = int(max(a0[0], b0[0]))
        slope_along = seg_dy0 / seg_dx0 if abs(seg_dx0) > 1e-6 else 0.0
        for cc in range(max(0, c_lo), min(W_, c_hi + 1)):
            rows_in_col = np.where(mask[:, cc])[0]
            if rows_in_col.size == 0:
                continue
            analytical_y = a0[1] + slope_along * (cc - a0[0])
            run = _run_containing(rows_in_col, analytical_y)
            if run is None:
                continue
            run_w = run[1] - run[0] + 1
            if run_w > fused_thresh:
                continue
            pure_x.append(float(cc))
            pure_y.append((run[0] + run[1]) / 2.0)

    if len(pure_x) < 5:
        return None

    # LSQ fit. For row-major, fit col = m*row + c (col as a function of
    # row). For col-major, fit row = m*col + c.
    if row_major:
        m_, b_ = np.polyfit(np.array(pure_y), np.array(pure_x), 1)

        def _proj(p: tuple[float, float]) -> tuple[float, float]:
            return (m_ * p[1] + b_, p[1])
    else:
        m_, b_ = np.polyfit(np.array(pure_x), np.array(pure_y), 1)

        def _proj(p: tuple[float, float]) -> tuple[float, float]:
            return (p[0], m_ * p[0] + b_)
    a_proj = _proj(a0)
    b_proj = _proj(b0)
    seg_dx = b_proj[0] - a_proj[0]
    seg_dy = b_proj[1] - a_proj[1]
    L = math.hypot(seg_dx, seg_dy)
    if L < 1e-6:
        return None
    ux, uy = seg_dx / L, seg_dy / L
    # No endpoint policy — endpoints are the LSQ-projected literal
    # anchor positions. Only joint-adjacent trim_pct applies for
    # multi-arm strokes.
    left_pct = 0.0 if k == 0 else trim_pct
    right_pct = 0.0 if k == n_arms - 1 else trim_pct
    a_trim = (a_proj[0] + ux * L * left_pct,
              a_proj[1] + uy * L * left_pct)
    b_trim = (b_proj[0] - ux * L * right_pct,
              b_proj[1] - uy * L * right_pct)
    ia = (int(round(a_trim[0])), int(round(a_trim[1])))
    ib = (int(round(b_trim[0])), int(round(b_trim[1])))
    if ia == ib:
        return [(float(ia[0]), float(ia[1]))]
    seg = line_sampler([ia, ib])
    return [(float(c), float(r)) for c, r in seg]


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
                               max_handle: float = DEFAULT_CBEZ_MAX_HANDLE,
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
    # Mark any out-of-mask samples as skip indices. A cubic Bézier
    # passes through exactly one apex region by construction, so any
    # out-of-mask sample is part of the unavoidable chord overshoot at
    # a sharp geometric apex (lowercase v/w valleys). Gates 1 and 2
    # ignore these.
    mh, mw = mask.shape
    skip_indices: set[int] = set()
    for s_i, (sx, sy) in enumerate(samples):
        ic = int(round(sx)); ir = int(round(sy))
        if not (0 <= ir < mh and 0 <= ic < mw and bool(mask[ir, ic])):
            skip_indices.add(s_i)
    return {"type": "cbez", "P_end": P_end, "P_start": P_start,
            "V": g["V"], "C1": C1, "C2": C2,
            "tangent_prev": tp, "tangent_next": tn,
            "s_v": g["s_v"], "s_v_alt": g["s_v_alt"],
            "h1": h1, "h2": h2, "samples": samples,
            "skip_indices": skip_indices}


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


def joint_sharp_meeting_at_intersection(
        arm_prev: list[tuple[float, float]],
        arm_next: list[tuple[float, float]], *,
        mask: np.ndarray, dt: np.ndarray,
        anchor: tuple[int, int],
        ) -> dict | None:
    """Sharp angular meeting at the math intersection of the two arm
    fitted lines. `apex = V` unconditionally — no walk-clamp, no
    h_target. The two straight arms naturally meet at V whether V is
    inside or outside the mask. Concave valleys: V is in-mask, the
    polyline kinks at apex with one out-of-mask sample (apex itself
    may sit at low dt but is in-mask). Convex peaks: V is above the
    cap top, outside the mask; samples near apex are out-of-mask in
    a contiguous window. That window is recorded in `skip_indices`
    so gates 1 and 2 ignore intentional out-of-mask / kinked samples
    at the apex.

    Returns `None` if the arm lines are parallel."""
    if len(arm_prev) < 2 or len(arm_next) < 2:
        return None
    mh, mw = mask.shape
    p1a = arm_prev[0]; p1b = arm_prev[-1]
    d1x = p1b[0] - p1a[0]; d1y = p1b[1] - p1a[1]
    L1 = math.hypot(d1x, d1y)
    if L1 < 1e-6:
        return None
    d1x /= L1; d1y /= L1
    p2a = arm_next[0]; p2b = arm_next[-1]
    d2x = p2b[0] - p2a[0]; d2y = p2b[1] - p2a[1]
    L2 = math.hypot(d2x, d2y)
    if L2 < 1e-6:
        return None
    d2x /= L2; d2y /= L2
    det = d1x * (-d2y) - d1y * (-d2x)
    if abs(det) < 1e-6:
        return None
    dx_ = p2a[0] - p1a[0]; dy_ = p2a[1] - p1a[1]
    t = (dx_ * (-d2y) - dy_ * (-d2x)) / det
    V_apex = (p1a[0] + t * d1x, p1a[1] + t * d1y)
    apex = V_apex
    apc = int(round(apex[0])); apr = int(round(apex[1]))
    P_end = arm_prev[-1]
    P_start = arm_next[0]
    a = (int(round(P_end[0])), int(round(P_end[1])))
    b = (apc, apr)
    c = (int(round(P_start[0])), int(round(P_start[1])))
    samples: list[tuple[float, float]] = []
    if a != b:
        samples.extend((float(cc), float(rr))
                       for cc, rr in line_sampler([a, b]))
    else:
        samples.append(P_end)
    apex_index = len(samples) - 1
    if b != c:
        seg = [(float(cc), float(rr))
               for cc, rr in line_sampler([b, c])]
        if samples and seg and samples[-1] == seg[0]:
            seg = seg[1:]
        samples.extend(seg)
    else:
        samples.append(P_start)
    # Skip window: apex_index plus contiguous out-of-mask samples on
    # either side. Concave valleys with V in-mask collapse to just
    # {apex_index}. Convex peaks expand to include the cap-overshoot
    # window around the apex.
    skip_indices: set[int] = {apex_index}

    def _in_mask(p: tuple[float, float]) -> bool:
        ic = int(round(p[0])); ir = int(round(p[1]))
        return (0 <= ir < mh and 0 <= ic < mw and mask[ir, ic])

    j = apex_index - 1
    while j >= 0 and not _in_mask(samples[j]):
        skip_indices.add(j)
        j -= 1
    j = apex_index + 1
    while j < len(samples) and not _in_mask(samples[j]):
        skip_indices.add(j)
        j += 1
    v_in_mask = (0 <= apr < mh and 0 <= apc < mw and mask[apr, apc])
    return {"type": "sharp_meeting",
            "P_end": P_end, "P_start": P_start, "apex": apex,
            "V": V_apex, "v_in_mask": v_in_mask,
            "tangent_prev": (d1x, d1y),
            "tangent_next": (d2x, d2y),
            "samples": samples, "apex_index": apex_index,
            "skip_indices": skip_indices}


def joint_fillet_at_intersection(
        arm_prev: list[tuple[float, float]],
        arm_next: list[tuple[float, float]], *,
        mask: np.ndarray, dt: np.ndarray,
        anchor: tuple[int, int],
        trim_back: float = 8.0,
        ) -> dict | None:
    """Fillet-style joint: cubic Bézier arc between trim points offset
    `trim_back` pixels back from the math intersection V along each
    arm's tangent. Both Bézier control points sit at V, so the arc
    interpolates with tangent continuity at the seams and the midpoint
    sits 3/4 of the way from the chord-midpoint to V.

    Construction:
      V = math intersection of arm_prev's and arm_next's fitted lines
      d_prev = unit vector from arm_prev[0] to arm_prev[-1]
      d_next = unit vector from arm_next[0] to arm_next[-1]
      P_end_trim   = V - trim_back * d_prev   (back from V along arm_prev)
      P_start_trim = V + trim_back * d_next   (forward from V along arm_next)
      Cubic Bézier: P0 = P_end_trim, C1 = C2 = V, P3 = P_start_trim

    Bridge segments stitch arm_prev[-1] → P_end_trim and
    P_start_trim → arm_next[0] (straight lines along the arm tangents)
    so the chain remains continuous even when trim_back doesn't match
    the natural arm endpoint exactly. Returns None when arms are
    parallel or |trim_back| exceeds the |V−arm[-1]| distance (which
    would force a reversal)."""
    if len(arm_prev) < 2 or len(arm_next) < 2:
        return None
    mh, mw = mask.shape
    p1a = arm_prev[0]; p1b = arm_prev[-1]
    d1x = p1b[0] - p1a[0]; d1y = p1b[1] - p1a[1]
    L1 = math.hypot(d1x, d1y)
    if L1 < 1e-6:
        return None
    d1x /= L1; d1y /= L1
    p2a = arm_next[0]; p2b = arm_next[-1]
    d2x = p2b[0] - p2a[0]; d2y = p2b[1] - p2a[1]
    L2 = math.hypot(d2x, d2y)
    if L2 < 1e-6:
        return None
    d2x /= L2; d2y /= L2
    det = d1x * (-d2y) - d1y * (-d2x)
    if abs(det) < 1e-6:
        return None
    dx_ = p2a[0] - p1a[0]; dy_ = p2a[1] - p1a[1]
    t_param = (dx_ * (-d2y) - dy_ * (-d2x)) / det
    V = (p1a[0] + t_param * d1x, p1a[1] + t_param * d1y)
    # Trim points: trim_back pixels back from V along each arm tangent.
    P_end_trim = (V[0] - trim_back * d1x, V[1] - trim_back * d1y)
    P_start_trim = (V[0] + trim_back * d2x, V[1] + trim_back * d2y)
    # Bridges from natural arm endpoints to trim points. If the trim
    # point sits BEHIND the natural arm endpoint (i.e., trim_back is
    # larger than the |V − arm_prev[-1]| distance along d_prev), the
    # bridge would walk backward — bail out so callers can pick a
    # smaller trim_back.
    bridge_prev_signed = (
        (P_end_trim[0] - p1b[0]) * d1x
        + (P_end_trim[1] - p1b[1]) * d1y
    )
    bridge_next_signed = (
        (p2a[0] - P_start_trim[0]) * d2x
        + (p2a[1] - P_start_trim[1]) * d2y
    )
    if (bridge_prev_signed < FILLET_BRIDGE_REVERSAL_TOLERANCE
            or bridge_next_signed < FILLET_BRIDGE_REVERSAL_TOLERANCE):
        return None
    # Sample the bridges + Bézier into one continuous polyline.
    samples: list[tuple[float, float]] = []

    def _extend(seg: list[tuple[float, float]]):
        if not samples:
            samples.extend((float(x), float(y)) for x, y in seg)
            return
        last = samples[-1]
        start = 1 if (int(round(seg[0][0])), int(round(seg[0][1]))) == (
            int(round(last[0])), int(round(last[1]))) else 0
        samples.extend((float(x), float(y)) for x, y in seg[start:])

    a = (int(round(p1b[0])), int(round(p1b[1])))
    b = (int(round(P_end_trim[0])), int(round(P_end_trim[1])))
    if a != b:
        _extend(line_sampler([a, b]))
    else:
        samples.append((float(p1b[0]), float(p1b[1])))
    bez = sample_cubic_bezier(P_end_trim, V, V, P_start_trim)
    _extend([(int(round(x)), int(round(y))) for x, y in bez])
    c = (int(round(P_start_trim[0])), int(round(P_start_trim[1])))
    d = (int(round(p2a[0])), int(round(p2a[1])))
    if c != d:
        _extend(line_sampler([c, d]))
    # Mark any out-of-mask samples as skip indices. For concave valleys
    # the entire arc sits inside the mask (V inside, bezier interpolates
    # within); for convex peaks the arc may briefly leave the mask near
    # V where the cap rounds off.
    skip_indices: set[int] = set()
    for s_i, (sx, sy) in enumerate(samples):
        ic = int(round(sx)); ir = int(round(sy))
        if not (0 <= ir < mh and 0 <= ic < mw and bool(mask[ir, ic])):
            skip_indices.add(s_i)
    return {"type": "fillet",
            "P_end_trim": P_end_trim, "P_start_trim": P_start_trim,
            "V": V, "trim_back": trim_back,
            "tangent_prev": (d1x, d1y),
            "tangent_next": (d2x, d2y),
            "samples": samples, "skip_indices": skip_indices}


# --- Walker primitives (extracted from 77f1c220) ---------------------------
# Three walker primitives that traverse the letter's skeleton between
# bbox-relative cardinal anchors: walk (start→end), continuous (multi-
# anchor chain), loop (closed-loop CCW/CW). Used by closed-bowl letters
# B/D/P/R/p/q via the "walker" kind. Produces clean medial-axis
# centerlines because skimage.skeletonize gives a single-pixel ridge
# through the band center.

WALKER_ANCHOR_POSITIONS: dict[str, tuple[float, float]] = {
    "TL": (0.0, 0.0), "TR": (1.0, 0.0),
    "BL": (0.0, 1.0), "BR": (1.0, 1.0),
    "T":  (0.5, 0.0), "TC": (0.5, 0.0),
    "B":  (0.5, 1.0), "BC": (0.5, 1.0),
    "L":  (0.0, 0.5), "ML": (0.0, 0.5),
    "R":  (1.0, 0.5), "MR": (1.0, 0.5),
    "C":  (0.5, 0.5),
}

_NEIGHBOURS_8 = ((-1, -1), (-1, 0), (-1, 1),
                  (0, -1),           (0, 1),
                  (1, -1),  (1, 0),  (1, 1))


def _build_skel_adjacency(skel_pixels: set[tuple[int, int]]
                            ) -> dict[tuple[int, int],
                                       list[tuple[int, int]]]:
    """Map each (col, row) skeleton pixel to its 8-connected neighbours
    that are also on the skeleton."""
    adj: dict[tuple[int, int], list[tuple[int, int]]] = {}
    for (c, r) in skel_pixels:
        nbrs = []
        for dr, dc in _NEIGHBOURS_8:
            n = (c + dc, r + dr)
            if n in skel_pixels:
                nbrs.append(n)
        adj[(c, r)] = nbrs
    return adj


def _walker_resolve_anchor(anchor,
                             skel: np.ndarray,
                             bbox: tuple[int, int, int, int]
                             ) -> tuple[int, int] | None:
    """Map a cardinal anchor name (TL/TR/.../C) or (x, y) tuple in
    [0, 1] to the nearest skeleton pixel."""
    x_min, y_min, x_max, y_max = bbox
    w = max(1, x_max - x_min)
    h = max(1, y_max - y_min)
    if isinstance(anchor, str):
        if anchor not in WALKER_ANCHOR_POSITIONS:
            raise ValueError(
                f"unknown walker anchor name: {anchor!r}")
        ax, ay = WALKER_ANCHOR_POSITIONS[anchor]
    else:
        ax, ay = anchor
    target_x = x_min + ax * w
    target_y = y_min + ay * h
    rows, cols = np.where(skel)
    if rows.size == 0:
        return None
    dx = cols.astype(np.float64) - target_x
    dy = rows.astype(np.float64) - target_y
    i = int(np.argmin(dx * dx + dy * dy))
    return (int(cols[i]), int(rows[i]))


def _walker_bfs_path(start: tuple[int, int],
                       end: tuple[int, int],
                       adj: dict[tuple[int, int],
                                   list[tuple[int, int]]]
                       ) -> list[tuple[int, int]] | None:
    """Shortest path along the skeleton graph."""
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
            if n not in parent:
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


def _walker_walk(from_anchor, to_anchor, *,
                   skel: np.ndarray,
                   adj: dict, bbox: tuple[int, int, int, int]
                   ) -> list[tuple[int, int]] | None:
    start = _walker_resolve_anchor(from_anchor, skel, bbox)
    end = _walker_resolve_anchor(to_anchor, skel, bbox)
    if start is None or end is None:
        return None
    return _walker_bfs_path(start, end, adj)


def _walker_continuous(anchors: list, *,
                         skel: np.ndarray,
                         adj: dict, bbox: tuple[int, int, int, int]
                         ) -> list[tuple[int, int]] | None:
    if not anchors:
        return None
    pixels = [_walker_resolve_anchor(a, skel, bbox) for a in anchors]
    if any(p is None for p in pixels):
        return None
    full: list[tuple[int, int]] = [pixels[0]]
    for i in range(len(pixels) - 1):
        seg = _walker_bfs_path(pixels[i], pixels[i + 1], adj)
        if seg is None or len(seg) < 2:
            return None
        full.extend(seg[1:])
    return full


def _walker_cycle_ccw(seed: tuple[int, int],
                        adj: dict[tuple[int, int],
                                    list[tuple[int, int]]]
                        ) -> list[tuple[int, int]]:
    """Walk a closed skeleton cycle starting at `seed`; force visual
    CCW orientation (Austrian handwriting convention for O/o)."""
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
    # Image-coord shoelace: positive = clockwise visually.
    s = 0.0
    for i in range(len(path) - 1):
        x1, y1 = path[i]
        x2, y2 = path[i + 1]
        s += (x2 - x1) * (y2 + y1)
    if s > 0:
        path = list(reversed(path))
    return path


def _walker_loop(start_anchor, direction: str, *,
                   skel: np.ndarray,
                   adj: dict, bbox: tuple[int, int, int, int]
                   ) -> list[tuple[int, int]] | None:
    seed = _walker_resolve_anchor(start_anchor, skel, bbox)
    if seed is None or seed not in adj:
        return None
    if len(adj[seed]) >= 2:
        path = _walker_cycle_ccw(seed, adj)
        if direction == "cw":
            path = list(reversed(path))
        return path
    # Degenerate (degree-1): walk endpoint to endpoint of the component.
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
    return _walker_bfs_path(endpoints[0], endpoints[1], adj) or [seed]


def _walker_dispatch(stroke_spec: dict, *,
                       skel: np.ndarray,
                       adj: dict, bbox: tuple[int, int, int, int]
                       ) -> list[tuple[int, int]] | None:
    """Dispatch a walker stroke spec to walk / continuous / loop."""
    prim = stroke_spec.get("primitive")
    if prim == "walk":
        return _walker_walk(stroke_spec["from"], stroke_spec["to"],
                              skel=skel, adj=adj, bbox=bbox)
    if prim == "continuous":
        return _walker_continuous(stroke_spec["anchors"],
                                    skel=skel, adj=adj, bbox=bbox)
    if prim == "loop":
        return _walker_loop(stroke_spec["start"],
                              stroke_spec.get("direction", "ccw"),
                              skel=skel, adj=adj, bbox=bbox)
    raise ValueError(f"unknown walker primitive {prim!r}")


# --- Registries -------------------------------------------------------------

ARM_STRATEGIES = {
    "chord": arm_chord,
    "bfs_raw": arm_bfs_raw,
    "lsq_line": arm_lsq_line,
    "smoothed_medial_axis": arm_smoothed_medial_axis,
    "straight_line": arm_straight_line,
    "analytical_line_stem": arm_analytical_line_stem,
}

JOINT_STRATEGIES = {
    "sharp": joint_sharp,
    "family_a_fillet": joint_family_a_fillet,
    "quadratic_bezier_at_V": joint_quadratic_bezier_at_V,
    "cubic_bezier_clamped": joint_cubic_bezier_clamped,
    "sharp_meeting": joint_sharp_meeting,
    "sharp_meeting_at_intersection": joint_sharp_meeting_at_intersection,
    "fillet_at_intersection": joint_fillet_at_intersection,
}

# Default pair matches the byte-identical line-kind output shipping at
# 6cf5740 — change the defaults only with a sweep + visual review.
DEFAULT_ARM_STRATEGY: tuple[str, dict] = ("smoothed_medial_axis", {})
DEFAULT_JOINT_STRATEGY: tuple[str, dict] = ("cubic_bezier_clamped",
                                            {"max_handle": DEFAULT_CBEZ_MAX_HANDLE})


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
    if letter in SHIPPED_AS_STATIC_ARTIFACT:
        raise KeyError(
            f"{letter!r} ships as a static artifact; bake is "
            f"intentionally not authored. See SHIPPED_AS_STATIC_ARTIFACT "
            f"+ iPad calibrator workflow (StrokeCalibrationOverlay.swift).")
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
    # Chain indices to skip in gates 1 (overshoot) and 2 (reversal) for
    # sharp_meeting joints. Covers the apex sample plus any contiguous
    # out-of-mask samples around it (convex peaks at the cap top emit
    # an out-of-mask window; concave valleys collapse to just the apex).
    sharp_skip_indices_per_stroke: list[set[int]] = []

    # Per-letter anchor caches. Same `name` referenced across multiple
    # strokes resolves once and re-uses the same pixel — required for
    # multi-stroke shared-meeting-point letters (e.g. T-architecture
    # variants). Key on `(kind, name)` because curve-kind passes `dt`
    # to `resolve_anchor` and applies `extend_tip_inward` for tip
    # anchors, returning a different pixel than line-kind.
    anchor_cache: dict[tuple[str, str], tuple[int, int]] = {}
    snap_cache: dict[str, tuple[int, int]] = {}
    total_resolve_calls = 0
    total_snap_calls = 0

    def _cached_resolve(name: str, kind_: str,
                        anchor_dt: np.ndarray | None
                        ) -> tuple[int, int]:
        nonlocal total_resolve_calls
        total_resolve_calls += 1
        key = (kind_, name)
        if key not in anchor_cache:
            anchor_cache[key] = resolve_anchor(name, mask, bbox,
                                                dt=anchor_dt)
        return anchor_cache[key]

    def _cached_snap(p: tuple[int, int],
                     name: str) -> tuple[int, int]:
        nonlocal total_snap_calls
        total_snap_calls += 1
        if name not in snap_cache:
            snap_cache[name] = snap_to_medial_axis(
                p, mask, dt, skeleton,
                letter=letter, anchor_name=name)
        return snap_cache[name]

    # ----- Letter-level line-fitting pre-pass -----
    # Both shared-apex and T-junction pre-computes need each
    # `straight_line` arm's LSQ-fitted line. Pre-fit once, cache by
    # (stroke_idx, arm_idx), so neither pre-compute re-runs SVD on the
    # same skeleton path. This pre-pass is invisible (no output
    # change) for letters that don't use shared-apex or T-junction.

    def _arm_strategy_name(spec_: dict, k_: int) -> str:
        arms_ = spec_.get("arms")
        if arms_ is None:
            return DEFAULT_ARM_STRATEGY[0]
        if k_ >= len(arms_):
            return DEFAULT_ARM_STRATEGY[0]
        entry = arms_[k_]
        if entry is None:
            return DEFAULT_ARM_STRATEGY[0]
        if isinstance(entry, str):
            return entry
        if isinstance(entry, dict):
            return entry.get("strategy") or DEFAULT_ARM_STRATEGY[0]
        return DEFAULT_ARM_STRATEGY[0]

    stroke_arm_lines: dict[tuple[int, int],
                            tuple[tuple[float, float],
                                  tuple[float, float]]] = {}
    for s_idx, spec_ in enumerate(specs):
        if spec_.get("kind") != "line":
            continue
        names_ = spec_.get("anchors") or []
        if len(names_) < 2:
            continue
        n_arms_ = len(names_) - 1
        for k_ in range(n_arms_):
            if _arm_strategy_name(spec_, k_) != "straight_line":
                continue
            a_name = names_[k_]
            b_name = names_[k_ + 1]
            try:
                a_raw = _cached_resolve(a_name, "line", None)
                b_raw = _cached_resolve(b_name, "line", None)
            except (KeyError, ValueError):
                continue
            a_snap = _cached_snap(a_raw, a_name)
            b_snap = _cached_snap(b_raw, b_name)
            bfs_pts = _bfs_skeleton_path(a_snap, b_snap, skeleton)
            if bfs_pts is None or len(bfs_pts) < 5:
                continue
            # Trim the BFS path to the contiguous middle segment whose
            # per-segment tangent is within ±30° of the anchor-pair
            # direction. When ML/MR snap onto adjacent strokes (A:
            # crossbar anchors snap to the diagonals' skeletons), the
            # BFS path is L-shaped — leg/midbar/leg — and SVD over the
            # full path averages the perpendicular legs into the fit.
            # Trimming to the on-axis run drops those legs; benign for
            # already-straight paths (every segment is on-axis).
            bfs_pts = _trim_bfs_to_on_axis(bfs_pts, a_raw, b_raw)
            if len(bfs_pts) < 5:
                continue
            arr = np.array(bfs_pts, dtype=float)
            centroid = arr.mean(axis=0)
            _, _, vt = np.linalg.svd(arr - centroid,
                                      full_matrices=False)
            direction = vt[0]
            stroke_arm_lines[(s_idx, k_)] = (
                (float(centroid[0]), float(centroid[1])),
                (float(direction[0]), float(direction[1])),
            )

    # ----- Letter-level shared-apex pre-compute -----
    # When an anchor name is referenced as an endpoint of multiple
    # line-kind strokes whose endpoint arm is straight_line, both
    # strokes should terminate at the SAME pixel. Compute the LSQ
    # intersection of all relevant fitted arm lines and inject via
    # arm_straight_line's start_pixel / end_pixel override.
    candidate_uses: dict[str, list[tuple[int, str]]] = {}
    for s_idx, spec_ in enumerate(specs):
        if spec_.get("kind") != "line":
            continue
        names_ = spec_.get("anchors") or []
        if len(names_) < 2:
            continue
        n_arms_ = len(names_) - 1
        if _arm_strategy_name(spec_, 0) == "straight_line":
            candidate_uses.setdefault(
                names_[0], []).append((s_idx, "start"))
        if _arm_strategy_name(spec_, n_arms_ - 1) == "straight_line":
            candidate_uses.setdefault(
                names_[-1], []).append((s_idx, "end"))

    shared_apex_cache: dict[str, tuple[int, int] | None] = {}
    for shared_name, uses in candidate_uses.items():
        if len({u[0] for u in uses}) < 2:
            continue
        fitted_lines: list[tuple[tuple[float, float],
                                  tuple[float, float]]] = []
        for s_idx, side in uses:
            n_arms_ = len(specs[s_idx]["anchors"]) - 1
            arm_idx = 0 if side == "start" else n_arms_ - 1
            line = stroke_arm_lines.get((s_idx, arm_idx))
            if line is not None:
                fitted_lines.append(line)
        if len(fitted_lines) < 2:
            shared_apex_cache[shared_name] = None
            continue
        if len(fitted_lines) == 2:
            (p1x, p1y), (d1x, d1y) = fitted_lines[0]
            (p2x, p2y), (d2x, d2y) = fitted_lines[1]
            det = d1x * (-d2y) - d1y * (-d2x)
            if abs(det) < 1e-9:
                shared_apex_cache[shared_name] = None
                continue
            ddx = p2x - p1x; ddy = p2y - p1y
            t = (ddx * (-d2y) - ddy * (-d2x)) / det
            apex_f = (p1x + t * d1x, p1y + t * d1y)
        else:
            # LSQ for 3+ lines: minimise Σ perpendicular distances.
            # Per line (point p, direction d), the perpendicular
            # normal is n = (d_y, -d_x). Constraint n·x = n·p.
            A_mat: list[list[float]] = []
            b_vec: list[float] = []
            for (px, py), (dx_, dy_) in fitted_lines:
                nx, ny = dy_, -dx_
                A_mat.append([nx, ny])
                b_vec.append(nx * px + ny * py)
            sol, *_ = np.linalg.lstsq(np.array(A_mat),
                                       np.array(b_vec), rcond=None)
            apex_f = (float(sol[0]), float(sol[1]))
        ai = (int(round(apex_f[0])), int(round(apex_f[1])))
        if (0 <= ai[1] < mask.shape[0]
                and 0 <= ai[0] < mask.shape[1]
                and mask[ai[1], ai[0]]):
            shared_apex_cache[shared_name] = ai
        else:
            shared_apex_cache[shared_name] = None

    # ----- Letter-level T-junction pre-compute -----
    # A straight_line arm can declare its endpoint to be a T-junction
    # meeting with another stroke's centerline via the arm strategy
    # dict: {"strategy": "straight_line", "t_junction_start": <idx>,
    # "t_junction_end": <idx>}. The endpoint pixel is the intersection
    # of this arm's fitted line with the target stroke's fitted line
    # (target stroke's arm 0 — single-arm assumption). Distinct from
    # shared-apex (V-meeting between two strokes ending at the same
    # named anchor); this is one stroke's centerline crossing another.
    t_junction_cache: dict[tuple[int, int, str],
                            tuple[int, int]] = {}
    for s_idx, spec_ in enumerate(specs):
        if spec_.get("kind") != "line":
            continue
        names_ = spec_.get("anchors") or []
        if len(names_) < 2:
            continue
        arms_spec = spec_.get("arms")
        if arms_spec is None:
            continue
        n_arms_ = len(names_) - 1
        for k_ in range(n_arms_):
            if k_ >= len(arms_spec):
                continue
            entry = arms_spec[k_]
            if not isinstance(entry, dict):
                continue
            if entry.get("strategy") != "straight_line":
                continue
            my_line = stroke_arm_lines.get((s_idx, k_))
            if my_line is None:
                continue
            for field, side in (("t_junction_start", "start"),
                                 ("t_junction_end", "end")):
                target_idx = entry.get(field)
                if target_idx is None:
                    continue
                target_line = stroke_arm_lines.get((target_idx, 0))
                if target_line is None:
                    continue  # target not straight_line; skip
                (p1x, p1y), (d1x, d1y) = my_line
                (p2x, p2y), (d2x, d2y) = target_line
                det = d1x * (-d2y) - d1y * (-d2x)
                if abs(det) < 1e-9:
                    continue
                ddx = p2x - p1x; ddy = p2y - p1y
                t = (ddx * (-d2y) - ddy * (-d2x)) / det
                ix_f = p1x + t * d1x
                iy_f = p1y + t * d1y
                ix = int(round(ix_f)); iy = int(round(iy_f))
                if (0 <= iy < mask.shape[0]
                        and 0 <= ix < mask.shape[1]
                        and mask[iy, ix]):
                    t_junction_cache[(s_idx, k_, side)] = (ix, iy)

    for i, spec in enumerate(specs, start=1):
        if spec.get("kind") == "dot":
            # Tittle / period: a single-checkpoint stroke at one anchor.
            # No arms, no joints, no skeleton walk — the child taps it.
            anchor_name = spec.get("anchor")
            if not isinstance(anchor_name, str):
                raise ValueError(
                    f"{letter} stroke {i}: 'dot' kind needs 'anchor' key")
            pos = _cached_resolve(anchor_name, "dot", None)
            stroke_pixel_chains.append([pos])
            resolved_anchors.append([(anchor_name, pos)])
            joint_arcs_per_stroke.append([])
            smoothed_paths_per_stroke.append([])
            sharp_skip_indices_per_stroke.append(set())
            json_strokes.append({
                "id": i,
                "checkpoints": [
                    {"x": round(pixel_to_rel(pos, bbox)[0], 4),
                     "y": round(pixel_to_rel(pos, bbox)[1], 4)},
                ],
                "comment": "dot",
            })
            continue
        if spec.get("kind") == "walker":
            # Walker stroke: BFS-walk the letter's skimage skeleton
            # between cardinal anchors. Produces a medial-axis
            # centerline directly — no further processing needed for
            # the closed-bowl letters that ship via walkers.
            if "_walker_adj" not in locals():
                _rows, _cols = np.where(skeleton)
                _walker_skel_pixels = set(zip(_cols.tolist(),
                                                _rows.tolist()))
                _walker_adj = _build_skel_adjacency(_walker_skel_pixels)
            try:
                chain_w = _walker_dispatch(spec, skel=skeleton,
                                             adj=_walker_adj, bbox=bbox)
            except Exception as e:
                raise ValueError(
                    f"{letter} stroke {i}: walker failed — {e}") from e
            if chain_w is None or len(chain_w) < 2:
                raise ValueError(
                    f"{letter} stroke {i}: walker returned no path")
            stroke_pixel_chains.append(chain_w)
            resolved_anchors.append([])
            joint_arcs_per_stroke.append([])
            smoothed_paths_per_stroke.append([])
            sharp_skip_indices_per_stroke.append(set())
            resampled = resample_uniform(chain_w, CHECKPOINT_COUNT)
            json_strokes.append({
                "id": i,
                "checkpoints": [
                    {"x": round(pixel_to_rel(p, bbox)[0], 4),
                     "y": round(pixel_to_rel(p, bbox)[1], 4)}
                    for p in resampled
                ],
            })
            continue
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
                pos = _cached_resolve(name, kind, anchor_dt)
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
                _cached_snap(p, n) for p, n in zip(anchors, names)
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
                call_params = dict(params)
                # T-junction control fields are spec-level metadata;
                # strip before forwarding to the arm primitive.
                call_params.pop("t_junction_start", None)
                call_params.pop("t_junction_end", None)
                # Inject shared-apex / T-junction overrides only for
                # arm_straight_line. analytical_line_stem and
                # smoothed_medial_axis have no endpoint policy — the
                # primitives' outputs ship as-is.
                if name == "straight_line":
                    left_name = names[k]
                    right_name = names[k + 1]
                    sp_left = shared_apex_cache.get(left_name)
                    sp_right = shared_apex_cache.get(right_name)
                    tj_left = t_junction_cache.get(
                        (i - 1, k, "start"))
                    tj_right = t_junction_cache.get(
                        (i - 1, k, "end"))
                    if sp_left is not None:
                        call_params["start_pixel"] = sp_left
                    elif tj_left is not None:
                        call_params["start_pixel"] = tj_left
                    if sp_right is not None:
                        call_params["end_pixel"] = sp_right
                    elif tj_right is not None:
                        call_params["end_pixel"] = tj_right
                # analytical_line_stem fits a line through per-row stem
                # midpoints — it needs the LITERAL cap/foot anchor rows
                # (not medial-axis-snapped) to span the full glyph
                # height. smoothed_medial_axis BFS-walks the skeleton
                # and needs SNAPPED anchors to start/end on it.
                if name == "analytical_line_stem":
                    arm_a = anchors[k]
                    arm_b = anchors[k + 1]
                else:
                    arm_a = rough_snapped[k]
                    arm_b = rough_snapped[k + 1]
                arms.append(fn(arm_a, arm_b,
                               k, n_arms,
                               mask=mask, dt=dt, skeleton=skeleton,
                               **call_params))

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
            stroke_skip_indices: set[int] = set()

            def _emit_pts(pts: list[tuple[float, float]],
                          skip_sample_indices: set[int] | None = None
                          ) -> None:
                for s_i, p in enumerate(pts):
                    ip = (int(round(p[0])), int(round(p[1])))
                    if not chain or chain[-1] != ip:
                        chain.append(ip)
                    if (skip_sample_indices is not None
                            and s_i in skip_sample_indices):
                        # Sample's chain index is the last chain index
                        # whether we just appended or dedup'd against
                        # chain[-1].
                        stroke_skip_indices.add(len(chain) - 1)

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
                        skip = jd_prev.get("skip_indices")
                        _emit_pts(jd_prev["samples"],
                                  skip_sample_indices=skip)
                    elif chain:
                        _emit_line(chain[-1], arm_start)
                if arm_path is not None:
                    _emit_pts(arm_path)
                else:
                    _emit_line(arm_start, arm_end)
            joint_arcs_per_stroke.append(joints)
            smoothed_paths_per_stroke.append(arms)
            sharp_skip_indices_per_stroke.append(stroke_skip_indices)
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
            sharp_skip_indices_per_stroke.append(set())
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
        "sharp_skip_indices_per_stroke": sharp_skip_indices_per_stroke,
        "anchor_cache_size": len(anchor_cache),
        "snap_cache_size": len(snap_cache),
        "total_resolve_calls": total_resolve_calls,
        "total_snap_calls": total_snap_calls,
        "shared_apex_cache": dict(shared_apex_cache),
        "t_junction_cache": dict(t_junction_cache),
        "stroke_arm_lines": dict(stroke_arm_lines),
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
    trigger a re-bake. `fontPath` is stored repo-relative so the file
    is byte-identical across developer machines; falls back to the
    absolute path if the font lives outside the repo."""
    font_hash = hashlib.sha256(font_path.read_bytes()).hexdigest()
    try:
        font_path_str = str(font_path.resolve().relative_to(REPO_ROOT))
    except ValueError:
        font_path_str = str(font_path)
    (out_base / "_meta.json").write_text(json.dumps({
        "fontPath": font_path_str,
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
    parser.add_argument("--weight", choices=["regular", "light", "both"],
                        default="regular",
                        help="Font weight to bake. Each weight writes to "
                             "<out>/<Weight>/<letter>/strokes.json. Default: regular.")
    parser.add_argument("--font", default=None,
                        help="Override font path. Implies a single bake "
                             "into <out>/Regular/ unless --weight=light.")
    parser.add_argument("--out", default=None,
                        help="Output base dir. Default: PrimaeNative/Resources/Letters.")
    parser.add_argument("--no-overwrite", action="store_true",
                        help="Skip letters whose strokes.json already exists.")
    parser.add_argument("--debug", action="store_true",
                        help="Save /tmp/centerline_<L>.png overlays.")
    args = parser.parse_args()

    if args.weight == "both":
        weights = ["regular", "light"]
    else:
        weights = [args.weight]

    out_base = Path(args.out) if args.out else OUTPUT_BASE
    letters = args.letters or list(LETTERS.keys())

    overall_fail = 0
    for weight in weights:
        if args.font and weight == args.weight:
            font_path = Path(args.font)
        else:
            font_path = FONTS[weight]
        if not font_path.exists():
            print(f"Font not found: {font_path}")
            overall_fail += 1
            continue
        weight_base = out_base / weight.capitalize()
        print(f"=== Baking weight={weight} font={font_path.name} → {weight_base} ===")
        ok = 0
        fail = 0
        for letter in letters:
            out_dir = (weight_base / letter
                       if letter.isupper() or not letter.isalpha()
                       else weight_base / f"{letter}{LOWERCASE_SUFFIX}")
            out_file = out_dir / "strokes.json"
            if args.no_overwrite and out_file.exists():
                print(f"  {letter}: skipped (exists)")
                continue
            if letter in SHIPPED_AS_STATIC_ARTIFACT:
                print(f"  {letter}: skipped (static artifact — "
                      f"hand-tuned via iPad calibrator)")
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
                                 Path(f"/tmp/centerline_{weight}_{letter}.png"))
                except Exception as e:
                    print(f"  {letter}: overlay FAIL — {e}")
            ok += 1
        if ok > 0:
            try:
                write_meta(weight_base, font_path)
            except Exception as e:
                print(f"  _meta.json: FAIL — {e}")
        print(f"  Done {weight} — {ok} ok, {fail} failed.")
        overall_fail += fail
    return 0 if overall_fail == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
