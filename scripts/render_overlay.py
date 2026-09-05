"""Render letter glyph + bundled stroke checkpoints overlay for visual QA.

For each letter in PrimaeNative/Resources/Letters/, draws:
  1. The Primae-Regular glyph in light gray
  2. The bundled strokes.json checkpoints as colored polylines (one
     color per stroke), with start = green dot, end = red dot
  3. Stroke index labels

Outputs a single contact-sheet PNG covering all letters so we can
eyeball misalignments at a glance.
"""
import json, math, pathlib
from PIL import Image, ImageDraw, ImageFont

ROOT = pathlib.Path(__file__).resolve().parent.parent
FONT_PATH = ROOT / "design-system/fonts/Primae-Regular.otf"
# The per-letter strokes.json live one level down, under the weight
# directory; iterating Letters/ itself rendered "Regular"/"Light" and the
# audio folders with no checkpoints at all (audit 2026-09-04).
LETTERS_DIR = ROOT / "PrimaeNative/Resources/Letters/Regular"

CELL = 360
PAD = 28
COLORS = ["#1f77b4", "#ff7f0e", "#2ca02c", "#d62728", "#9467bd", "#8c564b"]

def load_strokes(letter_dir):
    p = letter_dir / "strokes.json"
    if not p.exists():
        return None
    return json.loads(p.read_text())

def glyph_bbox(font, ch, render_size=180):
    img = Image.new("L", (render_size * 2, render_size * 2), 0)
    d = ImageDraw.Draw(img)
    d.text((render_size // 2, render_size // 2), ch, fill=255, font=font)
    bbox = img.getbbox()
    return img, bbox

def render_letter_cell(letter_name, letter_char, strokes_obj, font):
    cell = Image.new("RGB", (CELL, CELL), "white")
    draw = ImageDraw.Draw(cell)

    glyph_img, bbox = glyph_bbox(font, letter_char)
    if bbox is None:
        return cell
    gx0, gy0, gx1, gy1 = bbox
    gw, gh = gx1 - gx0, gy1 - gy0
    target = CELL - 2 * PAD
    scale = min(target / gw, target / gh)
    sw, sh = int(gw * scale), int(gh * scale)
    glyph_crop = glyph_img.crop(bbox).resize((sw, sh), Image.LANCZOS)
    glyph_rgba = Image.new("RGBA", glyph_crop.size, (0, 0, 0, 0))
    for x in range(sw):
        for y in range(sh):
            v = glyph_crop.getpixel((x, y))
            if v > 20:
                glyph_rgba.putpixel((x, y), (180, 180, 180, int(v * 0.7)))
    ox = (CELL - sw) // 2
    oy = (CELL - sh) // 2
    cell.paste(glyph_rgba, (ox, oy), glyph_rgba)

    if strokes_obj:
        for i, stroke in enumerate(strokes_obj.get("strokes", [])):
            cps = stroke.get("checkpoints", [])
            color = COLORS[i % len(COLORS)]
            pts = [(ox + cp["x"] * sw, oy + cp["y"] * sh) for cp in cps]
            if len(pts) >= 2:
                draw.line(pts, fill=color, width=3)
            for p in pts:
                draw.ellipse([p[0] - 3, p[1] - 3, p[0] + 3, p[1] + 3], fill=color)
            if pts:
                s = pts[0]; e = pts[-1]
                draw.ellipse([s[0] - 8, s[1] - 8, s[0] + 8, s[1] + 8],
                             outline="#0a0", width=3)
                draw.ellipse([e[0] - 8, e[1] - 8, e[0] + 8, e[1] + 8],
                             outline="#a00", width=3)
                mid = pts[len(pts) // 2]
                draw.text((mid[0] + 6, mid[1] - 12), str(i + 1), fill=color)

    label_font = ImageFont.load_default()
    n_strokes = len(strokes_obj.get("strokes", [])) if strokes_obj else 0
    draw.text((4, 4), f"{letter_name} ({n_strokes})", fill="black",
              font=label_font)
    draw.rectangle([0, 0, CELL - 1, CELL - 1], outline="#ddd")
    return cell

def main():
    font = ImageFont.truetype(str(FONT_PATH), 180)
    letter_dirs = sorted([d for d in LETTERS_DIR.iterdir() if d.is_dir()])
    cells = []
    for d in letter_dirs:
        strokes = load_strokes(d)
        ch = (strokes or {}).get("letter") or d.name
        cells.append((d.name, render_letter_cell(d.name, ch, strokes, font)))

    cols = 6
    rows = math.ceil(len(cells) / cols)
    sheet = Image.new("RGB", (cols * CELL, rows * CELL), "white")
    for idx, (_, c) in enumerate(cells):
        r, cc = divmod(idx, cols)
        sheet.paste(c, (cc * CELL, r * CELL))
    out_dir = ROOT / "tmp_overlays"
    out_dir.mkdir(exist_ok=True)
    sheet.save(out_dir / "all_letters.png", optimize=True)
    # Also save per-letter close-ups
    for name, c in cells:
        c.save(out_dir / f"{name}.png", optimize=True)
    print(f"wrote {out_dir}/all_letters.png + {len(cells)} per-letter PNGs "
          f"({cols}x{rows} sheet)")

if __name__ == "__main__":
    main()
