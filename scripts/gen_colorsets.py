#!/usr/bin/env python3
"""
Generate Asset-Catalog colorsets for the Primae design tokens.

For each (name, lightHex, darkHex, alpha) tuple, writes:

  Primae/Primae/Assets.xcassets/Colors/<name>.colorset/Contents.json

The Contents.json declares two universal entries, one default
(light) and one tagged with `appearance: luminosity / value: dark`
so iOS resolves them per the active trait collection — no
closures, no actor-isolation concerns (the renderer reads a
compiled .car at trait change, not Swift code).

Light + dark hexes come from `design-system/colors_and_type.css`
(`:root` block + `html[data-theme="dark"]` block respectively).
"""
import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
BASE = REPO_ROOT / "Primae/Primae/Assets.xcassets/Colors"
BASE.mkdir(parents=True, exist_ok=True)

# (name, light_hex, dark_hex, alpha)
TOKENS = [
    # Surface
    ("paper",                0xFFFFFF, 0x0B1220, 1.0),
    ("paperDeep",            0xF8FAFC, 0x111827, 1.0),
    ("paperEdge",            0xE2E8F0, 0x1F2937, 1.0),
    ("ink",                  0x0F172A, 0xF8FAFC, 1.0),
    ("inkSoft",              0x475569, 0xCBD5E1, 1.0),
    ("inkFaint",             0x94A3B8, 0x94A3B8, 1.0),
    ("inkGhost",             0xCBD5E1, 0x475569, 1.0),
    # Canvas semantics
    ("canvasPaper",          0xF8FAFC, 0x111827, 1.0),
    ("canvasGhost",          0x2563EB, 0x60A5FA, 1.0),
    ("canvasGhostSoft",      0x2563EB, 0x60A5FA, 0.35),
    ("canvasInkStroke",      0x10B981, 0x34D399, 1.0),
    ("canvasInkStrokeDeep",  0x059669, 0x10B981, 1.0),
    ("canvasGuide",          0xF59E0B, 0xFBBF24, 1.0),
    ("canvasGuideSoft",      0xF59E0B, 0xFBBF24, 0.20),
    ("canvasStartDot",       0x0F172A, 0xF8FAFC, 1.0),
    # Brand
    ("brand",                0x2563EB, 0x3B82F6, 1.0),
    ("brandDeep",            0x1D4ED8, 0x2563EB, 1.0),
    ("brandSoft",            0xDBEAFE, 0x1E3A8A, 1.0),
    # World tints
    ("schule",               0x2563EB, 0x3B82F6, 1.0),
    ("schuleSoft",           0xDBEAFE, 0x1E3A8A, 1.0),
    ("werkstatt",            0xF59E0B, 0xFBBF24, 1.0),
    ("werkstattSoft",        0xFEF3C7, 0x78350F, 1.0),
    ("fortschritte",         0xEC4899, 0xF472B6, 1.0),
    ("fortschritteSoft",     0xFCE7F3, 0x831843, 1.0),
    # Feedback
    ("success",              0x10B981, 0x34D399, 1.0),
    ("successSoft",          0xD1FAE5, 0x064E3B, 1.0),
    ("warning",              0xF59E0B, 0xFBBF24, 1.0),
    ("warningSoft",          0xFEF3C7, 0x78350F, 1.0),
    ("danger",               0xEF4444, 0xF87171, 1.0),
    ("dangerSoft",           0xFEE2E2, 0x7F1D1D, 1.0),
    ("info",                 0x2563EB, 0x60A5FA, 1.0),
    ("infoSoft",             0xDBEAFE, 0x1E3A8A, 1.0),
    # Stars
    ("star",                 0xF59E0B, 0xFBBF24, 1.0),
    ("starEmpty",            0xE2E8F0, 0x1F2937, 1.0),
    # Adult
    ("adultPaper",           0xF8FAFC, 0x0B1220, 1.0),
    ("adultCard",            0xFFFFFF, 0x111827, 1.0),
    ("adultInk",             0x0F172A, 0xF8FAFC, 1.0),
    ("adultInkSoft",         0x475569, 0xCBD5E1, 1.0),
]

def hex_components(hex_value: int, alpha: float) -> dict:
    r = (hex_value >> 16) & 0xFF
    g = (hex_value >>  8) & 0xFF
    b =  hex_value        & 0xFF
    return {
        "color-space": "srgb",
        "components": {
            "red":   f"0x{r:02X}",
            "green": f"0x{g:02X}",
            "blue":  f"0x{b:02X}",
            "alpha": f"{alpha:.3f}",
        },
    }

def build_colorset(name: str, light: int, dark: int, alpha: float) -> dict:
    return {
        "colors": [
            {
                "idiom": "universal",
                "color": hex_components(light, alpha),
            },
            {
                "idiom": "universal",
                "appearances": [
                    {"appearance": "luminosity", "value": "dark"},
                ],
                "color": hex_components(dark, alpha),
            },
        ],
        "info": {"author": "primae", "version": 1},
    }

# Top-level Colors group needs its own Contents.json so Xcode
# treats it as a folder (not a synced subset).
(BASE / "Contents.json").write_text(json.dumps({
    "info": {"author": "primae", "version": 1},
    "properties": {"provides-namespace": False},
}, indent=2) + "\n")

for name, light, dark, alpha in TOKENS:
    cs_dir = BASE / f"{name}.colorset"
    cs_dir.mkdir(parents=True, exist_ok=True)
    payload = build_colorset(name, light, dark, alpha)
    (cs_dir / "Contents.json").write_text(json.dumps(payload, indent=2) + "\n")
    print(f"  {name:25}  light=0x{light:06X}  dark=0x{dark:06X}  alpha={alpha}")

print(f"\nWrote {len(TOKENS)} colorsets to {BASE}")
