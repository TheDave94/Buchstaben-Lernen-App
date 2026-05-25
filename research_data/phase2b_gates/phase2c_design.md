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

**Problem statement.** Lowercase p has stroke 1 (the bowl)
attaching at a non-endpoint of stroke 0 (the stem) — the bowl's
first cp lies at y=0.33 bbox-rel, on the stem's centerline
mid-stroke. The four endpoint-pairing distances for p (s0, s1)
are 144–305 px apart in both rounds. p has no end-to-end junction
in the geometric sense G4 measures, even though it has a
structural junction in the pedagogical sense (the bowl is attached
to the stem; the pen lifts between strokes during writing). G4
correctly classifies p as `no_junctions_detected`, but the
bowl/stem attachment quality is unmeasured. (See
`g4_calibration_run.md` "Discovered scope constraint" for the
characterization.)

**Proposed approach.** Measure perpendicular distance from the
attaching stroke's endpoint to the host stroke's medial axis, with
a noise-floor tolerance analogous to G3/G4. Polish-preservation
criterion (per the G2 negative-result lesson — see
`g3_calibration_run.md` G2/G3 reflection section): the measured
quantity must not change under maintainer-approved polish.
Candidate metrics:

- (a) Perpendicular distance from attaching-stroke first-cp to
  host-stroke medial-axis polyline
- (b) Perpendicular distance from attaching-stroke first-cp to
  host-stroke LSQ best-fit line
- (c) Drift of (a) or (b) between rounds — analogous to G4's
  kink-drift framing

Decision deferred to G6's own design pass; the calibration corpus
inventory should reveal which formulation is polish-stable.

**Calibration plan.**

1. Inventory mid-stroke attachment letters in the corpus. At
   minimum: p. Survey for others by scanning the `LETTERS` dict in
   `scripts/generate_strokes_auto.py` for letters where one
   stroke's anchors include `STEM_T` / `STEM_B` / `STEM_MID` of
   another stroke, or whose first cp lies on another stroke's
   medial axis. Likely candidates worth checking: k (arm meeting
   stem), some forms of r.
2. Compute the candidate metric for each attachment pair across
   both rounds of the 2026-05-22 corpus.
3. Polish-preservation check: does the metric stay stable between
   rounds for maintainer-approved polish?
4. Derive threshold = `max(observed) + noise-floor margin` (mirror
   G4's `+2.0°` derivation pattern; the noise-floor for
   distance-to-medial-axis needs its own derivation).

**Methodology framing — predict explicitly, verify empirically,
refine when data falsifies.** Prediction: mid-stroke attachment
quality is polish-stable because the attachment point is
structural — David's polish refines stroke geometry around the
attachment without rotating the join itself. If the corpus
falsifies this — polish actively moves attachment points across
rounds — the metric needs different framing (e.g., gate the host
stroke's straightness near the attachment point rather than the
attachment-point position itself). This is the same
predict-verify-refine pattern that G2 used (where the data
falsified the prediction and the gate was retired) and G3/G4 used
(where the data confirmed and the gates shipped).

**Effort.** M — gate design + corpus inventory + calibration + CI
integration. Comparable to G4's effort profile.

---

### G3-curved — Curved-stroke inversion gate

**Problem statement.** G3 enforces that strokes classified
STRAIGHT have low perpendicular-deviation against a least-squares
best-fit line. The symmetric question is: do strokes classified
CURVED have any sub-segments that have accidentally become
STRAIGHT at the resampled scale? `BAKE_INVARIANTS.md` §2
Threshold 3 spec: "no straight runs ≥ 5 consecutive points with
cumulative turn-sum < 5°."

**Proposed approach.** For each stroke classified CURVED by G3's
existing classifier (`scripts/audit_invariants.py::_stroke_angle_stats`
+ the straightness-criterion check in `gate_g3_per_stroke`):

1. Walk the resampled polyline in a sliding window of 5 cps.
2. Compute cumulative `|turn-sum|` within each window.
3. Flag any window with cumulative turn-sum < 5°.
4. Threshold: zero flagged windows for the stroke to pass.

The metric is structurally different from G3's drift-from-reference
framing — it is a **single-stroke shape-purity check**, not a
comparison to a reference. G3 asks "did the polyline drift from
approved geometry?"; G3-curved asks "is the polyline actually
curved everywhere it claims to be?"

**Calibration plan.**

1. Run the classifier from `g3_design.md` over the corpus to
   identify CURVED strokes (D bowl, O, p bowl, b bowl, U arc,
   etc.; the classifier already handles this via the combined
   max + p95 + signed-cumulative criterion documented in G3.1).
2. Compute the sliding-window metric per CURVED stroke.
3. Verify expected pass: hand-calibrated reference strokes should
   all pass (any straight runs would have been caught by the
   maintainer's visual review). Per-stroke results land in
   `g3_curved_calibration_run.md` when ready.
4. Verify polish-preservation: rounds 1 and 2 should produce
   identical pass/fail (polish refines centerline shape but
   doesn't introduce or remove straight sub-segments).
5. Verify the constants (window=5 cps, turn-sum=5°) are
   corpus-appropriate before locking. These come from
   `BAKE_INVARIANTS.md` §2 Threshold 3 spec; the corpus may
   suggest tighter or looser values.

**Methodology framing — predict explicitly, verify empirically,
refine when data falsifies.** Prediction: every CURVED stroke in
the corpus passes (otherwise the maintainer would have flagged it
during visual review). Falsification means either the corpus has
latent issues worth surfacing, or the constants need tuning.
Either outcome is informative — same predict-verify-refine
pattern as G6.

**Effort.** M — classifier reuse + sliding-window metric + corpus
run + CI integration. Smaller code surface than G6 because the
metric is simpler and the classifier is already implemented.

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
