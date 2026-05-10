#!/usr/bin/env python3
"""Audit every letter's rendered-glyph skeleton and report the
quality issues that drive bad strokes.

For each of the 59 bundled letters this script:
  1. Rasterises the glyph at the same SIZE / PAD / font-metric
     scaling the generator uses.
  2. Skeletonises the mask via skimage's Zhang-Suen.
  3. Computes per-letter stats:
       * Connected components (more than one ⇒ disconnected pieces;
         the BFS in iOS can never bridge them, so anchor pairs
         placed in different components fall back to a straight
         line through whitespace).
       * Endpoints (degree-1 pixels) — many endpoints often indicate
         skeletonisation spurs at corners.
       * Branch points (degree ≥ 3) — junctions where BFS
         shortest-path can pick the wrong branch.
       * Spurs: degree-1 endpoints whose path back to the nearest
         degree-≥3 junction is shorter than `--spur-len` pixels.
         These are the 1–3 px dangling pieces that make corners
         look glitchy in the calibrator.
       * Bbox-vs-skeleton drift: how far each named anchor (TL, TC,
         TR, ML, C, MR, BL, BC, BR) sits from its nearest skeleton
         pixel. >5 % is the threshold above which "tapping the
         corner" feels like the anchor lands in the wrong place.

A global summary at the end groups letters by failure type and
ranks them by severity, so you know which letters to fix first
(via override-table edits, font-side glyph adjustments, or
generator tuning).

Usage:
    python3 scripts/skeleton_audit.py
    python3 scripts/skeleton_audit.py --letters M N W k --verbose
    python3 scripts/skeleton_audit.py --json /tmp/audit.json
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from collections import deque
from pathlib import Path

import numpy as np
import skimage.morphology as morph

sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_strokes_auto import (  # noqa: E402
    ALL_LETTERS,
    ANCHOR_POSITIONS,
    DEFAULT_FONT,
    build_adjacency,
    output_dir_for,
    rasterize,
)

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_BUNDLE = REPO_ROOT / "PrimaeNative/Resources/Letters"


def degrees(adj: dict) -> dict:
    return {p: len(ns) for p, ns in adj.items()}


def find_components(adj: dict) -> list[set]:
    seen: set = set()
    comps: list[set] = []
    for p in adj:
        if p in seen:
            continue
        comp: set = set()
        stack = [p]
        while stack:
            cur = stack.pop()
            if cur in seen:
                continue
            seen.add(cur)
            comp.add(cur)
            stack.extend(adj.get(cur, []))
        comps.append(comp)
    return comps


def spur_lengths(adj: dict, deg: dict, max_walk: int = 50) -> list[tuple[tuple, int]]:
    """Walk every degree-1 endpoint inward and report the path length
    until it hits a degree-≥3 junction or another endpoint. Lengths
    below the spur threshold flag glitchy corners."""
    out: list[tuple[tuple, int]] = []
    endpoints = [p for p, d in deg.items() if d == 1]
    for ep in endpoints:
        prev: tuple | None = None
        cur = ep
        steps = 0
        while steps < max_walk:
            ns = [n for n in adj[cur] if n != prev]
            if not ns:
                break
            nxt = ns[0]
            prev, cur = cur, nxt
            steps += 1
            if deg[cur] >= 3:
                break
        out.append((ep, steps))
    return out


def anchor_drifts(skel_pixels: list[tuple[int, int]],
                  bbox: tuple[int, int, int, int]) -> dict[str, float]:
    x_min, y_min, x_max, y_max = bbox
    w = max(1, x_max - x_min)
    h = max(1, y_max - y_min)
    diag = math.hypot(w, h)
    arr = np.array(skel_pixels, dtype=np.float64)
    out: dict[str, float] = {}
    for name, (ax, ay) in ANCHOR_POSITIONS.items():
        target_x = x_min + ax * w
        target_y = y_min + ay * h
        d = np.hypot(arr[:, 0] - target_x, arr[:, 1] - target_y).min()
        out[name] = float(d / diag)  # bbox-diagonal fraction
    return out


# Reversal-defect predicate. Angle-only thresholds (used before
# Phase 2.5) misclassify natural sharp corners — M/V/W apexes, u_l's
# bowl-to-vertical transition — as defects, because the geometric
# truth of the glyph involves 120-145° corners that the resampled
# checkpoint chain faithfully captures.
#
# The refined predicate flags a reversal as a defect only when the
# turn angle exceeds the threshold AND some pair of non-adjacent
# checkpoints within a ±window of the kink lies within `revisit_px`
# raster pixels of each other. The second condition is structural
# evidence that the BFS path revisited the same chain region — the
# textbook retrace pattern. Natural apex corners walk monotonically
# along the chain; only true retraces (e.g. r_l from the
# `continuous: TL→BL→TR` override walking the vertical stem twice)
# pair up in raster space.
def stroke_reversal_defects(strokes_data: dict,
                            bbox: tuple[int, int, int, int],
                            angle_thr_deg: float = 120.0,
                            window: int = 8,
                            revisit_px: float = 8.0) -> list[dict]:
    """Defects = sharp-turn checkpoints that also show chain-revisit
    in their ±window neighbourhood. Returns one entry per defect."""
    from itertools import combinations
    x_min, y_min, x_max, y_max = bbox
    bw = max(1, x_max - x_min)
    bh = max(1, y_max - y_min)
    angle_thr_rad = math.radians(angle_thr_deg)
    revisit_sq = revisit_px * revisit_px

    out: list[dict] = []
    for stroke in strokes_data.get("strokes", []):
        sidx = stroke.get("id", 0)
        cps = stroke.get("checkpoints") or []
        if len(cps) < 3:
            continue
        raster = [(x_min + c["x"] * bw, y_min + c["y"] * bh) for c in cps]
        for i in range(1, len(cps) - 1):
            ax, ay = raster[i - 1]
            bx, by = raster[i]
            cx, cy = raster[i + 1]
            v1x, v1y = bx - ax, by - ay
            v2x, v2y = cx - bx, cy - by
            n1 = math.hypot(v1x, v1y)
            n2 = math.hypot(v2x, v2y)
            if n1 < 1e-9 or n2 < 1e-9:
                continue
            dot = (v1x * v2x + v1y * v2y) / (n1 * n2)
            dot = max(-1.0, min(1.0, dot))
            ang = math.acos(dot)
            if ang <= angle_thr_rad:
                continue
            lo = max(0, i - window)
            hi = min(len(raster), i + window + 1)
            revisits = []
            for (ia, ib) in combinations(range(lo, hi), 2):
                if abs(ia - ib) < 3:
                    continue
                rax, ray = raster[ia]
                rbx, rby = raster[ib]
                if (rax - rbx) ** 2 + (ray - rby) ** 2 <= revisit_sq:
                    revisits.append((ia, ib))
            if revisits:
                out.append({
                    "stroke": sidx,
                    "cp": i,
                    "angle_deg": math.degrees(ang),
                    "revisits": revisits,
                })
    return out


def audit_letter(letter: str, font_path: Path, spur_len: int,
                 bundle_dir: Path | None = None) -> dict | None:
    try:
        mask = rasterize(letter, font_path)
    except Exception as e:
        return {"letter": letter, "error": str(e)}
    skel = morph.skeletonize(mask)
    rows, cols = np.where(mask)
    if rows.size == 0:
        return {"letter": letter, "error": "empty glyph"}
    bbox = (int(cols.min()), int(rows.min()),
            int(cols.max()), int(rows.max()))
    sk_xs, sk_ys = np.where(skel)
    sk_pixels = list(zip(sk_ys.tolist(), sk_xs.tolist()))  # (col, row)
    sk_pixels = list(zip(np.where(skel)[1].tolist(),
                         np.where(skel)[0].tolist()))
    if not sk_pixels:
        return {"letter": letter, "error": "empty skeleton"}
    adj = build_adjacency(set(sk_pixels))
    deg = degrees(adj)
    comps = find_components(adj)
    spurs = spur_lengths(adj, deg)
    short_spurs = [(p, n) for p, n in spurs if n < spur_len]
    drift = anchor_drifts(sk_pixels, bbox)

    reversal_defects: list[dict] = []
    if bundle_dir is not None:
        strokes_file = bundle_dir / output_dir_for(letter).name / "strokes.json"
        if strokes_file.exists():
            try:
                reversal_defects = stroke_reversal_defects(
                    json.loads(strokes_file.read_text()), bbox)
            except Exception as e:
                reversal_defects = [{"error": str(e)}]

    return {
        "letter": letter,
        "skel_size": len(sk_pixels),
        "components": len(comps),
        "comp_sizes": sorted([len(c) for c in comps], reverse=True),
        "endpoints": sum(1 for d in deg.values() if d == 1),
        "branch_points": sum(1 for d in deg.values() if d >= 3),
        "spurs_under_thr": len(short_spurs),
        "spurs": [{"len": n, "at": p} for p, n in sorted(short_spurs,
                                                          key=lambda x: x[1])],
        "max_anchor_drift_pct": max(drift.values()) * 100,
        "anchor_drifts_pct": {k: round(v * 100, 1) for k, v in drift.items()},
        "bbox": list(bbox),
        "reversal_defects": reversal_defects,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--letters", nargs="*", default=None,
                        help="Audit only these letters. Default: all 59.")
    parser.add_argument("--font", default=str(DEFAULT_FONT),
                        help="OTF / TTF font path.")
    parser.add_argument("--spur-len", type=int, default=4,
                        help="Spur-length threshold in skeleton pixels. "
                             "Default 4 — endpoints whose path to the "
                             "nearest junction is shorter are flagged.")
    parser.add_argument("--anchor-drift-pct", type=float, default=8.0,
                        help="Anchor-drift % above which a letter is "
                             "flagged for 'corner mismatch'. Default 8.")
    parser.add_argument("--bundle-dir", default=str(DEFAULT_BUNDLE),
                        help="Directory of strokes.json bundles to "
                             "scan for reversal defects. Default: "
                             "PrimaeNative/Resources/Letters.")
    parser.add_argument("--verbose", action="store_true",
                        help="Print per-letter detail in addition to the "
                             "global ranked summary.")
    parser.add_argument("--json", default=None,
                        help="Write the full audit as JSON to this path.")
    args = parser.parse_args()

    bundle_dir = Path(args.bundle_dir) if args.bundle_dir else None
    letters = args.letters or ALL_LETTERS
    results = []
    for L in letters:
        r = audit_letter(L, Path(args.font), args.spur_len, bundle_dir)
        if r is not None:
            results.append(r)

    if args.json:
        Path(args.json).write_text(json.dumps(results, indent=2))
        print(f"wrote {args.json}")

    if args.verbose:
        for r in results:
            if "error" in r:
                print(f"{r['letter']!r}: ERROR {r['error']}")
                continue
            print(f"{r['letter']!r}: skel={r['skel_size']} "
                  f"comps={r['components']} {r['comp_sizes']} "
                  f"endpts={r['endpoints']} branches={r['branch_points']} "
                  f"spurs<{args.spur_len}px={r['spurs_under_thr']} "
                  f"max_drift={r['max_anchor_drift_pct']:.1f}%")

    print()
    print("=== Letters with disconnected skeleton (BFS can't bridge) ===")
    for r in sorted(results,
                    key=lambda r: -r.get("components", 0)):
        if r.get("components", 1) > 1:
            print(f"  {r['letter']!r}: {r['components']} components "
                  f"(sizes {r['comp_sizes']})")

    print()
    print(f"=== Letters with skeletonisation spurs (<{args.spur_len} px) ===")
    spurry = [r for r in results if r.get("spurs_under_thr", 0) > 0]
    spurry.sort(key=lambda r: -r["spurs_under_thr"])
    for r in spurry[:15]:
        print(f"  {r['letter']!r}: {r['spurs_under_thr']} spurs "
              f"({r['endpoints']} endpoints, {r['branch_points']} branches)")

    print()
    print(f"=== Letters where named anchors drift > {args.anchor_drift_pct}% ===")
    drifty = [r for r in results
              if r.get("max_anchor_drift_pct", 0) > args.anchor_drift_pct]
    drifty.sort(key=lambda r: -r["max_anchor_drift_pct"])
    for r in drifty[:15]:
        worst = sorted(r["anchor_drifts_pct"].items(),
                       key=lambda kv: -kv[1])[:3]
        worst_str = ", ".join(f"{k}={v}%" for k, v in worst)
        print(f"  {r['letter']!r}: max {r['max_anchor_drift_pct']:.1f}% "
              f"(worst: {worst_str})")

    print()
    print("=== Letters with stroke-checkpoint reversal defects "
          "(>120° turn AND chain-revisit within ±8 cps / ≤8 raster px) ===")
    with_defects = [r for r in results if r.get("reversal_defects")]
    with_defects.sort(key=lambda r: r["letter"])
    for r in with_defects:
        for d in r["reversal_defects"]:
            if "error" in d:
                print(f"  {r['letter']!r}: ERROR {d['error']}")
                continue
            print(f"  {r['letter']!r}: stroke {d['stroke']} "
                  f"cp[{d['cp']}] = {d['angle_deg']:.1f}° "
                  f"({len(d['revisits'])} revisit pair(s))")
    if not with_defects:
        print("  (none — no chain-revisit retrace defects detected)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
