#!/usr/bin/env python3
"""
Generate Primae app icons from the onboarding trace-demo design.

The icon shows the three blue strokes that trace out an "A" — exactly the
visual a child sees in step 2 of onboarding, just without the ghost glyph
underneath (the strokes are recognisable on their own, and a ghost typographic
"A" added clutter / visual mismatch with the geometric stroke "A").

Produces three 1024x1024 PNGs:
  - AppIcon.png         light-mode primary (warm honey background)
  - AppIcon-dark.png    dark-mode variant (deep navy background)
  - AppIcon-tinted.png  monochrome grayscale for iOS 18 tinted icons
"""
from PIL import Image, ImageDraw
import os
from pathlib import Path

SIZE = 1024
REPO_ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = str(REPO_ROOT / "Primae/Primae/Assets.xcassets/AppIcon.appiconset")

# Onboarding stroke geometry (normalized 0-1) ported verbatim from
# OnboardingView.swift's AnimatedStrokePath.
STROKES = [
    ((0.50, 0.00), (0.05, 1.00)),   # left leg of A
    ((0.50, 0.00), (0.95, 1.00)),   # right leg of A
    ((0.22, 0.62), (0.78, 0.62)),   # crossbar
]

# How much of the icon area the stroke pattern fills. 0.62 leaves a comfortable
# margin so the strokes never kiss the icon mask iOS applies.
INNER_FRACTION = 0.62


def render(bg, stroke_color, dot_color, mode="RGB"):
    """Render one icon variant. Colors are RGB tuples."""
    img = Image.new(mode, (SIZE, SIZE), bg)
    draw = ImageDraw.Draw(img)

    inner_size = int(SIZE * INNER_FRACTION)
    inner_x = (SIZE - inner_size) // 2
    inner_y = (SIZE - inner_size) // 2

    # Stroke thickness — chunky enough to read at the smallest displayed size
    # (40x40 spotlight icon) without looking spindly. ~6.5% of icon edge.
    sw = max(8, int(SIZE * 0.065))

    for (x1, y1), (x2, y2) in STROKES:
        p1 = (inner_x + x1 * inner_size, inner_y + y1 * inner_size)
        p2 = (inner_x + x2 * inner_size, inner_y + y2 * inner_size)
        # Manually round the line endpoints (PIL's line() is square-capped).
        draw.line([p1, p2], fill=stroke_color, width=sw)
        r = sw // 2
        for px, py in (p1, p2):
            draw.ellipse([px - r, py - r, px + r, py + r], fill=stroke_color)

    # Orange "tracing dot" at the apex of the A — same accent the onboarding
    # uses to draw the child's eye to where the next stroke begins. Centered
    # at the top vertex (0.50, 0.00) inside the inner area.
    dot_r = int(SIZE * 0.055)
    cx = inner_x + 0.50 * inner_size
    cy = inner_y + 0.00 * inner_size
    draw.ellipse([cx - dot_r, cy - dot_r, cx + dot_r, cy + dot_r], fill=dot_color)

    return img


# Light mode: warm honey background, kid-blue strokes, orange tracing dot.
# The honey/blue/orange palette echoes the in-app trace demo exactly.
HONEY        = (255, 224, 153)
TRACE_BLUE   = ( 52, 120, 246)
ACCENT_ORANGE = (255, 149,  10)

# Dark mode: night-blue background, brighter cyan strokes for contrast,
# warm orange dot kept the same (orange reads against any background).
NIGHT_BLUE   = ( 20,  30,  60)
TRACE_CYAN   = (110, 180, 255)

# Tinted mode: monochrome white-on-dark; iOS 18 applies the user's chosen
# tint. Keeping the dot and strokes the same shade preserves the geometry.
WHITE_BG     = (255, 255, 255)
DARK_FG      = ( 40,  40,  40)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)

    light = render(HONEY, TRACE_BLUE, ACCENT_ORANGE)
    light.save(os.path.join(OUT_DIR, "AppIcon.png"), "PNG", optimize=True)

    dark = render(NIGHT_BLUE, TRACE_CYAN, ACCENT_ORANGE)
    dark.save(os.path.join(OUT_DIR, "AppIcon-dark.png"), "PNG", optimize=True)

    tinted = render(WHITE_BG, DARK_FG, DARK_FG)
    tinted.save(os.path.join(OUT_DIR, "AppIcon-tinted.png"), "PNG", optimize=True)

    for name in ("AppIcon.png", "AppIcon-dark.png", "AppIcon-tinted.png"):
        p = os.path.join(OUT_DIR, name)
        print(f"  wrote {p} ({os.path.getsize(p):,} bytes)")


if __name__ == "__main__":
    main()
