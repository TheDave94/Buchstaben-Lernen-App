# G1 calibration run — 2026-05-23

**Corpus state SHA at calibration run:** `d90a5cd8` (HEAD immediately
before this commit; the calibration ran against this corpus state, and
the doc lands together with the gate changes in the next commit).
**Calibration data:** `research_data/calibration_sessions/2026-05-22/`
(13 letters with session pairs).
**Script:** `scripts/calibrate_g1_threshold.py`.
**Result doc cited by:** `docs/BAKE_INVARIANTS.md` Threshold 1;
`research_data/phase2b_gates/g1_design.md` Section 3.

## Framing

Calibrated as a **freeze gate** against the hand-calibrated Regular
corpus per David's confirmation 2026-05-23. The bake pipeline at
`scripts/generate_strokes_auto.py` is retired for Regular (commit
`6a85811c`, 2026-05-15: "Druckschrift Regular complete — all 59 letters
as static artifacts"). HEAD's `strokes.json` files are the canonical
reference; G1's job is to flag any future PR producing drift larger than
David's previously-approved polish edits in the 2026-05-22 session pairs.

The bake pipeline is not involved in this calibration. The original
draft of `g1_design.md` proposed a "fresh-bake-vs-shipped self-Pearson
floor" measurement; that procedure is obsolete with the bake pipeline
retired. The reframed procedure measures session-pair drift directly.

## Procedure

For each letter in the 2026-05-22 session corpus:

1. Load `pre_polyline` of the earliest session JSON (sorted by ISO
   timestamp filename) — that's "round-1", David's starting state.
2. Load HEAD `strokes.json` for the same letter — that's "round-2",
   David's approved state.
3. Rasterize the letter glyph from `Primae-Regular.otf`, compute the
   ink-mask bbox via `bbox_from_mask`.
4. Build per-stroke Voronoi masks from round-2 (the canonical reference).
5. For each stroke index up to `min(len(round1), len(round2))`, call
   `gate_g1_per_stroke(round1[i], round2[i], stroke_mask[i], bbox,
   threshold=1.0)` and collect the result.

Vacuous-pass cases (`not_applicable_too_short`, `insufficient_measured_points`,
`low_variance_asymmetry`) are excluded from the threshold-floor derivation.

## Per-(letter, stroke) calibration table

| Letter | Stroke | Pearson | cand_std | ref_std | n_meas | edits | Class | Note |
|---|---:|---:|---:|---:|---:|---:|---|---|
| A | 0 | 0.9943 | 0.1562 | 0.1560 | 94 | 3 | tight | |
| A | 1 | 0.9142 | 0.1586 | 0.1276 | 92 | 3 | substantial | |
| A | 2 | 1.0000 | 0.0565 | 0.0565 | 94 | 3 | tight | |
| D | 0 | — | 0.0273 | 0.0273 | 94 | 3 | vacuous | `low_variance_asymmetry` |
| D | 1 | 0.4903 | 0.0416 | 0.0521 | 94 | 3 | substantial | Closed-bowl polish (smallest std above filter) |
| N | 0 | 0.8814 | 0.1364 | 0.1715 | 94 | 16 | substantial | |
| U | 0 | 0.9616 | 0.1989 | 0.2029 | 88 | 1 | moderate | |
| U | 1 | 1.0000 | 0.2860 | 0.2860 | 89 | 1 | tight | |
| W | 0 | 0.9337 | 0.1577 | 0.1989 | 94 | 31 | substantial | |
| **b** | **0** | **0.2005** | 0.0627 | 0.1023 | 94 | 4 | **substantial** | **Threshold floor — closed-bowl polish** |
| l | 0 | — | 0.0438 | 0.0315 | 94 | 0 | vacuous | `low_variance_asymmetry` (uniform-stem noise) |
| m | 0 | 0.8883 | 0.1771 | 0.2292 | 94 | 3 | substantial | |
| p | 0 | 1.0000 | 0.1991 | 0.1991 | 94 | 8 | tight | |
| p | 1 | 0.6730 | 0.0797 | 0.0771 | 94 | 8 | substantial | Closed-bowl polish |
| v | 0 | 0.8464 | 0.1621 | 0.1866 | 94 | 17 | substantial | |
| Ä | 0 | 1.0000 | 0.1320 | 0.1320 | 93 | 2 | tight | |
| Ä | 1 | 1.0000 | 0.1199 | 0.1199 | 94 | 2 | tight | |
| Ä | 2 | 1.0000 | 0.0998 | 0.0998 | 94 | 2 | tight | |
| Ö | 0 | — | 0.0420 | 0.0420 | 94 | 2 | vacuous | `low_variance_asymmetry` |
| Ü | 0 | 1.0000 | 0.2201 | 0.2201 | 94 | 8 | tight | |
| Ü | 1 | 1.0000 | 0.3164 | 0.3164 | 94 | 8 | tight | |
| Ü | 2 | — | — | — | 0 | 8 | vacuous | `not_applicable_too_short` (dot) |
| Ü | 3 | — | — | — | 0 | 8 | vacuous | `not_applicable_too_short` (dot) |

Stroke-count delta notes:
- `Ä`: round-1 had 3 strokes (base A only), HEAD has 5 (3 base + 2 dots).
  Compared first 3 only; dots have no round-1 counterpart.
- `Ö`: round-1 had 1 stroke (base O only), HEAD has 3 (1 base + 2 dots).
  Compared first 1 only.

## Distribution stats

- Real Pearson values: **18** (vacuous: 5)
- Pearson == 1.0 exactly: 8
- Pearson ≥ 0.99: 9
- Tight (≥ 0.99): 9
- Moderate (0.95–0.99): 1
- Substantial (< 0.95): 8
- **min: 0.2005** (b stroke 0)
- median: 0.9779
- max: 1.0000 (Ü stroke 0)

## Vacuous-pass cases

Three strokes excluded from threshold derivation via `low_variance_asymmetry`
filter (std < `G1_MIN_ASYMMETRY_STD = 0.05`):

- **l s0** (std cand=0.044, ref=0.032). Uniform-stem letter; asymmetry signal
  sits below the perpendicular-walk's sub-pixel rounding noise floor. Pearson
  came in at 0.1528 with `edit_count=0` — strongly suggestive of measurement
  noise rather than meaningful drift. This case motivated the filter's
  introduction.
- **D s0** (std 0.027). D's vertical stem; uniform width. Pre-filter Pearson
  was 1.0 (no actual drift); filter just marks it vacuous instead.
- **Ö s0** (std 0.042). Ö's base O outline; round-1 = HEAD for the base
  stroke (only batch-2 dot additions touched Ö). Pre-filter Pearson was 1.0.

Two strokes vacuous via `not_applicable_too_short`:

- **Ü s2, Ü s3** — 1-cp diacritic dots. No centerline geometry to measure.

## Derived threshold

**Production threshold: 0.2005** (b s0's closed-bowl polish).

This sits at the lowest non-vacuous Pearson in the corpus. No safety
margin: the reference is static, so there is no algorithmic noise floor
to subtract against. Future PRs producing per-stroke Pearson ≥ 0.2005
against the pre-modification reference pass silently; PRs producing
lower Pearson fail the gate and require manual review.

## Interpretation

The 2026-05-22 session corpus contains a wide range of polish-edit
magnitudes — from `edit_count=0` (near-tight) up to `edit_count=31`
(W's 0.9337 with 31 edits, which still preserves most of the asymmetry
profile because the edits redistributed cp positions without changing
overall shape).

The threshold floor is set by **closed-bowl polish on `b`** (Pearson
0.2005, `edit_count=4`). Closed-bowl letters (b, d, p, q, R) have
intrinsically narrow asymmetry-signal margins at the bowl-stem junction
region (Investigation 3 documented this); small geometric adjustments
in that region produce large Pearson swings.

**G1 functions as a catastrophic-drift detector.** It catches:
- Wholesale stroke reshaping (e.g., re-baking from an algorithmic spec
  that produces fundamentally different centerlines)
- Polyline corruption (e.g., a script bug shifting all cps by an offset)
- Stroke-topology mistakes that survive automated tests but change the
  letter's identity (e.g., a "polish" that accidentally inverts a curve)

It does NOT catch:
- Small-magnitude systematic drift (e.g., a 2 px shift along the whole
  polyline produces high Pearson because the asymmetry profile shape is
  preserved). G3 (stem-width / Threshold 3 perpendicular deviation) is
  the gate that should catch this.
- Turn-angle drift without centerline drift. G2 (Threshold 2 turn-angle
  Pearson) is the gate that should catch this.
- Junction-tangent drift. G4 (Threshold 4 tangent delta at junctions) is
  the gate that should catch this.

G2-G4 will land with their own calibration runs and result docs in
this directory.

## Files referenced

- Corpus: `research_data/calibration_sessions/2026-05-22/*/<timestamp>.json`
- Reference: `PrimaeNative/Resources/Letters/Regular/<letter>/strokes.json`
  at HEAD `d90a5cd8`
- Script: `scripts/calibrate_g1_threshold.py`
- Gate implementation: `scripts/audit_invariants.py::gate_g1_per_stroke`
  (with `G1_MIN_ASYMMETRY_STD = 0.05` filter)
- Spec: `docs/BAKE_INVARIANTS.md` §2 Threshold 1
- Design: `research_data/phase2b_gates/g1_design.md`
