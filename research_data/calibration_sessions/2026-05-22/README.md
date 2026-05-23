# Calibration session pairs — 2026-05-22

38 (pre, post) polyline pairs captured by `CalibrationSessionLogger`
across **two batches** of iPad calibration on May 22, 2026. The
first batch (22 pairs, ~17:35-17:59 UTC) is polish edits on
already-calibrated letters; the second batch (16 pairs,
~18:38-18:45 UTC) adds the diaeresis dots to Ä / ä / Ö / ö / Ü via
the newly-shipped "+ Punkt" feature.

## Capture metadata

| | Batch 1 | Batch 2 |
|---|---|---|
| Window (UTC) | 17:35–17:59 | 18:38–18:45 |
| Instrumentation commit | `40e275da` | `40e275da` |
| Calibrator-feature commit | (`+ Strich` only) | **`b0d26ab6`** added `+ Punkt` |
| Bundle SHA at session start | `cc2a8ff3` | `b17ab215` |
| Bundle SHA after import | `b17ab215` (commit) | `<this commit>` |
| Pairs captured | 22 | 16 |
| Tool tally | 13 ANKER + 9 SKELETT | 6 ANKER + 10 SKELETT |
| Edit operations summed | 128 | 55 |

**Combined: 38 pairs · 19 ANKER + 19 SKELETT · 183 edit operations summed.**

Tool tags reflect `topMode` at save time, not strictly the mode that
authored each edit. Some batch-2 pairs are tagged SKELETT because
David toggled to SKELETT to verify body strokes between dot
placements; the underlying dot edit itself was an ANKER `.punkt`
action.

## Letters touched (13)

| Letter | Pairs in batch 1 | Pairs in batch 2 | File diff vs prior bundle? |
|---|---:|---:|---|
| A | 1 | 0 | ✓ (batch 1) |
| Ä | 4 | 8 | ✓ (batch 2 — added 2 dots) |
| D | 1 | 0 | ✓ (batch 1) |
| N | 1 | 0 | ✓ (batch 1) |
| Ö | 5 | 5 | ✓ (batch 2 — added 2 dots) |
| U | 1 | 0 | ✓ (batch 1) |
| Ü | 0 | 3 | ✓ (batch 2 — dot positions refined) |
| W | 3 | 0 | ✓ (batch 1) |
| b | 1 | 0 | ✓ (batch 1) |
| l | 1 | 0 | ✓ (batch 1) |
| m | 2 | 0 | ✓ (batch 1) |
| p | 1 | 0 | ✓ (batch 1) |
| v | 1 | 0 | ✓ (batch 1) |

**Note — bundle-update vs session-pair mismatch for ä / ö / ü.**
The batch-2 bundle import updated the strokes.json files for ä and
ö (added 2 dot strokes each) AND already had ü at the correct
shape from earlier. But **no session pairs were captured under
ä, ö, or ü directories on the iPad** — only their uppercase
counterparts produced session JSONs. This anomaly is queued for
investigation (logger-gap question after the umlaut import lands)
as a potential NFC/NFD mismatch in the on-iPad session directory
naming OR a David-side workflow detail. The Ü-only / ü-zero
asymmetry rules out "David didn't touch the lowercase set" since
Ü was already correctly dotted; Ü's 3 pairs were dot-position
refinements.

## Nature of edits

**Batch 1** is POLISH — refinements on already-calibrated letters
from prior calibrator rounds.

**Batch 2** is mostly NEW-STROKE authoring — the diaeresis dots
that didn't exist for Ä / ä / Ö / ö, plus position refinement on
Ü's already-present dots. This is the first batch of "add-stroke"
data category in the corpus, distinct from batch 1's "edit-
existing" pattern. Useful for any future analysis that wants to
separate "what new strokes look like when authored by hand" from
"what existing strokes look like when refined."

Both batches: SPEC-VISUAL-APPROVAL — every save survived David's
eye at iPad render scale against the live letter ink.

## Per-pair payload schema

```json
{
  "letter": "<character>",
  "schriftArt": "druckschrift",
  "timestamp_iso": "<ISO-8601 with Z>",
  "tool": "SKELETT" | "ANKER" | "OTHER",
  "edit_count_in_session": <int>,
  "pre_polyline":  [<stroke>, <stroke>, ...],
  "post_polyline": [<stroke>, <stroke>, ...]
}
```

- `<stroke>` = `[{"x": <float>, "y": <float>}, ...]` in bbox-relative
  [0, 1] coordinates
- Coordinates rounded to 4 decimal places (~0.1 raster-px at 1024²)
- Single-checkpoint strokes (umlaut dots, tittles) appear as
  `[{"x": ..., "y": ...}]` — exactly 1 element. Created via the
  `+ Punkt` feature (`b0d26ab6`) which bypasses the multi-anchor
  rebuild path.
- `tool` reflects the active calibrator `topMode` at the moment
  of save; see `StrokeCalibrationOverlay.swift::persistAndLog`.

## References

- `docs/BAKE_INVARIANTS.md` — invariants this corpus helps validate
- `../spec_decision/framing.md` — the SPEC-VISUAL-APPROVAL argument
  that makes these pairs meaningful as ground truth
- `PrimaeNative/Core/CalibrationSessionLogger.swift` — captures
  these pairs at every `CalibrationStore.persist()` call
- `README.txt` (in this directory) — the bootstrap-time README that
  the app writes on first launch; preserved verbatim for iPad-side
  context
