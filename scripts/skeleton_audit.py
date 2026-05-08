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
    rasterize,
)


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


def audit_letter(letter: str, font_path: Path, spur_len: int) -> dict | None:
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
    parser.add_argument("--verbose", action="store_true",
                        help="Print per-letter detail in addition to the "
                             "global ranked summary.")
    parser.add_argument("--json", default=None,
                        help="Write the full audit as JSON to this path.")
    args = parser.parse_args()

    letters = args.letters or ALL_LETTERS
    results = []
    for L in letters:
        r = audit_letter(L, Path(args.font), args.spur_len)
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

    return 0


if __name__ == "__main__":
    sys.exit(main())
