#!/usr/bin/env python3
"""Suggest a `LETTER_OVERRIDES` patch from a calibrated strokes.json.

After you ship a hand-calibrated stroke file, run this against the
JSON to see what `generate_strokes_auto.py` would need in its override
table to produce the same shape automatically.

Usage:
    python3 scripts/calibration_to_override.py i
    python3 scripts/calibration_to_override.py M --schrift druckschrift

The script:
  1. Renders the letter via the generator's `rasterize` to recover the
     same skeleton + bbox the generator works with.
  2. For each stroke in the calibrated `strokes.json`:
       - Maps the first / last checkpoint to the closest named anchor
         (TL, TC, TR, ML, C, MR, BL, BC, BR) — falls back to a tuple
         when no named anchor lands within 8 % of the bbox.
       - Detects whether the stroke needs `via` points by walking the
         skeleton from the chosen start anchor to the end anchor and
         comparing the resulting checkpoint cloud against the
         calibrated checkpoint cloud (Hausdorff-style nearest-distance
         max). If the reroute drift exceeds 12 % of the bbox diagonal,
         picks the stroke's centroid as a `via` anchor and re-runs the
         comparison.
  3. Emits a Python literal ready to paste into `LETTER_OVERRIDES`.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

import numpy as np
import skimage.morphology as morph

# Reuse the generator's rasteriser + skeleton utilities.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_strokes_auto import (  # noqa: E402
    ANCHOR_POSITIONS,
    DEFAULT_FONT,
    bfs_path,
    build_adjacency,
    rasterize,
    resolve_anchor,
)

REPO_ROOT = Path(__file__).resolve().parent.parent
LETTERS_DIR = REPO_ROOT / "PrimaeNative" / "Resources" / "Letters"


def output_dir_for(letter: str) -> Path:
    """Mirror the generator's `output_dir_for`."""
    if letter.isupper() or not letter.isalpha():
        return LETTERS_DIR / letter
    return LETTERS_DIR / f"{letter}_l"


def nearest_anchor(pt_bbox: tuple[float, float],
                   threshold: float = 0.08
                   ) -> str | tuple[float, float]:
    """Return the closest named anchor name to a bbox-relative point,
    or the raw tuple if no named anchor is within `threshold` of the
    bbox diagonal."""
    px, py = pt_bbox
    best_name: str | None = None
    best_d2 = math.inf
    for name, (ax, ay) in ANCHOR_POSITIONS.items():
        d2 = (ax - px) ** 2 + (ay - py) ** 2
        if d2 < best_d2:
            best_d2 = d2
            best_name = name
    if best_name is not None and math.sqrt(best_d2) <= threshold:
        return best_name
    return (round(px, 2), round(py, 2))


def hausdorff_drift(path_a: list[tuple[int, int]],
                    path_b_xy: list[tuple[float, float]]
                    ) -> float:
    """Max nearest-neighbour distance from path_a to path_b — measures
    how far the BFS path drifts from the calibrated checkpoints."""
    if not path_a or not path_b_xy:
        return float("inf")
    arr_b = np.array(path_b_xy, dtype=np.float64)
    drift = 0.0
    for (ax, ay) in path_a:
        d = np.hypot(arr_b[:, 0] - ax, arr_b[:, 1] - ay).min()
        if d > drift:
            drift = float(d)
    return drift


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("letter", help="Letter to analyse (e.g. 'i', 'M').")
    parser.add_argument("--font", default=str(DEFAULT_FONT),
                        help="OTF / TTF font path. Default: Primae-Regular.")
    parser.add_argument("--via-threshold", type=float, default=0.12,
                        help="Hausdorff drift (bbox-diagonal fraction) above "
                             "which a `via` anchor is suggested. Default 0.12.")
    args = parser.parse_args()

    json_path = output_dir_for(args.letter) / "strokes.json"
    if not json_path.exists():
        print(f"No strokes.json at {json_path}", file=sys.stderr)
        return 1
    data = json.load(json_path.open())
    strokes = data["strokes"]

    mask = rasterize(args.letter, Path(args.font))
    skel = morph.skeletonize(mask)
    rows, cols = np.where(mask)
    bbox = (int(cols.min()), int(rows.min()),
            int(cols.max()), int(rows.max()))
    bw = max(1, bbox[2] - bbox[0])
    bh = max(1, bbox[3] - bbox[1])
    bbox_diag = math.hypot(bw, bh)
    sk_pixels = set(zip(np.where(skel)[1].tolist(),
                        np.where(skel)[0].tolist()))
    adj = build_adjacency(sk_pixels)

    # Helper: bbox-relative → skeleton pixel
    def bbox_pt_to_skel(pt: tuple[float, float]) -> tuple[int, int]:
        return resolve_anchor(pt, skel, bbox)

    # Helper: skeleton pixel → bbox-relative
    def skel_to_bbox(p: tuple[int, int]) -> tuple[float, float]:
        return ((p[0] - bbox[0]) / bw, (p[1] - bbox[1]) / bh)

    print(f'    "{args.letter}": [')
    for stroke in strokes:
        cps = [(cp["x"], cp["y"]) for cp in stroke["checkpoints"]]
        if not cps:
            continue
        if len(cps) == 1:
            x, y = cps[0]
            print(f'        # Single-point stroke (dot/mark) — anchor as a tuple')
            print(f'        {{"kind": "loop", "start": ({x:.2f}, {y:.2f}), '
                  f'"direction": "ccw"}},')
            continue
        start_anchor = nearest_anchor(cps[0])
        end_anchor = nearest_anchor(cps[-1])

        # Check whether a straight BFS from start to end matches the
        # calibrated stroke. If not, pick the centroid as a via.
        start_px = bbox_pt_to_skel(
            ANCHOR_POSITIONS[start_anchor] if isinstance(start_anchor, str)
            else start_anchor)
        end_px = bbox_pt_to_skel(
            ANCHOR_POSITIONS[end_anchor] if isinstance(end_anchor, str)
            else end_anchor)
        path = bfs_path(start_px, end_px, adj)

        # Convert calibrated cps to skel pixel coords for drift compare.
        cps_skel = [(bbox[0] + x * bw, bbox[1] + y * bh) for (x, y) in cps]
        drift = hausdorff_drift(path or [], cps_skel) / bbox_diag

        anchors_list = [start_anchor]
        if drift > args.via_threshold:
            mid_idx = len(cps) // 2
            via = nearest_anchor(cps[mid_idx])
            anchors_list.append(via)
        anchors_list.append(end_anchor)

        kind = "walk" if len(anchors_list) == 2 else "continuous"
        if kind == "walk":
            a, b = anchors_list
            af = format_anchor(a)
            bf = format_anchor(b)
            print(f'        {{"kind": "walk", "from": {af}, "to": {bf}}},  '
                  f'# drift {drift:.2%}')
        else:
            ans = ", ".join(format_anchor(a) for a in anchors_list)
            print(f'        {{"kind": "continuous", "anchors": [{ans}]}},  '
                  f'# drift {drift:.2%}')
    print("    ],")
    return 0


def format_anchor(a) -> str:
    if isinstance(a, str):
        return f'"{a}"'
    return f'({a[0]:.2f}, {a[1]:.2f})'


if __name__ == "__main__":
    sys.exit(main())
