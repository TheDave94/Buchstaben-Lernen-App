# G3 calibration findings — 2026-05-23

**Corpus state SHA at calibration run:** `3c890380` (G3 implementation
commit; the calibration ran against this corpus state, this findings
doc lands together with BAKE_INVARIANTS.md update in the next commit).
**Calibration data:** `research_data/calibration_sessions/2026-05-22/`
(13 letters with session pairs).
**Script:** `scripts/calibrate_g3_threshold.py`.
**Outcome:** **Threshold = 2.05 px. Polish-preservation verified.
Implementation enforced (CI wiring pending G5).**

## Framing

G3 is the first **conformance gate** in the Phase 2b Track B family —
intrinsic geometric property of the candidate polyline (perpendicular
deviation from its best-fit straight line), upper-bounded by a
threshold derived from the corpus. This differs from G1/G2's **drift
gate** shape (lower-bound Pearson against reference). G3 applies only
to strokes classified STRAIGHT via the combined `max(|angle|) < π/12`
AND `p95(|angle|) < 0.1` criterion documented in
`g3_design.md` G3.1 "Caveat caught during implementation".

The 2026-05-22 session-pair corpus serves all four Phase 2b gates'
calibration. For G3, each stroke pair is run twice:
- round-1 candidate vs round-2 reference (captures the round-1 polyline's
  deviation from its own best-fit line, plus the round-2 classification)
- round-2 candidate vs round-2 reference (captures the round-2 polyline's
  deviation from its own best-fit line)

Polish-preservation is verified before threshold derivation: do
round-2 deviations stay ≤ round-1 deviations for STRAIGHT-classified
strokes? If yes, threshold = max(per-stroke max(r1, r2)) + 1 px safety
margin (per `g3_design.md` G3.7 step 5; rasterization noise). If no,
soft-V outcome (metric mismatched to gate purpose).

## Procedure

For each letter in `research_data/calibration_sessions/2026-05-22/`:
1. Load round-1 polyline (earliest session JSON `pre_polyline`) and
   round-2 polyline (HEAD `strokes.json`).
2. Rasterize the letter glyph, compute bbox.
3. For each stroke index up to `min(len(round1), len(round2))`:
   a. Run `gate_g3_per_stroke(round1[i], round2[i], bbox, threshold=∞)`
      → captures classification + dev_r1.
   b. Run `gate_g3_per_stroke(round2[i], round2[i], bbox, threshold=∞)`
      → captures dev_r2.
   c. Report (max_ref_angle, p95_ref_angle, classification,
      dev_r1_px, dev_r2_px, dev_r1_bbox_frac, dev_r2_bbox_frac,
      edit_count).

For strokes vacuous-classified (non-straight or 1-cp), deviations are
computed diagnostically (bypassing the straightness gate) so the table
shows "what the deviation would have been". These diagnostic values
are NOT used for threshold derivation.

## Per-(letter, stroke) calibration table

| Letter | Stroke | max_ref | p95_ref | Classification | dev_r1 px | dev_r2 px | Δdev | bf_r1 | bf_r2 | edits |
|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|
| A | 0 | 0.0390 | 0.0302 | **STRAIGHT** | 0.19 | 0.26 | +0.07 | 0.0004 | 0.0005 | 3 |
| A | 1 | 0.0229 | 0.0104 | **STRAIGHT** | 0.46 | 0.18 | -0.28 | 0.0009 | 0.0004 | 3 |
| A | 2 | 0.1021 | 0.0870 | **STRAIGHT** | 0.89 | 0.89 | +0.00 | 0.0018 | 0.0018 | 3 |
| D | 0 | 0.0275 | 0.0243 | **STRAIGHT** | 0.17 | 0.17 | +0.00 | 0.0004 | 0.0004 | 3 |
| D | 1 | 0.1432 | 0.1011 | SMOOTH-CURVED | 129.49 | 129.43 | -0.07 | 0.2627 | 0.2625 | 3 |
| N | 0 | 1.5307 | 0.0442 | SHARP-CORNER | 204.55 | 202.90 | -1.65 | 0.4192 | 0.4158 | 16 |
| U | 0 | 0.1858 | 0.1470 | SMOOTH-CURVED | 158.70 | 157.93 | -0.78 | 0.3252 | 0.3236 | 1 |
| U | 1 | 0.0300 | 0.0244 | **STRAIGHT** | 0.76 | 0.76 | +0.00 | 0.0016 | 0.0016 | 1 |
| W | 0 | 2.2717 | 0.3745 | CORNERED | 210.44 | 211.19 | +0.76 | 0.3673 | 0.3686 | 31 |
| b | 0 | 0.2089 | 0.1759 | SMOOTH-CURVED | 109.84 | 110.40 | +0.57 | 0.2232 | 0.2244 | 4 |
| l | 0 | 0.2536 | 0.2308 | SMOOTH-CURVED | 36.40 | 37.00 | +0.60 | 0.0741 | 0.0754 | 0 |
| m | 0 | 2.3942 | 0.4335 | CORNERED | 114.22 | 115.12 | +0.90 | 0.2813 | 0.2835 | 3 |
| p | 0 | 0.0236 | 0.0214 | **STRAIGHT** | 0.89 | 0.89 | +0.00 | 0.0018 | 0.0018 | 8 |
| p | 1 | 0.1997 | 0.1338 | SMOOTH-CURVED | 86.97 | 87.32 | +0.35 | 0.1757 | 0.1764 | 8 |
| v | 0 | 1.2223 | 0.0718 | SHARP-CORNER | 90.41 | 94.25 | +3.84 | 0.3075 | 0.3206 | 17 |
| Ä | 0 | 0.1002 | 0.0667 | **STRAIGHT** | 1.05 | 1.05 | +0.00 | 0.0017 | 0.0017 | 2 |
| Ä | 1 | 0.1048 | 0.1033 | SMOOTH-CURVED | 0.19 | 0.19 | +0.00 | 0.0003 | 0.0003 | 2 |
| Ä | 2 | 0.2901 | 0.0000 | SHARP-CORNER | 0.28 | 0.28 | +0.00 | 0.0005 | 0.0005 | 2 |
| Ö | 0 | 0.1743 | 0.1351 | SMOOTH-CURVED | 149.84 | 149.84 | +0.00 | 0.2432 | 0.2432 | 2 |
| Ü | 0 | 0.1874 | 0.1189 | SMOOTH-CURVED | 151.76 | 151.76 | +0.00 | 0.2464 | 0.2464 | 8 |
| Ü | 1 | 0.0747 | 0.0634 | **STRAIGHT** | 0.27 | 0.27 | +0.00 | 0.0004 | 0.0004 | 8 |
| Ü | 2, 3 | — | — | TOO-SHORT | — | — | — | — | — | 8 |

## Classification summary

- **STRAIGHT: 8 strokes** — A 0/1/2, D 0, U 1, p 0, Ä 0, Ü 1
- **SMOOTH-CURVED: 8 strokes** — D 1, U 0, b 0, l 0, p 1, Ä 1, Ö 0, Ü 0
- **SHARP-CORNER: 3 strokes** — N 0, v 0, Ä 2
- **CORNERED: 2 strokes** — W 0, m 0
- **TOO-SHORT: 2 strokes** — Ü 2, Ü 3 (diacritic dots)

Total: 23 stroke pairs. 8 STRAIGHT (G3 applies); 15 vacuous-pass.

### Borderline classifications

Two strokes sit just outside the STRAIGHT class:

- **Ä s1 (right diagonal):** p95 = 0.103 rad (5.92°), just above
  the 0.100 rad (5.73°) threshold (3% margin). Classified
  CURVED.
- **Ä s2 (crossbar):** max = 0.290 rad (16.62°), just above the
  π/12 = 0.262 rad (15.00°) threshold (10% margin). Classified
  CURVED.

The analogous strokes in pure A are well clear of the thresholds
(A s1 p95 = 0.010 rad / 0.60°; A s2 max = 0.102 rad / 5.85°).

**Source of the divergence — calibrator-authored, NOT
`bake_composite`.** Original framing (pre-2026-05-26) attributed
this to a `bake_composite` artifact. Investigation 2026-05-26
falsified that attribution: Ä's shipped strokes.json carries
`[200, 200, 181, 1, 1]` cps per stroke (calibrator densities),
while pure A carries `[40, 40, 40]` (the `bake_letter` default).
`bake_composite` preserves cp count; the densification mismatch
proves the calibrator authored Ä's base directly, bypassing
`bake_composite`. Empirically, `bake_composite` is
angle-preserving on this corpus (uniform 1.0×1.0 scale factors
across A/Ä, O/Ö, U/Ü); if it had been used, the base would
match pure A. The borderline geometry is the calibrator's
authored intent, not a pipeline artifact. See
`research_data/phase2b_gates/phase2c_design.md` "Composite-
umlaut bake artifact investigation" section for the full
finding.

**Decision: keep thresholds as derived.** The G3 classifier
correctly catches the calibrator-authored geometric variation in
Ä's base. Tweaking p95 to 0.11 to admit Ä s1 would fit to one
borderline case — exactly the kind of fitting-to-data the
calibration methodology is supposed to avoid.

## Polish-preservation verification

Polish-preservation is verified by comparing dev_round1 vs dev_round2
for strokes classified STRAIGHT under round-2's classification.
Round-2 is the HEAD reference, so classification is anchored to the
shipped corpus state. Deviations are per-round (round-1 deviation is
the round-1 polyline's deviation from its OWN best-fit line; round-2
deviation likewise). This setup measures whether polish changed a
straight stroke's intrinsic straightness, not whether polish moved
one stroke closer to another.

Results across the 8 STRAIGHT strokes:

```
Strokes where dev_round2 ≤ dev_round1: 7 (polish preserved or improved)
Strokes where dev_round2 > dev_round1: 1 (polish increased deviation)
Median Δdev:                            +0.00 px
Max Δdev (most polish-increased):       +0.07 px at A s0
```

7 of 8 STRAIGHT strokes had deviation preserved or improved by polish.
The 1 exception (A s0) increased by 0.07 px — well within
rasterization sub-pixel noise. **Polish-preservation HOLDS.** Threshold
derivation proceeds.

The pattern matches the design prediction (`g3_design.md` §
"Polish-preservation prediction"): David's polish moves cps to refine
centerline position, not to introduce wobble into straight strokes.
G3's metric (perpendicular deviation from best-fit line) measures a
quantity polish does NOT actively change. Threshold can be derived.

## Threshold derivation

```
max(per-stroke max(dev_r1, dev_r2)) = 1.0497 px at Ä s0
+ 1.0 px safety margin (per G3.7 step 5; rasterization noise)
= threshold 2.05 px
```

The threshold-setting stroke is **Ä s0 at 1.05 px**. Next runners-up
are A s2 (0.89), p s0 (0.89), U s1 (0.76). Pure A strokes are all
under 0.89 px.

The Ä base diagonal (s0) deviates more than the pure A diagonals —
consistent with the calibrator-authored variation in Ä's base (see
the Borderline classifications section above for the misattribution
correction). The threshold of 2.05
px is therefore set higher than it would have been on a pure-A-only
corpus (which would put the threshold around 1.89 px based on A s2's
0.89 max + 1 px margin). **This is the correct behavior — the corpus
contains Ä, so Ä's geometry contributes.**

Bbox-fractions for all STRAIGHT strokes are below 0.002 (well under
0.2% of the bbox dimension). The threshold value of 2.05 px on a 1024²
mask corresponds to ~0.002 bbox-fraction maximum.

## What stays

The G3 implementation is enforced (CI wiring pending G5):

- `scripts/audit_invariants.py::gate_g3_per_stroke` and `::gate_g3`
- `_perpendicular_deviation` (LSQ via SVD), `_stroke_angle_stats`
  (max + p95)
- Constants: `G3_RESAMPLE_N=100`, `G3_MIN_MEASURED=10`,
  `G3_ENDPOINT_SKIP=3`, `G3_STRAIGHTNESS_MAX_ANGLE=π/12`,
  `G3_STRAIGHTNESS_P95_ANGLE=0.1`, `G3_PERCENTILE=95`
- `scripts/run_gates.py --gate g3` routing via `GATE_METADATA`
- `scripts/tests/test_gate_g3.py` (11 unit tests)
- `scripts/calibrate_g3_threshold.py` (this calibration driver,
  preserved for future re-runs)

**Threshold of record: 2.05 px on the 1024² mask.** Recorded in
`docs/BAKE_INVARIANTS.md` §2 Threshold 3.

## Methodology-chapter content

This is the first conformance gate to ship (upper-bound deviation
≤ threshold), contrasting with G1's drift-gate shape (lower-bound
Pearson ≥ threshold). The drift/conformance taxonomy in
`g3_design.md` G3 "two gate shapes in the family" holds in practice:
both serve the same freeze-gate purpose; they differ in the metric
direction and the polish-preservation criterion that makes them
viable.

G2's negative result and G3's positive result together support the
load-bearing claim from G2's findings doc: **a freeze-gate metric
must measure a quantity that maintainer-approved edits do not
change.** G3 (perpendicular deviation from best-fit line on straight
strokes) satisfies this — polish refines centerline position but
doesn't introduce wobble. G2 (turn-angle profile) does not — polish
actively redistributes curvature. Choice of metric must match the
gate's purpose; this is an empirically-verifiable criterion before
threshold derivation, not a post-hoc rationalization.

The classifier's reliance on an empirically-derived p95 boundary
(0.1 rad sitting in a 0.014-wide gap) is documented as a maintenance
hazard in `g3_design.md` G3.1 "Caveat caught during implementation"
and in the Borderline classifications section above. Future corpus
expansion could land strokes in this gap and force re-derivation.
This is honest about the empirical-not-first-principles nature of
the criterion.

## Files referenced

- Corpus: `research_data/calibration_sessions/2026-05-22/*/<timestamp>.json`
- Reference: `PrimaeNative/Resources/Letters/Regular/<letter>/strokes.json`
  at HEAD `3c890380`
- Script: `scripts/calibrate_g3_threshold.py`
- Gate implementation: `scripts/audit_invariants.py::gate_g3` and
  `gate_g3_per_stroke`
- Design: `research_data/phase2b_gates/g3_design.md`
- Spec: `docs/BAKE_INVARIANTS.md` §2 Threshold 3 (updated in this
  commit with the derived threshold)

---

## Post-deployment refinement (2026-05-24)

G5 verification (PR #1) deployed G3 to run against all 59 letters
on every PR, not just the 13-letter calibration corpus. The
verification PR's deliberate A violation was caught correctly, but
the run also flagged three previously-unmeasured pre-existing
strokes in the shipped corpus:

- Y s0 (deviation 24.05 px) — left-arm-through-vertex L-curve
- Y s1 (deviation 25.57 px) — right-arm-through-vertex L-curve
- g s1 (deviation 69.59 px) — bowl + descender as one continuous stroke

Visual rendering confirmed these are correctly-drawn smooth-curve
polylines, not bake artifacts. The G3 max+p95 straightness
classifier was admitting them as STRAIGHT because their per-
segment angles fall under both thresholds (smooth curves at
N=100 resample have small per-segment angles), but their
cumulative net direction change is substantial.

**Classifier refinement (see `g3_design.md` G3.1 "Refinement
caught during G5 verification" subsection):** added a third
criterion to the straightness check:

```
|signed_cumulative_angle| < G3_STRAIGHTNESS_SIGNED_CUM_RAD = π/12
```

Empirically derived from a full-corpus signed-cumulative sweep on
2026-05-24. The 22.9°-wide gap between the last well-behaved
STRAIGHT stroke (ä s1 at 4.7°) and the first offender (Y s1 at
27.6°) places the cutoff unambiguously; π/12 sits in the middle
of the gap. After the refinement: Y s0, Y s1, g s1 correctly
vacuous as not-straight; G3 doesn't apply to them.

**Calibration corpus check post-refinement.** All 8 STRAIGHT-
classified strokes in the 2026-05-22 calibration corpus have
`|signed_cum| ≤ 0.023 rad` (1.3°) — well under the new π/12
threshold. They remain STRAIGHT after the refinement; no
re-measurement of their deviations needed.

**Threshold of record stays at 2.05 px.** Y/g were previously
wrongly admitted; they're now correctly out-of-scope. The
deviation threshold derived from the calibration corpus is
unaffected.

**Methodology continuity.** This is the fifth instance of
design-prediction-meets-data in Phase 2b Track B (after G2's
calibration falsification, G3's max-only-classifier
falsification, G4's design pivot, and G4's mid-stroke-attachment
scope discovery). Predicted max+p95 was adequate for the full
corpus; G5 deployment-to-all-letters falsified the prediction;
refined criterion derived from data. The
"predict explicitly, verify empirically, refine when data
falsifies" methodology now has five trail markers.
