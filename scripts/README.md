# scripts/

Asset-generation utilities and the local Git pre-commit hook. Each
file here is run by hand from the repo root (no part of the iOS build
depends on these). Run order when adding a new letter is documented at
the bottom.

## Asset generators

### `generate_strokes_auto.py`
Generate `strokes.json` for every letter from the Primae font's
rendered glyph centerlines. Reads per-letter specs from the `LETTERS`
dict at the top of the script — each entry composes one **arm
primitive** per arm (`chord` / `bfs_raw` / `lsq_line` /
`smoothed_medial_axis` / `straight_line`) with one **joint primitive**
per interior corner (`sharp` / `family_a_fillet` / `quadratic_bezier_at_V`
/ `cubic_bezier_clamped` / `sharp_meeting` /
`sharp_meeting_at_intersection` / `fillet_at_intersection`). The
default pair (`smoothed_medial_axis` + `cubic_bezier_clamped`)
matches the byte-identical line-kind output shipping at `6cf5740` —
override per-arm or per-joint via the spec's `"arms"` / `"joints"`
keys. The full pipeline + primitive catalogue + visual-sweep workflow
is documented in `docs/APP_DOCUMENTATION.md` §13. Coordinates are
bbox-relative 0–1.

```bash
python3 scripts/generate_strokes_auto.py            # all 59 letters
python3 scripts/generate_strokes_auto.py M N B      # subset
```

Output: `PrimaeNative/Resources/Letters/<X>/strokes.json`.

### `skeleton_audit.py`
Per-letter and global diagnostics on the rendered skeletons —
disconnected components, spurs, named-anchor drift. Surfaces
letters whose `LETTERS` anchors won't resolve cleanly.

```bash
python3 scripts/skeleton_audit.py
python3 scripts/skeleton_audit.py --letters K k --verbose
```

### `render_overlay.py`
Render a contact-sheet PNG of every letter — glyph in light gray
overlaid with the bundled `strokes.json` polylines (one colour per
stroke, start = green dot, end = red dot, stroke index labels).
Use it to eyeball misalignments after a bake.

```bash
python3 scripts/render_overlay.py
```

Output: `tmp_overlays/<letter>.png` + `tmp_overlays/sheet_part*.png`
(not tracked — `tmp_overlays/` is gitignored).

### `render_sweep_grid.py`
Visual-sweep-workflow renderer. Bakes N variant `LETTERS`-specs across
one or more letters and composes a contact-sheet PNG (rows = letters,
cols = variants) with per-panel overlay showing gate counts
(overshoot / reversal / max-turn) + per-joint metrics (V_sd, P_end dt,
apex_sd). The variant file is a JSON document declaring `letters` +
`variants` — see the module docstring for the exact shape.

```bash
python3 scripts/render_sweep_grid.py path/to/variants.json \
    --out /tmp/sweep_grid.png
```

Use it whenever a geometric tunable has multiple plausible values
(`docs/APP_DOCUMENTATION.md` §13.7).

### `verify_bake.sh`
Codifies the two release-blocking properties of the bake pipeline
(`docs/APP_DOCUMENTATION.md` §13.6):

1. **Determinism** — 3 successive bakes produce byte-identical output.
2. **Byte-identity** — a fresh bake matches HEAD's checked-in
   `strokes.json` for every letter the `LETTERS` dict covers
   (the b firewall is a special case).

```bash
./scripts/verify_bake.sh            # all 18 letters in LETTERS dict
./scripts/verify_bake.sh M N V W b  # subset
```

Exits non-zero on drift. Cheap enough (~12 s for the full set) to
run before any commit that touches `generate_strokes_auto.py`.

### `generate_letter_audio.py`
ElevenLabs voice generator for the letter-**name** audio, example
words, and tracing words (the `audioFiles` population) across multiple
voices. Used to build the name/word audio inventory for the demo
letters and any future expansion. **Not for phonemes** — the pilot
phoneme (Anlaut) set is RECORDED by a human voice, not synthesised
(ElevenLabs returns letter names/words, not isolated phones); see
`docs/SOUND_PRODUCTION_SPEC.md`.

```bash
export ELEVENLABS_API_KEY=...                    # never commit; .env is gitignored
pip install requests
python3 scripts/generate_letter_audio.py --letter M   # audition mode (one letter, all voices)
python3 scripts/generate_letter_audio.py             # full inventory
```

The script writes to `audio_variants/<Voice>/<Letter>/` and
`audio_variants/<Voice>/words/`. That directory is **not** tracked in
git — pick the favourite voice's files and copy them into
`PrimaeNative/Resources/Letters/<X>/` to ship them.

> The phoneme (Anlaut) recordings — `M` as "mmmh", not "Em", the
> Anlauttabelle approach used in Austrian Volksschule 1. Klasse — are
> produced separately by studio recording (human voice), NOT by this
> script. See `docs/SOUND_PRODUCTION_SPEC.md`.

### `generate_prompts.py`
ElevenLabs generator for the 13 static prompt MP3s the child hears
during normal practice (phase entries, praise tiers, paper-transfer
cues, retrieval question). Runs across the same 10 voices as
`generate_letter_audio.py` so a voice can be picked alongside the
letter audio. The shipped MP3s live at
`PrimaeNative/Resources/Prompts/<key>.mp3`; filenames match
`PromptPlayer.PromptKey.rawValue`. Until generated, `PromptPlayer`
falls back to `AVSpeechSynthesizer`.

```bash
export ELEVENLABS_API_KEY=...
python3 scripts/generate_prompts.py                              # full inventory
python3 scripts/generate_prompts.py --prompt phase_freewrite     # audition one
```

### `gen_colorsets.py`
Regenerate the design-token Asset Catalog colorsets from a hex table
that mirrors `design-system/colors_and_type.css` (`:root` block for
light + `html[data-theme="dark"]` block for dark). 38 tokens —
paper / ink / canvas semantics / brand / world tints / feedback /
stars / adult area — each emitted as a `*.colorset/Contents.json`
pair (universal-light + appearance-dark luminosity variant).

```bash
python3 scripts/gen_colorsets.py
```

Output: `Primae/Primae/Assets.xcassets/Colors/<token>.colorset/Contents.json`.

The runtime side reads these via `Color("name")` from
`PrimaeNative/Theme/Colors.swift`. Do **not** hand-edit the
generated JSON — re-run the script after a design-system update so
hexes stay in sync.

### `gen_appicon.py`
Render the app-icon PNG set (light / dark / monochrome) into the Xcode
asset catalogue. The icon shows the same three-stroke "A" the child
sees in the onboarding observe-phase demo.

```bash
pip install Pillow
python3 scripts/gen_appicon.py
```

Output: `Primae/Primae/Assets.xcassets/AppIcon.appiconset/`
(`AppIcon.png`, `AppIcon-dark.png`, `AppIcon-tinted.png`).

### `render_checklist.py`
Regenerate `docs/testing_checklist.html` from the canonical
Markdown source `docs/TESTING_CHECKLIST.md`. The HTML page carries
real `<input type="checkbox">`es backed by `localStorage`, a sticky
progress counter, and a "Copy unchecked" button. Run after editing
the Markdown source.

```bash
python3 scripts/render_checklist.py
```

Output: `docs/testing_checklist.html`.

## Git hooks

### `install-hooks.sh`
Copies `scripts/pre-commit` into `.git/hooks/pre-commit` and makes it
executable. Run **once** after every fresh clone.

```bash
./scripts/install-hooks.sh
```

### `pre-commit`
Pre-commit gate that runs `swift build --build-tests` and
`swift test --parallel` whenever a `PrimaeNative/*.swift` file is
staged. Blocks the commit on a build or test failure.

Emergency bypass:
```bash
git commit --no-verify
```

## Adding a new letter

1. Add a `LETTERS[letter]` entry in `generate_strokes_auto.py`
   (start by copying the closest already-shipped letter's spec; see
   `docs/APP_DOCUMENTATION.md` §13.2 for the spec shape and §13.8 for
   the full authoring loop), then run it for the new letter:
   `python3 scripts/generate_strokes_auto.py X`. Review the output
   against the Volksschule-1.-Klasse Druckschrift worksheet, and use
   the visual sweep workflow (`docs/APP_DOCUMENTATION.md` §13.7) for
   any geometric tunable that has multiple plausible values.
2. `python3 scripts/generate_letter_audio.py --letter X` — auditions
   all bundled voices for the phoneme. Pick one, copy its files into
   `PrimaeNative/Resources/Letters/X/`.
3. `./scripts/verify_bake.sh` — confirms 3-trial determinism + that no
   already-shipped letter's `strokes.json` regressed (the b firewall).
4. The DEBUG-only `StrokeCalibrationOverlay` is for on-device
   inspection only — it persists tweaked checkpoints to Application
   Support so you can see them inside that session, but there is no
   round-trip back to the source `LETTERS` dict. Calibration findings
   must be hand-translated into a `LETTERS` spec edit + re-bake.
