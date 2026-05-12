"""Polyline-based stroke generator for Primae.

Each letter is authored as one or more polylines — short lists of
bbox-relative (x, y) tuples. Every polyline becomes one stroke in
strokes.json; consecutive tuples within a polyline are connected via
Bresenham line rasterisation. The dense pixel sequence is then
resampled to a fixed checkpoint count.

Why we abandoned the medial-axis approach: skimage.skeletonize is a
faithful geometric reduction of the rendered glyph ink, but the
pedagogical decomposition of a letter into pen-strokes doesn't follow
medial-axis topology. Y-junctions appear at outer corners (N, M, W),
stems bend toward bowl-stem merge zones (b, p, d), and apex stubs
litter sharp corners. Months of patching (split, stitch, extend,
straighten, thinning) accumulated complexity without converging on
clean output. Hand-authored polylines bypass the geometry mismatch
entirely: the author encodes intended stroke order, direction, and
shape directly.

Pipeline per letter:

  1. Rasterise the glyph via `rasterize`; compute the bbox from ink.
  2. Convert every polyline tuple to a raster pixel via the bbox and
     verify each lies inside the ink mask. If any tuple falls in
     whitespace the bake aborts, reporting which letter / polyline /
     tuple is bad so the author can correct the offending coord.
  3. Walk Bresenham between consecutive tuples to a dense pixel chain.
  4. Resample each chain uniformly to `CHECKPOINT_COUNT` points.
  5. Skeleton field = deduplicated union of all polyline pixels.
  6. skeletonAdj = 8-connected adjacency over those pixels (trivial,
     since they come from Bresenham-connected polylines).
  7. Emit strokes.json — schema unchanged from the medial-axis era.

Usage:
    pip install Pillow numpy
    python scripts/generate_strokes_auto.py            # all authored
    python scripts/generate_strokes_auto.py N V M      # subset
    python scripts/generate_strokes_auto.py --debug N  # save PNG
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

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

# APFS / HFS+ folders are case-insensitive — uppercase and lowercase
# letter directories collide without a suffix.
LOWERCASE_SUFFIX = "_l"


# -----------------------------------------------------------------------------
# Hand-authored stroke decompositions
# -----------------------------------------------------------------------------
#
# Data structure: LETTERS[letter] is a list of polylines; each polyline is a
# list of (rel_x, rel_y) tuples in glyph-bbox-relative [0, 1] coordinates.
# One polyline = one pen-stroke a child draws.
#
# Authoring philosophy: each polyline traces a single uninterrupted pen-down
# motion in the order taught by the Wiener Bildungsserver "Arbeitsblätter
# Druckschrift" worksheets. Sharp corners between strokes (e.g. M's apexes,
# W's valleys) live as adjacent tuples within one continuous polyline.
# Genuinely separate strokes (b's stem vs. bowl, A's verticals vs. crossbar)
# become separate entries in the list.
#
# Font portability: tuple values are calibrated for Primae-Regular.otf at
# SIZE=1024 / PAD=0.10. Other fonts whose stem widths or proportions differ
# may require re-eyeballing the tuples — the bake aborts with a per-tuple
# report if any value falls outside the new font's ink.

LETTERS: dict[str, list[list[tuple[float, float]]]] = {
    "N": [
        # Three strokes meeting at corners. Both verticals go top-to-
        # bottom; the diagonal runs TL to BR. Children draw all three
        # separately, pen-up between each.
        [(0.14, 0.00), (0.05, 1.00)],
        [(0.14, 0.00), (0.86, 1.00)],
        [(0.95, 0.00), (0.86, 1.00)],
    ],
    "V": [
        # Single-stroke zigzag: TL diagonal down to apex, back up to TR.
        # Waypoints sit on the diagonal-stripe centerlines (not bbox
        # corners) so straight chords stay inside the ink.
        [(0.076, 0.000), (0.42, 0.95), (0.93, 0.000)],
    ],
    "M": [
        # Single-stroke zigzag: BL up to TL, diagonal down to BC valley,
        # up to TR, down to BR. Every waypoint on the vertical / diagonal
        # stripe centerlines — TL at 0.196 not 0.10 because the Primae
        # M's TL serif insets the ink start.
        [(0.044, 1.000), (0.196, 0.000), (0.500, 0.947),
         (0.911, 0.000), (0.948, 1.000)],
    ],
    "W": [
        # Single-stroke zigzag: TL down to BL, up to TC apex, down to BR,
        # up to TR. Coordinates nudged a few thousandths off the bbox
        # edges so the corner waypoints land on ink.
        [(0.05, 0.00), (0.244, 0.994), (0.50, 0.10), (0.719, 0.977), (0.949, 0.002)],
    ],
    "b": [
        # Stem: 3 waypoints to track the Primae font's mildly-slanted
        # stem — the column drifts left by ~10% rel-x between top and
        # midline, then back right toward the baseline. A 2-point
        # straight chord misses the ink in y=0.73-0.84.
        [(0.195, 0.000), (0.130, 0.500), (0.180, 0.950)],
        # Bowl: 9-waypoint open arc. Stem and bowl share ink only in two
        # merge zones (y≈0.62 upper, y≈0.94 lower); a chord from the
        # stem mid-height to the bowl crest cuts whitespace, so the arc
        # enters / exits via the merge zones and traces bowl-left-wall,
        # top-peak, bowl-right-wall, and bottom-curve in between.
        [(0.180, 0.620),
         (0.270, 0.600),
         (0.430, 0.500),
         (0.700, 0.400),
         (0.864, 0.500),
         (0.910, 0.650),
         (0.830, 0.800),
         (0.676, 0.900),
         (0.397, 0.940)],
    ],
}

ALL_LETTERS = tuple(LETTERS.keys())


# -----------------------------------------------------------------------------
# Rasterisation
# -----------------------------------------------------------------------------

def rasterize(letter: str, font_path: Path,
              features: list[str] | None = None) -> np.ndarray:
    """Render `letter` to a SIZE×SIZE binary mask using uniform
    font-metric scaling (em-square = 80 % of canvas height, baseline at
    pad + ascent). Mirrors `PrimaeLetterRenderer.glyphPath`. `features`
    is an optional list of OpenType feature tags."""
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


def bbox_from_mask(mask: np.ndarray) -> tuple[int, int, int, int]:
    """Return the ink mask's bbox `(x_min, y_min, x_max, y_max)` in
    raster coords. Raises on an empty mask."""
    rows, cols = np.where(mask)
    if rows.size == 0:
        raise ValueError("Empty ink mask")
    return (int(cols.min()), int(rows.min()),
            int(cols.max()), int(rows.max()))


# -----------------------------------------------------------------------------
# Coordinate conversion
# -----------------------------------------------------------------------------

def rel_to_pixel(rel: tuple[float, float],
                 bbox: tuple[int, int, int, int]) -> tuple[int, int]:
    """Map a bbox-relative `(rx, ry)` tuple to a raster `(col, row)`
    pixel via the ink bbox."""
    x_min, y_min, x_max, y_max = bbox
    bw = max(1, x_max - x_min)
    bh = max(1, y_max - y_min)
    col = int(round(x_min + rel[0] * bw))
    row = int(round(y_min + rel[1] * bh))
    return col, row


def pixel_to_rel(p: tuple[int, int],
                 bbox: tuple[int, int, int, int]) -> tuple[float, float]:
    """Inverse of `rel_to_pixel`: raster `(col, row)` → bbox-relative."""
    x_min, y_min, x_max, y_max = bbox
    bw = max(1, x_max - x_min)
    bh = max(1, y_max - y_min)
    return ((p[0] - x_min) / bw, (p[1] - y_min) / bh)


# -----------------------------------------------------------------------------
# Polyline → dense pixel chain
# -----------------------------------------------------------------------------

def bresenham(p0: tuple[int, int],
              p1: tuple[int, int]) -> list[tuple[int, int]]:
    """Integer Bresenham line from `p0` to `p1` inclusive. Consecutive
    output pixels are 4- or 8-adjacent."""
    x0, y0 = p0
    x1, y1 = p1
    dx = abs(x1 - x0)
    dy = abs(y1 - y0)
    sx = 1 if x0 < x1 else -1
    sy = 1 if y0 < y1 else -1
    err = dx - dy
    x, y = x0, y0
    out: list[tuple[int, int]] = []
    while True:
        out.append((x, y))
        if (x, y) == (x1, y1):
            break
        e2 = 2 * err
        if e2 > -dy:
            err -= dy
            x += sx
        if e2 < dx:
            err += dx
            y += sy
    return out


def polyline_to_pixels(polyline: list[tuple[float, float]],
                       bbox: tuple[int, int, int, int]
                       ) -> list[tuple[int, int]]:
    """Convert a relative-coord polyline to an ordered, deduplicated
    pixel chain by Bresenham-connecting consecutive tuples. Joint
    pixels shared between adjacent segments appear once."""
    if not polyline:
        return []
    if len(polyline) == 1:
        return [rel_to_pixel(polyline[0], bbox)]
    pixels: list[tuple[int, int]] = []
    for i in range(len(polyline) - 1):
        seg = bresenham(rel_to_pixel(polyline[i], bbox),
                        rel_to_pixel(polyline[i + 1], bbox))
        if i > 0 and pixels and seg and seg[0] == pixels[-1]:
            seg = seg[1:]
        pixels.extend(seg)
    return pixels


# -----------------------------------------------------------------------------
# Validation + resampling
# -----------------------------------------------------------------------------

def validate_polylines_in_ink(letter: str,
                              polylines: list[list[tuple[float, float]]],
                              mask: np.ndarray,
                              bbox: tuple[int, int, int, int]) -> list[str]:
    """Validate that every authored polyline stays inside the ink mask.
    Runs two passes: per-tuple (each waypoint's raster pixel must be on
    ink) and per-segment (the Bresenham line between consecutive
    waypoints must be entirely on ink). The dense check catches
    polylines whose waypoints are all in ink but whose straight chords
    cut through interior whitespace — common on closed bowls. Returns
    one error string per offender; empty list = clean."""
    h, w = mask.shape
    errors: list[str] = []
    for pi, poly in enumerate(polylines):
        for ti, t in enumerate(poly):
            col, row = rel_to_pixel(t, bbox)
            if not (0 <= row < h and 0 <= col < w):
                errors.append(f"{letter} polyline {pi} tuple {ti} {t} "
                              f"→ pixel ({col}, {row}) outside canvas")
                continue
            if not bool(mask[row, col]):
                errors.append(f"{letter} polyline {pi} tuple {ti} {t} "
                              f"→ pixel ({col}, {row}) outside ink")
        for si in range(len(poly) - 1):
            a = rel_to_pixel(poly[si], bbox)
            b = rel_to_pixel(poly[si + 1], bbox)
            line = bresenham(a, b)
            off: list[tuple[int, int]] = []
            for col, row in line:
                if not (0 <= row < h and 0 <= col < w):
                    off.append((col, row))
                    continue
                if not bool(mask[row, col]):
                    off.append((col, row))
            if off:
                first_rel = pixel_to_rel(off[0], bbox)
                last_rel = pixel_to_rel(off[-1], bbox)
                errors.append(
                    f"{letter} polyline {pi} segment {si}→{si + 1}: "
                    f"{len(off)} of {len(line)} pixels outside ink at rel "
                    f"({first_rel[0]:.3f}, {first_rel[1]:.3f})..."
                    f"({last_rel[0]:.3f}, {last_rel[1]:.3f})")
    return errors


def resample_uniform(pixels: list[tuple[int, int]],
                     n: int) -> list[tuple[int, int]]:
    """Resample a dense pixel chain to exactly `n` points by linear
    interpolation along arc length. Output is integer-rounded raster
    pixels (col, row)."""
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
    """Union all stroke pixel chains into a deduplicated skeleton in
    bbox-relative coords and return parallel 8-connected adjacency
    lists. Output matches the strokes.json `skeleton` / `skeletonAdj`
    fields the iOS calibrator reads."""
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
    """Resolve the per-letter resource directory under
    `PrimaeNative/Resources/Letters/`, honouring the lowercase suffix
    convention."""
    if letter.isupper() or not letter.isalpha():
        return OUTPUT_BASE / letter
    return OUTPUT_BASE / f"{letter}{LOWERCASE_SUFFIX}"


def bake_letter(letter: str, font_path: Path) -> dict:
    """End-to-end bake for one letter. Rasterises the glyph, validates
    every authored tuple is inside the ink, rasterises each polyline
    into a dense pixel chain, resamples each to `CHECKPOINT_COUNT`, and
    packages everything into the strokes.json payload. Raises
    `ValueError` listing every offending tuple if any falls off-ink."""
    polylines = LETTERS.get(letter)
    if not polylines:
        raise KeyError(f"No polylines authored for {letter!r}")
    mask = rasterize(letter, font_path)
    bbox = bbox_from_mask(mask)
    errors = validate_polylines_in_ink(letter, polylines, mask, bbox)
    if errors:
        raise ValueError("Out-of-ink polyline tuples:\n  "
                         + "\n  ".join(errors))

    stroke_pixel_chains: list[list[tuple[int, int]]] = []
    json_strokes: list[dict] = []
    for i, poly in enumerate(polylines, start=1):
        dense = polyline_to_pixels(poly, bbox)
        resampled = resample_uniform(dense, CHECKPOINT_COUNT)
        stroke_pixel_chains.append(dense)
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

    return {
        "letter": letter,
        "checkpointRadius": DEFAULT_RADIUS,
        "strokes": json_strokes,
        "skeleton": skeleton_pts,
        "skeletonAdj": skeleton_adj,
    }


# -----------------------------------------------------------------------------
# Debug overlay
# -----------------------------------------------------------------------------

def save_overlay(letter: str, font_path: Path, out_path: Path) -> None:
    """Save a polyline-over-ink PNG for visual review. Author-placed
    tuples are drawn as labelled dots; the Bresenham-rasterised path is
    drawn as a coloured line."""
    polylines = LETTERS.get(letter, [])
    mask = rasterize(letter, font_path)
    bbox = bbox_from_mask(mask)
    img = Image.fromarray(np.where(mask, 0, 230).astype(np.uint8)).convert("RGB")
    draw = ImageDraw.Draw(img)
    palette = [
        (220, 30, 30), (30, 130, 30), (30, 60, 200), (220, 130, 30),
        (180, 30, 180),
    ]
    for pi, poly in enumerate(polylines):
        color = palette[pi % len(palette)]
        pixels = polyline_to_pixels(poly, bbox)
        if len(pixels) >= 2:
            draw.line(pixels, fill=color, width=4)
        for ti, t in enumerate(poly):
            col, row = rel_to_pixel(t, bbox)
            r = 10
            draw.ellipse((col - r, row - r, col + r, row + r),
                         fill=color, outline=(0, 0, 0))
            draw.text((col + 12, row - 14), f"{pi}.{ti}", fill=(0, 0, 0))
    img.save(str(out_path))


# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------

def write_meta(out_base: Path, font_path: Path) -> None:
    """Write `_meta.json` next to the per-letter folders so consumers
    can detect a font swap and trigger a re-bake."""
    font_hash = hashlib.sha256(font_path.read_bytes()).hexdigest()
    (out_base / "_meta.json").write_text(json.dumps({
        "fontPath": str(font_path),
        "fontSha256": font_hash,
        "generator": "generate_strokes_auto.py",
    }, indent=2))
    print(f"  _meta.json: font sha256 {font_hash[:12]}…")


def main() -> int:
    """CLI entry point. Bakes one or more letters; with `--debug`,
    saves `/tmp/polyline_<L>.png` overlays."""
    parser = argparse.ArgumentParser(
        description="Bake hand-authored polyline strokes.json files.")
    parser.add_argument("letters", nargs="*",
                        help="Letters to bake. Default: every entry in LETTERS.")
    parser.add_argument("--font", default=str(DEFAULT_FONT),
                        help="OTF / TTF font path. Default: Primae-Regular.")
    parser.add_argument("--out", default=None,
                        help="Output base dir. Default: PrimaeNative/Resources/Letters.")
    parser.add_argument("--no-overwrite", action="store_true",
                        help="Skip letters whose strokes.json already exists.")
    parser.add_argument("--debug", action="store_true",
                        help="Save /tmp/polyline_<L>.png overlays.")
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
            data = bake_letter(letter, font_path)
        except Exception as e:
            print(f"  {letter}: FAIL — {e}")
            fail += 1
            continue
        out_dir.mkdir(parents=True, exist_ok=True)
        out_file.write_text(json.dumps(data, indent=2, ensure_ascii=False))
        n_pts = sum(len(s["checkpoints"]) for s in data["strokes"])
        print(f"  {letter}: ✓ {len(data['strokes'])} strokes, {n_pts} checkpoints")
        if args.debug:
            save_overlay(letter, font_path, Path(f"/tmp/polyline_{letter}.png"))
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
