# Spec decision framing — `docs/BAKE_INVARIANTS.md` Rule 1 / Rule 2

The choice between SPEC-MEDIAL-AXIS and SPEC-VISUAL-APPROVAL for what
"the centerline" means, and the empirical evidence that drove it.

Persisted from the May 2026 Phase-2b investigation. Cited by
`docs/BAKE_INVARIANTS.md` and (eventually) by the thesis methodology
chapter.

---

## The fork

Two coherent specifications of "the polyline":

| Spec | Centerline definition | Operational form | Shipped corpus satisfies? |
|---|---|---|---|
| **SPEC-MEDIAL-AXIS** | The medial axis of the ink. | Asymmetry ≤ 0.10 / 0.20 (absolute geometric) | 18 / 59 letters |
| **SPEC-VISUAL-APPROVAL** | The polyline that survived visual review against the live letter at iPad render scale. | "No drift from approved reference" | 59 / 59 by construction |

Both specs are coherent. They make **different thesis claims**.

## What `docs/LESSONS.md` Part A already argued

Already on the page for SPEC-VISUAL-APPROVAL:

- **Part A §1** — "Tool-assisted authorship beats fully-automated
  bake for handwriting pedagogy."
- **Part A §2** — "Medial-axis math ≠ pedagogical centerline. The
  mathematical medial axis … coincides with what a human reads as
  'the line through the middle of the stroke' for simple shapes.
  For asymmetric or junction-heavy shapes it branches, takes
  detours, or sits visibly off-center."

This is the maintainer's prior. The investigations below quantify it.

## Investigation 1 — Scoring tolerance

**Question.** Is the SPEC-MEDIAL-AXIS drift large enough to affect
runtime scoring?

**Method.** For each polyline point, compute the absolute offset
from the local medial axis (`asymmetry × stroke_width / 2`).
Compare against the runtime's scoring tolerances:
- Guided-phase: `checkpointRadius × radiusMultiplier`, default
  `0.05` bbox-relative — `12–24 raster-px` per letter.
- FreeWrite-phase: `6 × checkpointRadius = 0.30` normalized —
  `88–209 raster-px`.

**Result.**

| Comparison | Letters within | Letters over |
|---|---:|---:|
| Drift ≤ guided-phase tolerance | 42 / 59 | 17 / 59 |
| Drift ≤ freeWrite tolerance | 58 / 59 | 1 / 59 |

**Finding.** The drift is **pedagogically invisible in freeWrite
scoring** and visible but rare in guided-phase scoring (and only at
apex / junction points). Even on the worst letter (V's apex at 93
raster-px max), the drift sits well within the freeWrite-phase
acceptance band.

**Implication.** Whether SPEC-MEDIAL-AXIS is satisfied does not
materially affect what a child experiences during practice. The
runtime is robust to the drift the bake produces.

## Investigation 2 — Calibrator vs bake (does David's eye target the medial axis?)

**Question.** When David hand-corrects polylines via the calibrator,
does he move them **toward** the geometric medial axis (which would
suggest SPEC-MEDIAL-AXIS is his implicit target), or somewhere else?

**Method.** Compared the asymmetry profile of bake output (pre-
`e8bd3075`) vs calibrator output (HEAD) for the 52 letters that
existed in both states. Aggregated change in mean asymmetry per
letter.

**Result.**

| Direction | Letters |
|---|---:|
| Calibrator improves vs bake (mean Δ < −0.005) | 20 |
| Bake better than calibrator (mean Δ > +0.005) | 16 |
| Effectively unchanged (|Δ| ≤ 0.005) | 16 |

Largest regressions where the calibrator **increased** asymmetry vs
the bake: `d` +0.271, `Y` +0.184, `r` +0.107, `n` +0.090, `J` +0.078.

**Finding.** The calibrator did **not** systematically move polylines
toward the medial axis. The distribution is roughly balanced, and
several letters had the calibrator deliberately move the polyline
**away** from the medial axis. Three letters (D, J, L) even flipped
from G1-pass under the bake to G1-fail under the calibrator.

**Implication.** David's eye and the geometric medial axis are
**different quality criteria**. Whatever the calibrator targets, it
is not "medial-axis correctness." SPEC-MEDIAL-AXIS does not describe
what is actually being optimised.

## Investigation 3 — Medial-axis rendering on closed-bowl letters

**Question.** Would a hypothetical SPEC-MEDIAL-AXIS-perfect bake
produce visibly correct polylines for the letters where the bake
currently struggles most (R, b, d)?

**Method.** Rendered `skimage.morphology.skeletonize()` output (the
bare medial axis) alongside the shipped (calibrator-tuned) polyline
on top of the live letter ink, for 5 letters: D, P, R, b, d.

**Result.**

| Letter | Medial axis verdict |
|---|---|
| D | Coincides with shipped polyline. Both correct. |
| P | Small spur at the bowl-stem T-junction. Borderline. |
| R | **Two cross-branches** — bowl-stem and leg-bowl. Pedagogically misleading. |
| b | **Horizontal cross-branch** at the bowl-stem junction. |
| d | Same mechanism as b. |

**Finding.** For R, b, d, the bare medial axis includes branches
that **are not part of how a human writes the letter**. They are
mathematically the equidistant locus, but they imply pen-lifts or
direction changes that don't exist in the writing motion. This is
direct visual evidence of `docs/LESSONS.md` Part A §2.

**Implication.** SPEC-MEDIAL-AXIS produces incorrect polylines for
at least three letters (and structurally similar geometries).
Adopting it as the operational form of Rule 1 would write a
contradiction into `docs/BAKE_INVARIANTS.md` — the rule would be
unsatisfiable for those letters without departing from the medial
axis.

## Synthesis — why SPEC-VISUAL-APPROVAL

Each investigation alone is suggestive. Together they form a
coherent case:

- **Investigation 1** says SPEC-MEDIAL-AXIS doesn't matter at runtime.
- **Investigation 2** says SPEC-MEDIAL-AXIS isn't what the
  maintainer optimises.
- **Investigation 3** says SPEC-MEDIAL-AXIS is positively wrong for
  some geometries.

The defensible position is SPEC-VISUAL-APPROVAL: the polyline is
what the maintainer approved by eye at iPad render scale, the
shipped corpus is the canonical reference, and automated gates
measure **drift from that reference** rather than absolute geometric
properties of the ink.

This framing is honest about how the bake pipeline actually works
(`docs/LESSONS.md` Part A §1) and what the calibrator does
(`docs/LESSONS.md` Part A §7), and it makes the thesis claim
provable: every shipped letter trivially satisfies the rule because
the rule is defined relative to the shipped letter.

## Trade-off accepted

SPEC-VISUAL-APPROVAL accepts:

- A weaker reproducibility claim — "another maintainer with
  different eyes could ship a different corpus and both would
  satisfy the rule, internally." Mitigated by:
  - The documented visual-review cadence in BAKE_INVARIANTS.md §4
  - The captured session-pair corpus in
    `research_data/calibration_sessions/` (transparent record of
    what was changed and when)
- No closed-form acceptance test for new letters; the maintainer
  has to sign off. Mitigated by:
  - The sweep workflow (CLAUDE.md → BAKE_INVARIANTS.md §3 → §13.7
    of APP_DOCUMENTATION.md)
  - Threshold 6 (determinism) still automated; bake output is
    byte-stable

## Open question — captured in `docs/ROADMAP.md`

After enough session pairs accumulate (Track C), revisit whether a
residual model trained on the corrections becomes attractive. The
22 pairs in 2026-05-22 are insufficient; ~50-100 across multiple
sessions would be the minimum scale for that question.
