# Stroke Audit — Authoritative Synthesis
*Generated 2026-05-08. Synthesised from four parallel audit agents; all critical claims verified against source files.*

---

## Executive Summary

The stroke data for uppercase **I** is catastrophically wrong — the skeleton walker produced a diagonal slash (x: 0.712→0.288) instead of a vertical stroke, so every child trace attempt will fail silently. Compounding this, **Z** has a 21% dead zone at the top-bar start and **U** was generated as two disconnected strokes instead of one continuous bowl, both due to the same root cause: BFS skeleton walking executes LETTER_OVERRIDES anchors incorrectly when the skeleton's nearest pixel to a named anchor is an interior junction rather than the intended endpoint. The single highest-leverage action is to open the `StrokeCalibrationOverlay` in the Simulator for the broken letters and re-author them directly, bypassing the generator entirely — this takes 5–10 minutes per letter and produces ground-truth output that the pipeline has never managed for complex letters.

---

## Severity-Ranked Issues

### CRITICAL — Child will always fail; ship-blocking

| # | Letter / Location | Finding | Verified? | Root Cause |
|---|---|---|---|---|
| C1 | `I/strokes.json` | Stroke is a diagonal slash: start (0.712, 0.053) → end (0.288, 0.947). X decreases 42% across 39 checkpoints. Completely unrecognizable as a vertical stroke. | **Yes — JSON read** | BFS resolved `TL` and `BL` anchors to the wrong skeleton pixels; the Primae I has serifs and the skeleton branches create four arms, none of which is the vertical stem alone. |
| C2 | `Z/strokes.json` stroke 1 (top bar) | First checkpoint at x=0.213. A child who starts at the left ink tip (x≈0) traces 21% of the glyph width before any checkpoint registers. Checkpointradius=0.05, detection range=0.15 — gap = 0.063 bbox units ≈ 50 pt on a 800 pt cell. Stroke 3 (bottom bar) ends at x=0.834, leaving a 17% unresponsive tail. | **Yes — JSON read** | `TL`/`BR` anchors resolved to the bar-diagonal junction pixel, not the horizontal bar tip. |
| C3 | `U/strokes.json` | 2 strokes (left arm 92 pts, right arm 41 pts) instead of 1 continuous bowl. Child must lift finger at the bottom and restart mid-stroke. | **Yes — JSON read** | BFS between `TL→BL→BR` resolved to two disconnected skeleton components; the U's bottom arc was disconnected in the skeleton. |

---

### HIGH — Significant tracing failure or pedagogical mismatch

| # | Letter / Location | Finding | Verified? | Root Cause |
|---|---|---|---|---|
| H1 | `M/strokes.json` | 180° reversal spike at valley bottom: path reaches (0.489, 0.883) then bounces back to (0.489, 0.879). StrokeTracker requires advancing checkpoints in sequence — a child tracing smoothly will hit the reversal point then have to double back to advance. | Agent 3 (single-source) | BFS path includes a spur pixel at the valley; path briefly retreats before continuing. |
| H2 | `V/strokes.json` | 180° reversal near apex: path dips to y=0.945 then retreats to y=0.936 before ending. Same spike-bounce pattern. | Agent 3 (single-source) | Same BFS spur issue at apex junction. |
| H3 | `B/strokes.json` | 3 strokes confirmed (Agents 1+3+JSON), but stroke 2 contains a 177.5° spike at cp[48] that causes checkpoint regression. The 3-stroke count itself may be correct Austrian Volksschrift pedagogy — this is a **contradiction between agents** (Agent 1: correct; Agent 3: wrong). Spike is the actionable defect regardless of stroke count. | Partial — stroke count confirmed by JSON; spike single-source (Agent 3) | BFS spur at bump-to-stem junction. |
| H4 | `E/strokes.json` stroke 3, `H/strokes.json` stroke 3 | Crossbar anchor resolves ~0.024 units below the actual bar midline, causing first checkpoint step to go upward 76–82° before turning right. Child who starts tracing horizontally will not advance the first checkpoint until they move upward first. | Agent 3 (single-source) | `ML` anchor resolved to a pixel below the true bar centre. |
| H5 | `TracingViewModel.swift:241` | `rawGlyphStrokes` skips CalibrationStore for Druckschrift. `activeScriptStrokes` returns nil when `schriftArt.bundleVariantID` is nil (Druckschrift has none). The fallback `letters[letterIndex].strokes` is the un-calibrated bundle default. Meanwhile `glyphRelativeStrokes:225` and `reloadStrokeCheckpoints:1516` both call `calibrationStore.strokes(for:...) ?? letter.strokes`. Direct-phase numbered dots, observe-phase animation guide, and freeWrite KP overlay all consume `rawGlyphStrokes` — they will render at bundle positions after a Druckschrift calibration, visually diverging from the ghost and checkpoints. | **Yes — code read** | Divergence between `rawGlyphStrokes` (lines 233–265) and `glyphRelativeStrokes` (lines 220–226): the calibration store lookup was added to one but not the other. |
| H6 | `i/strokes.json` | Stem ends at (0.256, 0.94) — 24% left of centre. A child writing a straight vertical `i` will try to end near x≈0.5 and miss the final checkpoint cluster. | **Yes — JSON read** | `B` anchor resolved to bottom-left of a serif or stem-base element rather than stem base centre. |

---

### MEDIUM — UX degradation or latent data corruption

| # | Letter / Location | Finding | Verified? |
|---|---|---|---|
| M1 | `StrokeTracker.swift:99` + `TracingViewModel.swift:1566` | `checkpointRadius=0.05` is authored in glyph-bbox-relative space but applied in cell-fraction space after the bbox→cell mapping. For normal letters (gr.width≈0.7) the effective hit zone is ~7% of glyph bbox — acceptably close. For narrow letters (`i`, `j`, `l`, `ß`) where gr.width≈0.15–0.25, effective radius is 20–33% of glyph bbox width. Child can pass checkpoints 3–5× more easily than intended. `checkpointRadius` should be scaled by `sqrt(gr.width * gr.height)` during the remap in `reloadStrokeCheckpoints`. | **Yes — code confirmed** |
| M2 | `Ä/strokes.json` strokes 4 & 5 | Each diacritic dot has 1 checkpoint (a tap target). For `Ä` this means the child must tap a precise point at (0.429, 0.052) and (0.783, 0.050) — no tolerance path, no visual arc. Combined with the 80.8° kink at crossbar end (stroke 3). | Agent 3 (single-source) |
| M3 | `G/strokes.json` | 3 strokes (arc + connecting segment + shelf) vs expected 2; arc gap 46°. | Agent 3 (single-source) |
| M4 | Font update silent breakage | No font hash is stored anywhere. If `Primae-Regular.otf` is updated, all LETTER_OVERRIDES silently remain but walk a different skeleton. Every strokes.json in the bundle would be wrong until regenerated. | Agent 1 (single-source) |

---

### LOW — Code hygiene / minor drift

| # | Location | Finding | Verified? |
|---|---|---|---|
| L1 | `LetterCache.swift:71–101` | Agent 2 reports `phonemeAudioFiles` lost on warm launch. The actual field in `CodableLetterAsset` is `audioFiles` (confirmed, line 76). If `LetterAsset` has a *separate* `phonemeAudioFiles` property not present in `CodableLetterAsset`, that field is silently dropped after first launch. **Unresolved: verify `LetterAsset` definition.** | Partial — field name discrepancy noted |
| L2 | `PrimaeLetterRenderer.swift:71` | Full-evict cache (`cache.removeAll`) at cap=52. Letter picker cycles 60+ letters — beyond the 52nd key, every render is a cold miss. LRU or a higher cap is better. | **Yes — code confirmed** |
| L3 | `PrimaeLetterRenderer.swift:346–393` | `draw()` / `render()` use ink-bbox fit-to-cell scaling; `glyphPath()` uses em-height scaling. These are different. `render()` appears uncalled from app code (Agent 2). | Agent 2 (single-source) |
| L4 | `scripts/generate_strokes.py` | Dead code: writes to `BuchstabenNative/Resources/Letters` (non-existent pre-rebrand path), carries wrong `checkpointRadius: 0.06`, uses hand-coded coordinates. Will never run or corrupt anything. | Agent 1 confirmed |
| L5 | `scripts/generate_strokes_centerline.py`, `generate_strokes_topology.py` | Parallel prototype pipelines, never run on production letters. Override coverage is 100%; auto-fallback path has never fired for any current strokes.json. | Agent 1 confirmed |
| L6 | No CI gate for anchor drift | `skeleton_audit.py` exists but is not run in CI. A post-generation check that flags anchor resolve distance > 10% of bbox would have caught C1 (I), C2 (Z), and C3 (U). | Agent 1 confirmed |

---

## Root Cause (Single Sentence)

The BFS skeleton walker in `generate_strokes_auto.py` resolves named anchor positions (`TL`, `BL`, etc.) to the **nearest skeleton pixel** to the bounding-box corner — which is reliably an interior junction pixel, not an endpoint — producing paths that start/end in the wrong place or walk the wrong topological branch.

---

## Recommended Path

### Phase 1 — Emergency letter fixes (4–6 hours, this week)
Fix the three ship-blockers using the `StrokeCalibrationOverlay`. Open a debug build in the Simulator. For each letter: enable `showDebug`, open the calibrator, select "Anker" mode, delete all existing anchors, place 3–5 waypoints in correct tracing order, verify the cyan polyline follows the ink, tap "Apply" to test live, tap "Speichern" to persist.

| Letter | What to do | Est. time |
|---|---|---|
| I | Delete diagonal checkpoints. Place start at top of vertical stem centre (≈0.5, 0.05), end at bottom (≈0.5, 0.95). | 5 min |
| Z | Move top bar start anchor to the actual left tip of the bar. Move bottom bar end anchor to the actual right tip. | 10 min |
| U | Merge to 1 stroke: from top-left, arc through bottom centre, up to top-right. | 10 min |
| M, V | Remove the reversal spike checkpoints near the valley/apex. Drag the offending dots in "Ziehen" mode. | 5–10 min each |
| B | Remove the spike around checkpoint 48 of stroke 2 in "Ziehen" mode. | 5 min |
| E, H | Move crossbar start anchor up ≈0.024 units so first step goes horizontal, not upward. | 5 min each |
| i | Move bottom anchor to stem base centre (≈0.5, 0.95). | 5 min |

### Phase 2 — Code bugs (2–3 hours, this sprint)
These are isolated, low-risk code fixes:

1. **`rawGlyphStrokes` CalibrationStore bypass** (`TracingViewModel.swift:241`): Replace `bbox = letters[letterIndex].strokes` with `bbox = calibrationStore.strokes(for: letters[letterIndex].name, schriftArt: schriftArt) ?? letters[letterIndex].strokes`. This is a one-line fix.

2. **`checkpointRadius` unit mismatch** (`TracingViewModel.swift:1565`): When mapping checkpoints from bbox-relative to cell-fraction, also scale the radius: `checkpointRadius: raw.checkpointRadius * sqrt(gr.width * gr.height)`. This makes the hit zone match the intended 5% of glyph for all letter widths.

3. **Verify `phonemeAudioFiles` in `LetterAsset`** (`LetterCache.swift`): Read the `LetterAsset` struct definition. If it has a `phonemeAudioFiles` property separate from `audioFiles`, add it to `CodableLetterAsset` and thread it through `init` and `var asset`.

### Phase 3 — Structural hygiene (1 hour, when convenient)
- Delete `scripts/generate_strokes.py` (dead, pre-rebrand path, misleading radius).
- Add `skeleton_audit.py --anchor-drift-pct 10` to CI so future regeneration failures are caught before commit.
- Document in CLAUDE.md: "For new letters or fonts, the calibration overlay is the authoring tool. Estimated 5–10 min per letter."

---

## Three Concrete Next Steps

1. **Open `I` in the calibrator right now.** The diagonal slash is the most damaging error — a child tracing down cannot possibly succeed. Fix it in 5 minutes via drag-and-reanchor. This unblocks any Schule-world user testing.

2. **Fix `rawGlyphStrokes:241` in TracingViewModel.swift** — one line, adds the `calibrationStore` lookup that `glyphRelativeStrokes` and `reloadStrokeCheckpoints` already have. Without this fix, any calibration work done for direct-phase or observe-phase animation is silently ignored.

3. **Work through the HIGH severity letters (Z, U, M, V, B, E, H, i) in a single 2-hour simulator session** using the calibration overlay. Export each to Application Support, verify with a finger trace in guided phase, then use `calibration_to_override.py` to commit the fixed anchors to `LETTER_OVERRIDES` so a `generate_strokes_auto.py` re-run doesn't overwrite the fixes.

---

## What NOT to Do

- **Do not tune `generate_strokes_auto.py` BFS logic to fix individual letters.** The BFS anchor resolution is a known-broken heuristic for serif fonts with interior junctions. Every fix creates a new failure somewhere else. Agent 4's analysis is correct: the pipeline's override table already does the hard cognitive work; BFS execution introduces the failures.
- **Do not run `generate_strokes_auto.py` to regenerate strokes for any letter currently in the bundle without first recording the existing file.** A regeneration of `I`, `Z`, or `U` via the current override entries will produce the same broken output.
- **Do not raise `DOT_LENGTH_THRESHOLD_PX` or reduce `checkpointRadius` globally** to paper over the hit-zone mismatch. Fix the unit conversion (Phase 2 item 2) instead.
- **Do not delete `generate_strokes_auto.py`.** It is still useful as a bootstrap for simple single-stroke letters (O, C, S, L). Delete the unused parallel prototypes (`centerline`, `topology`) instead.
- **Do not address the cache full-eviction (L2) before the critical letter fixes.** It is a performance issue, not a correctness issue.

---

## Agent Agreement Matrix

| Issue | Agent 1 | Agent 2 | Agent 3 | Agent 4 | Verified in code/JSON |
|---|---|---|---|---|---|
| I diagonal stroke | — | — | CRITICAL | — | **Yes** |
| Z dead zone | HIGH | — | MINOR | — | **Yes** |
| U 2-stroke error | Unusual | — | BAD | — | **Yes** |
| M/V reversal spike | — | — | BAD | — | No (single-source) |
| rawGlyphStrokes bypass | — | HIGH | — | — | **Yes** |
| checkpointRadius unit | — | MEDIUM | — | — | **Yes (code)** |
| i stem offset | MEDIUM | — | — | — | **Yes** |
| phonemeAudioFiles loss | — | HIGH | — | — | Partial (field name discrepancy) |
| Pipeline is override-only | CONFIRMED | — | — | CONFIRMED | **Yes (100% coverage)** |
| Overlay-first authoring | — | — | — | Recommended | Consistent with findings |
