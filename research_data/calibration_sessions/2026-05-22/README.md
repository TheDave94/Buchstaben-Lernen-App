# Calibration session pairs — 2026-05-22

22 (pre, post) polyline pairs captured by `CalibrationSessionLogger`
during David's iPad calibration session on May 22, 2026. **First
batch since the instrumentation landed** — these are the first
training-data entries per Sub-D of the correction-corpus
investigation.

## Capture metadata

| | |
|---|---|
| Date | 2026-05-22 |
| Instrumentation commit | `40e275da` ("feat: log SKELETT/ANKER session pairs for future correction analysis") |
| Bundle SHA at start of session | `cc2a8ff3` (pre-second-pass baseline import) |
| Bundle SHA after subsequent import | `b17ab215` (round-2 import) |
| Tool breakdown | 13 ANKER saves + 9 SKELETT saves |
| Edit operations summed | 128 |

## Letters touched (12)

| Letter | Sessions | File diff vs `cc2a8ff3`? |
|---|---:|:---:|
| A | 1 | ✓ |
| Ä | 4 | — (undone-before-save / sub-rounding) |
| D | 1 | ✓ |
| N | 1 | ✓ |
| Ö | 5 | — |
| U | 1 | ✓ |
| W | 3 | ✓ |
| b | 1 | ✓ |
| l | 1 | ✓ |
| m | 2 | ✓ |
| p | 1 | ✓ |
| v | 1 | ✓ |

## Nature of edits — POLISH, not bake-bug fixes

These are refinements on already-calibrated letters from earlier
rounds. **Not "fixing bad bake output"** — per David's framing on
the correction-corpus investigation, the bake produces ship-acceptable
output for many letters and the calibrator work is fine-tuning
against visual review, not geometric correction.

This framing matters for how the pairs are used downstream:
- They are **not** error-correction labels.
- They are **delta-from-already-good-to-visually-approved** signals.
- A residual model trained on these would learn "polish patterns,"
  not "common bake mistakes."

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
- `tool` reflects the active calibrator mode at the moment of save;
  see `StrokeCalibrationOverlay.swift::persistAndLog`

## References

- `docs/BAKE_INVARIANTS.md` — invariants this corpus helps validate
- `../spec_decision/framing.md` — the SPEC-VISUAL-APPROVAL argument
  that makes these pairs meaningful as ground truth
- `PrimaeNative/Core/CalibrationSessionLogger.swift` — captures
  these pairs at every `CalibrationStore.persist()` call
- `README.txt` (in this directory) — the bootstrap-time README that
  the app writes on first launch; preserved verbatim for iPad-side
  context
