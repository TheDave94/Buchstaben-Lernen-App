# G2 calibration findings — 2026-05-23

**Corpus state SHA at calibration run:** `a4bf2a75` (G2 implementation
commit; the calibration ran against this corpus state, this findings doc
lands together with BAKE_INVARIANTS.md update in the next commit).
**Calibration data:** `research_data/calibration_sessions/2026-05-22/`
(13 letters with session pairs).
**Script:** `scripts/calibrate_g2_threshold.py`.
**Outcome:** **Not viable as a freeze gate on current corpus. Implementation
preserved; threshold not derived.**

## Framing

G2 (turn-angle-profile drift) was designed to mirror G1's freeze-gate
shape: per-stroke Pearson of the candidate's turn-angle sequence against
the reference's, threshold = min(real Pearson) across the 2026-05-22
session-pair corpus, vacuous-pass on 1-cp dot strokes / insufficient
measured points / low-variance turn-angle. See `g2_design.md` for the
full design and approved redlines.

The calibration run revealed that turn-angle Pearson is intrinsically
polish-sensitive in a way G1's asymmetry Pearson is not. This findings
doc documents what was measured and why the freeze-gate framing doesn't
apply.

## Per-(letter, stroke) calibration table

Run at N=100, threshold=1.0, G2_MIN_TURN_ANGLE_STD=0.0 (filter off so
all values surface):

| Letter | Stroke | Pearson | cand_std | ref_std | max\|c\| | max\|r\| | edits | Class |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| A | 0 | 0.5075 | 0.0139 | 0.0143 | 0.037 | 0.039 | 3 | substantial |
| A | 1 | 0.0959 | 0.0079 | 0.0060 | 0.034 | 0.023 | 3 | substantial |
| A | 2 | 1.0000 | 0.0313 | 0.0313 | 0.102 | 0.102 | 3 | tight |
| D | 0 | 1.0000 | 0.0116 | 0.0116 | 0.028 | 0.028 | 3 | tight |
| D | 1 | 0.8896 | 0.0372 | 0.0364 | 0.154 | 0.143 | 3 | substantial |
| N | 0 | 0.9878 | 0.2661 | 0.2641 | 1.427 | 1.531 | 16 | moderate |
| U | 0 | 0.6016 | 0.0491 | 0.0452 | 0.219 | 0.186 | 1 | substantial |
| U | 1 | 1.0000 | 0.0093 | 0.0093 | 0.030 | 0.030 | 1 | tight |
| W | 0 | 0.9897 | 0.4080 | 0.3662 | 2.576 | 2.272 | 31 | moderate |
| b | 0 | 0.5291 | 0.0673 | 0.0558 | 0.312 | 0.209 | 4 | substantial |
| l | 0 | -0.0444 | 0.0956 | 0.0954 | 0.256 | 0.254 | 0 | substantial |
| m | 0 | 0.8334 | 0.3472 | 0.3686 | 1.915 | 2.394 | 3 | substantial |
| p | 0 | 1.0000 | 0.0108 | 0.0108 | 0.024 | 0.024 | 8 | tight |
| p | 1 | 0.3313 | 0.1525 | 0.0418 | 1.038 | 0.200 | 8 | substantial |
| v | 0 | 0.3072 | 0.1746 | 0.1429 | 1.674 | 1.222 | 17 | substantial |
| Ä | 0 | 1.0000 | 0.0390 | 0.0390 | 0.100 | 0.100 | 2 | tight |
| Ä | 1 | 1.0000 | 0.0583 | 0.0583 | 0.105 | 0.105 | 2 | tight |
| Ä | 2 | 1.0000 | 0.0400 | 0.0400 | 0.290 | 0.290 | 2 | tight |
| Ö | 0 | 1.0000 | 0.0366 | 0.0366 | 0.174 | 0.174 | 2 | tight |
| Ü | 0 | 1.0000 | 0.0444 | 0.0444 | 0.187 | 0.187 | 8 | tight |
| Ü | 1 | 1.0000 | 0.0249 | 0.0249 | 0.075 | 0.075 | 8 | tight |
| Ü | 2,3 | — | — | — | — | — | 8 | vacuous (1-cp dots) |

**Real Pearson values:** 21 (vacuous: 2, both 1-cp diacritic dots).

## Resample-validation diagnostic — N=100 confirmed adequate

The G2.2 design diagnostic flagged `max(|turn_angle|) = 2.576 rad
(147.6°)` on W stroke 0, suggesting N=100 might be undersampling. Two
follow-up checks ruled this out.

### Check A — Raw turn-angle on unresampled HEAD cps

For each of W/m/N/v/p s1, computed turn-angle directly on the original
strokes.json checkpoints (no resampling):

| Letter | n_cp | max\|angle\| raw | max\|angle\| N=100 | Δ |
|---|---:|---:|---:|---:|
| W s0 | 200 | 2.034 rad (116.5°) | 2.272 rad | +0.24 |
| m s0 | 104 | 2.191 rad (125.5°) | 2.394 rad | +0.20 |
| N s0 | 200 | 1.775 rad (101.7°) | 1.531 rad | -0.24 |
| v s0 | 200 | 0.850 rad (48.7°) | 1.222 rad | +0.37 |
| p s1 | 64 | 0.201 rad (11.5°) | 0.200 rad | -0.00 |

W/m/N have legitimate ~100-125° corners by design (the natural vertices
the pen passes through at the bottom of W, between m's humps, at N's
diagonal-to-vertical transition). The N=100 readings are faithful, not
artifacts. Only v shows meaningful inflation (49° → 70°), and not enough
to invalidate N=100 by itself.

**The π/4 threshold proposed in the G2.2 diagnostic was too coarse.** It
conflated real corner geometry with resampling artifact. The diagnostic
should be retired in favor of the direct check on raw cps.

### Check B — N=100 vs N=200 Pearson

| Stroke | N=100 | N=200 | Δ |
|---|---:|---:|---:|
| A s0 | 0.5075 | 0.5456 | +0.04 |
| A s1 | 0.0959 | 0.1831 | +0.09 |
| U s0 | 0.6016 | 0.0189 | **-0.58** |
| p s1 | 0.3313 | 0.1077 | **-0.22** |
| v s0 | 0.3072 | 0.0826 | **-0.22** |
| b s0 | 0.5291 | 0.3073 | **-0.22** |
| l s0 | -0.0444 | 0.0859 | +0.13 |
| D s1 | 0.8896 | 0.9297 | +0.04 |

Finer resampling does NOT consistently improve Pearson. For multiple
low-Pearson cases (U, p, v, b), N=200 makes them substantially WORSE.
Higher-resolution sampling EXPOSES more fine-grained polish drift,
decorrelating the sequences further. N=100 is honest; the distribution
shape is signal, not noise.

## Three-class partition — does not discriminate

Per Option III framing, attempted to partition strokes by max\|ref\|
turn-angle into STRAIGHT (< π/12, 15°), SMOOTH ([π/12, π/3), 15°–60°),
CORNER (≥ π/3, 60°):

| Class | N | min P | median P | max P |
|---|---:|---:|---:|---:|
| STRAIGHT | 16 | -0.0444 | 1.0000 | 1.0000 |
| SMOOTH | 1 | 1.0000 | 1.0000 | 1.0000 |
| CORNER | 4 | 0.3072 | 0.9106 | 0.9897 |

**Problems:**
- **SMOOTH class is degenerate** (1 member: Ä s2). Arc-length
  resampling makes per-segment angles tiny for smoothly curved strokes;
  the middle class barely exists.
- **STRAIGHT class is heterogeneous** (Pearson -0.04 to 1.0). 8 strokes
  at 1.0 (untouched-in-this-round); 8 at 0.10–0.89 (real polish drift).
  Geometric class doesn't separate untouched from polished.
- **CORNER class straddles both clusters.** v0 sits at 0.31; W/N/m at
  0.83–0.99. v's max\|ref\| is right at the π/3 boundary.

Per-class thresholds wouldn't work given the small samples and
within-class spread.

## Distribution analysis — bimodal, no usable cluster structure

Sorted Pearson values (across all classes):

```
-0.0444  l0    edits=0       (anti-correlated; uniform stem)
 0.0959  A1    edits=3       (substantive polish on diagonal)
 0.3072  v0    edits=17      (substantive polish, sharp corner)
 0.3313  p1    edits=8       (closed-bowl polish)
 0.5075  A0    edits=3       (polish on left diagonal)
 0.5291  b0    edits=4       (closed-bowl polish)
 0.6016  U0    edits=1       (light polish on left half)
 0.8334  m0    edits=3       (preserved corner positions)
 0.8896  D1    edits=3       (bowl polish with stable curvature peaks)
 0.9878  N0    edits=16      (corners preserved)
 0.9897  W0    edits=31      (corners preserved)
 1.0000  ×9    untouched strokes across all 3 geometric classes
```

Two clusters:
- **Tight cluster:** 9 strokes at Pearson exactly 1.0. These are strokes
  that weren't part of David's polish in that session (e.g., A s2 = the
  crossbar of A, while polish was on the diagonals; Ä bases unchanged
  in batch 1, while batch 2 added dots). No signal — these strokes
  weren't measured against polish drift, just against themselves.
- **Polish-spread cluster:** 12 strokes spread essentially uniformly
  from -0.04 to 0.99. No clusters within this group. Pearson is loosely
  correlated to edit substantiveness but only loosely (v0 has 17 edits,
  Pearson 0.31; W0 has 31 edits, Pearson 0.99).

## Why the polish-spread cluster has no structure

G2 measures **where the curve bends along its length** (the per-segment
signed turn-angle sequence). Polish edits **actively redistribute** where
curves bend along their length — David smooths a sharp bend into a
gradual one, or moves the inflection point earlier along the arc, or
tightens a curve in one segment while relaxing another.

This is fundamentally different from G1's asymmetry-profile measurement,
which captures the centerline's LOCATION relative to the ink edges
locally. Centerline location is a property that polish typically
preserves (David's polish keeps the centerline equidistant from the ink
edges, just shifts the shape along the arc). Curvature direction along
arc length is a property polish actively edits.

**Three tendencies observed in the polish-spread (each based on small
samples; future calibration could test whether these are reliable
patterns or coincidence):**

1. **Corner-preserving polish (high Pearson).** N, W, M-family strokes
   have sharp natural corners at consistent positions. David's polish
   refines the entry/exit segments around the corner but doesn't move
   the corner itself. The corners anchor the sequence; Pearson stays
   high (0.83–0.99).
2. **Smooth-curve polish (low Pearson).** Bowls, descenders, smooth
   diagonals have continuous curvature distributed along the arc.
   David's polish shifts where the curve is sharpest. The angle
   sequence decorrelates substantially (Pearson 0.10–0.60).
3. **Anti-correlated polish (l0).** Uniform stems have near-zero
   turn-angles. Sub-pixel position differences between round-1 and
   round-2 produce noise-dominated angle sequences that can be
   negatively correlated.

There is no Pearson value below which "all polish in the corpus is
above" — polish itself produces the full range.

## Outcome — metric measures real signal but mismatches freeze-gate purpose

The G2 metric measures what it was designed to measure (turn-angle
Pearson is a faithful signal of curvature redistribution along arc
length). What the calibration revealed is that maintainer-approved
polish edits *intentionally* redistribute curvature along arc length,
making this metric an unsuitable basis for a freeze gate against
polish-comparable drift.

A freeze-gate threshold is defensible only if it sits BELOW all "real
polish" Pearson values (so polish-similar PRs pass) and ABOVE
"catastrophic regression" Pearson values (so genuine drift fails). The
calibration data shows real polish ranges from -0.04 to 0.99 with no
gap — there is no defensible threshold.

The alternatives considered:

| Option | Threshold | Why rejected |
|---|---|---|
| I — Percentile (5th percentile of polish-spread) | ≈ 0.10 | Statistically arbitrary on a 12-sample distribution. Would catch l0 + A1 only; misses substantive polish on closed bowls / smooth curves / sharp corners. False reassurance. |
| II — Negative threshold (~-0.2) | -0.2 | Catches NOTHING in the corpus. G2 becomes a polyline-corruption-only guard — duplicates what file-integrity checks already do. |
| III — Per-class thresholds | varies by class | Three-class partition does not discriminate (above). Insufficient samples per class to derive distinct thresholds. |
| IV — Distribution-shift detection | n/a per-stroke | Requires statistical test (KS or similar) on PR-vs-corpus distribution. 12 polish samples insufficient as a baseline; this approach needs a much larger corpus. Out of scope for a per-stroke gate. |

**Decision: Option V — keep G2 implementation, do not derive a
threshold.** Document the finding here; future revisits can use this
calibration as a starting point.

## What stays

The following G2 code is preserved for future use:

- `scripts/audit_invariants.py::gate_g2_per_stroke` and `::gate_g2`
- `_turn_angle_per_point` primitive
- `G2_RESAMPLE_N`, `G2_MIN_MEASURED`, `G2_ENDPOINT_SKIP`,
  `G2_MIN_TURN_ANGLE_STD` (placeholder 0.0) constants
- `scripts/run_gates.py --gate g2` routing via GATE_METADATA
- `scripts/tests/test_gate_g2.py` (9 unit tests)
- `scripts/calibrate_g2_threshold.py` (calibration driver, reusable)

If G2 is revisited:
- With a much larger calibration corpus (e.g., 50+ session pairs across
  more letters), per-class thresholds may become derivable.
- With a distribution-shift framing (Option IV), the metric could be
  reframed away from per-stroke pass/fail toward "does this PR's
  distribution match the corpus baseline."

## Methodology-chapter content

This negative result is itself thesis-relevant. Not every proposed
metric admits a meaningful threshold; recognizing this empirically
rather than papering over it is the honest path.

The structural lesson: a freeze-gate metric must measure a quantity
that the maintainer's approved edits SHOULD NOT change. G1 (centerline
location via asymmetry) approximated this — polish kept Pearson above a
defensible floor (≥0.20 across the corpus). G2 (curvature direction
along arc length) did not — polish IS curvature redistribution. The
choice of metric must match the gate's purpose.

## Files referenced

- Corpus: `research_data/calibration_sessions/2026-05-22/*/<timestamp>.json`
- Reference: `PrimaeNative/Resources/Letters/Regular/<letter>/strokes.json`
  at HEAD `a4bf2a75`
- Script: `scripts/calibrate_g2_threshold.py`
- Gate implementation: `scripts/audit_invariants.py::gate_g2_per_stroke`
- Design: `research_data/phase2b_gates/g2_design.md`
- BAKE_INVARIANTS Threshold 2: updated in this commit to reflect
  not-viable-on-current-corpus status
