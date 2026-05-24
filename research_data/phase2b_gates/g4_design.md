# G4 — Threshold 4 (Junction-tangent delta) — Design Proposal

**Spec ref:** `docs/BAKE_INVARIANTS.md` §2 Threshold 4 (tangent-delta
portion).
**Inherits from:** `g1_design.md` (freeze-gate framing; arc-length
resample; calibration corpus); `g3_design.md` (conformance-gate
shape; reference-based geometric classifier; polish-preservation
verification procedure; safety margin).
**Status:** design only. No code yet; awaits David approval / redlines.

This doc covers ONLY the G4-specific design questions. Anything
inherited from G1/G2/G3 is referenced rather than restated.

---

## Corpus context (inherited)

All 59 letters of Druckschrift Regular ship as hand-calibrated static
artifacts (commit `6a85811c`). G4 is a freeze gate against HEAD's
`strokes.json` files. Calibration data is the same 2026-05-22
session-pair corpus.

See `g1_design.md` Section "Corpus context" for the full framing.

---

## What's the same as G1/G2/G3

| Aspect | G1/G2/G3 | G4 |
|---|---|---|
| Freeze-gate framing | Yes | Yes |
| Arc-length resample to N=100 | Yes | Same (per-stroke resample before junction-tangent extraction) |
| Endpoint skip | Yes (=3) | Same (=3 for tangent calculation away from the junction) |
| Reference lookup | `HEAD:Letters/Regular/<L>/strokes.json` | Same |
| CLI integration | `run_gates.py --gate g{1,2,3}` | Add `--gate g4` |
| Output format | Stdout default; `--json` flag | Same |
| Calibration corpus | 2026-05-22 session pairs | Same |
| Mask requirement | G1 yes; G2/G3 no | G4 no (pure polyline property) |
| Comparison direction | G1/G2 lower-bound (≥); G3 upper-bound (≤) | G4 upper-bound (≤) — second conformance gate |

G4 inherits G3's conformance-gate shape (per the drift/conformance
taxonomy in `g3_design.md` "two gate shapes in the family"):
intrinsic geometric property of the candidate, upper-bounded by a
corpus-derived threshold. Polish-preservation must be verified
pairwise before threshold derivation.

---

## Novel — unit of measurement is the JUNCTION, not the stroke

G1/G2/G3 measure a per-stroke property. **G4 measures a per-junction
property** (per stroke PAIR meeting at an endpoint).

This affects the implementation shape:

- `gate_g4_per_junction(stroke_a, stroke_b, junction_pairing, bbox,
  threshold)` takes TWO strokes plus the junction's endpoint pairing
  (which endpoint of A meets which endpoint of B).
- `gate_g4` (letter-level) iterates over CONSECUTIVE stroke pairs and
  any other geometric end-to-end pairings within the letter, calls
  `gate_g4_per_junction` for each, aggregates per-junction results.
- The letter-level result reports a list of junctions tested rather
  than a list of strokes. Some letters will have zero junctions
  (b/l/W/m/N/v all ship as single strokes per the inspected schema);
  those letters vacuous-pass at the letter level.
- `GATE_METADATA` likely doesn't need a new flag — the per-junction
  iteration is internal to `gate_g4`. `run_gates.py` continues to call
  `gate_g4(candidate_strokes, reference_strokes, bbox, threshold)` per
  letter; the per-pair iteration happens inside.

---

## Polish-preservation prediction

**Prediction:** Junction tangent delta IS polish-preserved.

**Why:** Junctions are designed structural features. David's polish
typically refines centerline position within each stroke without
rotating the junction's tangent. If anything, polish should ALIGN
tangents better (reduce delta) as rough first-pass junctions get
cleaned up.

**Empirical pattern predicted on the corpus:**
- Per-junction tangent delta values should be similar between round-1
  and round-2 for each junction in the corpus.
- If anything, round-2 deltas should be ≤ round-1 deltas (polish
  aligns junctions).
- A round-2 delta noticeably ABOVE round-1 would suggest polish added
  misalignment — flag for investigation.

**Soft-V trigger:** polish systematically INCREASING tangent delta
falsifies the prediction. Calibration is set up to verify pairwise
before threshold derivation (mirroring G3's procedure).

---

## G4-specific design

### G4.1 — Which stroke pairs does G4 apply to?

**Recommendation: geometric junction detection on the reference
polylines.** A pair of strokes (A, B) forms a junction iff the
endpoint distance between some endpoint of A and some endpoint of B
is below an epsilon threshold (in raster pixels, post bbox-conversion).

| Option | Rationale |
|---|---|
| (a) Manual per-letter junction config | Brittle. Spec is retired for Regular; the `LETTERS` dict no longer drives output and may carry stale junction flags. |
| (b) Geometric detection via endpoint-distance check **(recommended)** | Self-documenting at gate time. Generalizes to new fonts. Mirrors G3's reference-based classifier pattern. |

Threshold: `G4_JUNCTION_EPSILON_PX = 2.0` (raster pixels on the 1024²
mask). Empirically derived from inspection: D's top junction has both
strokes starting at exactly (0.160, 0.060) — distance 0 px; A's apex
has endpoints at (0.583, 0.031) and (0.587, 0.039) — distance ~9 px
in bbox-rel coords ≈ ~7 px on the rendered mask depending on bbox
size; need to verify during calibration whether 2 px is too tight.
**This constant may need adjustment after calibration measurement.**

Endpoint pairings to check (for each pair A, B):
- last(A) ↔ first(B) — the natural "pen continues" pairing
- last(A) ↔ last(B) — both strokes terminate at the junction (A apex)
- first(A) ↔ first(B) — both strokes begin at the junction (D top)
- first(A) ↔ last(B) — less common

A junction "fires" for the pairing with the smallest endpoint
distance, if below `G4_JUNCTION_EPSILON_PX`.

### G4.2 — Smooth vs corner junction classifier (reference-based)

**Critical question for G4 viability:** the spec says tangent delta
≤ 10°, but many junctions in the corpus are CORNER junctions (e.g.,
A's apex where two diagonals meet at ~60-120°). The spec's "10°"
applies only to SMOOTH junctions where the pen flows continuously
through.

**Recommendation: geometric classifier on the reference tangent
delta.** A junction is "smooth" iff `reference_tangent_delta <
G4_SMOOTH_JUNCTION_MAX`. Corner junctions vacuous-pass with
`reason="not_applicable_corner_junction"`. G4 applies only to smooth
junctions.

Threshold for "smooth": `G4_SMOOTH_JUNCTION_MAX = 30°` (≈ 0.524 rad).
Empirically derived during calibration; sits between typical smooth
junctions (≤ 10° per spec) and typical corner junctions (≥ 60° for
diagonals meeting at apex). May need tuning.

This mirrors G3's straightness-classifier pattern: the reference's
geometric property decides whether the gate applies.

### G4.3 — Tangent computation

**Recommendation: LSQ best-fit line through the K junction-adjacent
cps after endpoint-skip.** Mirrors G3's `_perpendicular_deviation`
LSQ approach but adapted for tangent direction.

For each stroke at the junction:
1. Identify which endpoint (first or last) is at the junction.
2. Apply endpoint-skip K=3: take cps `[skip:skip+window]` if junction
   is at first, or `[-skip-window:-skip]` if junction is at last.
3. Fit an LSQ line through those K cps.
4. Tangent direction = direction of the line, oriented OUTWARD from
   the junction toward the stroke interior.

Window size: `G4_TANGENT_WINDOW = 5` cps (after the endpoint skip).
Empirically derived; needs to be large enough for a stable fit but
small enough to be local to the junction.

| Alternative | Rejected because |
|---|---|
| Direction of first/last segment only | Vulnerable to single-cp noise |
| Direction from junction to centroid of first K cps | Approximates the LSQ but biased by cp distribution along the window |
| **LSQ on K junction-adjacent cps** | Robust, consistent with G3's primitive |

### G4.4 — Tangent delta sign convention

**Recommendation: outgoing-vs-outgoing angle.**

At a junction where two strokes meet, both strokes have tangents
oriented OUTWARD from the junction toward their respective interiors
(per G4.3). The tangent delta is the angle between these two outgoing
vectors.

- Outgoing-vs-outgoing **= 180°**: the two strokes are co-linear and
  point away from each other (a perfect "pen-flows-straight-through"
  junction)
- Outgoing-vs-outgoing **= 0°**: the two strokes overlap (degenerate;
  shouldn't happen)
- Outgoing-vs-outgoing **= 60°-120°**: corner junction (e.g., A's
  apex)

For G4's spec ("tangent delta ≤ 10°"), this is interpreted as
**"how much does the outgoing-vs-outgoing angle deviate from 180°"**:

```
tangent_delta = |180° - outgoing_outgoing_angle|
```

- Smooth junction (perfect flow): `outgoing_outgoing_angle = 180°` →
  `tangent_delta = 0°`.
- Slightly imperfect smooth junction: `outgoing_outgoing_angle = 175°`
  → `tangent_delta = 5°`.
- Corner junction: `outgoing_outgoing_angle = 60°` →
  `tangent_delta = 120°` (huge; vacuous via G4.2 smoothness
  classifier).

This matches the spec's "≤ 10°" semantics: smaller = smoother, larger
= more misaligned.

### G4.5 — Threshold units

**Recommendation: degrees.** Per BAKE_INVARIANTS.md spec, tangent
delta is expressed in degrees ("≤ 10°"). Degrees are more
interpretable than radians for angular threshold reasoning.

Internal computation may use radians for `math.atan2` / `numpy`
primitives; convert to degrees for the threshold check and report.

### G4.6 — Vacuous-pass conditions

- **Stroke pair without an end-to-end junction** (endpoint distance
  > `G4_JUNCTION_EPSILON_PX`) → `not_applicable_no_junction`. Not a
  pair; G4 doesn't apply.
- **Corner junction** (reference tangent delta ≥
  `G4_SMOOTH_JUNCTION_MAX`) → `not_applicable_corner_junction`.
  Junction is by-design a corner; G4 doesn't gate corners.
- **Strokes too short to compute tangent** (post-skip cp count below
  `G4_TANGENT_WINDOW`) → `insufficient_measured_points`.
- **Single-stroke letter** (no stroke pairs to check) → letter-level
  vacuous; emits no per-junction rows but the letter as a whole
  passes G4.

### G4.7 — Mask requirement

**Not needed.** Tangent computation is a pure polyline property.
`gate_g4_per_junction` takes only polylines + bbox + threshold. Same
as G2 and G3.

### G4.8 — Calibration procedure

Mirrors G3's structure with junction-pair iteration:

For each letter in the 2026-05-22 corpus:
1. Load round-1 polylines (earliest session JSON `pre_polyline`) and
   round-2 polylines (HEAD `strokes.json`).
2. Detect end-to-end junctions in round-2 (round-2 is the canonical
   reference; classification anchored there).
3. For each detected junction:
   a. Compute reference tangent delta on round-2's polylines.
   b. If reference delta ≥ `G4_SMOOTH_JUNCTION_MAX`: mark
      `not_applicable_corner_junction`; skip to next.
   c. Compute candidate tangent delta on round-1's polylines at the
      same junction (assuming round-1 has a junction at the same
      endpoint pairing — verify; if not, surface as "junction
      topology changed between rounds" diagnostic).
   d. Record `(letter, junction_id, ref_delta_round1,
      ref_delta_round2, classification, edit_count)`.

4. **Polish-preservation check.** For all SMOOTH-class junctions:
   - Strokes where `delta_round2 ≤ delta_round1`: count
   - Strokes where `delta_round2 > delta_round1`: count
   - Median Δdelta, max Δdelta, location
   - If polish systematically INCREASES delta (worsened ≥ preserved)
     → soft-V trigger, mirroring G2.

5. **Threshold derivation** (if polish-preservation holds):
   `threshold_deg = max(per-junction max(delta_round1, delta_round2))
   + G4_SAFETY_MARGIN_DEG`.

### G4.9 — Safety margin

G3 used 1 px for rasterization noise. G4's measurement units are
degrees of angle, not pixels. The noise floor is different:
- Arc-length resample stride affects tangent direction by sub-degree
  amounts.
- LSQ fit uncertainty on K=5 cps is typically ≤ 1-2°.

**Recommendation: `G4_SAFETY_MARGIN_DEG = 2.0°`**, pending empirical
verification at calibration. The margin should be small enough not
to admit meaningful junction drift but large enough to absorb the
LSQ-fit + resample noise floor.

If calibration shows the noise floor is meaningfully different from
2°, surface and pick empirically (same gap-finding pattern as G1's
`G1_MIN_ASYMMETRY_STD=0.05`).

### G4.10 — Implementation outline

New code in `scripts/audit_invariants.py`:

```
# Constants
G4_RESAMPLE_N = 100            # mirrors G1/G2/G3
G4_ENDPOINT_SKIP = 3           # mirrors G1/G2/G3
G4_TANGENT_WINDOW = 5          # cps used for LSQ tangent fit
G4_JUNCTION_EPSILON_PX = 2.0   # endpoint-distance threshold
G4_SMOOTH_JUNCTION_MAX = 30.0  # degrees; corner vs smooth boundary
G4_SAFETY_MARGIN_DEG = 2.0     # rasterization + LSQ noise floor


def _stroke_tangent_at_endpoint(poly_px, at_first: bool,
                                  endpoint_skip=G4_ENDPOINT_SKIP,
                                  window=G4_TANGENT_WINDOW) -> tuple[float, float] | None:
    # Return unit vector pointing OUTWARD from the endpoint toward
    # the stroke interior, based on LSQ fit over `window` cps after
    # `endpoint_skip`. Returns None if too few cps.

def _detect_junctions(strokes_rel, bbox) -> list[dict]:
    # For each pair (i, j) with j = i+1, check all four endpoint
    # pairings. Return junctions with endpoint distance below
    # G4_JUNCTION_EPSILON_PX.

def gate_g4_per_junction(stroke_a_rel, stroke_b_rel, pairing,
                          ref_a_rel, ref_b_rel, bbox, threshold_deg,
                          smooth_max_deg=G4_SMOOTH_JUNCTION_MAX) -> dict:
    # 1. Resample all four polylines to G4_RESAMPLE_N.
    # 2. Compute reference outgoing-vs-outgoing angle on (ref_a, ref_b).
    # 3. ref_tangent_delta = |180° - outgoing_outgoing|.
    # 4. If ref_tangent_delta >= smooth_max_deg → vacuous
    #    (not_applicable_corner_junction).
    # 5. If tangent computation fails (insufficient cps) → vacuous
    #    (insufficient_measured_points).
    # 6. Compute candidate tangent delta on (stroke_a, stroke_b).
    # 7. Return { ref_delta_deg, cand_delta_deg, classification,
    #            n_cp_a, n_cp_b, pass: cand_delta_deg <= threshold_deg }

def gate_g4(candidate_strokes_rel, reference_strokes_rel, bbox,
            threshold) -> dict:
    # 1. _detect_junctions(reference_strokes_rel, bbox)
    #    → list of (i, j, pairing) tuples.
    # 2. For each junction, call gate_g4_per_junction with
    #    candidate_strokes[i], candidate_strokes[j], same pairing,
    #    reference_strokes[i], reference_strokes[j], bbox, threshold.
    # 3. Letter pass = all per-junction pass (or no junctions).
```

Approx LoC: ~180 added to `audit_invariants.py`.

**`scripts/run_gates.py`** — add g4 to `GATE_METADATA`:

```
"g4": {
    "function_with_mask": None,
    "function_without_mask": ai.gate_g4,
    "needs_mask": False,
    "title": "junction-tangent delta on smooth end-to-end junctions",
    "comparison": "≤",
}
```

Single-entry addition. ~5 LoC change.

The per-junction iteration is internal to `gate_g4`; `run_gates.py`
calls it per letter and doesn't need to know G4 measures
per-junction. The result dict's `per_stroke` field is replaced with
`per_junction` for G4 — small change to `format_letter_human` to
handle the new key.

**`scripts/calibrate_g4_threshold.py`** — new file, ~160 LoC.
Mirrors G3's calibration pattern with junction iteration and the
polish-preservation pairwise check.

**`scripts/tests/test_gate_g4.py`** — new file, ~120 LoC. Tests:
junction detection (epsilon check; four endpoint pairings), tangent
computation (collinear, perpendicular, mirror-invariant), vacuous
cases (no junction, corner junction, insufficient cps),
smooth-junction pass/fail.

**`docs/BAKE_INVARIANTS.md`** Threshold 4 tangent portion — replace
"≤ 10°" placeholder with derived value once calibration runs.

**Total new code:** ~470 LoC across 2 modified + 2 new files +
1 doc edit.

### G4.11 — Empirical predictions

Predictions for the corpus calibration run (verify or contradict):

1. **Corpus junction count is small.** Letters that ship as single
   strokes (b, l, W, m, N, v) contribute zero junctions. Multi-stroke
   letters in the corpus (A, D, U, p, Ä, Ö, Ü) contribute 1-3
   junctions each. Predict 8-15 total end-to-end junctions detected.

2. **Most junctions are CORNERS, not smooth.** A's apex, the
   diagonal-crossbar contacts (if they're end-to-end), D's top/bottom
   junctions where the bowl meets the stem at a curve-to-vertical
   transition. Predict 2-5 SMOOTH junctions; the rest vacuous as
   corners. **Risk: if zero SMOOTH junctions, G4 hits no-calibration-
   data scenario; soft-V outcome.**

3. **Polish-preservation holds on smooth junctions.** David's polish
   refines centerline positions but doesn't introduce rotational drift
   at junctions. Round-1 and round-2 deltas pairwise similar.

4. **Threshold lands ~3-10°.** Below the spec's 10° upper bound,
   wider than the noise floor (~2°). Empirical via calibration.

**Counter-predictions (what would falsify the design):**
- If round-2 deltas systematically larger than round-1 → soft-V
  trigger.
- If zero SMOOTH junctions in the corpus → can't calibrate;
  implementation preserved as future scaffolding.
- If the corner-vs-smooth classifier boundary (30°) lands in a region
  with empirical ambiguity (junctions clustering AT 25-35°) → tune
  the boundary and re-run.

### G4.12 — Questions flagged during drafting

**Q1: Smooth-junction availability in the corpus.**
The corpus may have very few smooth end-to-end junctions. Many
multi-stroke letters (A, D) have corner junctions, not smooth ones.
This is the highest-risk question for G4 viability. **Action:**
calibration should report ALL junction tangent deltas (both smooth
and corner) so we can see the distribution before committing to a
threshold.

**Q2: Junction-topology changes between rounds.**
If round-1 has a junction at endpoint-pairing X but round-2 has it
at endpoint-pairing Y (because David moved an endpoint significantly
during polish), the calibration script needs to handle this. **Action:**
detect junctions in BOTH rounds and report any topology mismatches as
diagnostic (mirroring G3's stroke-count mismatch notes).

**Q3: 1-cp diacritic dots.**
Ä/Ö/Ü dots are 1-cp strokes (diacritic dots). They have no
junction-eligible endpoints. Need to skip them during junction
detection. **Action:** `_detect_junctions` filters strokes with <
`G4_ENDPOINT_SKIP + G4_TANGENT_WINDOW` cps before attempting pairings.

**Q4: Continuous-walk letters with internal vertices.**
W, m, N, v, b, l ship as single strokes with internal vertices (no
end-to-end stroke pairs). G4 doesn't apply. **Confirmed in schema
inspection 2026-05-23.** They vacuous-pass at the letter level
(zero junctions detected).

**Q5: The `G4_JUNCTION_EPSILON_PX = 2.0` constant.**
A's apex has endpoints at (0.583, 0.031) and (0.587, 0.039) in
bbox-rel coords — distance ~0.009 in [0,1]² which converts to ~9 px
on a 1024² mask depending on A's bbox size. **The 2 px threshold
may be too tight to catch A's apex.** Surface during calibration;
tune to admit known junctions.

---

## Decisions summary

| Section | Decision | Alternative |
|---|---|---|
| **G4.1** | Geometric junction detection via endpoint-distance ≤ G4_JUNCTION_EPSILON_PX (=2.0 px, may tune) | Manual per-letter config (brittle, spec retired) |
| **G4.2** | Reference-based smooth/corner classifier; corner junctions vacuous via `not_applicable_corner_junction` (smooth_max = 30°) | No classifier (G4 forced on every junction; meaningless on corners) |
| **G4.3** | LSQ best-fit line through K=5 junction-adjacent cps post endpoint-skip | First/last-segment-only direction (vulnerable to noise) |
| **G4.4** | Outgoing-vs-outgoing angle; `tangent_delta = |180° - angle|` so smaller = smoother | Polyline-bend angle (equivalent but inverted; less spec-aligned) |
| **G4.5** | Degrees | Radians |
| **G4.6** | Vacuous: no-junction, corner-junction, insufficient-cps, 1-cp dots filtered before pairing | — |
| **G4.7** | No mask (pure polyline) | — |
| **G4.8** | Same shape as G3's calibration; pairwise round1/round2 deltas; max(round1, round2) + safety margin | — |
| **G4.9** | `G4_SAFETY_MARGIN_DEG = 2.0°` (LSQ + resample noise floor) | 1° (too tight); empirical via calibration if needed |
| **G4.10** | New code in `audit_invariants.py`; new `scripts/calibrate_g4_threshold.py`; new `scripts/tests/test_gate_g4.py`; per-junction iteration internal to `gate_g4`; minor `format_letter_human` extension for `per_junction` key | Per-junction iteration in `run_gates.py` (couples gate logic to driver) |
| **G4.11** | Polish-preservation predicted; verified empirically; soft-V trigger if smooth junctions missing or polish increases delta | — |
| **Structural** | Second **conformance gate** (sibling of G3); reuses drift/conformance taxonomy from `g3_design.md`; G4 is the first **per-junction** gate (vs G1/G2/G3 per-stroke) | — |

---

## Hold

Awaiting David's approval / redlines. No code, no commits beyond
this docs commit until then.

Open questions for explicit yes/no:

1. **G4.1** Geometric junction detection via endpoint distance ≤ 2 px
   (tunable post-calibration)? **Y/N**
2. **G4.2** Reference-based smooth-vs-corner classifier at 30°
   boundary (tunable post-calibration); corner junctions vacuous?
   **Y/N**
3. **G4.3** LSQ best-fit line on K=5 junction-adjacent cps for
   tangent? **Y/N**
4. **G4.4** Outgoing-vs-outgoing angle, with
   `tangent_delta = |180° - angle|` so smaller = smoother (matches
   spec's "≤ 10°" semantics)? **Y/N**
5. **G4.5** Degrees as threshold unit? **Y/N**
6. **G4.9** `G4_SAFETY_MARGIN_DEG = 2.0°` (empirical via calibration
   if noise floor differs)? **Y/N**
7. **G4.10** Per-junction iteration internal to `gate_g4` (no
   `GATE_METADATA` change beyond the new entry); minor
   `format_letter_human` extension for `per_junction` key vs the
   existing `per_stroke` key? **Y/N**
8. **G4.11 / G4.12** Anything to flag before calibration runs?
   Specifically: **is the smooth-junction-availability concern (Q1)
   a stop-and-surface trigger before implementation, or proceed and
   let calibration verify empirically?**

The Q1 concern in G4.12 is the load-bearing risk: if the 2026-05-22
corpus has zero smooth end-to-end junctions, G4 has no calibration
data and the gate ships as future scaffolding only (G2-like
outcome). Surface during calibration unless you'd prefer a
pre-implementation diagnostic to verify smooth junctions exist
before sinking implementation time.
