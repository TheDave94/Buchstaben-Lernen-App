# Bake invariants

Single source of truth for what every shipped letter polyline must
satisfy. Three layers:

1. **Permanent rules (four).** Conceptual statements that apply to
   every letter, every weight, every bake.
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

## 1. Permanent rules

A bake that violates any of these is not shippable, regardless of
gate metrics or visual judgment.

### Rule 1 — Centerline location (medial axis)

Every polyline point sits at the medial axis — the middle of the
stroke width — never offset toward either border.

**Enforced by**
- *Construction.* `smoothed_medial_axis` arm walks the
  `skimage.morphology.skeletonize` skeleton, which IS the medial
  axis by definition. See `ARM_STRATEGIES` in
  `scripts/generate_strokes_auto.py` (line ~1922 of the file's
  current top-of-script registry).
- *Construction.* `path`-kind strokes route Dijkstra-on-distance-
  transform between consecutive anchors, with edge weight
  `step_length / (dt[pixel] + 1)` — deep-ink pixels are cheaper,
  so the path tracks the medial axis. See pipeline step 6 in
  APP_DOCUMENTATION.md §13.1.
- *Not enforced as a measurement.* No asymmetry computation in
  the bake, in `verify_bake.sh`, or in CI. Pending Phase 2b
  (Threshold 1 below).

### Rule 2 — Centerline shape

The centerline's overall shape mirrors the inner border (counter)
of the glyph, not the outer silhouette. For asymmetric bands (D
bowl, P bowl, b bowl, R bowl) the centerline resembles the inner
shape, scaled outward into the middle of the band.

Visual check: place the centerline alongside the counter — same
shape, larger size, sitting halfway out into the band.

**Enforced by**
- *Visual review only.* §4 "Visual-review cadence" below; primary
  tool is the sweep-grid workflow (CLAUDE.md "Visual sweep
  workflow" + APP_DOCUMENTATION.md §13.7).
- *Not enforced as a measurement.* No Pearson-correlation
  computation against the inner counter exists in the bake or
  CI. Pending Phase 2b (Threshold 2 below).

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
- *Not enforced (tangent alignment).* No tangent-delta computation
  between connecting stroke pairs. Pending Phase 2b (Threshold 4
  below).

---

## 2. Measurable acceptance thresholds

The four rules expand into six numeric thresholds. A candidate that
fails any measured threshold must auto-reject; thresholds the bake
doesn't measure today are reviewed by the visual-sweep workflow
(§4) and tracked for Phase 2b coverage.

### Threshold 1 — Centerline-location asymmetry (Rule 1)

Mean asymmetry ≤ 0.10; p95 ≤ 0.20.

Per polyline point:
`asymmetry = |d_inner − d_outer| / (d_inner + d_outer)` along the
local cross-section normal, where `d_inner` and `d_outer` are
distances to the inner counter and outer silhouette respectively.

**Enforced by**: not currently enforced. Pending Phase 2b.

### Threshold 2 — Centerline-shape Pearson (Rule 2)

Pearson correlation of turn-angle profiles ≥ 0.85 between the
polyline and the inner counter. At each inner-counter corner with
turn angle > 60°, the polyline's nearest-point corner must be
within ±20°.

**Enforced by**: not currently enforced. Pending Phase 2b.

### Threshold 3 — Stroke type purity (Rule 3)

*Straight strokes.* 95th-percentile perpendicular deviation
between the analytical line and the stem-ink medial axis,
measured across **pure-stem rows only**, ≤ 1.5 px.

Pure-stem rows are rows (or columns, for primarily horizontal /
diagonal strokes) where the stroke is the only one passing
through — operationally: medial-axis pixels at that row span
≤ 1.5 × stem_width AND that row is not within stem_width of any
other stroke's analytical path. Y-branched rows and junction-
adjacent rows are excluded.

The exclusion makes Threshold 3 robust to Y-junctions (bowl-stem,
leg-stem) and vertex meetings (V/W/M/N apex corners), where the
stem ink's medial axis branches into neighbouring strokes'
centerlines.

*Curved strokes.* No straight runs ≥ 5 consecutive points with
cumulative turn-sum < 5°. Each stroke is flagged `'straight'` or
`'curved'` in the `LETTERS` spec.

**Enforced by**: not currently enforced. Pending Phase 2b.

### Threshold 4 — End-to-end junction (Rule 4)

For consecutive stroke pairs flagged end-to-end:
- Endpoint pixel distance = 0
- Tangent delta ≤ 10°

**Enforced by**
- *Endpoint = 0*: construction (per-letter anchor cache, shared-apex
  pre-compute) — see Rule 4 above.
- *Tangent ≤ 10°*: not currently enforced. Pending Phase 2b.

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

## 6. Enforcement tally — current state (before Phase 2b)

| Rule / Threshold | Mechanism |
|---|---|
| Rule 1 — centerline location | Construction (`smoothed_medial_axis` arm, Dijkstra-on-DT for path strokes) |
| Rule 2 — centerline shape | Visual review only (§4) |
| Rule 3 — stroke-type purity | Construction (`kind: line` vs `path` discriminator) |
| Rule 4 — junction (endpoint sharing) | Construction (anchor cache, shared-apex / T-junction pre-compute) |
| Rule 4 — junction (tangent alignment) | **Not enforced** — pending Phase 2b |
| Threshold 1 — asymmetry ≤ 0.10 | **Not enforced** — pending Phase 2b |
| Threshold 2 — Pearson ≥ 0.85 | **Not enforced** — pending Phase 2b |
| Threshold 3 — straight ≤ 1.5 px | **Not enforced** — pending Phase 2b |
| Threshold 4 — end-to-end tangent ≤ 10° | **Not enforced** — pending Phase 2b |
| Threshold 5 — Y-junction gap = 0 px | Construction (T-junction pre-compute) |
| Threshold 6 — determinism + b firewall + byte-identity vs HEAD | Automated (`scripts/verify_bake.sh`, manual / pre-commit) |

**Sweep diagnostics** (overshoot, reversal, max-turn, advisory
skeleton audit) are informational gauges, not ship gates.

**Net.** Three of four permanent rules have construction-only
enforcement; one (Rule 2) is visual-review only. Only Threshold 6
(determinism) is automated. Phase 2b ships Thresholds 1–4 as
automated gates AND lifts `verify_bake.sh` into CI (currently a
manual / pre-commit guard). After Phase 2b, Rules 1 / 3 / 4 move
from "construction-only" to "construction + measurement", Rule 2
moves from "visual-review only" to "measurement-backed visual
review", and the automated enforcement floor becomes "every PR
passes Thresholds 1–6 in CI before merge."
