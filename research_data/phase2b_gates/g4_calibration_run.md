# G4 calibration findings — 2026-05-23

**Corpus state SHA at calibration run:** `108c8d47` (G4
implementation commit; the calibration ran against this corpus state,
this findings doc lands together with BAKE_INVARIANTS.md update in
the next commit).
**Calibration data:** `research_data/calibration_sessions/2026-05-22/`
(13 letters with session pairs).
**Script:** `scripts/calibrate_g4_threshold.py`.
**Outcome:** **Threshold = 4.43°. Polish-preservation verified.
Implementation enforced (CI wiring pending G5). Scope constraint
documented: G4 covers end-to-end junctions only; mid-stroke
attachment junctions are out of scope.**

## Framing

G4 is the **third metric shape** in the Phase 2b Track B family — a
drift gate on a per-junction property. Distinct from:
- G1 / G2: drift gates on per-stroke properties (Pearson against
  reference)
- G3: conformance gate on a per-stroke property (deviation ≤
  threshold)

G4's metric is the per-junction kink (outgoing-vs-outgoing tangent
angle, expressed as `|180° − angle|`); the gate measures the
absolute drift between candidate and reference kinks. See
`g4_design.md` "Diagnostic finding" section for the pre-
implementation design pivot from conformance-on-smooth-junctions to
drift-on-all-junctions.

The 2026-05-22 session-pair corpus serves all four gate
calibrations. For G4, each consecutive stroke pair (i, i+1) in each
letter is run through `gate_g4_per_junction(round1, round2, ...)`
with threshold=∞ so the result reports actual drift values rather
than pass/fail.

## Per-junction calibration table

5 detected junctions across 13 letters (`no_pairs` and
`no_junctions_detected` letters reported in the letter-level rollup):

| Letter | i | j | pairing | dist_r1 | dist_r2 | kink_r1 | kink_r2 | drift | edits |
|---|---:|---:|---|---:|---:|---:|---:|---:|---:|
| A | 0 | 1 | last/last | 4.88 | 4.14 | 143.46° | 142.42° | **1.04°** | 3 |
| D | 0 | 1 | first/first | 0.00 | 0.00 | 76.13° | 78.56° | **2.43°** | 3 |
| U | 0 | 1 | last/first | 0.00 | 0.00 | 178.82° | 178.63° | **0.20°** | 1 |
| Ä | 0 | 1 | first/first | 3.45 | 3.45 | 142.85° | 142.85° | **0.00°** | 2 |
| Ü | 0 | 1 | last/first | 0.00 | 0.00 | 176.79° | 176.79° | **0.00°** | 8 |

All five junctions show drift ≤ 2.5°, with the max at D (2.43°) and
two junctions at exactly 0.00° (Ä, Ü — kink completely preserved by
polish).

## Letter-level rollup

| Category | Count | Letters |
|---|---:|---|
| Letters with detected junctions | 5 | A, D, U, Ä, Ü |
| `no_pairs` (single-stroke) | 7 | N, W, b, l, m, v, Ö |
| `no_junctions_detected` (flag) | 1 | p |
| `junction_detection_mismatch_between_rounds` | 0 | — |

`Ö` appears as `no_pairs` because its earliest session JSON
(2026-05-22) captured Ö with 1 stroke (base only, before dots were
added in batch 2). With round-1 having a single stroke, `n_pairs <
2` and the letter classifies as `no_pairs` at the round-1
comparison. This is expected behavior given the corpus structure;
the HEAD Ö has 3 strokes but the calibration uses `min(round1,
round2) = 1`.

(This is a corpus-state artifact, not a structural finding: Ö's
HEAD strokes.json has 3 strokes; round-1's session capture predated
the dot-addition. Future calibration runs against a corpus with
both rounds at HEAD-equivalent stroke counts would gate Ö's
base-dot junctions if any exist. Not a flag.)

## Discovered scope constraint — mid-stroke attachment junctions

Calibration surfaced a 4th cause beyond the design's anticipated
three (`no_junction`, `junction_detection_mismatch_between_rounds`,
`insufficient_measured_points`): **mid-stroke attachment junctions.**

Lowercase **p** in Primae has stroke 1 (the bowl) attaching at a
non-endpoint of stroke 0 (the stem) — specifically, the bowl's first
cp lies at y=0.33 bbox-rel, ON the stem's centerline mid-stroke. The
four endpoint-pairing distances for p (s0, s1) are 144–305 px apart
in both rounds. p has no end-to-end junction in the geometric sense
G4 measures, even though it has a structural junction in the
pedagogical sense (the bowl is attached to the stem; the pen lifts
between the two strokes during writing).

G4's scope is end-to-end junctions per BAKE_INVARIANTS Rule 4
("For consecutive stroke pairs flagged end-to-end"). Mid-stroke
attachment junctions (T-attachments in the structural sense where
one stroke endpoint lies in another stroke's interior) are a
different geometric class outside G4's scope. **p correctly
classifies as `no_junctions_detected`.**

**Future work:** a separate gate could measure mid-stroke attachment
quality (e.g., perpendicular distance from the attaching stroke's
endpoint to the host stroke's medial axis, with a tolerance for
measurement noise). Not in Phase 2b Track B scope; flagged for
methodology-chapter discussion or future Phase 2c work.

## Polish-preservation verification

The drift metric `kink_drift_deg = |kink_round2 − kink_round1|`
measures how much polish moved the junction's geometric kink between
rounds. The prediction in `g4_design.md` G4'.4: junction kink is
polish-stable; David's polish refines surrounding stroke geometry
without rotating the junction itself.

Results across the 5 detected end-to-end junctions:

```
kink_drift_deg distribution:
  min:    0.000°
  median: 0.195°
  max:    2.425°  (D s0-s1)

n where drift = 0.000° (kink unchanged): 2 (Ä, Ü)
n where drift > 0.000°:                   3
  U s0-s1: 0.195°  (negligible; point-meeting kink ~179°)
  A s0-s1: 1.039°  (small; apex kink ~143°)
  D s0-s1: 2.425°  (largest; T-corner kink 76°→79°)
```

**Polish-preservation HOLDS spectacularly.** All 5 junctions show
drift ≤ 2.5°. Median 0.2°. Two junctions at exactly 0.00° (Ä, Ü).
The largest drift (D at 2.43°) represents David's polish refining
the T-corner angle by ~2.4° between rounds — well within
polish-preserved behavior. **No soft-V trigger.**

The pattern matches the design prediction: junctions are designed
structural features. David's polish doesn't rotate them; it refines
the surrounding stroke geometry.

## Round-1 kink sanity check

Round-1 kink values (76.13°, 142.85°, 143.46°, 176.79°, 178.82°)
cluster identically to round-2 (78.56°, 142.85°, 142.42°, 176.79°,
178.63°). All five are in the 76–179° range. The three geometric
classes from the pre-implementation diagnostic (T-corner ~80°, apex
~143°, point-meeting ~178°) hold consistently across rounds. The
metric is round-stable.

## Threshold derivation

```
max(per-junction kink_drift_deg) = 2.425° at D s0-s1
+ 2.0° safety margin (LSQ + resample noise floor)
= threshold 4.43°
```

The threshold-setting junction is **D s0-s1 at 2.43°.** Margin per
`g4_design.md` G4'.5: 2.0° accounts for LSQ-tangent fit uncertainty
on 5 cps + arc-length-resample noise. Self-comparison (G4 with
candidate = reference = HEAD) returns drift = 0.00° across all
junctions, so the 2° margin reflects gate-time PR-vs-HEAD
measurement noise rather than corpus noise.

**Threshold of record: 4.43°** (4.4247 to 4 decimals).

## Sanity check against G4'.5 predictions

- **Polish-preservation holds:** ✓ All 5 junctions ≤ 2.5° drift,
  median 0.2°.
- **Threshold in predicted 1-3° margin range:** ✓ 2.0° margin
  produces 4.43° threshold.
- **No soft-V trigger:** ✓ Max drift 2.43° far below the 30°
  soft-V boundary.
- **No round-1 anomalies:** ✓ Kink values cluster identically to
  round-2.

## What stays

The G4 implementation is enforced (CI wiring pending G5):
- `scripts/audit_invariants.py::gate_g4_per_junction` and `::gate_g4`
- `_stroke_tangent_at_endpoint`, `_kink_deg`, `_detect_junctions`
- Constants: `G4_RESAMPLE_N=100`, `G4_ENDPOINT_SKIP=3`,
  `G4_TANGENT_WINDOW=5`, `G4_JUNCTION_EPSILON_PX=15.0`,
  `G4_DEFAULT_THRESHOLD_DEG=4.43`
- `scripts/run_gates.py --gate g4` routing via `GATE_METADATA`
- `scripts/tests/test_gate_g4.py` (15 unit tests)
- `scripts/calibrate_g4_threshold.py` (calibration driver,
  preserved for future re-runs)

**Threshold of record: 4.43°.** Recorded in `docs/BAKE_INVARIANTS.md`
§2 Threshold 4.

## Methodology-chapter content

Phase 2b Track B's gate development has now produced **four
instances of design-prediction-meets-data**:

- **G2:** predicted turn-angle would be polish-stable; calibration
  falsified the prediction; soft-V outcome.
- **G3 classifier:** predicted max-only criterion adequate;
  implementation falsified; redesigned with combined max+p95.
- **G4 design:** predicted smooth pen-continuation class existed;
  pre-implementation diagnostic falsified; redesigned as drift gate.
- **G4 scope:** predicted all consecutive-pair junctions are
  end-to-end; calibration's p finding refined this to "most are
  end-to-end; mid-stroke attachments exist as a separate class
  outside G4's scope."

The **empirical-prediction-then-verification methodology** is now
load-bearing across the gate set. Each gate's calibration surfaces
what the design got right AND what the design got wrong; the gate
set is honest about its scope rather than papering over edge cases.

This pattern is substantial enough for its own methodology-chapter
section in the thesis. The four-instance trail is the empirical
evidence that the methodology — predict explicitly, verify
empirically, refine when data falsifies — works as intended. The
corrections are caught because the process was designed to surface
them, not because the design space happens to be self-correcting.

## Files referenced

- Corpus: `research_data/calibration_sessions/2026-05-22/*/<timestamp>.json`
- Reference: `PrimaeNative/Resources/Letters/Regular/<letter>/strokes.json`
  at HEAD `108c8d47`
- Script: `scripts/calibrate_g4_threshold.py`
- Gate implementation: `scripts/audit_invariants.py::gate_g4` and
  `gate_g4_per_junction`
- Design: `research_data/phase2b_gates/g4_design.md`
- Spec: `docs/BAKE_INVARIANTS.md` §2 Threshold 4 (updated in this
  commit with the derived threshold)
