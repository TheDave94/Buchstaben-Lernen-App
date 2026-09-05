"""Design-token drift gate.

The color pipeline has three hand-synced layers:

    design-system/colors_and_type.css          (source of truth)
      -> scripts/gen_colorsets.py TOKENS       (hand-mirrored hex table)
        -> Primae/Primae/Assets.xcassets/Colors/*.colorset/Contents.json
                                               (generated, committed)

plus the design-system preview cards, whose hex *labels* are hand-typed.
Nothing parses anything, so historically these drifted silently (the
2026-07 sweep found preview labels still showing a retired cream/red
palette).  This test makes every layer-pair mismatch a test failure.
"""
import importlib.util
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
CSS_PATH = REPO_ROOT / "design-system/colors_and_type.css"
PREVIEW_DIR = REPO_ROOT / "design-system/preview"
COLORSETS = REPO_ROOT / "Primae/Primae/Assets.xcassets/Colors"

# TOKENS entries are camelCase; CSS vars are kebab-case. camel->kebab
# covers everything except the canvas semantics, whose CSS names
# predate the `canvas` prefix.
CSS_NAME_EXCEPTIONS = {
    "canvasGhost": "ghost",
    "canvasGhostSoft": "ghost-soft",
    "canvasInkStroke": "ink-stroke",
    "canvasInkStrokeDeep": "ink-stroke-deep",
    "canvasGuide": "guide",
    "canvasGuideSoft": "guide-soft",
    "canvasStartDot": "start-dot",
}

# Non-token colors previews may legitimately use (pure white/black text).
PREVIEW_HEX_WHITELIST = {"#FFFFFF", "#FFF", "#000000", "#000"}


def _load_gen_colorsets():
    spec = importlib.util.spec_from_file_location(
        "gen_colorsets", REPO_ROOT / "scripts/gen_colorsets.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules["gen_colorsets"] = mod
    spec.loader.exec_module(mod)
    return mod


def _camel_to_kebab(name: str) -> str:
    return re.sub(r"(?<!^)(?=[A-Z])", "-", name).lower()


def _parse_color(value: str):
    """Return (hex_int, alpha) from a CSS `#RRGGBB` or `rgba(r,g,b,a)`."""
    value = value.strip()
    m = re.fullmatch(r"#([0-9A-Fa-f]{6})", value)
    if m:
        return int(m.group(1), 16), 1.0
    m = re.fullmatch(
        r"rgba\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*([0-9.]+)\s*\)", value)
    if m:
        r, g, b = (int(m.group(i)) for i in (1, 2, 3))
        return (r << 16) | (g << 8) | b, float(m.group(4))
    return None


def _blocks(css: str, opener: str) -> str:
    """Concatenated bodies of every block whose selector starts with
    `opener` (e.g. `:root` appears several times: color-scheme stanza,
    palette stanza, non-color-token stanza)."""
    bodies = []
    for m in re.finditer(re.escape(opener) + r"[^{]*\{", css):
        depth = 0
        for i, ch in enumerate(css[m.start():], start=m.start()):
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    bodies.append(css[m.end():i])
                    break
        else:
            raise AssertionError(f"unbalanced braces after {opener!r}")
    if not bodies:
        raise AssertionError(f"no {opener!r} block found")
    return "\n".join(bodies)


def _vars_in(block: str) -> dict:
    out = {}
    for m in re.finditer(r"--([a-z0-9-]+)\s*:\s*([^;]+);", block):
        parsed = _parse_color(m.group(2))
        if parsed is not None:
            out[m.group(1)] = parsed
    return out


CSS = CSS_PATH.read_text()
LIGHT = _vars_in(_blocks(CSS, ":root"))
DARK = _vars_in(_blocks(CSS, 'html[data-theme="dark"]'))
# The dark palette is declared TWICE: the explicit opt-in block above and
# the system-preference block below. The second one never entered the
# comparison (audit 2026-09-04).
DARK_MEDIA = _vars_in(_blocks(CSS, "@media (prefers-color-scheme: dark)"))
GEN = _load_gen_colorsets()


def test_every_token_matches_css_light_and_dark():
    problems = []
    for name, light, dark, alpha in GEN.TOKENS:
        css_name = CSS_NAME_EXCEPTIONS.get(name, _camel_to_kebab(name))
        for scheme, table, expected in (("light", LIGHT, light),
                                        ("dark", DARK, dark)):
            got = table.get(css_name)
            if got is None:
                problems.append(f"{name}: no --{css_name} in CSS {scheme} block")
            elif got != (expected, alpha):
                problems.append(
                    f"{name} ({scheme}): CSS --{css_name} is "
                    f"#{got[0]:06X}@{got[1]} but TOKENS says "
                    f"#{expected:06X}@{alpha}")
    assert not problems, "\n".join(problems)


def test_system_dark_block_matches_explicit_dark_block():
    """Every var in the opt-in dark block must appear with the same value
    in the prefers-color-scheme block, or system-dark users see a palette
    no test compared."""
    problems = []
    for name, value in DARK.items():
        got = DARK_MEDIA.get(name)
        if got is None:
            problems.append(f"--{name}: missing from the @media dark block")
        elif got != value:
            problems.append(f"--{name}: @media dark #{got[0]:06X}@{got[1]} != "
                            f"[data-theme=dark] #{value[0]:06X}@{value[1]}")
    assert not problems, "\n".join(problems)


def test_written_colorsets_match_tokens():
    """The committed Contents.json must be exactly what TOKENS generates
    (catches hand-edited JSON and forgotten re-runs of gen_colorsets)."""
    problems = []
    for name, light, dark, alpha in GEN.TOKENS:
        path = COLORSETS / f"{name}.colorset/Contents.json"
        if not path.exists():
            problems.append(f"{name}: colorset missing — run gen_colorsets.py")
            continue
        expected = GEN.build_colorset(name, light, dark, alpha)
        if json.loads(path.read_text()) != expected:
            problems.append(f"{name}: Contents.json differs from TOKENS — "
                            f"run gen_colorsets.py")
    assert not problems, "\n".join(problems)


def test_no_orphan_colorsets():
    token_names = {name for name, *_ in GEN.TOKENS}
    on_disk = {p.name.removesuffix(".colorset")
               for p in COLORSETS.glob("*.colorset")}
    orphans = on_disk - token_names
    assert not orphans, (
        f"colorsets on disk without a TOKENS entry: {sorted(orphans)}")


def test_preview_and_readme_hexes_are_current_palette():
    """Every 6-digit hex hand-typed into a preview card or the README
    must exist in the current CSS palette (either scheme) — stale labels
    from a retired palette fail here."""
    palette = {f"#{h:06X}" for h, _ in LIGHT.values()}
    palette |= {f"#{h:06X}" for h, _ in DARK.values()}
    palette |= PREVIEW_HEX_WHITELIST
    problems = []
    files = sorted(PREVIEW_DIR.glob("*.html"))
    files.append(REPO_ROOT / "design-system/README.md")
    for f in files:
        for m in re.finditer(r"#[0-9A-Fa-f]{6}\b", f.read_text()):
            if m.group(0).upper() not in palette:
                problems.append(f"{f.name}: {m.group(0)} not in current palette")
    assert not problems, "\n".join(problems)


def test_non_color_tokens_live_in_root_not_media_block():
    """Regression guard: type/spacing/radii/shadow/motion tokens once sat
    stranded inside the prefers-color-scheme media block as bare
    declarations (invalid CSS — they never applied)."""
    media = _blocks(CSS, "@media")
    for token in ("--font-display", "--fz-base", "--sp-1", "--r-md",
                  "--sh-1", "--dur-1"):
        assert token not in media, (
            f"{token} declared inside the @media block (dead CSS)")
        assert re.search(r":root\s*{[^@]*?" + re.escape(token), CSS, re.S), (
            f"{token} not reachable in a :root block")
