# G3 — Threshold 3 (Stem-width / perpendicular deviation) — Design Proposal

**Spec ref:** `docs/BAKE_INVARIANTS.md` §2 Threshold 3 (straight strokes
portion).
**Inherits from:** `g1_design.md` (freeze-gate framing; arc-length
resample; per-stroke evaluation; 2026-05-22 session-pair calibration
corpus).
**G2 lesson applied:** explicit polish-preservation prediction before
threshold-derivation procedure (new section, see below).
**Status:** design only. No code yet; awaits David approval / redlines.

---

## Corpus context (inherited from G1/G2)

All 59 letters of Druckschrift Regular ship as hand-calibrated static
artifacts (commit `6a85811c`). G3 is a freeze gate against HEAD's
`strokes.json` files. Calibration data is the same 2026-05-22
session-pair corpus.

See `g1_design.md` Section "Corpus context" for the full framing.

---

## What's the same as G1/G2

| Aspect | G1/G2 | G3 |
|---|---|---|
| Freeze-gate framing | Yes | Yes |
| Per-stroke evaluation | Yes | Yes |
| Arc-length resample to N=100 | Yes | Yes |
| 1-cp strokes vacuous-pass | `not_applicable_too_short` | Same |
| `n_measured < 10` vacuous-pass | `insufficient_measured_points` | Same |
| Reference lookup | `HEAD:Letters/Regular/<L>/strokes.json` | Same |
| CLI integration | `scripts/run_gates.py --gate g{1,2}` | Add `--gate g3` |
| Output format | Stdout default; `--json` flag | Same |
| Calibration corpus | 2026-05-22 session pairs | Same |
| Mask requirement | G1 yes, G2 no | G3 no (pure polyline) |

---

## What's structurally different — two gate shapes in the family

Per David's Q7 redline, the freeze-gate family has two shapes. Both
serve the same purpose (catch PRs producing output David hasn't seen +
approved) but use opposite metric directions:

- **Drift gate** (G1, G2): comparison metric, lower-bound Pearson
  against reference at HEAD. "Did the candidate diverge from
  reference?" Pass iff candidate Pearson ≥ threshold.
- **Conformance gate** (G3, likely G4): intrinsic geometric property,
  upper-bound deviation from spec. "Does the candidate satisfy the
  structural constraint?" Pass iff candidate deviation ≤ threshold.

This is a genuinely novel design point that future gates and the
methodology chapter should explicitly name. The drift-vs-conformance
distinction generalizes the freeze-gate framing.

| Gate | Shape | Threshold form | Pass condition |
|---|---|---|---|
| G1 | Drift gate | `min(Pearson)` across polished strokes | candidate Pearson ≥ threshold |
| G2 | Drift gate | (would have been `min(Pearson)` — investigated, not viable) | — |
| **G3** | **Conformance gate** | `max(deviation)` across straight strokes + safety margin | candidate deviation ≤ threshold |
| G4 (proposed) | Conformance gate | `max(tangent_delta)` at junctions + safety margin | candidate tangent_delta ≤ threshold |

G3 is the first conformance gate. G4 (junction-tangent delta) will
share G3's shape (max-deviation, not Pearson). G5 (CI wiring) is
shape-agnostic.

---

## Polish-preservation prediction (new section per G2 lesson)

**Prediction:** Perpendicular deviation IS polish-preserved.

**Why:** When David polishes a straight stroke, he adjusts cp positions
to refine the centerline — but the polished centerline remains straight
(or, if anything, becomes straighter). Polish typically:
- Shifts the stroke's overall position (e.g., the whole stem moves 2 px
  left). Doesn't change deviation from local straightness.
- Refines endpoint positions. Doesn't introduce bends mid-stroke.
- Smooths small kinks that came from algorithmic baking or earlier
  rounds. DECREASES deviation.

Polish does NOT typically:
- Introduce deliberate curvature into a straight stroke. (If a stroke
  needs to be curved, it's a different stroke kind.)
- Add wobble or zigzag patterns. (Visual approval gate filters those
  out.)

**Empirical pattern predicted on the corpus:**
- Per-stroke deviation values should be similar between round-1 (David's
  starting state) and round-2 (David's polished state), within ~2× of
  each other for any straight stroke.
- If anything, round-2 deviations should be ≤ round-1 deviations (polish
  improves straightness). A round-2 deviation noticeably ABOVE round-1
  would suggest polish added bend — flag for investigation.
- The corpus's worst-case deviation (across all straight strokes, both
  rounds) should land in the small-px range — predict 3–7 px on the
  1024² mask, based on the bake's typical positional precision and the
  calibrator's anchor-rebuild resampling fidelity.

**If the prediction fails:** round-2 deviations would systematically
differ from round-1 — specifically, polish INCREASING deviation
systematically would indicate polish actively changes straightness,
which is the soft-V trigger (mirroring G2's outcome). Polish DECREASING
deviation systematically is the opposite — polish makes strokes
straighter, which is consistent with polish-preservation. The
calibration script reports both round-1 and round-2 deviations per
stroke for pairwise verification (Section G3.7 step 3).

The metric's polish-stability is the load-bearing assumption. State it,
test it, then derive the threshold — not the other way around.

---

## G3-specific design

### G3.1 — Which strokes does G3 apply to?

**Recommendation: geometric straightness detection at gate entry,
mirroring G2's STRAIGHT-class partition.** A stroke is "straight" for
G3 purposes iff `max(|turn_angle|)` on the reference polyline
post-resample is below a threshold.

| Option | Rationale |
|---|---|
| (a) Manually classified per letter in a config | Brittle; requires per-letter labeling for all 59 letters × per-stroke; doesn't generalize to new fonts. |
| (b) Geometrically detected via `max(|ref_turn_angle|) < threshold` **(recommended)** | Reuses G2's `_turn_angle_per_point` primitive. Self-documenting at gate time. Generalizes to new fonts. |

Threshold for "straight": `G3_STRAIGHTNESS_MAX_ANGLE = π/12 (≈15°,
0.262 rad)`, mirroring the STRAIGHT-class boundary used in the G2
calibration partition. That boundary captured the strokes we'd
intuitively call straight (all-vertical-stem letters + crossbars +
diagonals of A) in the G2 analysis.

Non-straight strokes return vacuous pass with
`reason="not_applicable_not_straight"`.

**Classification surfacing (per David's Q1 redline).** The calibration
script reports, for each stroke in the corpus, the actual
`max(|ref_turn_angle|)` value and whether the classifier marked the
stroke as straight. This lets David verify the classifier's output
matches his intuition — particularly borderline cases like D s0 (the
left vertical of D, which may or may not be perfectly straight at the
bowl junction).

If any stroke's classification looks wrong, the
`G3_STRAIGHTNESS_MAX_ANGLE` threshold can be tuned post-hoc before the
calibration commit lands.

### Caveat caught during implementation

The original max-only criterion above was found inadequate during
implementation. This subsection documents what was discovered and the
working criterion that replaced it. Preserved as a record of the
empirical derivation; the original G3.1 text above stands as the
design hypothesis that needed correction.

**Problem 1 — max-only admits smooth curves.** At N=100 resample,
per-segment turn-angles on smoothly-curved arcs are around 0.03–0.14
rad — below π/12 (0.262 rad). The original criterion classified
D s1 (bowl, max 0.143), U s0 (max 0.186), b s0 (max 0.209), and
similar bowls as STRAIGHT. A perfect half-circle resampled to N=100
has per-segment angles of ~0.032 rad, also admitted.

**Problem 2 — cumulative-sum was tried and rejected (Option A).**
Raster noise on a resampled polyline accumulates linearly with N.
Genuinely straight strokes (A diagonals, D vertical, p stem) showed
cumulative `sum|angle|` of 0.4–1.3 rad just from sub-pixel jitter.
`l` (which turned out to be L-shaped in Primae) had cumulative 5.5
rad, with most of it being noise rather than the foot's structural
curvature. Cumulative conflates real curvature with raster noise and
scales with N; rejected.

**Problem 3 — signed cumulative (|Σa|) admits localized corners.**
Letters like N and m have continuous-walk strokes where successive
turns cancel (the net direction change end-to-end is near zero).
Signed cumulative classifies these as straight, which is wrong.

**Working criterion (combined max AND p95).**

```
is_straight = (max(|per-segment angle|) < G3_STRAIGHTNESS_MAX_ANGLE)
              AND (p95(|per-segment angle|) < G3_STRAIGHTNESS_P95_ANGLE)
```

with:
- `G3_STRAIGHTNESS_MAX_ANGLE = π/12 ≈ 0.262 rad ≈ 15°` (catches sharp
  corners)
- `G3_STRAIGHTNESS_P95_ANGLE = 0.1 rad ≈ 5.7°` (catches sustained
  curvature)

Empirically derived against the 2026-05-22 corpus. Eight strokes
cleanly admitted (A 0/1/2, D 0, U 1, p 0, Ü 1, Ä 0); thirteen cleanly
rejected (curves: D 1, U 0, b 0, p 1, Ö 0, Ü 0, Ä 1; corners: N 0,
W 0, m 0, v 0; mixed: l 0 — see foot finding below; sharp-crossbar
artifact: Ä 2).

The p95 threshold (0.1 rad) sits in the **0.014-wide empirical gap**
between A s2's p95=0.087 (admitted) and D s1's p95=0.101 (rejected).
Honest acknowledgment: p95=0.1 is empirically derived, not first-
principles. Future corpus additions could land in this gap and force
re-derivation. Documented as a maintenance hazard, not a design flaw —
empirical calibration is what G3's classifier required.

**Four-outcome decision matrix:**

| max criterion | p95 criterion | Classification |
|---|---|---|
| max < π/12 | p95 < 0.1 | STRAIGHT (G3 applies) |
| max < π/12 | p95 ≥ 0.1 | SMOOTH-CURVED (vacuous: bowls) |
| max ≥ π/12 | p95 < 0.1 | SHARP-CORNER (vacuous: v with one corner but mostly low p95) |
| max ≥ π/12 | p95 ≥ 0.1 | CORNERED (vacuous: W, m, N) |

The strict-AND interpretation (any failure → vacuous) is correct.
A V-shape with one sharp corner and otherwise low p95 should not be
gated by G3 — if finer-grained straightness checking on V's straight
segments is wanted, define them as separate strokes.

**N-coupling note.** Both thresholds depend on `G3_RESAMPLE_N=100`.
p95 scales with N more weakly than cumulative (it's a quantile of
magnitudes, not a sum), but if anyone ever changes `G3_RESAMPLE_N`,
both straightness thresholds and the deviation threshold must be
re-derived. Code-site comments at the constants flag this.

**Empirical data preserved for the derivation record.** Sorted by p95
(critical separator between admitted and rejected):

| Letter | Stroke | max\|a\| | sum\|a\| | p95\|a\| | Classification | Intuition |
|---|---:|---:|---:|---:|---|---|
| A | 1 | 0.023 | 0.395 | 0.010 | straight | right diag |
| p | 0 | 0.024 | 0.718 | 0.021 | straight | stem |
| D | 0 | 0.028 | 0.682 | 0.024 | straight | left vert |
| U | 1 | 0.030 | 0.456 | 0.024 | straight | right vert |
| A | 0 | 0.039 | 0.936 | 0.030 | straight | left diag |
| N | 0 | 1.531 | 6.152 | 0.044 | **vacuous (max)** | corner — diag→vert |
| Ü | 1 | 0.075 | 1.330 | 0.063 | straight | right vert |
| Ä | 0 | 0.100 | 2.943 | 0.067 | straight | Ä A left diag |
| v | 0 | 1.222 | 3.723 | 0.072 | **vacuous (max)** | corner — V vertex |
| A | 2 | 0.102 | 1.285 | 0.087 | straight | crossbar |
| D | 1 | 0.143 | 3.498 | 0.101 | **vacuous (p95)** | bowl |
| Ä | 1 | 0.105 | 4.733 | 0.103 | **vacuous (p95)** | Ä A right diag |
| Ü | 0 | 0.187 | 3.619 | 0.119 | **vacuous (p95)** | U base s0 |
| p | 1 | 0.200 | 4.532 | 0.134 | **vacuous (p95)** | bowl |
| Ö | 0 | 0.174 | 5.692 | 0.135 | **vacuous (p95)** | O base |
| U | 0 | 0.186 | 3.249 | 0.147 | **vacuous (p95)** | left arc |
| b | 0 | 0.209 | 5.968 | 0.176 | **vacuous (p95)** | bowl + stem |
| l | 0 | 0.254 | 5.488 | 0.231 | **vacuous (p95)** | L-shape with foot |
| Ä | 2 | 0.290 | 0.580 | 0.000 | **vacuous (max)** | Ä A crossbar (slight max overshoot) |
| W | 0 | 2.272 | 8.829 | 0.374 | **vacuous (both)** | continuous walk |
| m | 0 | 2.394 | 12.389 | 0.433 | **vacuous (both)** | continuous walk |

### Finding — Primae's lowercase l has a foot/serif

During G3 classifier verification, the lowercase l stroke in Primae was
found to be **L-shaped** (vertical stem with a foot/serif at the
bottom), not a uniform straight stem. Concretely: the polyline starts
at (0.39, 0.05), descends to (0.20, 0.79), then turns right to end at
(0.84, 0.93). l correctly classifies as non-straight under G3 and
vacuous-passes (max=0.254, p95=0.231 — both fail).

Separately, this finding clarifies G1's calibration result for l
(Pearson -0.04 with edit_count=0): that value reflects
perpendicular-walk asymmetry behavior on an L-shape, not noise on a
uniform stem. G1's threshold (0.2005) stands; only the framing
narrative for l in `g1_calibration_run.md` would benefit from a minor
adjustment.

**Open question flagged for David:** is l's foot/serif intentional in
Primae's lowercase l design? If intentional, the corpus is correctly
representing the font. If unintentional, there may be a separate
investigation needed in the bake or calibrator (l should have been
imported as a uniform vertical stroke from the calibrator; the L-shape
may indicate a stroke-decomposition error or an import error).
Surfacing for visual confirmation; not blocking G3 either way.

### G3.2 — Perpendicular deviation: what's the reference line?

**Recommendation: least-squares best-fit line through the
endpoint-skipped cps.**

The "expected straight line" can be defined three ways:

| Option | Definition | Trade-off |
|---|---|---|
| (a) Endpoint-only line | Line through first cp (post-skip) and last cp (post-skip) | Simplest. Sensitive to endpoint position; if endpoints sit at junctions, the reference line is dominated by junction geometry. |
| (b) Least-squares through all cps | Best-fit through every cp on the resampled polyline | Most robust mathematically; but includes endpoint cps that are junction-adjacent. |
| (c) Least-squares through endpoint-skipped cps **(recommended)** | Same as (b) but excludes the first/last K=3 cps via `G3_ENDPOINT_SKIP` | Robust to outliers AND junction-adjacent contamination. Reuses the endpoint-skip pattern from G1/G2. |

Constants: `G3_ENDPOINT_SKIP = 3`, mirroring G1's `T1_ENDPOINT_SKIP`
and G2's `G2_ENDPOINT_SKIP`.

### G3.3 — 95th percentile vs max vs mean?

**Recommendation: 95th percentile, per BAKE_INVARIANTS.md spec.**

Max is too brittle (a single noisy cp tanks the gate). Mean is too
permissive (a systematic bias gets diluted across mostly-good cps).
95th percentile catches systematic deviation without being dominated
by single outliers. Spec-aligned.

### G3.4 — Threshold units

**Recommendation: raster pixels on the 1024² mask.**

Two options:

| Option | Trade-off |
|---|---|
| Raster pixels | Intuitive at the bake's natural scale. Threshold values are reasoning-friendly ("3 px is fine, 15 px is wrong"). |
| Bbox-normalized fraction | Scale-agnostic; future-proof against different mask sizes. But thresholds in [0, 1] coords (e.g., "0.0029") are harder to reason about. |

Bake operates at 1024² and isn't planned to change. Pick pixels for
reasoning clarity; document the assumption.

Constant: deviation values flow through as floats in raster-pixel
units. Threshold value (derived post-calibration) recorded in
`BAKE_INVARIANTS.md` §2 Threshold 3 alongside the corpus state SHA.

**Bbox-fraction secondary column (per David's Q4 redline).** The
calibration script also reports each stroke's
`percentile_dev_px / bbox_dimension` (using whichever bbox dimension
is more relevant — typically the longer axis for the stroke; or
`max(bbox_width, bbox_height)` for simplicity). Reason: future
debugging will want "how big is this deviation relative to the
stroke's natural scale?" — not derivable from pixels alone without
bbox context. The bbox-fraction column is reporting-only; the threshold
of record stays in raster pixels.

### G3.5 — Vacuous-pass conditions

- **1-cp strokes** (diacritic dots) → `not_applicable_too_short`. Same
  as G1/G2.
- **Non-straight strokes** (`max(|ref_turn_angle|) ≥ G3_STRAIGHTNESS_MAX_ANGLE`)
  → `not_applicable_not_straight`. New for G3. The gate doesn't apply.
- **Insufficient measured points** (`n_measured < G3_MIN_MEASURED`,
  `= 10` mirroring G1/G2) → `insufficient_measured_points`. Edge case
  for very short straight strokes that lose too many cps to endpoint
  skip.

### G3.6 — Mask requirement

**Not needed.** Perpendicular deviation is a pure polyline property
(deviation of cp from least-squares line through other cps). No ink
mask involved. `gate_g3_per_stroke` takes `(stroke_poly_rel, bbox,
threshold)` — no mask argument. Lighter than G1; same as G2.

### G3.7 — Calibration procedure

**This is where G3 diverges from G1/G2 structurally.** G3 isn't a
drift metric; it's a per-stroke deviation property. The candidate's
deviation is compared to a threshold derived from the corpus's
deviations, not to the reference's deviation directly.

**Procedure:**

For each letter in `research_data/calibration_sessions/2026-05-22/`:

1. Load `pre_polyline` of earliest session JSON (round-1) and HEAD
   `strokes.json` (round-2).
2. For each stroke index up to `min(len(round1), len(round2))`:
   a. Check if reference (round-2) stroke is straight via
      `_turn_angle_per_point` max check. If not straight, this stroke
      doesn't contribute to G3 calibration. Move on.
   b. If straight: compute `gate_g3_per_stroke(round1_polyline, bbox)`
      → 95th-percentile deviation (in px). Call this `dev_round1`.
      Same for `round2_polyline` → `dev_round2`.
   c. Record `(letter, stroke, dev_round1, dev_round2,
      max(dev_round1, dev_round2), n_measured)`.

3. **Polish-preservation check.** Plot or print round-1 vs round-2
   deviation per stroke. Verify (predicted):
   - Pairwise within ~2× of each other for most strokes.
   - No systematic difference (round-2 not consistently larger than
     round-1 across the corpus).

4. **Threshold derivation.** If polish-preservation holds:
   `threshold = max(max(dev_round1, dev_round2))` across all straight
   strokes + **1 px safety margin** (see step 5). Recorded in
   `BAKE_INVARIANTS.md` with corpus state SHA.

5. **1-pixel safety margin (per David's Q5 redline).** G3 takes a 1-px
   safety margin because of rasterization noise. This differs from G1's
   no-margin approach, which was specific to drift-from-reference's
   structure (the reference is static; no algorithmic noise floor to
   subtract against on a comparison metric). G3 is an intrinsic
   geometric measurement on a rasterized polyline; arc-length
   resampling and pixel quantization introduce ~1 px of jitter on top
   of any actual geometric deviation. The 1-px margin is small enough
   not to admit meaningful drift but large enough to absorb measurement
   noise.

6. **Sub-threshold predictions** for sanity check (mirroring G1's
   sanity-check predictions but quantitative):
   - Letter `l` should produce deviation < 2 px (uniform stem;
     baseline against which we'd flag any wobble).
   - The diagonals of `A` should produce deviation < 3 px (straight
     diagonals; arc-length resampling may introduce small bends).
   - `T`'s and `E`'s straight strokes should be similar to `l`.
   - If any straight stroke in the corpus produces > 7 px deviation,
     flag and investigate — that's not consistent with the corpus
     being hand-polished against straight-stroke geometry.

**If polish-preservation FAILS** (step 3 shows systematic divergence):
G3 hits the same outcome as G2 — implementation preserved, threshold
not derived, finding documented as a methodology result.

### G3.8 — Implementation outline

New code in `scripts/audit_invariants.py`:

```
# Constants
G3_RESAMPLE_N = 100
G3_MIN_MEASURED = 10
G3_ENDPOINT_SKIP = 3
G3_STRAIGHTNESS_MAX_ANGLE = math.pi / 12  # ≈15°
G3_PERCENTILE = 95


def _perpendicular_deviation(poly_px) -> tuple[float, int]:
    # Least-squares fit a line to poly_px (in pixel coords, after
    # endpoint skip applied by caller).
    # Compute perpendicular distance from each point to the line.
    # Return (95th_percentile_deviation, n_measured).


def gate_g3_per_stroke(stroke_poly_rel, reference_poly_rel, bbox,
                       threshold, n_resample=G3_RESAMPLE_N,
                       n_min_measured=G3_MIN_MEASURED,
                       straightness_max=G3_STRAIGHTNESS_MAX_ANGLE) -> dict:
    # 1. <2 cp → vacuous (not_applicable_too_short)
    # 2. Resample CANDIDATE to n_resample; convert to px.
    # 3. Resample REFERENCE polyline; check max(|turn_angle|) on it.
    #    If above straightness_max → vacuous (not_applicable_not_straight).
    # 4. Apply endpoint skip to candidate cps (drop first/last G3_ENDPOINT_SKIP).
    # 5. n_measured < n_min → vacuous (insufficient_measured_points).
    # 6. Compute 95th-percentile perpendicular deviation on the candidate.
    # 7. Return { deviation, n_measured, n_cp_candidate, n_cp_reference,
    #            pass: deviation <= threshold, reason? }


def gate_g3(candidate_strokes_rel, reference_strokes_rel, bbox,
            threshold) -> dict:
    # Iterate strokes, call gate_g3_per_stroke per pair.
    # Letter pass = all paired strokes pass (vacuous-pass strokes count
    # as pass per existing pattern).
    # No per-stroke mask building (mask-free gate).
```

Approx LoC: ~130 added to `audit_invariants.py`.

**`scripts/run_gates.py`** — add `g3` to `GATE_METADATA`:

```
"g3": {
    "function_with_mask": None,
    "function_without_mask": ai.gate_g3,
    "needs_mask": False,
    "title": "perpendicular deviation on straight strokes",
},
```

Single-entry table addition. ~5 LoC change to `run_gates.py`.

**`scripts/calibrate_g3_threshold.py`** — new file, ~150 LoC. Reports
`(letter, stroke, dev_round1, dev_round2, n_measured)` per stroke.
Polish-preservation diagnostic table comparing the two columns. Derives
threshold from `max(max(round1, round2))` over straight strokes.
Per-reason vacuous breakdown (consistent with G1 + G2).

**`scripts/tests/test_gate_g3.py`** — new file, ~120 LoC.
Tests: straight line → deviation 0 or near-0; bent line → deviation
proportional to bend; 1-cp / insufficient / not-straight → vacuous
pass with correct reason; identical candidate=ref-line passes; mirror/
reflection produces same deviation (deviation is unsigned).

**`docs/BAKE_INVARIANTS.md`** Threshold 3 — replace the "Pending Phase
2b" language for the straight-strokes part with the derived threshold
value + corpus state SHA + reference to
`research_data/phase2b_gates/g3_calibration_run.md`.

**Total new code:** ~400 LoC across 2 modified + 2 new files + 1 doc
edit.

### G3.9 — Empirical predictions

Predictions for the corpus calibration run (verify or contradict):

1. **All G2-classified STRAIGHT strokes contribute to G3 calibration.**
   From G2's calibration partition, 16/21 measured strokes were
   STRAIGHT-class. Of those, l, A diagonals, D s0, U s1, p s0,
   Ä/Ö/Ü base strokes, the crossbar of A (A s2), and similar are
   genuinely straight and should produce small deviations.
2. **Threshold lands ~3-7 px** on 1024² mask. Predict the corpus's
   worst-case deviation across all straight strokes is in this range.
3. **Polish-preservation holds.** Round-1 and round-2 deviations are
   within ~2× of each other per stroke. No systematic round-2 >
   round-1.
4. **The A's-diagonals edge case from G2 calibration is informative.**
   A's diagonals (max\|ref\| 0.034-0.039 rad) are flagged STRAIGHT by
   G3's detector but had borderline turn-angle variance. If
   arc-length resampling does introduce ~0.005-0.015 rad bends along
   the A diagonals, the resulting perpendicular deviation should be
   small (~1-3 px) but not zero. This is the case to watch.
5. **W, m, N, v, the bowls of b/p/D/Ä/Ö/Ü, ß — all vacuous-pass via
   `not_applicable_not_straight`.** They're not straight strokes;
   G3 doesn't apply.

**Counter-predictions (what would falsify the design):**
- If round-2 deviations are systematically larger than round-1
  across the corpus, polish-preservation fails → G3 is not viable as
  a freeze gate (mirrors G2 outcome).
- If the worst-case corpus deviation is > 15 px, that's much larger
  than predicted and suggests either (a) the polyline is genuinely
  not very straight even for "straight" strokes, or (b) the
  least-squares line fit is off in some systematic way. Investigate
  before deriving a threshold.

### G3.10 — Question flagged during drafting

**Q: Should the straightness detector use round-2 (HEAD) reference or
round-1 (session pre_polyline)?**

In G2 calibration, the straightness classification was done on the
HEAD reference polyline. For G3 gate-time use, the same: HEAD is the
canonical reference. The straightness classification is a property of
the reference, not the candidate.

But for calibration, both round-1 and round-2 polylines exist for the
same letter. If the round-1 stroke fails the straightness check but
the round-2 stroke passes (or vice versa), what should the
calibration do?

Two natural answers:
- (a) Use round-2's straightness only — if HEAD says straight, both
  rounds contribute to deviation calibration.
- (b) Use both rounds' straightness — only include the stroke if BOTH
  rounds pass straightness check (conservative).

Practically, polish doesn't typically convert a curved stroke to a
straight one or vice versa. The two answers should agree on the
2026-05-22 corpus. Pick (a) for consistency with gate-time behavior;
flag for surfacing during calibration if (a) and (b) ever disagree on
a real corpus.

---

## Decisions summary (post-redline)

| Section | Decision | Alternative |
|---|---|---|
| **G3.1** | Geometric straightness detector via `max(|ref_turn_angle|) < π/12`; calibration script surfaces classification + raw angle per stroke for verification | Manual per-letter classification |
| **G3.2** | Least-squares line through endpoint-skipped cps | Endpoint-only line; LSQ all cps |
| **G3.3** | 95th percentile | Max; mean |
| **G3.4** | Raster pixels on 1024² mask (threshold of record); bbox-fraction reported as secondary column for debugging | Bbox-normalized as primary |
| **G3.5** | Vacuous-pass: too-short, not-straight, insufficient-measured | — |
| **G3.6** | No mask (pure polyline) | — |
| **G3.7** | Per-stroke `max(round1, round2)` deviation; threshold = max across corpus straight strokes **+ 1 px safety margin** (rasterization noise) | Round-2 only; no margin |
| **G3.8** | New code in same `audit_invariants.py`; new calibration script + test file; add to `GATE_METADATA` | — |
| **Structural** | G3 is the first **conformance gate** (deviation ≤ threshold), distinct from G1/G2's **drift gate** shape (Pearson ≥ threshold). G4 likely shares G3's shape. | — |
| **Polish-preservation** | Predicted yes; verified empirically during calibration before threshold derivation. Soft-V trigger if polish systematically INCREASES deviation. | — |

---

## Approved

All eight Y/N questions approved (2026-05-23) with five clarifying
refinements:
1. Q1 — Classification (straight/not-straight) + raw
   `max(|ref_turn_angle|)` value surfaced per stroke in calibration
   output, so David can verify the classifier's intuition match
   particularly for borderline cases (e.g., D s0).
2. Q4 — Calibration script reports bbox-fraction as a secondary
   column alongside the raster-pixel deviation; threshold of record
   stays in pixels.
3. Q5 — 1-px safety margin added to threshold derivation. G3's
   measurement noise floor is different from G1's (rasterization
   jitter vs algorithmic determinism); margin documented as a
   deliberate departure from G1's no-margin approach.
4. Q7 — Drift-gate-vs-conformance-gate taxonomy named explicitly.
   G3 is the first conformance gate; G4 will likely share G3's
   shape.
5. Q8 — Polish-preservation soft-V trigger language tightened:
   polish INCREASING deviation systematically is the soft-V trigger;
   polish DECREASING deviation is consistent with polish-preservation.

Implementation lands next.
