#!/usr/bin/env python3
"""render_sweep_grid.py — visual-sweep-workflow renderer.

Bakes a set of LETTERS-spec variants for one or more letters, runs the
three numeric gates, and composes a contact-sheet PNG (rows = letters,
cols = variants). Use it when answering any geometric question with
finite candidate constructions or a single tunable parameter — see
`docs/APP_DOCUMENTATION.md` §13.7.

Variant input file (JSON):

    {
      "letters": ["v", "w"],
      "variants": [
        {
          "name": "v3 fillet tb=24",
          "specs": {
            "v": [{"kind": "line", "anchors": ["TL", "BC", "TR"],
                    "arms": ["straight_line", "straight_line"],
                    "joints": [{"strategy": "fillet_at_intersection",
                                 "trim_back": 24.0}]}],
            "w": [{"kind": "line", "anchors": ["TL", "BL", "TC", "BR", "TR"],
                    "arms": ["straight_line"] * 4,
                    "joints": [{"strategy": "fillet_at_intersection",
                                 "trim_back": 40.0}] * 3}]
          }
        },
        {
          "name": "tb=30 uniform",
          "specs": { ... }
        }
      ]
    }

Each variant's "specs" map provides the LETTERS[letter] override for
that variant — every letter in the top-level "letters" array must have
a spec in every variant.

Usage:
    python3 scripts/render_sweep_grid.py <variants.json> [--out PATH]

Output: a single PNG with rows = letters, cols = variants. Per-panel
overlay shows gate counts (ov/rv/maxturn) + per-joint metrics (V_sd,
P_end dt, apex_sd) so visual judgment is anchored to the numbers.
"""
from __future__ import annotations

import argparse
import importlib
import json
import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "scripts"))
import generate_strokes_auto as g  # noqa: E402

PALETTE = [(229, 62, 62), (62, 180, 90), (62, 140, 229),
           (236, 158, 56), (155, 89, 182)]

# Gate-2 reversal cutoff. `cos < this` between consecutive tangent
# vectors counts as a reversal — corresponds to a ~96° turn. Tighter
# (closer to 0) flags more turns as reversals; looser (more negative)
# tolerates sharper kinks. The b-bowl, M peaks, V/W valleys all sit
# below this threshold by design and are excluded via skip_indices.
REVERSAL_COSINE_CUTOFF = -0.1


def signed_dist(mask: np.ndarray, x: float, y: float, max_s: int = 200) -> float:
    """Signed distance from (x,y) to the mask boundary. + inside, - outside."""
    H, W = mask.shape
    ix, iy = int(round(x)), int(round(y))
    inside = (0 <= iy < H and 0 <= ix < W and bool(mask[iy, ix]))
    sign = +1 if inside else -1
    target = not inside
    for step in range(1, max_s):
        for dy in range(-step, step + 1):
            for dx in (-step, step):
                xx, yy = ix + dx, iy + dy
                if 0 <= yy < H and 0 <= xx < W and bool(mask[yy, xx]) == target:
                    return sign * math.hypot(xx - x, yy - y)
        for dx in range(-step + 1, step):
            for dy in (-step, step):
                xx, yy = ix + dx, iy + dy
                if 0 <= yy < H and 0 <= xx < W and bool(mask[yy, xx]) == target:
                    return sign * math.hypot(xx - x, yy - y)
    return sign * float(max_s)


def gates(chain: list, mask: np.ndarray, skip: set) -> tuple[int, int, float]:
    """Return (overshoot, reversal, max-turn-deg)."""
    H, W = mask.shape
    ov = sum(1 for i, (x, y) in enumerate(chain)
             if i not in skip and not (0 <= y < H and 0 <= x < W and mask[y, x]))
    rv = 0
    g3 = 0.0
    for i in range(1, len(chain) - 1):
        if i in skip:
            continue
        a, b, c = chain[i - 1], chain[i], chain[i + 1]
        v1 = (b[0] - a[0], b[1] - a[1])
        v2 = (c[0] - b[0], c[1] - b[1])
        L1, L2 = math.hypot(*v1), math.hypot(*v2)
        if L1 < 1e-6 or L2 < 1e-6:
            continue
        d = (v1[0] * v2[0] + v1[1] * v2[1]) / (L1 * L2)
        if d < REVERSAL_COSINE_CUTOFF:
            rv += 1
        d = max(-1.0, min(1.0, d))
        g3 = max(g3, math.degrees(math.acos(d)))
    return ov, rv, g3


def bake_variant(letter: str, spec: list) -> dict:
    """Reload bake module, install spec, bake. Returns debug dict."""
    importlib.reload(g)
    g.LETTERS[letter] = spec
    _, dbg = g.bake_letter(letter, g.DEFAULT_FONT)
    return dbg


def joint_metrics(j: dict | None, mask: np.ndarray, dt: np.ndarray) -> dict | None:
    if j is None:
        return None
    V = j.get("V")
    P_end = j.get("P_end") or j.get("P_end_trim")
    P_start = j.get("P_start") or j.get("P_start_trim")
    apex = j.get("apex", V)
    H, W = mask.shape

    def _dt(p):
        if p is None:
            return 0.0
        r, c = int(round(p[1])), int(round(p[0]))
        if 0 <= r < H and 0 <= c < W:
            return float(dt[r, c])
        return 0.0

    return {
        "V_sd": signed_dist(mask, V[0], V[1]) if V else None,
        "pe_dt": _dt(P_end),
        "ps_dt": _dt(P_start),
        "apex_sd": signed_dist(mask, apex[0], apex[1]) if apex else None,
    }


def render_panel(dbg: dict, label: str, lines: list[str], pad_top: int = 200) -> Image.Image:
    mask = dbg["mask"]
    chains = dbg["stroke_pixel_chains"]
    rs, cs = np.where(mask)
    if len(rs) == 0:
        return Image.new("RGB", (300, 200), "white")
    H, W = mask.shape
    r0 = max(0, rs.min() - 20)
    r1 = min(H, rs.max() + 20)
    c0 = max(0, cs.min() - 20)
    c1 = min(W, cs.max() + 20)
    sub = mask[r0:r1, c0:c1]
    sH, sW = sub.shape
    img = Image.new("RGB", (max(sW, 500), sH + pad_top), (250, 250, 250))
    px = img.load()
    for r in range(sH):
        for c in range(sW):
            if sub[r, c]:
                px[c, r + pad_top] = (45, 55, 72)
    draw = ImageDraw.Draw(img)
    for ki, ch in enumerate(chains):
        color = PALETTE[ki % len(PALETTE)]
        pts = [(c - c0, r - r0 + pad_top) for c, r in ch]
        if len(pts) >= 2:
            draw.line(pts, fill=color, width=3)
    try:
        font_b = ImageFont.truetype(
            "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 14)
        font = ImageFont.truetype(
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 10)
    except OSError:
        font_b = ImageFont.load_default()
        font = font_b
    draw.text((6, 4), label, fill="black", font=font_b)
    for i, ln in enumerate(lines):
        draw.text((6, 22 + i * 12), ln, fill="#333", font=font)
    return img


def diagnose(letter: str, variant_name: str, spec: list) -> tuple[dict, list[str]]:
    """Bake one variant of one letter, return (debug, annotation-lines)."""
    try:
        dbg = bake_variant(letter, spec)
    except Exception as e:
        empty = Image.new("RGB", (300, 200), "#eee")
        return ({"mask": np.zeros((10, 10), dtype=bool),
                 "stroke_pixel_chains": [], "dt": np.zeros((10, 10))},
                [f"SKIPPED: {type(e).__name__}", str(e)[:60]])

    chain = dbg["stroke_pixel_chains"][0]
    skip = (dbg["sharp_skip_indices_per_stroke"][0]
            if dbg.get("sharp_skip_indices_per_stroke") else set())
    ov, rv, g3 = gates(chain, dbg["mask"], skip)
    lines = [f"gates ov={ov} rv={rv} maxturn={g3:.0f}° skip={len(skip)}"]
    joints = (dbg.get("joint_arcs_per_stroke", [[]])[0] or [])
    for ji, j in enumerate(joints):
        m = joint_metrics(j, dbg["mask"], dbg["dt"])
        if m is None:
            lines.append(f"  j{ji}: None")
        else:
            lines.append(
                f"  j{ji}: V_sd={m['V_sd']:.1f} "
                f"P_e/s dt={m['pe_dt']:.1f}/{m['ps_dt']:.1f} "
                f"apex_sd={m['apex_sd']:.1f}"
            )
    return dbg, lines


def compose_grid(panels: list[list[Image.Image]], pad: int = 12) -> Image.Image:
    """panels[row][col] — letter-major. Composes into a single contact sheet."""
    if not panels:
        return Image.new("RGB", (200, 100), "white")
    row_heights = [max(p.height for p in row) for row in panels]
    col_widths: list[int] = []
    n_cols = max(len(row) for row in panels)
    for ci in range(n_cols):
        col_widths.append(max(
            (panels[ri][ci].width if ci < len(panels[ri]) else 0)
            for ri in range(len(panels))
        ))
    total_w = sum(col_widths) + (n_cols + 1) * pad
    total_h = sum(row_heights) + (len(panels) + 1) * pad
    grid = Image.new("RGB", (total_w, total_h), "white")
    y = pad
    for ri, row in enumerate(panels):
        x = pad
        for ci, p in enumerate(row):
            grid.paste(p, (x, y))
            x += col_widths[ci] + pad
        y += row_heights[ri] + pad
    return grid


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                      formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("variants_file", type=Path,
                        help="JSON spec file. See module docstring for shape.")
    parser.add_argument("--out", type=Path, default=Path("/tmp/sweep_grid.png"),
                        help="Output PNG path (default: /tmp/sweep_grid.png).")
    args = parser.parse_args()

    spec_doc = json.loads(args.variants_file.read_text())
    letters: list[str] = spec_doc["letters"]
    variants: list[dict] = spec_doc["variants"]
    if not letters or not variants:
        print("variants file must declare both 'letters' and 'variants'",
              file=sys.stderr)
        return 1

    panels: list[list[Image.Image]] = []
    for letter in letters:
        row: list[Image.Image] = []
        for v in variants:
            name = v.get("name", "?")
            spec = v["specs"].get(letter)
            if spec is None:
                row.append(Image.new("RGB", (300, 200), "#eed"))
                continue
            label = f"{letter} — {name}"
            print(f"  baking {label!r}")
            dbg, lines = diagnose(letter, name, spec)
            row.append(render_panel(dbg, label, lines))
        panels.append(row)

    grid = compose_grid(panels)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    grid.save(args.out, optimize=True)
    print(f"\nWrote {args.out}  size={grid.size}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
