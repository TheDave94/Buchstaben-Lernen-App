# G6 — Threshold 6 (T-junction attachment-tangent drift) — Design

**Spec ref:** `docs/BAKE_INVARIANTS.md` §1 Rule 4 (junction continuity;
mid-stroke attachment portion previously out of G4's scope) and §6
enforcement tally.
**Inherits from:** `g1_design.md` (freeze-gate framing; arc-length
resample; calibration corpus); `g4_design.md` (drift-gate shape on
per-junction property; LSQ tangent primitive; safety margin
convention).
**Scoping lock:** `research_data/phase2b_gates/phase2c_design.md` G6
section (Status: design locked 2026-05-26). This doc elaborates the
implementation details; the scoping-level decisions (measurement-
instrument framing, metric selection, threshold, dual-purpose
methodology claim, bowl-bearing absence vignette) are in the
phase2c_design.md G6 section. Do not duplicate; cite.
**Calibration:** `research_data/phase2b_gates/g6_calibration_run.md`
(corpus + per-junction table + threshold derivation; 2026-05-26 run
against the 2026-05-22 session pairs).
**Status:** locked and implemented. `gate_g6` / `gate_g6_per_junction`
+ helpers live in `scripts/audit_invariants.py`;
`GATE_METADATA["g6"]` in `scripts/run_gates.py`; 25 unit tests in
`scripts/tests/test_gate_g6.py` (all passing); calibration script
`scripts/calibrate_g6_threshold.py` derives the 4.50° threshold
deterministically.

This doc covers ONLY the G6-specific design decisions. Anything
inherited from G1–G4 is referenced rather than restated.

---

## Diagnostic findings (summary — see phase2c_design.md for full)

Two pre-implementation diagnostics shaped G6:

**G6.v1 (2026-05-26)** — `/tmp/diagnostic_g6_mid_stroke_attachment.py`.
Enumerated every stroke-pair (i, j) endpoint-vs-polyline pairing
across the 59-letter Regular corpus, classifying each row as
END-TO-END (G4 territory), MID-STROKE-ATTACHMENT (G6 territory), or
NO-JUNCTION. **15 letters surface 20 mid-stroke attachment rows
across 3 archetypes**: crossbar (A, E, F, H, T), bowl/loop attached
to stem (B, P, R, a, d, p, q, y), composite umlaut (Ä, ä). The
original "lowercase p alone" hypothesis underestimated the corpus
by 15×; G6 is a corpus-wide gate.

**G6.v2 (2026-05-26)** — `/tmp/diagnostic_g6_drift_metrics.py`. Measured
three candidate drift metrics — position, tangent, distance — against
the 2026-05-22 session pairs. Found 3 measurable rows (A s2→s0, A
s2→s1, p s1→s0); all three metrics co-vary, so picking one suffices.
Selected `tangent_drift_deg` as closest analogue to G4 and most
geometrically meaningful.

The diagnostics are not preserved in repo (they're `/tmp` artifacts).
Their findings are recorded in phase2c_design.md G6 section and in
the calibration-run doc.

---

## Corpus context (inherited)

Same as G1/G3/G4: all 59 letters of Druckschrift Regular ship as
hand-calibrated static artifacts (commit `6a85811c`). The 2026-05-22
session-pair corpus
(`research_data/calibration_sessions/2026-05-22/`) is the
polish-preservation calibration source. For G6, sessions with
pre/post stroke-count mismatch are excluded (12 of 12 Ä batch-2
sessions + 6 Ö sessions all involve the umlaut-dot-addition
workflow, not polish — see g6_calibration_run.md "Discovered scope
constraint" section).

---

## What's the same as G1/G2/G3/G4

- `_arc_length_resample(poly, n=100)` — same N=100 arc-length-uniform
  resample.
- `_stroke_tangent_at_endpoint(poly_px, at_first, ...)` — reused
  verbatim from G4 for the attaching-stroke tangent at the
  attaching endpoint. Same `G6_ENDPOINT_SKIP = 3`,
  `G6_TANGENT_WINDOW = 5`.
- bbox-from-rasterized-mask — same `generate_strokes_auto.rasterize`
  + `bbox_from_mask` to convert bbox-relative cps to px-space.
- Mask-free — like G2 and G4, G6 measures a pure polyline property;
  no ink-mask rasterization needed at gate time (rasterization is
  only used for bbox derivation).
- Drift-gate shape — like G1/G2/G4, G6 measures candidate-vs-reference
  drift; pass iff drift ≤ threshold.
- Safety margin pattern — `threshold = max(observed) + margin`. G6's
  margin is `+4.0°`, generous per the measurement-instrument framing
  (see phase2c_design.md G6 "Threshold derivation").

---

## What's novel — T-junction-specific geometry

G6 differs from G4 along four axes. These are the design decisions
that earn G6 its own design doc rather than being a G4 parameter
sweep:

1. **Junction class.** G4 = end-to-end junctions (one stroke's
   endpoint meets another stroke's endpoint). G6 = T-junctions
   (one stroke's endpoint meets another stroke's INTERIOR).
   Geometrically distinct: G4 measures kink between two outgoing
   tangents at a single shared point; G6 measures the angle at
   which an attaching tangent intersects a host's local tangent at
   a non-endpoint cp.

2. **Iteration topology.** G4 iterates only consecutive stroke
   pairs `(i, i+1)` because end-to-end junctions occur naturally
   between adjacent strokes (the pen lifts and re-starts). G6
   iterates ALL `(i, j)` pairs with `i ≠ j` because T-junctions
   are NOT constrained to adjacent stroke indices (e.g., in A,
   stroke 2 is the crossbar attaching to stroke 0 (left leg) and
   stroke 1 (right leg) — neither pair is "consecutive" in the
   `(i, i+1)` sense). Plus G6 iterates BOTH endpoints (`first`,
   `last`) of each stroke `i` against host `j`, where G4 picks
   the minimum-distance endpoint pairing (G4 looks for ONE
   junction per pair; G6 needs to check both endpoints because
   either might attach mid-host).

3. **Tangent computation.** G4 uses `_stroke_tangent_at_endpoint`
   on BOTH sides of the junction (both strokes' tangents at their
   junction endpoints). G6 uses it for the ATTACHING side only;
   for the HOST side, a new helper `_host_tangent_at_idx` computes
   an LSQ tangent on `G6_TANGENT_WINDOW = 5` cps **centered at**
   the detected `host_cp_idx`. The host doesn't have a natural
   "outgoing" direction at the attachment point (the attachment is
   mid-stroke, with polyline continuing on both sides); the LSQ
   on a centered window captures the host's local direction.

4. **Unsigned angle convention.** G4's `kink_deg = |180° −
   outgoing_outgoing_angle|` captures pen-continuation-vs-corner
   semantics for end-to-end junctions. G6 collapses to
   **unsigned [0°, 90°]** via `acos(|dot|)` because the host's
   tangent sign is arbitrary (depends on polyline sampling
   direction); the meaningful quantity is the angle between the
   attaching tangent and the host's local tangent regardless of
   which way the host was sampled. **0° = tangential (attaching
   stroke runs along the host); 90° = perpendicular T.**

---

## Implementation specifications

### G6.1 — Junction detection

`G6_JUNCTION_EPSILON_PX = 15.0` (raster pixels on 1024² mask).
Inherits G4's empirical rationale — the corpus's actual junctions
all sit ≤ ~11 px from the host polyline at the 1024² mask scale;
15 px sits in the natural gap to non-junctions. If a future corpus
addition lands in this gap, re-derive.

`G6_ENDPOINT_BAND = 5`. Determines the G4/G6 boundary:

- **G4 territory:** `host_cp_idx < 5` OR `host_cp_idx > N-1-5` (where
  `N = G6_RESAMPLE_N = 100`); i.e., the attaching endpoint lands
  within 5 cps of either end of the host polyline. These are
  end-to-end junctions that G4 measures with the cleaner outgoing-vs-
  outgoing tangent convention.
- **G6 territory:** `5 ≤ host_cp_idx ≤ 94`. Mid-stroke attachment.
- **No overlap.** Strict cutoff; no buffer zone. Borderline rows from
  the diagnostic — R s2→s1 at host_idx=93, q s0→s1 at host_idx=6 —
  fall unambiguously into G6's lane by inclusive `5 ≤ idx ≤ 94`.

`_t_junction_detect(attach_rel, host_rel, attach_at_first, bbox)`:

1. Resample `attach_rel` and `host_rel` to N=100 via
   `_arc_length_resample`.
2. Convert both to px-space via `bbox`.
3. Pick the attaching endpoint: `attach_px[0]` if `attach_at_first`
   else `attach_px[-1]`.
4. Find the closest cp on `host_px` to the attaching endpoint
   (linear scan; O(N)).
5. If `dist > G6_JUNCTION_EPSILON_PX`: return `None` (NO-JUNCTION).
6. If `host_cp_idx` is within `G6_ENDPOINT_BAND` of either host end:
   return `None` (END-TO-END; G4's lane).
7. Else: return a detection dict with `host_cp_idx`, `dist_px`,
   `attach_px`, `host_px`, `attach_at_first`.

### G6.2 — Detection mismatch between rounds

Same principle as G4'.1b. The drift metric requires the junction
exist in BOTH rounds. If `_t_junction_detect` returns a dict for
one round and `None` for the other, the per-junction result
vacuous-passes with reason
`t_junction_detection_mismatch_between_rounds`. The calibration
script surfaces these in the per-reason vacuous breakdown — a high
mismatch count would indicate ε or the band-edge is poorly chosen.
For the 2026-05-22 corpus on the measurable letters, the count is
0 (every junction's detection status is identical between rounds).

### G6.3 — Per-junction attachment angle

Two tangents, one angle:

- **Attaching tangent:** `_stroke_tangent_at_endpoint(attach_px,
  attach_at_first)` — reused verbatim from G4. LSQ principal axis
  on `G6_TANGENT_WINDOW = 5` cps after `G6_ENDPOINT_SKIP = 3` from
  the attaching endpoint. Oriented outward from the endpoint
  toward the stroke's interior.
- **Host tangent:** `_host_tangent_at_idx(host_px, host_cp_idx,
  window=5)` — new. LSQ principal axis on 5 cps centered at
  `host_cp_idx`. Window clips to polyline endpoints if `host_idx`
  is near the edge (the G4/G6 classifier guarantees
  `5 ≤ host_idx ≤ 94`, so the 5-cp window never spills past
  either end for an honest detection). Sign is arbitrary —
  collapsed to unsigned downstream.

**Attachment angle:** `_unsigned_angle_deg(t_attach, t_host) =
acos(|dot(t_attach, t_host)|)`, in degrees, range [0°, 90°].
Returns `None` if either tangent is unobtainable (degenerate cps,
collinear input). The `abs()` on the dot product is the load-bearing
collapse — it makes the angle insensitive to the host tangent's
arbitrary sign.

### G6.4 — Drift metric

```
attachment_drift_deg = |attachment_angle_round2 − attachment_angle_round1|
```

Absolute value. Symmetric to G4'.3. Signed-drift variant could be
added later if calibration reveals systematic asymmetry; current
corpus shows no such asymmetry (3 rows is too few to detect one
either way).

Pass condition: `attachment_drift_deg ≤ G6_DEFAULT_THRESHOLD_DEG`.

### G6.5 — Vacuous-pass taxonomy

Per-junction reasons (set in `gate_g6_per_junction`):

- `no_t_junction` — both rounds return `None` from
  `_t_junction_detect`. Pair is not a T-junction in either round.
  Skipped from `per_junction` output entirely (not surfaced as a
  vacuous-pass; it's just a non-junction).
- `t_junction_detection_mismatch_between_rounds` — one round
  detects, the other doesn't. `pass = True`.
- `insufficient_measured_points` — both rounds detect but at least
  one tangent is unobtainable. `pass = True`.

Letter-level reasons (set in `gate_g6`):

- `no_pairs` — letter has fewer than 2 strokes. Clean vacuous pass;
  nothing to iterate.
- `no_t_junctions` — multi-stroke letter, pairs iterated, zero
  detected T-junctions in either round. Clean vacuous pass; the
  letter doesn't have T-junctions.
- `all_vacuous` — T-junctions detected but ALL hit vacuous reasons
  (detection mismatch or insufficient tangent points). Methodologically
  meaningful "tried, couldn't measure"; **CI should pay attention to
  this state.** Pass is vacuous.
- `None` — at least one real drift measurement; pass is real.

### G6.6 — Iteration topology

```python
n_strokes = min(len(candidate_strokes_rel), len(reference_strokes_rel))
for i in range(n_strokes):
    for j in range(n_strokes):
        if i == j:
            continue
        for which_label, attach_at_first in (("first", True),
                                                ("last", False)):
            result = gate_g6_per_junction(
                candidate_strokes_rel[i], candidate_strokes_rel[j],
                reference_strokes_rel[i], reference_strokes_rel[j],
                attach_at_first, bbox, threshold)
```

`n_strokes * (n_strokes - 1) * 2` triples per letter. For a typical
3-stroke letter (A, B, E, …): 12 triples. For Ä (5 strokes when
both rounds present): 40 triples. Of those, only the ones that
classify as MID-STROKE-ATTACHMENT (G6.1) make it into `per_junction`.

**Why broader than G4's iteration:** G4 iterates only consecutive
pairs `(i, i+1)` because end-to-end junctions naturally bind
adjacent strokes (the pen lifts at i's end, restarts at (i+1)'s
start). G6 needs the full pair sweep because T-junctions are NOT
constrained to adjacent indices in the Primae stroke-ordering
convention.

**Concrete example — A.** The corpus's A has three strokes: s0
(left leg), s1 (right leg), s2 (crossbar). Both T-junctions G6
must capture have non-zero index gaps:

- A s2→s0 (crossbar to left leg): stroke-index gap |2−0| = **2**.
  Non-consecutive. G4 doesn't iterate (0, 2) at all → invisible
  to G4.
- A s2→s1 (crossbar to right leg): stroke-index gap |2−1| = **1**.
  Consecutive — but G4's min-distance endpoint-pairing for (1, 2)
  picks the closest endpoint pair (large because the legs and the
  crossbar don't share an endpoint), which exceeds the 15 px ε →
  G4 sees NO-JUNCTION. The actual mid-stroke attachment at
  idx=40 is invisible to G4's classifier.

Both junctions need BOTH design changes — broader iteration AND
mid-stroke-band classifier — to be captured. The crossbar
archetype (A, E, F, H, T) all share this pattern: the crossbar is
the highest stroke index and attaches to lower-index uprights,
with gaps that are sometimes ≥ 2. The bowl archetype (B, P, R, a,
d, p, q, y) generally has the bowl as a higher index attaching to
a lower-index stem with gap 1, but again G4's endpoint-pairing
classifier misses the mid-stroke attachment.

**Both endpoints of `i` are checked** because in principle the
attaching stroke could meet the host at either end. In practice
most letters use one specific endpoint (e.g., the bowl's first cp
attaches; its last cp ends free), but the gate doesn't depend on
that convention.

**Topology change handling.** `n_strokes = min(...)` caps iteration
at the shared range. Extra strokes in either round are simply
ignored. Junction detection across the topology change typically
vacuous-passes via the detection-mismatch reason (indices don't
mean the same thing across rounds → different geometry → different
detections). This is the natural behavior; no explicit
topology-change check.

### G6.7 — Threshold derivation

See `g6_calibration_run.md` for the full corpus + derivation.
Summary:

- Calibration corpus: 3 measurable junction rows across 2 letters
  (A, p) and 2 archetypes (crossbar, bowl).
- max observed drift: **0.498°** at A s2→s0 first (displays as
  0.50° rounded).
- safety margin: **+4.0°**. Generous per the measurement-instrument
  framing (phase2c_design.md G6 section); not tightly-fit because
  G6's design driver is future-font measurement, not Regular
  protection (Regular is frozen).
- **`G6_DEFAULT_THRESHOLD_DEG = 4.50`**.

Comparison to G3/G4 margins:

| Gate | Max observed | Margin | Threshold | Margin / max |
|---|---|---|---|---|
| G3 | 1.05 px | +1.0 px | 2.05 px | ~95% |
| G4 | 2.43° | +2.0° | 4.43° | ~82% |
| G6 | 0.50° | +4.0° | 4.50° | ~800% |

G6's 800% margin is the methodology-relevant signature of the
measurement-instrument framing.

### G6.8 — Mask requirement

G6 is mask-free at gate time (the metric is a pure polyline
property). The mask is used only to derive the letter's bbox for
the bbox-relative-to-px conversion. `GATE_METADATA["g6"]` has
`"needs_mask": False`.

### G6.9 — Implementation outline

```python
# audit_invariants.py constants
G6_RESAMPLE_N = 100             # mirrors G1/G2/G3/G4
G6_ENDPOINT_SKIP = 3            # cps to skip from attaching endpoint
G6_TANGENT_WINDOW = 5           # cps for LSQ tangent fit
G6_JUNCTION_EPSILON_PX = 15.0   # mirrors G4_JUNCTION_EPSILON_PX
G6_ENDPOINT_BAND = 5            # G4/G6 boundary at host_cp_idx
G6_DEFAULT_THRESHOLD_DEG = 4.50

# Helpers
_host_tangent_at_idx(poly_px, host_idx, window=5) -> (x, y) | None
_unsigned_angle_deg(t_a, t_b) -> float | None       # [0°, 90°] or None
_t_junction_detect(attach_rel, host_rel, attach_at_first, bbox, ...) -> dict | None
_t_junction_attachment_angle_deg(det, ...) -> float | None

# Gate functions
gate_g6_per_junction(cand_attach_rel, cand_host_rel,
                       ref_attach_rel, ref_host_rel,
                       attach_at_first, bbox, threshold_deg, ...) -> dict
gate_g6(candidate_strokes_rel, reference_strokes_rel,
          bbox, threshold) -> dict
```

`gate_g6` returns:

```python
{
    "per_junction": [...],
    "letter_score": float | None,        # max real drift, or None
    "n_strokes_candidate": int,
    "n_strokes_reference": int,
    "n_pairs_iterated": int,             # n × (n-1) × 2
    "n_t_junctions_detected": int,       # len(per_junction)
    "n_t_junctions_measured": int,       # rows with real drift
    "letter_reason": str | None,         # no_pairs / no_t_junctions / all_vacuous / None
    "pass": bool,
}
```

The three-counter funnel `iterated → detected → measured` is
explicitly surfaced (rather than G4's single `n_pairs_checked`)
because G6's broader iteration makes the funnel methodologically
meaningful — `iterated` ≫ `detected` ≫ `measured` is the expected
shape, and a deviation (e.g., `detected ≈ iterated`) would flag a
classifier bug.

### G6.10 — Test plan

`scripts/tests/test_gate_g6.py` (25 tests across 7 TestCase
classes; all passing):

- `TestHostTangentAtIdx` (3) — LSQ tangent on host at idx;
  endpoint clipping; degenerate input.
- `TestUnsignedAngleDeg` (5) — perpendicular (90°), parallel (0°),
  anti-parallel (0°), 45°, None propagation.
- `TestTJunctionDetect` (5) — MID-STROKE detection;
  endpoint-band rejection (first + last); distance-too-far;
  too-short input.
- `TestGateG6PerJunctionIdentity` (2) — perpendicular T identity
  (drift=0°, kink=90°); skewed T 45° identity (drift=0°,
  kink=45°).
- `TestGateG6PerJunctionDrift` (2) — 45°→40° polish drift (~5°,
  near threshold); 45°→30° drift (15°, fails threshold).
- `TestGateG6PerJunctionVacuous` (2) — `no_t_junction`;
  `t_junction_detection_mismatch_between_rounds`.
- `TestGateG6Letter` (6) — identity letter; single-stroke →
  `no_pairs`; multi-stroke no T → `no_t_junctions`;
  borderline-band G4 handoff (idx≈2 → no_t_junctions);
  topology change graceful (n_strokes differs);
  all-vacuous letter → `all_vacuous`.

Coverage notes:

- Synthetic geometric primitives only (no real Regular letters in
  unit tests).
- Integration testing lives in the calibration script, which runs
  the full gate on the real corpus.
- No test for `drift == threshold_deg` exact-boundary (testing
  inequality operator, not gate logic; skipped).

### G6.11 — G4/G6 boundary handoff

The same `(i, j, endpoint)` row cannot be both G4 and G6 territory
by construction. G4's `_detect_junctions` iterates consecutive
pairs and matches endpoints by minimum-distance pairing; it does
NOT check host_cp_idx — G4's logic assumes the matched endpoints
are exactly the host's endpoints. For the rare row where a
consecutive pair's endpoint lands mid-host (R s2→s1 idx=93;
q s0→s1 idx=6), G4 would still register a "junction" by minimum-
distance pairing but the resulting kink_deg is geometrically
ill-defined (one tangent is the attaching outgoing tangent;
the other is the host's outgoing tangent at an endpoint that
isn't where the attaching endpoint actually meets the host).

The G4/G6 boundary is enforced by **mutually exclusive
classification at the row level, not at the gate level**: G4
processes ALL consecutive pairs (regardless of host_cp_idx); G6
processes ALL (i, j) pairs filtered to `5 ≤ host_cp_idx ≤ 94`.
Both gates run; the per-row classifier in `_t_junction_detect`
returns `None` for endpoint-band rows so they don't appear in
G6's `per_junction`. Borderline letters (R, q) get measured by G6
on their MID-STROKE rows and by G4 on their end-to-end rows (if
any); no row is double-counted.

If a future investigation shows G4's minimum-distance pairing
produces meaningfully bad kink_deg values for the R/q borderline
rows, a downstream design pass might add a host_cp_idx filter to
G4 to symmetrize the boundary. Not done now; current G4 behavior
on those rows is the design-as-is.

**Edge case — non-consecutive borderline rows.** If a stroke pair
(i, j) is non-consecutive (|i − j| ≥ 2) AND the host_cp_idx falls
in G6's reject band (< 5 or > 94), neither gate measures the row:
G4 doesn't iterate non-consecutive pairs, and G6's classifier
rejects the row as out-of-mid-stroke-band. In the current Regular
corpus this case does not occur — the two borderline rows
(R s2→s1 idx=93, q s0→s1 idx=6) are both consecutive (gap=1) and
captured by G4's iteration. If a future font surfaces non-
consecutive borderline rows, the appropriate response is either to
extend G4's iteration to match G6's full pair sweep, OR to loosen
G6's classifier to accept borderline rows. Flagged as a known
boundary condition for future-font work, not a current bug.

---

## Empirical predictions

Predictions made during the design pass:

1. **The bowl-bearing archetype would be polish-stable on Regular.**
   Predicted because once correctly authored via the calibrator
   override, the bowl-stem attachment is structural and shouldn't
   move under polish. **Confirmed indirectly**: the 7 bowl-bearing
   letters with no 2026-05-22 session pairs (B, P, R, a, d, q, y)
   suggest David didn't need to polish them. p, the lone
   measurable bowl-bearing letter, shows 0.159° drift — well below
   any plausible threshold.

2. **The crossbar archetype would also be polish-stable.**
   Predicted. **Confirmed**: A s2→s0 = 0.498°; A s2→s1 = 0.148°.

3. **The three drift metrics would co-vary.** Predicted from the
   geometric intuition that "junction shifted" is one phenomenon,
   not three. **Confirmed** by G6.v2 sub-diagnostic.

4. **Identity-check count would match the diagnostic.** Predicted
   because the gate and diagnostic share the same classifier and
   enumeration. **Confirmed**: 20 T-junctions across 15 letters
   on both sides; diff = 0.

5. **Topology-change sessions would surface as vacuous-pass
   without manual intervention.** Predicted from the `n_strokes =
   min(...)` design. **Confirmed**: Ä's 12 batch-2 sessions + Ö's 6
   sessions all surface as `topology_change_r1=X_r2=Y` skip
   reasons in the calibration corpus's "Skipped" list, without
   crashing.

---

## Trail of evidence

Chronological summary for thesis-chapter citation:

1. **2026-05-15** — Druckschrift Regular all 59 letters ship as
   hand-calibrated static artifacts (commit `6a85811c`). Regular
   bake pipeline retired.
2. **2026-05-22** — Session-pair calibration corpus captured (38
   pairs across 13 letters; 22 batch-1 polish + 16 batch-2 umlaut-
   dot addition).
3. **2026-05-23** — G4 ships with `+2.0°` margin against the
   2026-05-22 corpus. G4's `g4_calibration_run.md` "Discovered
   scope constraint" section flags mid-stroke attachment as
   out of G4's geometric class; later resolved by G6.
4. **2026-05-26 — G6 pre-implementation diagnostic (G6.v1)**.
   15 letters / 20 T-junctions surface. Original "p alone"
   hypothesis falsified; G6 reframed as corpus-wide.
5. **2026-05-26 — G6 sub-diagnostic (G6.v2)**. Three metrics
   measured; co-variance finding; tangent-drift selected.
6. **2026-05-26 — Phase 2c-scoping design lock** in
   `phase2c_design.md` G6 section. Measurement-instrument framing
   + auto-calibrator-failure-class motivation + dual-purpose
   methodology claim + bowl-bearing-absence vignette.
7. **2026-05-26 — G6 implementation**. `gate_g6` + helpers in
   `audit_invariants.py`; `GATE_METADATA["g6"]`; 25 unit tests;
   `calibrate_g6_threshold.py`; this design doc;
   `g6_calibration_run.md`. Single commit ships all artifacts.

---

## Decisions summary

| Decision | Choice | Rationale |
|---|---|---|
| Junction class | T-junctions only (5 ≤ host_idx ≤ 94) | G4 already handles end-to-end; no overlap |
| Metric | `tangent_drift_deg`, unsigned [0°, 90°] | Co-variance with position/distance; cleanest G4 analogue |
| Tangent on host | LSQ centered at host_idx (window=5) | Host has no natural outgoing direction at mid-stroke |
| Iteration | All (i, j) pairs with i ≠ j; both endpoints | T-junctions not constrained to adjacent stroke indices |
| Topology change | `n_strokes = min(...)`; vacuous-pass on detection mismatch | Natural behavior; no explicit check needed |
| Threshold | 4.50° = 0.498° max + 4.0° margin | Generous; measurement-instrument framing |
| Margin convention | Same `max + margin` shape as G3/G4 | Methodology continuity |
| Letter-level reasons | `no_pairs`, `no_t_junctions`, `all_vacuous`, None | Three-state taxonomy; `all_vacuous` is CI-relevant |
| Count metrics | `n_pairs_iterated`, `n_t_junctions_detected`, `n_t_junctions_measured` | Funnel surfaces classifier health |
| Test scope | Synthetic primitives only (25 tests) | Integration testing in calibration script |
| Mask requirement | No (mask-free; bbox used only for px conversion) | Pure polyline property |

---

## Approved

Design locked 2026-05-26 from the diagnostic findings (G6.v1
+ G6.v2). Implementation ships in the Phase 2c G6 commit
together with `g6_calibration_run.md` and tests; CI wiring in
`bake-gates.yml` step parallel to G1/G3/G4.

---

## References

- Scoping lock: `research_data/phase2b_gates/phase2c_design.md`
  G6 section
- Calibration: `research_data/phase2b_gates/g6_calibration_run.md`
- Implementation: `scripts/audit_invariants.py` (constants +
  helpers + `gate_g6` + `gate_g6_per_junction`)
- Gate metadata: `scripts/run_gates.py` `GATE_METADATA["g6"]`
- Calibration script: `scripts/calibrate_g6_threshold.py`
- Tests: `scripts/tests/test_gate_g6.py`
- Methodology framing (dual-purpose): `phase2c_design.md`
  "Methodology-chapter framing" section
- Inherited design docs: `g1_design.md`, `g3_design.md`,
  `g4_design.md`
