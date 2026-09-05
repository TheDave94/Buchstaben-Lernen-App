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

# Supersampling factor for panel rendering. The glyph mask (binary)
# and the polylines drawn on top look pixelated at 1:1 — staircased
# mask edges, blocky PIL line rasterisation. Rendering everything at
# SUPERSAMPLE × the final panel size and downsampling with Lanczos
# produces antialiased edges (the kernel footprint crosses the
# staircase boundaries during downsample, producing soft gradients).
# 4× is the sweet spot — 2× still shows staircases, 8× is wasted
# (Lanczos saturates around 4×).
SUPERSAMPLE = 4


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
    # Every shipped letter is a static artifact; the sweep is exactly the
    # tool that re-bakes one on purpose (audit 2026-09-04).
    _, dbg = g.bake_letter(letter, g.DEFAULT_FONT, _suppress_static_guard=True)
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
    final_w = max(sW, 500)
    final_h = sH + pad_top
    # Internal supersampled canvas — Lanczos downsample at the end
    # blends staircased mask edges + line aliasing into soft gradients.
    S = SUPERSAMPLE
    img = Image.new("RGB", (final_w * S, final_h * S), (250, 250, 250))
    # Render the glyph mask as a SUPERSAMPLE-zoomed binary at native
    # ink resolution: each True pixel becomes a SxS block. Done in
    # numpy then pasted (faster than per-pixel PIL writes).
    glyph_arr = np.zeros((sH * S, sW * S, 3), dtype=np.uint8)
    glyph_arr[:] = (250, 250, 250)
    ink = np.repeat(np.repeat(sub, S, axis=0), S, axis=1)
    glyph_arr[ink] = (45, 55, 72)
    glyph_img = Image.fromarray(glyph_arr, mode="RGB")
    img.paste(glyph_img, (0, pad_top * S))
    draw = ImageDraw.Draw(img)
    for ki, ch in enumerate(chains):
        color = PALETTE[ki % len(PALETTE)]
        pts = [((c - c0) * S, (r - r0 + pad_top) * S) for c, r in ch]
        if len(pts) >= 2:
            draw.line(pts, fill=color, width=3 * S)
        # Single-point strokes (dots) render as filled disks.
        if len(pts) == 1:
            x, y = pts[0]
            r_disk = 4 * S
            draw.ellipse((x - r_disk, y - r_disk, x + r_disk, y + r_disk),
                          fill=color, outline=(0, 0, 0), width=S)
    try:
        font_b = ImageFont.truetype(
            "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 14 * S)
        font = ImageFont.truetype(
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 10 * S)
    except OSError:
        font_b = ImageFont.load_default()
        font = font_b
    draw.text((6 * S, 4 * S), label, fill="black", font=font_b)
    for i, ln in enumerate(lines):
        draw.text((6 * S, (22 + i * 12) * S), ln, fill="#333", font=font)
    # Downsample to final panel size with Lanczos — this is where
    # the anti-aliasing happens.
    return img.resize((final_w, final_h), Image.LANCZOS)


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


def diagnose_raw(letter: str, polyline_pixels: list[list[float]],
                  extra_lines: list[str] | None = None,
                  ) -> tuple[dict, list[str]]:
    """Render-only variant: rasterise the letter glyph from the bundled
    font, skip the bake entirely, treat `polyline_pixels` as the stroke
    chain. Used when a variant's polyline is computed outside the
    LETTERS-spec path (e.g. when prototyping a new primitive before it
    lands in the registry, or comparing hand-constructed alternatives).
    `polyline_pixels` is a list of [x, y] in pixel coords on the
    bundled-font raster."""
    g_local = importlib.import_module("generate_strokes_auto")
    importlib.reload(g_local)
    mask = g_local.rasterize(letter, g_local.DEFAULT_FONT)
    from scipy.ndimage import distance_transform_edt
    dt = distance_transform_edt(mask)
    chain = [(int(round(p[0])), int(round(p[1]))) for p in polyline_pixels]
    ov, rv, g3 = gates(chain, mask, set())
    lines = [f"gates ov={ov} rv={rv} maxturn={g3:.0f}° (raw)"]
    if extra_lines:
        lines.extend(extra_lines)
    return ({"mask": mask, "stroke_pixel_chains": [chain], "dt": dt}, lines)


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
            label = f"{letter} — {name}"
            # A variant carries EITHER "specs" (full LETTERS spec dict
            # consumed via bake_letter) OR "raw_polylines" (pre-computed
            # pixel-coord chains rendered directly on the glyph raster,
            # bypassing the bake — used when prototyping curve
            # constructions before a primitive lands in the registry).
            if "raw_polylines" in v:
                polys = v["raw_polylines"].get(letter)
                if polys is None:
                    row.append(Image.new("RGB", (300, 200), "#eed"))
                    continue
                print(f"  rendering {label!r} (raw)")
                # First polyline drives the gate diagnostics; extras
                # render in subsequent palette colours (matches how
                # multi-stroke bakes look).
                extra = v.get("notes", {}).get(letter, [])
                dbg, lines = diagnose_raw(letter, polys[0], extra_lines=extra)
                # Pile additional polylines onto the same chain list so
                # render_panel draws them in palette order.
                for p in polys[1:]:
                    dbg["stroke_pixel_chains"].append(
                        [(int(round(pt[0])), int(round(pt[1]))) for pt in p])
                row.append(render_panel(dbg, label, lines))
                continue
            spec = (v.get("specs") or {}).get(letter)
            if spec is None:
                row.append(Image.new("RGB", (300, 200), "#eed"))
                continue
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
