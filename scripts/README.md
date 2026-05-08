# scripts/

Asset-generation utilities and the local Git pre-commit hook. Each
file here is run by hand from the repo root (no part of the iOS build
depends on these). Run order when adding a new letter is documented at
the bottom.

## Asset generators

### `generate_strokes.py`
Generate `strokes.json` skeleton tracing paths for letters that don't
ship hand-calibrated checkpoints. Coordinates are normalised 0–1
(x = right, y = down), one entry per stroke.

```bash
python3 scripts/generate_strokes.py
```

> The output is algorithmic, not pedagogical. **Always review with a
> Volksschule-1.-Klasse handwriting reference before shipping** — wrong
> stroke order or direction will cement bad motor programs.

Output: `PrimaeNative/Resources/Letters/<X>/strokes.json`

### `generate_letter_audio.py`
ElevenLabs voice generator for letter phonemes, example words, and
tracing words across multiple voices. Used to build the audio inventory
for the demo letters and any future expansion.

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

> Phonemes, not letter names. `M` is recorded as "mmmh", not "Em" — the
> Anlauttabelle approach used in Austrian Volksschule 1. Klasse.

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

1. `python3 scripts/generate_strokes.py` — drafts `strokes.json`.
   **Review** the order and direction against a handwriting reference.
2. `python3 scripts/generate_letter_audio.py --letter X` — auditions
   all bundled voices for the phoneme. Pick one, copy its files into
   `PrimaeNative/Resources/Letters/X/`.
3. Open the calibration overlay in DEBUG mode on-device to refine the
   checkpoint positions interactively (the calibrator persists per-
   letter overrides into Application Support).
