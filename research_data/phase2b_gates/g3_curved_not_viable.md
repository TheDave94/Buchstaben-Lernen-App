# G3-curved — investigated, not viable as a freeze-gate metric — 2026-05-26

**Corpus state SHA at diagnostic run:** `f6365b9` (the G6
implementation commit; this disposition doc lands in the next
commit).
**Diagnostic:** `/tmp/diagnostic_g3curved.py` (G3-curved.v1,
2026-05-26).
**Outcome:** **Not viable as a freeze-gate metric on the current
corpus.** No code shipped; classifier-side reuse only.
Implementation deferred and may not be revisited unless the
corpus is later sub-classified by curvature shape.

## Outcome

G3-curved was scoped as the inversion of G3: G3 catches "curves
accidentally classified as straight" via perpendicular-deviation;
G3-curved would catch "straights accidentally classified as
curved" by sliding a 5-cp window across each CURVED stroke and
flagging windows where the absolute cumulative turn-sum is below
a small threshold (`< 5°`). The pre-implementation diagnostic
(G3-curved.v1) surfaced that the proposed criterion fires on 47
of 53 CURVED strokes (89% of the corpus's curved population),
because the existing G3 classifier groups three distinct
populations under the single CURVED label — and two of those
three have intrinsic straight sub-segments that the naive gate
would flag as authoring bugs. The freeze-gate framing does not
survive contact with the corpus's actual curvature distribution.

## Diagnostic finding — two populations inside CURVED

Corpus structure (run against HEAD `f6365b9`):

| Class | Count |
|---|---:|
| Total strokes | 119 |
| CURVED | 53 |
| STRAIGHT | 52 |
| TOO_SHORT (< 2 cps; mostly umlaut dots) | 14 |

Distribution of per-stroke angle signatures across the 53 CURVED
strokes (in degrees):

| Metric | min | p10 | median | p90 | max |
|---|---:|---:|---:|---:|---:|
| `max_a` (max per-cp turn) | 6.01 | 7.85 | 11.92 | 111.82 | 137.18 |
| `p95_a` (95th-pctile per-cp turn) | 0.00 | 4.63 | 7.85 | 14.16 | 24.84 |
| `\|signed_cum\|` (sum of signed turns) | 0.00 | 0.03 | 170.36 | 321.10 | 398.52 |

The bimodal `max_a` distribution (median 11.92° but p90 reaching
111.82°) is the load-bearing signal: the corpus's CURVED set is
not one population.

**Population (a) — angular strokes (high `max_a`, low `p95_a`).**
M, N, V, W, K, Z, Y and similar letters with sharp localized
turns plus extended straight sub-segments. The classifier marks
them CURVED because their `max_a` exceeds the 15° straightness
threshold at the corner, but their `p95_a` is small because most
cps are along straight legs. **Straight sub-segments are
intrinsic to the letter shape.**

**Population (b) — smoothly curved strokes (moderate `max_a`,
moderate `p95_a`, high `|signed_cum|`).** Bowls of B, P, R; full
loops in O-style geometry. Distributed curvature; `p95_a` is
nontrivial because curvature is sustained, not localized. **The
intended target of "smoothness preservation" framing.**

**Population (c) — near-straight strokes with cumulative noise.**
E s2 (a 168-cp horizontal arm) and similar long calibrator-drawn
arms that classify as CURVED via `|signed_cum| > π/12` rather
than via local sharp turns. The signed-cumulative criterion was
added 2026-05-24 (G5 verification refinement, commit `c4c143b`)
to catch smooth long curves that max+p95 missed — but it also
catches calibrator-drawn near-straights whose tiny per-cp wobble
accumulates over many cps. **Geometrically straight, but
classifier-labeled CURVED.**

## Per-letter rows that surface

The naive gate fires on 2007 windows across 47 of the 53 CURVED
strokes (89%). Per-letter concentration (top 15 by row count):

```
Ä:  169     Y:  159     V:   84     v:   80
N:   78     R:   78     Z:   78     E:   73
W:   71     M:   68     K:   58     g:   58
w:   58     f:   57     j:   57
```

Population (a) — angular — dominates the list (V/v/W/w, N/M, K,
Z, Y and their lowercase analogues, plus angular letter f and
j). Ä's 169 rows come from the composite umlaut's body strokes
plus its calibration noise. Population (b) — smoothly curved
(B, P, R bowls) — does NOT dominate; bowls appear lower in the
list because their distributed curvature gives every 5-cp window
nontrivial cumulative turn. Most of the rows reflect populations
(a) and (c), exactly the wrong target.

## Why the naive spec doesn't work

The proposed spec (`BAKE_INVARIANTS.md` §2 Threshold 3 curved
portion) assumes CURVED ⇒ smoothly curved. The actual G3
classifier (post-`c4c143b`) marks a stroke CURVED iff ANY of the
three criteria fail: `max_a > π/12`, OR `p95_a > 0.1` rad, OR
`|signed_cum| > π/12`. This is a "has non-trivial curvature
somewhere" test, not a "smoothly curved everywhere" test. The
gate's measurement intent and the classifier's actual semantics
do not line up.

A freeze-gate metric is defensible only if the quantity it
measures is one the maintainer's approved edits SHOULD NOT
change. For population (a) angular strokes, the straight
sub-segments between turns are exactly the by-design geometry —
the maintainer would polish them to BE straight, not to be
curved everywhere. The metric measures the opposite of what the
gate should enforce. For population (c) near-straight strokes,
the same logic: the maintainer drew them straight intentionally;
the CURVED classification is itself the artifact.

A defensible threshold would require population (a) and (c) to
pass while population (b) fires only on real authoring bugs. The
naive 5-cp/5° criterion cannot distinguish populations (a)+(c)
from population (b) because all three contain windows of low
cumulative turn — populations (a) and (c) by design,
population (b) only when something has actually gone wrong.

## What the data would support if redesigned

Three reframing options were considered during the diagnostic
write-up and surfaced for the disposition decision. None was
pursued in the current pass:

**Option (a) — Sub-classify CURVED into angular vs smooth.**
Add a sub-classifier that distinguishes population (a) angular
(high `max_a`, low `p95_a`) from population (b) smooth (moderate
`max_a`, moderate `p95_a`, high `|signed_cum|`). G3-curved fires
only on smooth CURVED strokes. Predicted scope: ~10-20 strokes
(the bowls). Methodology cost: introduces a second classification
gate before the measurement gate; calibration corpus for the
sub-classifier needs derivation. Worth pursuing if the gate is
revisited with a more discriminating curvature taxonomy.

**Option (b) — Loosen the "looks straight" criterion.**
Require the straight run to be SUSTAINED — say ≥ 20 consecutive
cps with cumulative turn below a larger threshold — so the angular
letters' short inter-turn straight bits do not fire. Predicted:
~ a handful of rows surface, all genuine "straight section inside
an intended smooth curve." Cleaner per-row signal but the
threshold/window pair becomes increasingly tuned to the corpus
rather than to the geometric question; defensibility-of-threshold
gets thinner with each tuning knob.

**Option (d) — Refine the upstream G3 classifier first.**
Population (c) (near-straight with cumulative noise) is a G3
classifier artifact, not a G3-curved finding. If the
`|signed_cum|` criterion were scaled by the cp count (current
threshold is absolute `π/12` regardless of stroke length), or if
the classifier required BOTH `max_a` AND `p95_a` to exceed their
thresholds (rather than `max_a` OR `p95_a` OR `|signed_cum|`),
population (c) would re-classify as STRAIGHT. That alone narrows
G3-curved's scope substantially. Larger scope change; touches
existing G3 calibration; would need re-running the 2026-05-22
session-pair calibration against the revised classifier to
confirm G3's existing threshold of record (2.05 px) holds.

If G3-curved is revisited, option (d) is the natural first step
(it tightens the upstream classifier), followed by option (a)
(sub-classify the remaining CURVED set). Option (b) is a
short-cut that improves the gate's signal without addressing the
classifier's heterogeneity, so it is the weakest of the three.

## What stays

Nothing G3-curved-specific ships. The pieces of the design that
remained as reusable components:

- The diagnostic script `/tmp/diagnostic_g3curved.py` is preserved
  here as the artifact of record (referenced inline below). It is
  not landed in `scripts/` — it was investigation work, not a
  shippable calibrator.
- The G3-curved scoping entry in `phase2c_design.md` is rewritten
  in the same commit to reflect this disposition.
- The G3 classifier (`_stroke_angle_stats` + the combined
  straightness criterion in `gate_g3_per_stroke`) is unchanged.
  Option (d)'s suggested refinement is documented for future
  consideration but NOT applied here.

## Methodology framing

G3-curved joins G2 in the "predicted, falsified by diagnostic"
track. Together they form a methodology pattern: the gate set was
built by predict-explicitly-then-verify-empirically, and not
every prediction survived contact with the corpus.

| Gate | Status | Falsification mode |
|---|---|---|
| G1 — asymmetry-profile Pearson | Enforced | (prediction confirmed; threshold derived) |
| G2 — turn-angle-profile Pearson | **Investigated, not viable** | Polish IS curvature redistribution → no defensible Pearson threshold |
| G3 — perpendicular deviation on straight | Enforced | (prediction confirmed; threshold derived) |
| **G3-curved — sliding-window inversion** | **Investigated, not viable** | CURVED classifier groups 3 populations; naive 5cp/5° criterion fires on 89% of corpus, 2 of 3 populations by design |
| G4 — junction-tangent kink | Enforced | (prediction confirmed; threshold derived) |
| G6 — T-junction attachment-tangent | Enforced (measurement-instrument framing) | (prediction confirmed; threshold derived with generous margin) |

The "five shipped + two investigated-not-viable" outcome is a
feature of the methodology, not a bug. The investigated-not-viable
gates are themselves trail markers — they document where the
geometric framing met empirical reality and required reframing or
deferral. The methodology chapter can frame this as evidence that
the predict-verify-refine pattern operates on the gate's PREMISE,
not just on its threshold.

The G3-curved disposition adds a specific structural finding to
the methodology record: **the corpus's CURVED class is
heterogeneous, and a meaningful "curve purity" gate requires
prior sub-classification by curvature shape.** This is a
positive finding (it sharpens the methodology's understanding of
the corpus) framed inside a negative outcome (no gate ships from
this scoping item).

## Reference

- Diagnostic: `/tmp/diagnostic_g3curved.py` (G3-curved.v1,
  2026-05-26)
- Phase 2c scoping: `research_data/phase2b_gates/phase2c_design.md`
  G3-curved section (updated in this commit to reflect not-viable
  disposition)
- Analogous case: `research_data/phase2b_gates/g2_calibration_run.md`
  (G2 not-viable)
- Existing G3 classifier (unchanged):
  `scripts/audit_invariants.py::_stroke_angle_stats` +
  `gate_g3_per_stroke` (the combined max + p95 + |signed_cum|
  straightness criterion; constants `G3_STRAIGHTNESS_MAX_ANGLE`,
  `G3_STRAIGHTNESS_P95_ANGLE`, `G3_STRAIGHTNESS_SIGNED_CUM_RAD`)
- Signed-cumulative refinement (added 2026-05-24 during G5
  verification): commit `c4c143b`
