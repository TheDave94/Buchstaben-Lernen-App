# Bake invariants

Single source of truth for what every shipped letter polyline must
satisfy. Three layers:

1. **Permanent rules (four).** Conceptual statements that apply to
   every letter, every weight, every bake — with their operational
   interpretation under **SPEC-VISUAL-APPROVAL** (see §0 below).
2. **Measurable acceptance thresholds (six).** The numeric form of
   the rules, the version used by visual review and by any
   automated gate.
3. **Rendering model.** How the polyline becomes pixels at runtime
   — independent concerns from how the polyline is produced.

Each rule and threshold carries an **enforcement label** describing
how it's enforced *today* (not aspirationally). Honest labelling is
the contract: an examiner asking "are your invariants enforceable"
gets the same answer as a maintainer asking "will the bake catch
this regression for me."

Audience: maintainer authoring a letter; Claude Code reviewing a
bake change; thesis reader asking about reproducibility.

Replaces the earlier split across `INVARIANTS.md`,
`STROKE_CALIBRATION.md`, and `RENDERING.md`. Those files remain in
place until Phase 2b ships the missing gates; this doc supersedes
them once verified.

---

## 0. The operative spec — SPEC-VISUAL-APPROVAL

A polyline IS-the-centerline if and only if it has been visually
approved by the maintainer at iPad render scale against the live
letter ink. The shipped corpus in
`PrimaeNative/Resources/Letters/Regular/<letter>/strokes.json` is
the canonical reference. Acceptance criteria below measure drift
from that reference, not absolute geometric properties of the ink.

**Empirical evidence.** Three Phase-2b investigations made the case
that the alternative spec (SPEC-MEDIAL-AXIS — "the polyline is the
medial axis of the ink") doesn't hold:

1. The drift between shipped polylines and the geometric medial
   axis is below the runtime's scoring tolerances on 58/59 letters
   (freeWrite) and 42/59 (guided phase).
2. Calibrator hand-corrections do NOT systematically move polylines
   toward the medial axis — 20 letters improved, 16 got worse,
   16 unchanged; D, J, L flipped from "passes G1" to "fails G1"
   when calibrated. David's eye and the medial axis are different
   criteria.
3. For closed-bowl letters with junctions (R, b, d), the bare
   `skimage.skeletonize` medial axis contains cross-branches that
   are not part of how a human writes the letter — visually
   wrong.

Full investigation evidence in
`research_data/spec_decision/framing.md`. This framing is also
consistent with `docs/LESSONS.md` Part A §1 (tool-assisted
authorship beats fully-automated bake) and §2 (medial-axis math
≠ pedagogical centerline).

**Trade-off accepted.** SPEC-VISUAL-APPROVAL is a weaker
reproducibility claim than SPEC-MEDIAL-AXIS. Mitigated by:

- The captured session-pair corpus under
  `research_data/calibration_sessions/<date>/` — transparent
  record of what was changed when.
- The visual-review cadence in §4 below.
- Threshold 6 (determinism) still automated; bake output is
  byte-stable.
- The spec itself is self-revising and version-controlled. When
  the spec or thresholds change because new evidence accumulates
  (e.g. new session pairs surface bake-bug patterns the threshold
  should account for), the change is committed and dated. The
  full methodology trail — including spec revisions — survives
  in git history and in `research_data/`.

---

## 1. Permanent rules

A bake that violates any of these is not shippable, regardless of
gate metrics or visual judgment.

### Rule 1 — Centerline location matches reference

Every shipped polyline's local centerline position matches the
maintainer-approved reference at the same letter and stroke. The
reference is the file at HEAD in
`PrimaeNative/Resources/Letters/Regular/<letter>/strokes.json`.

A re-bake or candidate edit satisfies Rule 1 iff its asymmetry
profile (per-point local cross-section asymmetry) correlates
strongly with the reference's asymmetry profile (Threshold 1,
below).

**Enforced by**
- *Reference comparison.* Pending Phase 2b Track B / G1 — Pearson
  correlation of asymmetry profile vs reference, computed in
  `scripts/audit_invariants.py`. Threshold details in §2.
- *Construction (today).* `smoothed_medial_axis` arm + Dijkstra-
  on-DT for `path` strokes — the bake produces medial-axis-
  tracking polylines as a starting point; the calibrator refines
  them. Documented for context, not enforcement.

### Rule 2 — Centerline shape matches reference

Every shipped polyline's overall turn-angle profile matches the
maintainer-approved reference at the same letter and stroke. The
reference is the file at HEAD.

**Enforced by**
- *Reference comparison.* Pending Phase 2b Track B / G2 — Pearson
  correlation of turn-angle profile vs reference. Threshold
  details in §2.
- *Visual review (today).* §4 below — the sweep workflow. Direct
  human comparison against the live letter is the ground truth
  that the automated gate approximates.

### Rule 3 — Stroke type purity

Every geometric stroke is exactly one type — straight or curved —
never mixed within a single stroke. Pedagogical merging of multiple
geometric strokes into one tracing motion happens in the iPad
anchor GUI, not in the bake.

**Enforced by**
- *Construction.* The `LETTERS` spec discriminates `{"kind": "line",
  ...}` (chord-based composition via arm/joint primitives) vs
  `{"path": [...]}` (Dijkstra-on-DT routing). A line stroke cannot
  accidentally become a curve; they are different code paths.
- *Not enforced as a measurement.* No perpendicular-deviation
  computation against an analytical line. Pending Phase 2b
  (Threshold 3 below).

> *Note: construction enforces type-LABEL purity — a line stroke
> can't become a curve at the data-model level. Visual purity (a
> "line" stroke is actually straight enough; a "curved" stroke is
> actually curved enough) is what Threshold 3 measures. Threshold
> 3 status: see §2.*

### Rule 4 — Junction continuity

Where two geometric strokes meet, they share an exact endpoint
pixel AND their tangents align. No direction discontinuity at the
meeting point.

**Enforced by**
- *Construction (endpoint sharing).* Per-letter `anchor_cache`
  (`scripts/generate_strokes_auto.py:3952`), shared-apex pre-
  compute (`shared_apex_cache` at line 4067, commit `e9cd0f3`),
  T-junction pre-compute (same commit). Both arms terminate on
  the same resolved pixel by construction. See APP_DOCUMENTATION.md
  §13.5.
- *Tangent-kink drift enforced via G4* (post-calibration 2026-05-23).
  See Threshold 4 below.

---

## 2. Measurable acceptance thresholds

The four rules expand into six numeric thresholds. A candidate that
fails any measured threshold must auto-reject; thresholds the bake
doesn't measure today are reviewed by the visual-sweep workflow
(§4) and tracked for Phase 2b coverage.

### Threshold 1 — Asymmetry-profile drift from reference (Rule 1)

Per-point asymmetry computed via the perpendicular cross-section
method (`scripts/audit_invariants.py::gate_g1`):

Pearson correlation of the candidate's per-point asymmetry
sequence against the reference's per-point asymmetry sequence
**≥ 0.2005** (post-calibration 2026-05-23 at corpus state
`d90a5cd8`).

**Threshold derivation (freeze-gate framing).** All 59 letters
of Druckschrift Regular ship as hand-calibrated static artifacts
(commit `6a85811c`). HEAD's `strokes.json` files are the canonical
reference. T1 functions as a freeze gate: any PR producing drift
larger than David's smallest previously-approved polish edit gets
flagged for manual review.

Calibration procedure: run `gate_g1_per_stroke(round1, round2,
mask, bbox, threshold=1.0)` for each (letter, stroke) pair in the
13-letter 2026-05-22 session-pair corpus, where round-1 =
`pre_polyline` of the earliest session JSON and round-2 = HEAD
`strokes.json`. Threshold = `min(real Pearson)` across non-vacuous
strokes. No safety margin (the reference is static; there is no
algorithmic noise floor to subtract against).

Vacuous-pass cases excluded from the min: `not_applicable_too_short`
(1-cp dot strokes), `insufficient_measured_points` (n_measured < 10),
`low_variance_asymmetry` (asymmetry std < `G1_MIN_ASYMMETRY_STD =
0.05` — sub-pixel-noise-floor strokes like uniform-stem l, I).

Derived: `min = 0.2005` at letter `b` stroke 0 (closed-bowl polish).
Full per-letter table + interpretation in
`research_data/phase2b_gates/g1_calibration_run.md`.

**Enforced by**: `scripts/audit_invariants.py::gate_g1` (CLI:
`scripts/run_gates.py --gate g1`), wired into CI as a PR merge-
blocker via `.github/workflows/bake-gates.yml` (G5).

### Threshold 2 — Turn-angle-profile drift from reference (Rule 2)

Pearson correlation of the candidate's turn-angle profile (signed
angle between consecutive segments, arc-length resampled to 100
points) against the reference's turn-angle profile.

**Threshold calibration.** **Investigated 2026-05-23; no threshold
derivable from current corpus.** The 2026-05-22 session-pair corpus
revealed that turn-angle Pearson is intrinsically polish-sensitive:
maintainer-approved polish edits actively redistribute where curves
bend along their length, producing Pearson values spread essentially
uniformly from -0.04 to 0.99 across 12 polished strokes — no usable
cluster structure to anchor a threshold.

The implementation is available at `scripts/audit_invariants.py::gate_g2`
and routed in `scripts/run_gates.py --gate g2`; it is **not currently
enforced**. Full calibration findings, including the three-class
partition attempt and resample-validation diagnostics, are documented
in `research_data/phase2b_gates/g2_calibration_run.md`.

**Future paths:**
- Larger calibration corpus (50+ session pairs across more letters)
  may admit per-stroke-class thresholds.
- Distribution-shift detection (Option IV — compare PR's Pearson
  distribution against corpus baseline rather than per-stroke threshold)
  reframes the gate away from per-stroke pass/fail. Out of scope for
  the current Phase 2b round.

**Enforced by**: not currently enforced; investigation complete; revisit
gated on either more calibration data or a distribution-shift framing.

### Threshold 3 — Stroke type purity (Rule 3)

Rule 3 has two parts. The straight-strokes portion ships as G3; the
curved-strokes portion is unimplemented.

**G3 — straight portion (enforced via gate_g3).** 95th-percentile
perpendicular deviation between the candidate's polyline cps (post
arc-length resample to N=100, post endpoint-skip of 3) and the
best-fit straight line through those cps **≤ 2.05 px** (on the 1024²
rasterization mask).

G3 applies only to strokes classified STRAIGHT via a three-part
geometric criterion on the reference's per-segment turn-angle
sequence: `max(|angle|) < π/12` AND `p95(|angle|) < 0.1` rad AND
`|signed cumulative angle| < π/12` (the third criterion added
2026-05-24 during G5 verification — catches smooth long curves
that max+p95 admits because per-segment angles stay small at N=100
resample but net direction change accumulates; see
`g3_design.md` G3.1 "Refinement caught during G5 verification"
subsection). Non-straight strokes (smooth curves, sharp corners,
continuous-walk letters, smooth long curves) vacuous-pass with
reason `not_applicable_not_straight` and are gated by Threshold 4
(junctions, via G4) or by visual review.

**Threshold calibration.** Derived 2026-05-23 against the 2026-05-22
session-pair corpus (13 letters, 23 stroke pairs, 8 STRAIGHT-class)
at HEAD `3c890380`. Polish-preservation verified pairwise: 7 of 8
STRAIGHT strokes had deviation preserved or improved by polish; the
one exception (A s0) increased by 0.07 px (within rasterization sub-
pixel noise). Threshold = max(per-stroke max(round1, round2)) + 1 px
safety margin = 1.05 + 1.0 = 2.05 px.

The safety margin (1 px) differs from G1's no-margin approach: G3's
measurement noise floor is rasterization jitter on the 1024² mask,
not algorithmic determinism, so a small margin is warranted. See
`research_data/phase2b_gates/g3_design.md` G3.7 step 5 for the
rationale and `research_data/phase2b_gates/g3_calibration_run.md`
for the full per-stroke table and borderline-classification notes
(Ä s1 / Ä s2 sit just outside the STRAIGHT class due to composite-
umlaut-bake artifacts; pure A equivalents are well clear of the
boundaries).

**Enforced by**: `scripts/audit_invariants.py::gate_g3` (CLI:
`scripts/run_gates.py --gate g3`), wired into CI as a PR merge-
blocker via `.github/workflows/bake-gates.yml` (G5).

**Curved portion (not yet enforced).** No straight runs ≥ 5
consecutive points with cumulative turn-sum < 5°. Each stroke is
flagged `'straight'` or `'curved'` in the `LETTERS` spec.

This curved-stroke check is not yet implemented; it would be a
separate gate from G3, which addresses only the straight-strokes
portion of Rule 3. Pending future Phase 2b work or methodology-
chapter discussion.

### Threshold 4 — End-to-end junction (Rule 4)

Rule 4 has two parts. The endpoint-distance portion is enforced by
construction; the tangent-kink-drift portion ships as G4.

**Endpoint pixel distance = 0** (enforced by construction). Per-
letter anchor cache and shared-apex pre-compute ensure consecutive
strokes flagged end-to-end share their meeting pixel exactly.

**G4 — tangent-kink drift portion (enforced via gate_g4).** Drift
of per-junction kink between candidate and reference **≤ 4.43°**.

Per-junction kink is computed as the outgoing-vs-outgoing tangent
angle (LSQ best-fit line through 5 junction-adjacent cps after
endpoint-skip 3 on each stroke; oriented outward from the junction
toward each stroke's interior), expressed as
`kink_deg = |180° − outgoing_outgoing_angle|`. Semantics:
- 0° = pen-continuation (rare/absent in Primae)
- ~90° = T-corner
- ~143° = apex / V-shape
- ~178° = point-meeting

Gate metric: `kink_drift_deg = |kink_candidate − kink_reference|`.
Pass iff `kink_drift_deg ≤ 4.43°`.

G4 applies to consecutive stroke pairs that form an end-to-end
junction in BOTH candidate and reference, detected geometrically:
the minimum-distance endpoint pairing across the four pairings
(first/first, first/last, last/first, last/last) must be < 15 px on
the 1024² mask.

**Scope constraint discovered during calibration:** mid-stroke
attachment junctions (where one stroke endpoint lies in another
stroke's interior, e.g., lowercase p's bowl attaches mid-stem)
classify as `no_junctions_detected` and are out of G4's scope. G4
specifically gates end-to-end junctions per Rule 4. Mid-stroke
attachment quality could be gated by a separate metric in future
Phase 2c work; flagged for methodology-chapter discussion. See
`research_data/phase2b_gates/g4_calibration_run.md` "Discovered
scope constraint" section.

**Threshold calibration.** Derived 2026-05-23 against the 2026-05-22
session-pair corpus (13 letters; 5 detected end-to-end junctions —
A, D, U, Ä, Ü) at HEAD `108c8d47`. Polish-preservation verified
pairwise: all 5 junctions had kink drift ≤ 2.5° between rounds,
with 2 junctions at exactly 0.00° and median 0.2°. Threshold =
max(per-junction `kink_drift_deg`) + 2° safety margin = 2.43 + 2.0
= 4.43°.

The 2° safety margin accounts for LSQ-tangent fit uncertainty on
5 cps + arc-length-resample noise. Self-comparison returns drift =
0.00°, so the margin reflects gate-time PR-vs-HEAD measurement
noise rather than corpus noise.

**Enforced by:**
- *Endpoint = 0*: construction (anchor cache, shared-apex
  pre-compute) — see Rule 4 above.
- *Tangent-kink drift ≤ 4.43°*: `scripts/audit_invariants.py::gate_g4`
  (CLI: `scripts/run_gates.py --gate g4`), wired into CI as a PR
  merge-blocker via `.github/workflows/bake-gates.yml` (G5).

### Threshold 5 — Y-junction continuity (Rule 4)

At every Y-junction, the curved stroke's endpoint and the trunk
stroke's endpoint are both the geometric intersection of their
centerlines (extended tangentially if needed). The intersection
pixel is shared by both polylines.

**Measurement**: gap between the two polylines' shared-end
checkpoints = 0 px by construction.

**Fallback**: when the two tangent lines are near-parallel (angle
< 10°), the computed intersection lies outside the ink mask, or
is more than `stem_width` away from the nominal anchor row, the
implementation falls back to the literal resolved anchor pixel.
Both polylines still terminate at the same pixel; only the
geometric "intersection" interpretation is approximated. Fallback
cases are documented in the bake's debug output for review.

**Enforced by**: construction — T-junction pre-compute in
`scripts/generate_strokes_auto.py` (commit `e9cd0f3`). By
construction the gap is 0 px.

### Threshold 6 — Determinism

3 successive bakes produce byte-identical output. The `b`-firewall
is a special case: `PrimaeNative/Resources/Letters/Regular/b_l/strokes.json`
must match commit `a803d9d`.

**Enforced by**: automated.
- 3-trial determinism: `scripts/verify_bake.sh:51-67`.
- Byte-identity vs HEAD (full bake matches checked-in strokes.json
  for every letter the `LETTERS` dict covers): `scripts/verify_bake.sh:69-89`.
- `b`-firewall (explicit, redundant with byte-identity above, but
  named separately so a failure log calls it out):
  `scripts/verify_bake.sh:91-102`.

**CI status**: `verify_bake.sh` is **not in CI today**. It is a
manual / pre-commit guard; run it before any commit that touches
`generate_strokes_auto.py`. Lifting it into CI is part of Phase
2b — after Phase 2b, every PR runs determinism + byte-identity +
b-firewall in CI.

---

## 3. Sweep diagnostics — informational gauges, not ship gates

The three "gates" CLAUDE.md and APP_DOCUMENTATION.md §13.6 name
(overshoot, reversal, max-turn) are computed by the **sweep
renderer**, not by the bake or CI:

| Gauge | Computes | Where |
|---|---|---|
| Overshoot | Polyline samples outside ink mask (skip-indices excluded) | `scripts/render_sweep_grid.py:104` (function `gates`) |
| Reversal | Consecutive-tangent pairs with cosine `< REVERSAL_COSINE_CUTOFF` (= -0.1, ≈ > 96° turn) | `scripts/render_sweep_grid.py:104` |
| Max-turn | Worst angular turn between consecutive tangents (degrees) | `scripts/render_sweep_grid.py:104` |

The bake itself (`generate_strokes_auto.py:main()` around line
4566) writes JSON unconditionally. The three gauges surface in the
sweep grid's per-panel overlay during authoring; they aid the
visual review but do not block a commit.

A separate **advisory** CI job runs `skeleton_audit.py` (anchor
drift) and an inline kink scan (turn > 150°): see
`.github/workflows/ios-build.yml:13-53`. Both deliberately
`sys.exit(0)` regardless of warnings, so neither blocks a merge.
Treat them as canaries, not gates.

---

## 4. Visual-review cadence

### David's eyes required when

- First letter shipped in a new geometric family (closed-bowl,
  bumps, circulars, umlauts, ß).
- New bake primitive introduced or modified (arm strategy, joint
  strategy, anchor resolver, pre-compute).
- New invariant rule or threshold added; threshold tightening.
- Candidate passes all automated checks but Claude Code flags low
  confidence on shape match or any other rule.

### Claude Code may ship autonomously when

- Candidate passes every automated check that exists today
  (Threshold 6 — `verify_bake.sh`) AND every Phase 2b gate as
  each lands AND the letter is in a family with at least one
  already-visually-approved member.
- Re-bake of a previously approved spec with no algorithmic
  changes.

David retains spot-check veto: if a shipped letter reads wrong,
the calibration grows a rule (a new measurable threshold) before
further shipping.

The visual-sweep workflow (CLAUDE.md "Visual sweep workflow" +
APP_DOCUMENTATION.md §13.7) is the primary tool: bake all
candidates, render PNG grid, let David pick. Do not pre-argue
constructions in prose; let the grid speak.

---

## 5. Rendering model

The polyline is the **input**. How a renderer turns the polyline
into pixels is the **output**. They are independent concerns.

### 5.1 Core principle

The letter polyline (in
`PrimaeNative/Resources/Letters/<weight>/<L>/strokes.json`) is the
**pen centerline** of the letter, in bbox-relative coordinates
[0, 1]. It is size-agnostic, instrument-agnostic, and width-
agnostic.

### 5.2 Polyline properties

For each letter, a sequence of strokes. Each stroke is a polyline
of 2D points. The polyline traces the path a pen would have taken
to produce that letter shape — its centerline, not its outline.

The polyline:
- Has endpoints at the visual corners of where the pen lifts
  (e.g. M's BL, BR; each leg of N).
- Has filleted interior joints at intra-stroke turning points
  (M's peaks and valley) with fillet radius matching the local
  stroke half-width of the source font. Fillets are part of the
  centerline geometry, not added by the renderer.
- Does NOT carry stroke-width information. Width is a render
  decision.

### 5.3 Renderer responsibilities

Two parameters per render context:

**Letter size.** Multiply bbox-relative coordinates by the target
render size. A 10 cm letter and a 1 cm letter use the same
polyline; only the multiplier changes.

**Stroke width — absolute, not proportional.** Pick stroke width
based on context, NOT proportional to letter size. A child's pen
produces a ~1-2 mm mark whether they write 1 cm or 10 cm letters;
computer fonts scale uniformly in all dimensions, pen-on-paper
does not. Suggested:
- Display glyph for tracing: ~3-4 mm.
- Finger trace render: ~3-4 mm.
- Pencil trace render: ~1 mm.

Stroke with `lineCap: .round` and `lineJoin: .round`. Rounded
caps at endpoints produce the visible letter terminals; the
filleted joints in the polyline data combined with round line
joins produce smooth peaks/valleys.

### 5.4 Scoring is separate from rendering

What "correct trace" means depends on input device.

- **Finger.** Lenient. Glyph-containment scoring: the finger mark
  stays within the display band. Drift within the band is fine —
  finger touches are exploratory.
- **Pencil.** Precise. Centerline-distance scoring: pencil-tip
  distance to the polyline centerline, with tolerance ~50% of
  the display band's half-width. Outside that tolerance counts
  as off-track.

The polyline supports both scoring modes without modification.

### 5.5 Calibrator vs gameplay

`StrokeCalibrationOverlay.swift` is a diagnostic view used during
authoring. It shows the font's outline (ink letter) with a thin
red polyline overlay. This is correct for authoring but is NOT
the gameplay rendering — the gameplay view should stroke the
polyline thick per the principles above, not render the font's
outline.

When debugging discrepancies between calibrator and iPad
gameplay, keep this distinction in mind:
- Calibrator: font outline + thin polyline overlay (authoring
  view).
- Gameplay: polyline stroked thick at constant absolute width
  (production view).

---

## 6. Enforcement tally — current state (post-Phase 2b Track B, 2026-05-24)

| Rule / Threshold | Mechanism |
|---|---|
| Rule 1 — centerline matches reference | Visual review (§4) + construction (medial-axis-tracking polyline as starting point, refined via calibrator) |
| Rule 2 — shape matches reference | Visual review (§4) |
| Rule 3 — stroke-type purity | Construction (`kind: line` vs `path` discriminator) |
| Rule 4 — junction (endpoint sharing) | Construction (anchor cache, shared-apex / T-junction pre-compute) |
| Rule 4 — junction (tangent alignment) | Enforced via G4 (`bake-gates.yml`) |
| Threshold 1 — asymmetry-profile Pearson vs reference ≥ 0.2005 (post-G1 calibration 2026-05-23) | **Enforced** via `bake-gates.yml` (G5); CLI: `scripts/run_gates.py --gate g1` |
| Threshold 2 — turn-angle-profile Pearson vs reference | **Investigated 2026-05-23, not viable** as freeze-gate metric; implementation preserved (see `g2_calibration_run.md`) |
| Threshold 3 — straight ≤ 2.05 px (post-G3 calibration 2026-05-23) | **Enforced** via `bake-gates.yml` (G5); CLI: `scripts/run_gates.py --gate g3` |
| Threshold 3 — curved (no straight runs ≥ 5 cp with turn-sum < 5°) | **Not enforced** — pending future Phase 2b |
| Threshold 4 — tangent-kink drift ≤ 4.43° (post-G4 calibration 2026-05-23) | **Enforced** via `bake-gates.yml` (G5); CLI: `scripts/run_gates.py --gate g4` |
| Threshold 5 — Y-junction gap = 0 px | Construction (T-junction pre-compute) |
| Threshold 6 — determinism + b firewall + byte-identity vs HEAD | Automated (`scripts/verify_bake.sh`, manual / pre-commit) |

**Sweep diagnostics** (overshoot, reversal, max-turn, advisory
skeleton audit) are informational gauges, not ship gates.

**Net.** Rules 1 and 2 are operationally defined under
SPEC-VISUAL-APPROVAL (§0): the shipped corpus IS the reference,
and visual review by the maintainer is the criterion. After
Phase 2b Track B (commits `e00a0d8d` G1 / `4f84afc7` G3 /
`cfc70a2d` G4 / `e238ad63` G5, 2026-05-23/24), Rules 1 / 2 are
measurement-backed visual review — G1, G3, G4 detect drift from
the approved reference. Rule 3 has construction enforcement
(`kind: line` vs `path` discriminator). Rule 4 has construction
(endpoint sharing via the anchor cache + T-junction pre-compute)
plus measurement (G4 tangent alignment). Threshold 6
(determinism + b firewall + byte-identity) is automated via
`scripts/verify_bake.sh`. The automated enforcement floor is:
every PR passes G1, G3, G4, and Threshold 6 in CI
(`bake-gates.yml`) before merge. Threshold 2 was investigated
2026-05-23 and is not viable as a freeze-gate metric (preserved
in code; see `g2_calibration_run.md`). Threshold 3-curved (no
straight runs ≥ 5 cp with turn-sum < 5°) remains the one
pending gate. Threshold 5 remains construction-enforced (by the
T-junction pre-compute, which always writes the shared pixel).
