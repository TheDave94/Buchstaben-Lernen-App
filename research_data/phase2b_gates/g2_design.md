# G2 — Threshold 2 (Turn-angle-profile drift from reference) — Design Proposal

**Spec ref:** `docs/BAKE_INVARIANTS.md` §2 Threshold 2.
**Inherits from:** `g1_design.md` (freeze-gate framing; arc-length resample;
per-stroke Pearson; letter-pass-iff-all-strokes-pass; vacuous-pass conditions;
calibration against 2026-05-22 session-pair corpus; no safety margin).
**Status:** design only. No code yet; awaits David approval / redlines.

This doc covers ONLY the G2-specific design questions. Anything inherited
from G1 is referenced rather than restated.

---

## Corpus context (inherited from G1)

All 59 letters of Druckschrift Regular ship as hand-calibrated static
artifacts (commit `6a85811c`). G2 is a freeze gate against HEAD's
`strokes.json` files. Calibration data is the same 2026-05-22 session-pair
corpus (13 letters with captured edit pairs).

See `g1_design.md` Section "Corpus context" for the full framing.

---

## What's the same as G1

These design decisions are inherited from G1 without re-derivation:

| Aspect | G1 decision | G2 decision |
|---|---|---|
| Per-stroke vs whole-letter | Per-stroke Pearson, letter pass = all | Same |
| Arc-length resampling | Both polylines to N=100 before computing the metric | Same |
| 1-cp diacritic dots | Vacuous pass with `reason="not_applicable_too_short"` | Same |
| `n_measured < 10` | Vacuous pass with `reason="insufficient_measured_points"` | Same |
| Reference lookup | `HEAD:Letters/Regular/<L>/strokes.json` (or `--reference-ref`) | Same |
| CLI integration | `scripts/run_gates.py --gate g1` | Add `--gate g2` |
| Output format | Stdout default; `--json` flag for CI | Same |
| Calibration corpus | 2026-05-22 session pairs | Same |
| Threshold derivation | `min(real Pearson)` across non-vacuous strokes; no safety margin | Same |
| Result doc | `research_data/phase2b_gates/g1_calibration_run.md` | Add `g2_calibration_run.md` |

---

## What's different — G2-specific design

### G2.1 — Turn-angle definition

**Recommendation: signed angle between successive segment vectors, in
radians.**

For a polyline resampled to N points, at index `i` (where `1 ≤ i ≤ N-2`):

```
segment_in  = p[i]   - p[i-1]
segment_out = p[i+1] - p[i]
turn_angle  = signed_angle_from(segment_in, segment_out)
```

Range: `[-π, π]`. Positive = left turn (CCW), negative = right turn (CW).

| Alternative | Rejected because |
|---|---|
| Unsigned angle magnitude | Loses chirality — a polyline mirrored along its axis would give identical Pearson. Reference polylines have specific handedness. |
| Curvature (angle / arc-length) | After arc-length-uniform resampling, segment lengths are constant within a stroke. Curvature = angle / constant → proportional to angle → Pearson is invariant. So they're equivalent under our resampling. Pick the simpler primitive. |
| Cumulative turn-angle (running sum) | Drifts; small errors compound. Per-segment is independent and cleaner. |

**Code-site invariant (per David's Q1 redline).** At the atan2 call site
in `_turn_angle_per_point`, an explicit comment must state:

> "Signed angle convention: positive = CCW turn (left), negative = CW turn
> (right), computed as atan2(cross, dot). The Pearson comparison is only
> valid if BOTH candidate and reference use the same sign convention. Do
> not refactor to a y-flip variant without updating the calibration data,
> since flipped polylines would compare differently."

The convention matters because the calibration measures *what is*, not
*what should be*: any sign flip silently changes what "drift from
reference" means.

### G2.2 — Resample N

**Recommendation: N=100, same as G1.**

Turn-angle is more sensitive to resample density than asymmetry — coarser
sampling produces larger per-segment angles for the same curve. But since
we resample BOTH candidate and reference to the same N at the same
arc-length positions, the angles are comparable index-to-index and Pearson
is what matters, not absolute angle magnitudes.

Consistency with G1 is the tiebreaker: same constant, same resample call,
shared `_arc_length_resample` helper.

If empirical evidence during calibration suggests N=100 is too coarse
(e.g., turn-angle Pearson is dominated by quantization at sharp peaks),
the constant can be revisited per-gate. Not pre-emptively.

**Resample-validation diagnostic (per David's Q2 redline).**
`calibrate_g2_threshold.py` reports `max(|turn_angle|)` per stroke
alongside Pearson + std + edit_count. Decision rule:
- If max(|angle|) stays below ~π/4 (45°) throughout the corpus → N=100
  is empirically validated; no resample-density artifacts.
- If max(|angle|) clusters near π/2 (90°) or π (180°) for real-polish
  strokes → resample is undersampling sharp peaks. Surface and investigate
  before threshold derivation.

### G2.3 — Endpoint handling

**Recommendation: mirror G1's `T1_ENDPOINT_SKIP = 3`, as `G2_ENDPOINT_SKIP = 3`.**

Turn-angle is mathematically undefined at the first and last cp (no
preceding/succeeding segment). That alone justifies skipping ≥ 1 from
each end.

But the deeper reason for G1's skip-3 is junction contamination: the cps
near a stroke's polyline endpoints are at T-junctions or shared-apex
meetings, where the polyline direction is dominated by junction geometry
rather than the natural stroke trajectory. That concern applies equally
to G2 — junction-snap dominates the turn-angle at endpoint-adjacent cps
the same way it dominates the tangent at those cps for G1.

Same constant value (3), separate name for layer-of-abstraction reasons
(G2's gate could in principle tune independently).

### G2.4 — Low-variance turn-angle filter

**Recommendation: yes, mirror G1's `low_variance_asymmetry` filter as a
sibling `low_variance_turn_angle`.** The empirical cutoff is determined
during calibration.

The same noise-floor problem applies. Letters with all-straight strokes
(I, l, the vertical stems of T E F H L K k Y) have turn-angle sequences
of ≈ 0 everywhere with sub-pixel jitter dominating the variance. Pearson
on two near-zero noisy sequences is meaningless.

**Letters likely to hit this filter at G2:**

- **All-uniform-stem letters:** l, I (entire letter is one straight
  stroke)
- **Letters with a straight stroke as one component:** T (crossbar + stem),
  E F (verticals + horizontals), H (3 strokes, all straight), L (vertical
  + horizontal), the stems of K k X x R b d p q
- **The straight component of mixed-shape letters:** D s0 (stem),
  P s0 (stem), B vertical, etc.

Predict G2 will vacuous-pass MORE strokes than G1. That's expected and
correct: G2's role is to catch turn-angle drift specifically. Letters with
no turn-angle to drift in don't contribute to or constrain the gate.

The cutoff value is open until calibration measures the distribution.
G1's value (`G1_MIN_ASYMMETRY_STD = 0.05`) was derived from empirical
gap-finding between noise-case and real-polish-case stds; G2 needs the
same gap-finding against the turn-angle distribution. **Units: radians**
(vs G1's unitless ratio).

Predicted cutoff range: **0.01–0.10 rad** of std, pending measurement.

**Gap-width escalation (per David's Q4 redline).** If the gap between
noise-case and real-polish-case stds is narrow (<0.005 rad), surface and
discuss before picking a value — same escalation path as G1's std=0.05
derivation, where a narrow gap means the cutoff choice is load-bearing
and should not be picked unilaterally.

Constant name: `G2_MIN_TURN_ANGLE_STD`, value TBD post-calibration.

### G2.5 — Mask requirement

**G2 does not need a mask.** Turn-angle is a pure polyline property; no
perpendicular walks, no ink-boundary measurements. So `gate_g2_per_stroke`
takes `(candidate_poly_rel, reference_poly_rel, bbox, threshold)` —
dropping the mask argument that G1 needs.

Implication: `gate_g2` doesn't call `build_per_stroke_masks`. Lighter
weight. The per-stroke iteration still happens (one Pearson per stroke
pair) but no mask partition.

Side benefit: G2 can run faster than G1 (no DT, no perpendicular walks).

### G2.6 — Implementation outline

New code in `scripts/audit_invariants.py`:

```
# Constants
G2_RESAMPLE_N = 100
G2_MIN_MEASURED = 10
G2_ENDPOINT_SKIP = 3
G2_MIN_TURN_ANGLE_STD = <TBD post-calibration>

# Primitive: per-point turn-angle on a px-space polyline.
def _turn_angle_per_point(poly_px, endpoint_skip=G2_ENDPOINT_SKIP)
    -> list[(angle, ok)]:
    # for i in [endpoint_skip, n - endpoint_skip):
    #   segment_in  = poly_px[i]   - poly_px[i-1]
    #   segment_out = poly_px[i+1] - poly_px[i]
    #   if either segment has near-zero length: (0.0, False)
    #   angle = signed angle (atan2(cross, dot)) between in and out
    # Returns same shape as _asymmetry_per_point for symmetry.

# Per-stroke gate function.
def gate_g2_per_stroke(candidate_poly_rel, reference_poly_rel, bbox,
                       threshold, n_resample=G2_RESAMPLE_N,
                       n_min_measured=G2_MIN_MEASURED) -> dict:
    # 1. <2 cp → vacuous (not_applicable_too_short)
    # 2. Resample both to n_resample; convert to px via bbox.
    #    (Resample the POLYLINE first, then compute angles on the
    #     resampled polyline — invariant identical to G1's comment.)
    # 3. _turn_angle_per_point on each; pair where both ok=True.
    # 4. n_measured < n_min → vacuous (insufficient_measured_points)
    # 5. max(cand_std, ref_std) < G2_MIN_TURN_ANGLE_STD → vacuous
    #    (low_variance_turn_angle)
    # 6. either std < 1e-12 → vacuous (constant_turn_angle_sequence)
    # 7. Pearson via np.corrcoef.
    # 8. Return same shape as gate_g1_per_stroke output.

# Letter-level aggregator.
def gate_g2(candidate_strokes_rel, reference_strokes_rel, bbox,
            threshold) -> dict:
    # Iterate strokes, call gate_g2_per_stroke per pair,
    # letter pass = all paired strokes pass.
    # No per-stroke mask building.
```

Approx LoC: ~110 added to `audit_invariants.py`.

**`scripts/run_gates.py`** — refactor to a `GATE_METADATA` table (per
David's Q6 addition) so G3/G4/G5 are mechanical to add:

```
GATE_METADATA = {
    "g1": {"function": gate_g1, "needs_mask": True,
           "title": "asymmetry-profile drift from reference"},
    "g2": {"function": gate_g2, "needs_mask": False,
           "title": "turn-angle-profile drift from reference"},
}

# Main loop:
meta = GATE_METADATA[args.gate]
# Per letter: rasterize → bbox → (mask if needs_mask) → call meta["function"]
```

Mask building lifts out of the per-gate branch into a conditional based
on `needs_mask`. Adding G3 (`needs_mask=True`) or G4 (`needs_mask=False`)
becomes a single-entry table addition. ~20 LoC refactor of existing
`run_g1_for_letter`; ~30 LoC for the `run_g2_for_letter`-equivalent
(but factored into the umbrella).

**`scripts/calibrate_g2_threshold.py`** — new file, near-clone of G1's:

```
# For each letter in 2026-05-22 corpus:
#   round-1 = earliest session pre_polyline
#   round-2 = HEAD strokes.json
#   per stroke: gate_g2_per_stroke(round1[i], round2[i], bbox, threshold=1.0)
# Print per-stroke table to stderr:
#   Pearson + cand_std + ref_std + max(|turn_angle|) + edit_count
# Print per-reason vacuous breakdown (per David's calibration-script addition):
#   vacuous: N total
#     low_variance_turn_angle:        X
#     not_applicable_too_short:       Y
#     insufficient_measured_points:   Z
# Print clean threshold = min(real Pearson) to stdout
```

~130 LoC (very similar to `calibrate_g1_threshold.py`, factoring out is
deferred until G3+ patterns clarify what's worth sharing).

**Also update `scripts/calibrate_g1_threshold.py`** to produce the
same per-reason vacuous breakdown (mechanical change, ~10 LoC). Both
gates' calibration scripts then produce comparable diagnostic output —
useful for comparing which vacuous-pass case dominates per gate (signals
whether the two gates measure orthogonal aspects of polish drift, as
predicted, or accidentally overlap).

**Unit tests** — add to `scripts/tests/test_gate_g1.py` (rename file or
add `test_gate_g2.py` — David's call; I'd vote add `test_gate_g2.py`):

- Pearson math sanity checks (already in test_gate_g1.py; can leave alone)
- 1-cp stroke → vacuous (not_applicable_too_short)
- Insufficient measured points → vacuous
- Low-variance turn-angle → vacuous (synthesize a straight polyline)
- Identical curved polyline → Pearson 1.0
- Mirror-reversed polyline → Pearson < 0 (chirality preserved)
- `_arc_length_resample` cases already covered

~80 LoC for `test_gate_g2.py`.

**`docs/BAKE_INVARIANTS.md`** Threshold 2 — replace `≥ TBD` with derived
value once calibration runs.

**Total new code:** ~340 LoC across 2 modified + 2 new files + 1 doc edit.

### G2.7 — Verification + Calibration

Same procedure as G1, condensed:

1. **Unit tests** pass locally.
2. **Self-comparison integration test:** run G2 with working tree =
   candidate = reference. Every (letter, stroke) should be Pearson = 1.0
   OR vacuous-pass with documented reason.
3. **Calibration run** against 2026-05-22 corpus. Surface the per-stroke
   table + derived threshold for David's review BEFORE committing.
4. **`G2_MIN_TURN_ANGLE_STD` cutoff** picked empirically from the
   calibration data, same gap-analysis pattern as G1. Surface before
   applying.

---

## Empirical predictions (to validate vs calibration)

These are surfaced for David to check his intuition before the calibration
runs. If results diverge wildly, that's a flag.

1. **More vacuous-pass cases than G1.** Straight-stroke letters (T E F H L
   strokes, vertical stems of compound letters) will likely hit
   `low_variance_turn_angle`. Expect ~half the calibration corpus to
   vacuous-pass, vs G1's ~25%.

2. **Threshold floor higher than G1's 0.2005.** Closed-bowl letters (b, p,
   D s1) had low G1 Pearson because asymmetry signal near the bowl-stem
   junction is intrinsically narrow. Turn-angle in the bowl region is
   richer (lots of curvature), so closed-bowl Pearson should be HIGHER for
   G2 than G1. Predict G2 floor lands at 0.5–0.8.

3. **Continuous-walk letters (M N W m v) will likely dominate the
   not-vacuous side of the table.** These have rich turn-angle variation
   at the interior peaks/valleys. Their G2 Pearson values will be the
   most discriminating signal for setting the threshold.

4. **Sanity-check predictions for A, W, m specifically:**
   - **A:** 3 straight strokes. Predict all 3 hit `low_variance_turn_angle`
     → A doesn't contribute to G2 threshold floor at all.
   - **W:** 1 continuous-walk stroke through 4 peaks/valleys. Predict
     Pearson 0.7–0.95 (rich signal, real polish drift).
   - **m:** continuous-walk like W but only 2-3 humps. Predict 0.7–0.95.

If post-calibration A's strokes are NOT vacuous, the cutoff is too low
and needs raising. If W's Pearson is < 0.5, the polish was substantial
enough to push G2 floor lower than predicted — interesting but expected
within the empirical spread.

**A's edge case (per David's Q5 flag).** Arc-length-uniform resampling
can introduce small angular bends along an otherwise-straight polyline
when the original cps weren't evenly spaced. If A's diagonals come back
with std in the **0.005–0.015 rad range** (borderline — above pure
sub-pixel noise, below real curvature), the cutoff choice becomes
load-bearing: a cutoff at 0.005 admits A's resample-artifact bends as
"real signal"; a cutoff at 0.015 excludes them.

If A's strokes land in this range, surface it specifically in the
calibration report and hold for David's call on the cutoff before
proceeding.

---

## Decisions summary (post-redline)

| Section | Decision | Alternative |
|---|---|---|
| **G2.1** | Signed angle between successive segments (atan2(cross, dot)) + defensive sign-convention comment at call site | Unsigned magnitude; curvature; cumulative |
| **G2.2** | N=100, mirror G1; `max(|turn_angle|)` reported in calibration as resample-validation diagnostic | Higher N pre-emptively |
| **G2.3** | `G2_ENDPOINT_SKIP = 3`, mirror G1; separate constant name | Smaller skip; reuse G1's constant |
| **G2.4** | Yes, add `low_variance_turn_angle` filter; cutoff empirical (units: radians); narrow-gap (<0.005 rad) escalates | No filter; calibration-time exclusion |
| **G2.5** | No mask needed; lighter gate signature | Carry mask for consistency |
| **G2.6** | New code in same `audit_invariants.py`; new `scripts/calibrate_g2_threshold.py` (with max-angle + per-reason vacuous breakdown); new `scripts/tests/test_gate_g2.py`; `run_gates.py` refactor to `GATE_METADATA` table | Per-gate file; reuse G1 test file; scattered branching |
| **G2.7** | Calibration ran; outcome not viable as freeze gate on current corpus (see Calibration outcome section + g2_calibration_run.md) | — |

---

## Approved

All five Y/N questions approved (2026-05-23) with five clarifying
additions:
1. Defensive sign-convention comment at atan2 call site (Q1).
2. `max(|turn_angle|)` resample-validation diagnostic in calibration
   script (Q2).
3. Narrow-gap (<0.005 rad) escalation path mirrors G1's std=0.05
   derivation (Q4).
4. A's-strokes edge case (std 0.005–0.015 rad range) gets explicit
   flag in the calibration report if it occurs (Q5).
5. `GATE_METADATA` table refactor in `run_gates.py` so G3/G4/G5 are
   mechanical additions; per-reason vacuous breakdown in both G1 and
   G2 calibration scripts for cross-gate diagnostic comparison (Q6).

Implementation lands next.

---

## Calibration outcome (2026-05-23)

Calibration ran against the 13-letter / 21-stroke 2026-05-22 session-pair
corpus. **Outcome: not viable as a freeze gate.** Implementation is
preserved; no threshold derived.

Summary of the finding:

- **Resample N=100 was confirmed adequate.** The G2.2 diagnostic
  (`max(|turn_angle|) > π/4 = undersampling`) was too coarse — it
  conflated real corner geometry with resample artifact. Direct
  measurement on raw HEAD cps confirmed W/m/N have legitimate
  ~100-125° vertices. N=200 sanity check showed finer resampling does
  not improve Pearson; it exposes more polish-induced decorrelation.

- **Three-class partition (STRAIGHT/SMOOTH/CORNER) does not discriminate.**
  SMOOTH class is degenerate (1 member). STRAIGHT class is heterogeneous
  (Pearson -0.04 to 1.0). CORNER class straddles both tight and
  polish-spread clusters.

- **Pearson distribution is bimodal:** 9 strokes at exactly 1.0
  (untouched-in-this-round, no signal), 12 strokes spread essentially
  uniformly from -0.04 to 0.99 with no internal cluster structure.

- **Structural reason:** G2 measures *where the curve bends along its
  length*. Polish edits actively redistribute where curves bend — David
  smooths sharp bends, moves inflection points, tightens/relaxes
  segments. The metric is intrinsically mismatched to the freeze-gate
  purpose. No threshold choice can resolve this.

**Decision: keep gate_g2 implementation; document the finding; do not
enforce.** Full data and analysis in
`research_data/phase2b_gates/g2_calibration_run.md`.

Future revisits could use either a much larger calibration corpus
(per-class thresholds) or a distribution-shift framing (Option IV);
neither is in scope for this round of Phase 2b Track B.

Concrete revisit triggers: (a) calibration corpus grows to 50+ session
pairs across more letters and stroke classes — at which point the
three-class partition could be re-attempted with adequate sample sizes;
(b) a separate gate proposal motivates distribution-shift detection
(Option IV) and G2's data becomes one component of that framework;
(c) a future polish pattern produces a noticeably different Pearson
distribution from this one, justifying re-measurement.
