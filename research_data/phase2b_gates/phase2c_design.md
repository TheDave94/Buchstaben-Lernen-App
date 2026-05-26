# Phase 2c — Gate-coverage gap closure — Design Scoping

**Spec ref:** `docs/BAKE_INVARIANTS.md` §6 (Enforcement tally; one
measured-threshold gap remains) and §1 Rule 4 scope constraint
(mid-stroke attachment is out of G4's scope).
**Inherits from:** G1–G5 design + calibration docs (Phase 2b Track B
operative gate set).
**Status:** scoping only. No code, no calibration runs yet. Awaits
David's go/no-go on timing (pre-thesis vs post-thesis).

Phase 2c is the umbrella for the gate-coverage gaps that Phase 2b
Track B identified but did not close. The term has been used as a
forward-pointer in `BAKE_INVARIANTS.md:309, 349` and
`g4_calibration_run.md:103` since 2026-05-23 without a definition;
this doc gives it one.

---

## Corpus context (inherited)

All 59 letters of Druckschrift Regular ship as hand-calibrated
static artifacts (commit `6a85811c`). The Phase 2b Track B gates
(G1 / G3 / G4) measure drift from this frozen reference; G5 wires
them into CI via `bake-gates.yml`. Phase 2c uses the same
2026-05-22 session-pair corpus
(`research_data/calibration_sessions/2026-05-22/`) that drives
G1–G4.

---

## Purpose

Phase 2b Track B shipped three operative measurement gates and
explicitly identified two unmeasured-threshold gaps:

- **Mid-stroke attachment junctions** (lowercase p's bowl/stem) —
  out of G4's scope per `g4_calibration_run.md` "Discovered scope
  constraint".
- **Curved-stroke straightness inversion** (Rule 3 curved portion)
  — not covered by G3, which addresses only straight strokes per
  `BAKE_INVARIANTS.md` §2 Threshold 3 block.

A third item surfaced during G3 calibration but is methodologically
distinct from the two gates above:

- **Composite-umlaut bake artifact** (Ä s1/s2 borderline
  classifications) — characterized in `g3_calibration_run.md:93-114`
  as a `bake_composite` geometry artifact, not a missing gate.

Phase 2c covers all three. After Phase 2c, the §6 tally reads "all
six thresholds measured" and the composite-umlaut question has a
documented disposition (fix-and-ship vs document-and-defer).

---

## Scope

### In-scope (Phase 2c workstream items)

- **G6** — Mid-stroke attachment gate (new measurement gate;
  parallels G4 structure)
- **G3-curved** — Curved-stroke inversion gate (new measurement
  gate; symmetric counterpart of G3)
- **Composite-umlaut investigation** — tier-2 sub-item;
  bake-pipeline analysis, not a new gate

### Out of scope (each tracked separately)

| Item | Why out of scope | Tracked at |
|---|---|---|
| Q-class bake topology (Q, a_l, ä_l, g_l, q_l, ü_l) | Light/future-font work; methodology-LOW; Regular ships these letters as hand-calibrated artifacts | `docs/ROADMAP.md` line 37 (bake-pipeline open follow-up) |
| ß Light resolver | Operational Light gap (single letter); methodology-LOW | `docs/ROADMAP.md` line 37 (same sub-bullet) |
| `verify_bake.sh` CI lift | Operational CI hygiene; methodology-LOW | `docs/BAKE_INVARIANTS.md` §2 Threshold 6 + §6 tally (post-Phase-2b future-work note) |
| G5.5 merge-base switch | Contingency for a workflow that doesn't yet exist (frequent main rebases); methodology-LOW | `research_data/phase2b_gates/g5_design.md` G5.4 |

Future readers looking for any of these items should find them
tracked at the locations above, not in Phase 2c.

---

## Workstream items

### G6 — Mid-stroke attachment gate

**Status:** design locked 2026-05-26 from pre-implementation
diagnostic (G6.v1) + sub-diagnostic (G6.v2). Detailed design + the
calibration-run output land in `g6_design.md` and
`g6_calibration_run.md` when the implementation cycle ships; this
scoping entry records the decisions made at the Phase 2c-scoping
level so the methodology chapter and the implementation can both
cite a single locked source.

**Reframing — measurement instrument, not merge-blocker.** Regular
ships as 59 hand-calibrated static artifacts (commit `6a85811c`,
2026-05-15); the Regular bake pipeline is retired. There is no
"candidate Regular bundle" for G6 to gate against. G6 therefore
exists not to protect Regular from regression but to provide a
measurement primitive for future-font auto-calibration sessions:
when Primae Light, or a future Schreibschrift weight, runs its
own session-pair polish workflow, G6 quantifies whether T-junction
attachment drift is occurring under polish.

**What G6 actually preserves — narrow, data-structural claim.** The
`strokes.json` polylines are not "the rendered glyph" — they are
the **operational definition** of letter geometry, consumed six
ways across the app:

1. observe-phase animated guide-dot path (`AnimationGuideController.swift:74-77`)
2. direct-phase numbered start-dot positions
3. guided-phase Catmull-Rom ghost render + per-checkpoint
   advancement gate (`StrokeTracker.swift:94-107`)
4. freeWrite discrete Fréchet scoring against concatenated
   reference (`FreeWriteScorer.swift:65, 173`)
5. Werkstatt symmetric Hausdorff scoring (per-stroke, no
   cross-stroke phantom edges; `FreeWriteScorer.swift:88-99`)
6. post-trace KP overlay straight-line reference for
   Knowledge-of-Performance feedback (`TracingCanvasView.swift:227-231`)

The renderer is one consumer of many. G6 measures a property of
this data structure (the T-junction attachment angle in the cp
data), not a property of any single downstream rendering. **This
is explicitly NOT a claim about visual fidelity.** The ghost
renderer's Catmull-Rom-to-Bezier blend absorbs sub-pixel cp
jitter on curves (per `docs/BAKE_INVARIANTS.md` §5.3); gate
thresholds can be tighter than what
the ghost layer would show. The claim is about preserving the
geometric data structure that defines the letter operationally
across all six consumers.

**Motivation — the auto-calibrator's documented failure class.**
The hand-calibrator-overrides-bake architecture (see `docs/LESSONS.md`
Part A §1-3 and `research_data/spec_decision/framing.md:67-98`)
exists because the auto-calibrator's `skeletonize` step produced
spurious medial-axis branches at the T-junction class. Documented
failure cluster from that investigation: **R, b, d, P** —
bowl-on-stem T-junctions where the medial axis spawned non-
trajectory branches that the BFS-walk picked up. The hand-
calibrator overrides this with the clean T-junction the letters
require. G6 is therefore not an abstract gate but the
measurement primitive for the specific geometric class whose
failure justified the entire calibrator-overrides-bake decision.
When a future font runs its own auto-calibration, G6 quantifies
whether the new font's T-junctions have drifted from the
calibrated reference — catching the exact failure mode that
motivated the architecture.

This is methodologically distinct from G1 / G3-straight / G4,
which exist primarily as freeze-gates on the shipped artifact.
Surfaced in "Methodology-chapter framing" below as a dual-
purpose claim.

**Diagnostic finding — mid-stroke attachment is structural, not
incidental.** A pre-implementation diagnostic (G6.v1, 2026-05-26)
enumerated every stroke-pair (i, j) endpoint-vs-polyline pairing
across the 59-letter Regular corpus and classified each row as
END-TO-END (G4 territory; host_cp_idx within 5 cps of an endpoint
after N=100 resample), MID-STROKE-ATTACHMENT (G6 territory;
5 ≤ host_idx ≤ 94 AND distance ≤ 15 px), or NO-JUNCTION. **15
letters surface 20 mid-stroke attachment rows**:

| Archetype | Letters | Rows |
|---|---|---|
| Crossbar on vertical(s) | A, E, F, H, T | 6 rows |
| Bowl/loop attached to stem | B, P, R, a, d, p, q, y | 10 rows |
| Composite umlaut diacritic attachment | Ä, ä | 4 rows |

This is not a Primae-decomposition idiosyncrasy — it is standard
Latin letter anatomy. Primae's per-pen-lift stroke convention
exposes the T-junction; alternative decompositions (one continuous
winding stroke per glyph) would erase the pedagogically-relevant
pen-lift semantics. The original G6 design hypothesis ("lowercase p
alone") underestimated the corpus by 15×; G6 is a corpus-wide gate
with a structural domain, not a p-specific patch.

**Borderline rows** at the G4/G6 boundary: R s2→s1 at host_idx=93
(band edge 94) and q s0→s1 at host_idx=6 (band edge 5). The strict
host_cp_idx classifier assigns each unambiguously into G4-territory
(idx < 5 or idx > 94) or G6-territory (5 ≤ idx ≤ 94) with no
overlap — no per-letter override required.

**Sub-diagnostic finding — three metrics co-vary; one is enough.**
A second diagnostic (G6.v2, 2026-05-26) measured three candidate
drift metrics against the 2026-05-22 session-pair corpus:

- `position_drift` (cp idx on host between r1 and r2)
- `tangent_drift_deg` (angle between attaching-stroke tangent and
  host-local tangent at the attachment point; unsigned, 0–90°)
- `distance_drift_px` (min-distance shift between r1 and r2)

Only 3 of the 20 mid-stroke rows have measurable session pairs:
A s2→s0, A s2→s1, p s1→s0. The other 17 fall into letters with no
2026-05-22 sessions (B, E, F, H, P, R, T, a, d, q, y, ä) or into
Ä's 12 batch-2 sessions, all of which involve stroke-count topology
changes (umlaut-dot addition workflow; r1 has 2–4 strokes, r2 has
4–5) and are excluded as polish-corpus-inapplicable.

Results across the n=3 measurable rows:

| Junction | pos_drift (cp) | tan_drift (°) | dist_drift (px) |
|---|---|---|---|
| A s2→s0 (crossbar → left leg) | 0 | 0.50 | 0.24 |
| A s2→s1 (crossbar → right leg) | 1 | 0.15 | 1.22 |
| p s1→s0 (bowl → stem) | 1 | 0.16 | 1.26 |

**Critical observation: the three metrics co-vary.** When the
junction shifts under polish, all three move together — they are
three views of one "junction wiggled" phenomenon, not three
orthogonal failure modes. Picking BOTH metrics (e.g.,
tangent-AND-distance) is redundant; picking ONE loses no diagnostic
power.

**Metric selection: `tangent_drift_deg`.** Two reasons:

1. *Closest analogue to G4.* G4 measures drift on per-junction kink
   angle; G6 measures drift on per-junction attachment angle. The
   methodology chapter can frame G6 as "G4's pattern extended from
   end-to-end junctions to T-junctions" — clean continuity, single
   pattern name for both gates.
2. *Most geometrically meaningful.* A T-junction's "shape" is
   fundamentally its attachment angle; position and distance are
   downstream of the angle plus host polyline geometry. Picking the
   semantically primary signal makes the methodology argument
   cleaner than picking either downstream metric.

**Threshold derivation: 4.5° = 0.50° (max observed) + 4° margin.**
The margin is intentionally generous:

- The calibration corpus is thin (n=3 across only 2 of 3 archetypes
  identified by G6.v1; bowl-bearing letters represented only by p,
  no representative from B/R/d/q; composite umlaut Ä/ä unmeasurable
  on this corpus).
- 13 of the 15 mid-stroke letters have no session-pair data;
  unmeasured archetypes could exhibit different drift profiles.
- G6's design driver is future-font measurement; Regular's
  threshold need not be tight (Regular is frozen).

For comparison (margin as fraction of max-observed-drift):

| Gate | Max observed | Margin | Threshold | Margin / max |
|---|---|---|---|---|
| G3 | 1.05 px | +1.0 px | 2.05 px | ~95% |
| G4 | 2.43° | +2.0° | 4.43° | ~82% |
| G6 | 0.50° | +4.0° | 4.50° | ~800% |

G6's 800% margin reflects both the corpus thinness AND the
measurement-instrument framing. If a future-font calibration
session surfaces a real tangent drift > 4.5° on a T-junction, that
is signal the threshold needs re-derivation against the expanded
corpus. Threshold-of-record may change; both outcomes are fine for
a measurement instrument.

**Methodology vignette — the bowl-bearing absence IS evidence.**
The bowl-bearing archetype (B, P, R, a, d, q, y; p is the lone
representative with a 2026-05-22 session pair) is conspicuously
absent from the n=3 calibration corpus. This is not random absence.
These letters were authored via the calibrator override precisely
BECAUSE the auto-calibrator failed on their T-junction topology
(per the Motivation block above: R, b, d, P documented failure
cluster). Once correctly authored by the calibrator, they're
stable — the 2026-05-22 polish sessions did not need to touch
them. The absence is therefore not a calibration weakness; it
reflects a structural property of the corpus: **the geometric
class G6 measures is high-stability once correctly authored.**
This is congruent with G6's measurement-instrument framing: the
gate is for catching the class when it goes WRONG (the auto-
calibrator-on-new-font case), not for tracking polish on Regular
where the class is already correctly stable. The undercoverage
of the most methodologically-motivating archetype is consistent
with the right framing — if those letters were unstable under
polish on Regular, we would have polish data on them, and we
don't.

**Implementation scope (mirrors G4).**

1. `scripts/audit_invariants.py`: `gate_g6_per_junction`, `gate_g6`,
   `_t_junction_detect`, `_host_tangent_at_idx`. Reuse
   `_stroke_tangent_at_endpoint` from G4 for the attaching-stroke
   side; reuse `_arc_length_resample` for both sides. Constant
   `G6_DEFAULT_THRESHOLD_DEG = 4.50`.
2. `scripts/run_gates.py`: GATE_METADATA["g6"] entry.
3. `scripts/tests/test_gate_g6.py`: synthetic-T-junction unit tests
   mirroring `test_gate_g4.py` (perpendicular T as identity case;
   skewed T as off-90° case; topology-change vacuous-pass case;
   borderline-band classifier handoff to G4 case; zero-junction
   letter vacuous-pass case).
4. `scripts/calibrate_g6_threshold.py`: formal calibration script
   producing the 4.5° threshold deterministically. Output mirrors
   `calibrate_g4_threshold.py`.
5. `.github/workflows/bake-gates.yml`: add G6 step.
6. `research_data/phase2b_gates/g6_design.md` +
   `g6_calibration_run.md`: detailed design + calibration-run docs
   (this scoping section is not a substitute).

**Effort.** M — comparable to G4, plus a small documentation cost
for the dual-purpose methodology claim.

---

### G3-curved — Curved-stroke inversion gate

**Status:** investigated 2026-05-26, **not viable** as a freeze-gate
metric on the current corpus. See
`research_data/phase2b_gates/g3_curved_not_viable.md` for the
diagnostic findings + reframing options.

**One-paragraph summary.** G3-curved was scoped as the inversion of
G3 — flag CURVED-classified strokes that have ≥5-cp runs with
absolute cumulative turn-sum < 5° (visually-straight segments
inside a curved stroke). The pre-implementation diagnostic
(G3-curved.v1, 2026-05-26) surfaced that the proposed criterion
fires on 47 of 53 CURVED strokes (89%) because the existing G3
classifier groups three distinct populations under the single
CURVED label: (a) angular strokes (M/V/W/N/K/Z/Y — sharp turns +
straight legs by design), (b) smoothly curved strokes (B/P/R
bowls — the gate's intended target), and (c) near-straight strokes
with cumulative noise (E s2 and similar). Populations (a) and (c)
have straight sub-segments intrinsic to their geometry; the naive
gate would fire on them. The freeze-gate framing does not survive
contact with the corpus's actual curvature heterogeneity.

**Methodology pattern.** G3-curved joins G2 in the
predicted-then-falsified-by-diagnostic track. The methodology
chapter can frame the gate set as "five shipped + two
investigated-not-viable," with the not-viable cases as substantive
findings rather than absences. The structural insight (the
corpus's CURVED class is heterogeneous, and a meaningful "curve
purity" gate requires prior sub-classification by curvature
shape) is captured in `g3_curved_not_viable.md` as
methodology-chapter-relevant content.

**If revisited.** Three reframing options documented in
`g3_curved_not_viable.md`: (a) sub-classify CURVED into angular
vs smooth; (b) loosen the looks-straight criterion to require
sustained runs; (d) refine the upstream G3 classifier so
populations (a) and (c) re-classify as STRAIGHT. Option (d) is
the natural first step. None pursued in the current pass.

**Effort.** S (disposition documentation only; no code shipped).

---

### Composite-umlaut bake artifact investigation (Ä s1 / Ä s2)

**Framing: investigation, not gate design.** This sub-item is
qualitatively different from G6 and G3-curved. It does not
propose a new measurement gate. The methodology question is:
**where in the bake does the artifact come from?** The answer
determines whether the disposition is fix-and-ship or
document-and-defer.

**Phenomenon.** Ä's base diagonals classify just outside G3's
STRAIGHT class:

- Ä s1 (right diagonal): p95 = 0.103, just above the 0.100
  threshold (3% margin) — classified SMOOTH-CURVED.
- Ä s2 (crossbar): max = 0.290, just above π/12 = 0.262 (10%
  margin) — classified SHARP-CORNER.

Pure A is well clear: A s1 p95 = 0.010; A s2 max = 0.102. Ä's
base glyph is nominally identical to A, so the geometric
divergence indicates `scripts/generate_strokes_auto.py::bake_composite`
introduces slight curvature/corner artifacts on Ä's base diagonals
that pure A doesn't have. The same pattern likely affects Ö and Ü.

**Investigation plan.**

1. **Reproduce in isolation.** Bake Ä via `bake_composite` and
   compare the resulting polyline against a fresh pure-A bake at
   the same code state. Confirm the divergence is reproducible
   (not corpus noise).
2. **Localize.** Which step of `bake_composite` introduces the
   curvature? Candidates: composite-mask construction (base + dot
   union); skeleton-walk on the composite mask (the dot ink may
   pull the skeleton near the top of the base); anchor resolution
   differences between A and Ä rasters (the optical bbox shifts
   when the diacritic is included); post-bake smoothing applied
   only to composites.
3. **Characterize.** If it's a mask-construction step, the fix is
   bake-pipeline scoped. If it's a font-rasterization difference
   (Ä's diacritic affecting optical bbox centering), the fix may
   be intrinsic to the composite design.
4. **Disposition decision tree.**
   - **Reproducible on Light calibrator output AND fixable in
     `bake_composite`** → fix the bake; re-bake Light composite
     umlauts; ship.
   - **Only appears in Regular hand-calibrated artifacts** (the
     bake output for Light doesn't show the artifact, or the
     artifact appears only because Regular's hand-calibration
     happened to leave residual divergence) → document as a
     known-limitation note. Regular ships these letters
     hand-calibrated, so there's no functional impact on the
     shipped product.
   - **Reproducible but rooted in font rasterization** (not bake
     logic) → document as intrinsic; flag in the methodology
     chapter as an example of where the bake honestly mirrors
     font-rendering quirks.

**Methodology framing.** This is the smaller-stakes methodology
vignette: not a gate, but a worked example of how the calibration
pipeline surfaces issues that don't fit any existing metric. The
useful claim is "we identified the artifact, characterized it,
chose disposition based on root cause" — regardless of which
branch of the decision tree fires.

**Effort.** M — bake-pipeline analysis + targeted re-bake +
disposition decision. Less predictable than G6/G3-curved because
the investigation may take longer than any subsequent
implementation work.

---

## Sequencing

**G6 first.** Closest in structure to G4 (junction-class metric;
polish-preservation check; threshold-derivation pattern). Fastest
path to a first Phase 2c deliverable. G6's design pass exercises
the predict-verify-refine methodology on the smallest novel design
surface, surfacing any pattern adjustments before G3-curved
follows.

**G3-curved second.** Reuses G3's existing classifier; the
sliding-window metric is mechanical once the design pattern is
locked. Benefits from any methodology refinements that emerged
from G6.

**Composite-umlaut investigation: anytime.** Not on the
gate-design critical path. Could run in parallel with G6 if
bandwidth allows; deferred to last if not.

**Hard ordering constraint:** none. G6 and G3-curved are
independent. The composite-umlaut sub-item is fully independent
of both.

---

## Methodology-chapter framing

The Phase 2b → Phase 2c arc gives the methodology chapter a
"gate-completeness narrative":

- Phase 2b Track B shipped three measurement gates (G1 /
  G3-straight / G4) and explicitly identified two
  unmeasured-threshold gaps.
- Phase 2c closes both gaps (G6 + G3-curved) and dispositions
  the composite-umlaut investigation.
- Result: full Rule 1–4 measurement coverage. The §6 tally in
  `BAKE_INVARIANTS.md` reads as a closed set rather than a
  closed set with footnotes.

**The narrative is contingent on Phase 2c actually shipping.** If
Phase 2c becomes post-thesis, the methodology chapter frames it
differently: "We identified two unmeasured-threshold gaps plus
one bake-artifact investigation during Track B; scoped them in
`phase2c_design.md`; deferred per timing. The Track B gate set
ships as enforced; the gaps are explicitly documented as known
limitations, not hidden as oversights." The defer framing is
defensible — the thesis claim is about the methodology + the
corpus, not about gate-set completeness for its own sake.

Either way, **having Phase 2c scoped (this doc) is the
load-bearing artifact for the methodology chapter.** The chapter
cites this doc whether or not the gates ship. The doc gives the
gap closure a defined shape that can be either claimed-as-shipped
or claimed-as-scoped-and-deferred.

**Dual purpose surfaced by G6.** Phase 2b's gates (G1 / G3-straight
/ G4 / G5) function primarily as freeze-gates: they protect the
shipped Regular artifact from regression. G6's design pass surfaces
a second purpose — measurement instrument for future-font auto-
calibration. Regular is frozen; G6 cannot meaningfully "protect"
it. But when Primae Light or a future weight runs its own polish-
session workflow, G6 quantifies T-junction attachment drift exactly
as G4 quantifies end-to-end junction kink drift.

The dual-purpose framing is grounded in two findings the G6
design pass surfaced:

1. *The polyline is the operational definition of letter geometry,
   not a rendering input.* The `strokes.json` cps are consumed six
   ways: observe guide-dot animation, direct start dots, guided
   ghost render + checkpoint advancement, freeWrite Fréchet,
   Werkstatt Hausdorff, KP overlay. Gates measure properties of
   THIS data structure; the rendered glyph is one consumer of many.
   Methodology claims should accordingly speak to the polyline's
   geometric properties, not to visual fidelity in any single
   renderer.

2. *G6's geometric class is exactly the class that motivated the
   calibrator-overrides-bake architecture.* The auto-calibrator's
   documented failure cluster (`docs/LESSONS.md` Part A §1-3;
   `research_data/spec_decision/framing.md:67-98`) was R, b, d, P
   bowl-on-stem T-junctions where `skeletonize` produced spurious
   medial-axis branches. G6 IS the measurement primitive for this
   class. The gate's existence is therefore directly traceable to
   the architectural decision that justified the entire hand-
   calibrator workflow — making G6 a natural anchor for the
   methodology chapter's narrative about why hand calibration is
   necessary.

The methodology chapter should be explicit about both purposes:
gates as freeze-protection for shipped artifacts (G1, G3, G4
primary use) and gates as calibration instruments for future
artifacts (G6 primary use; arguably G3-curved if/when it ships).
Every gate serves both roles to some degree — G6 is the case
where the calibration-instrument role IS the design driver, and
the threshold derivation reflects that (800% margin vs G3/G4's
~80-95%). This dual framing strengthens the "predict explicitly,
verify empirically" arc: G6 was predicted as a freeze-gate
analogue to G4, then the data (Regular is frozen; bowl-bearing
archetype already stable; no candidate to gate) surfaced that the
gate's actual role is different. The predict-verify-refine
pattern operates on the gate's PURPOSE, not only on its METRIC.

---

## Doc updates after Phase 2c lands

If/when **G6 and G3-curved ship**, update:

- `docs/BAKE_INVARIANTS.md` §6 (Enforcement tally): Threshold
  3-curved row + a new Threshold-for-mid-stroke-attachment row
  move from "Not enforced" to "Enforced via `bake-gates.yml`".
  Update the §6 closing "Net." paragraph accordingly.
- `docs/BAKE_INVARIANTS.md` §1 Rule 4 (scope-constraint
  paragraph at line ~343): point at G6 instead of "future
  Phase 2c work".
- `docs/BAKE_INVARIANTS.md` §2 Threshold 3 (curved-stroke check
  section at line ~287): point at G3-curved instead of
  "post-Phase-2b future work".
- `docs/PROJECT_STATUS.md` §5.2 (Phase 2c naming question): mark
  RESOLVED with the gate-completion commit reference.
- `docs/ROADMAP.md`: add a one-line note to the at-a-glance
  summary if Phase 2c becomes an active engineering workstream.
- `research_data/phase2b_gates/g4_calibration_run.md` "Discovered
  scope constraint" section: point at `g6_design.md` +
  `g6_calibration_run.md`.
- `research_data/phase2b_gates/g3_calibration_run.md` "Borderline
  classifications" section: point at the composite-umlaut
  investigation outcome (fix-and-ship vs document-and-defer).
- `research_data/phase2b_gates/README.md`: list `g6_design.md`,
  `g6_calibration_run.md`, `g3_curved_design.md`,
  `g3_curved_calibration_run.md` once they land.

If **only the composite-umlaut investigation completes** (G6 +
G3-curved deferred), update only the `g3_calibration_run.md`
borderline-section reference; leave the §6 tally + Threshold
3-curved + Rule 4 scope-constraint refs in place pointing at this
doc.

If **Phase 2c is deferred entirely** to post-thesis, this doc
stays as-is and is cited by the methodology chapter as the
explicit scoping of the deferred work.
