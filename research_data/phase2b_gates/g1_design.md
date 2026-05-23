# G1 — Threshold 1 (Asymmetry-profile drift from reference) — Design Proposal

**Spec ref:** `docs/BAKE_INVARIANTS.md` §2 Threshold 1, post-revision (`4d04beec`).
**Input layer:** unchanged. Uses existing helpers from `scripts/audit_invariants.py`
post-salvage (`c0711aab`): `_walk_to_boundary`, `_asymmetry_per_point`,
`build_per_stroke_masks`.
**Status:** design only. No code yet; awaits David approval / redlines.

---

## Corpus context (freeze-gate framing)

All 59 letters of Druckschrift Regular ship as hand-calibrated static
artifacts (commit `6a85811c`, 2026-05-15: "Druckschrift Regular complete — all
59 letters as static artifacts"). The bake pipeline at
`scripts/generate_strokes_auto.py` is permanently retired for Regular; it
lives on as the algorithmic baseline for Light template-warping and future
fonts. `LETTERS` dict and primitives remain in place as scaffolding but
produce no Regular output.

**G1 is therefore a FREEZE GATE.** HEAD's `strokes.json` files are the
canonical reference. A future PR producing drift larger than David's
previously-approved polish edits gets flagged for manual review.

The original design draft framed G1 as a "fresh-bake-vs-shipped self-Pearson
floor" measurement, distinguishing 37 bake-controlled vs 22 static letters.
That framing is obsolete: with all 59 letters static, there is no fresh bake
to compare against. Calibration now measures the magnitude of David's
hand-approved polish edits from the 2026-05-22 session-pair corpus and uses
that as the floor (see Section 3).

---

## Section 1 — Metric shape

### 1a — Per-stroke or whole-letter?

**Recommendation: Option A — one Pearson per stroke; letter passes iff every
stroke passes.**

| Option | Behavior | Trade-off |
|---|---|---|
| **A (recommended)** | Per-stroke Pearson; letter `pass` = `all(per_stroke.pass)` | Explicit, granular, debuggable. A single regressing stroke fails the letter, which is what we want. |
| B | Concatenate all strokes' asymmetry into one sequence; one Pearson | One number per letter, but concatenation order is arbitrary and a bad stroke gets diluted by good ones. |
| C | Per-stroke Pearson; letter score = `min(per_stroke.pearson)` | Same pass/fail behavior as A if threshold is per-stroke. Adds a "letter score" scalar for sorting. |

A and C are operationally equivalent under "letter passes iff every stroke
passes". Pick A and surface per-stroke Pearson in output; `min` is a one-line
derived scalar if needed.

### 1b — Resampling for sequence-length matching

**Recommendation: arc-length resample BOTH polylines to a fixed N before
computing the asymmetry sequence.** This makes the comparison index-aligned by
arc-length, regardless of original checkpoint counts.

| Option | Trade-off |
|---|---|
| Hard-fail on length mismatch | Catches determinism regression but brittle to legitimate calibrator edits (e.g., `+ Punkt` adds a stroke; rebuild path can change anchor density). |
| Resample both to fixed N (e.g., 100 or 200) **(recommended)** | Arc-length-uniform comparison; index `i` always pairs the same fractional position along the stroke. Slight interpolation smoothing, but the per-point asymmetry is a smooth signal so this is benign. |
| Resample candidate to reference's length | Preserves reference's sampling but doesn't help when reference's sampling itself is uneven (e.g., very few cps on a short stroke). |

**Proposed N:** 100 points per stroke. The shipped bake uses ~40 cps for a
short stroke and ~200 for a long one; N=100 is the geometric mean and gives
~one sample per ~10 raster pixels on a 1024² mask — fine enough to resolve
asymmetry features, coarse enough to keep the Pearson statistically meaningful.

Length mismatch is still surfaced in output (`n_cp_candidate`,
`n_cp_reference`) so a regression that produces wildly different counts is
visible even though it doesn't fail the gate. **A determinism regression in
checkpoint count is Threshold 6's job, not T1's.**

**Code-site invariant (per David's Redline 1).** At the resampling call site
in `gate_g1_per_stroke`, an explicit comment must state:

> "Resample the POLYLINE to N=100, THEN compute asymmetry on the resampled
> polyline. This is NOT equivalent to computing asymmetry on the original cps
> and then resampling the asymmetry sequence — the perpendicular walks happen
> at resampled cp positions. Do not refactor to swap the order."

The two orderings are mathematically different: `_asymmetry_per_point` runs
`_walk_to_boundary` from each cp position, so where the cps are placed
determines where the perpendiculars are measured. Resample-then-walk gives
asymmetry at the N=100 arc-length-uniform positions; walk-then-resample gives
interpolated asymmetry values *between* the original cps' walk results, which
is a strictly different signal.

### 1c — Diacritic dots (1-checkpoint strokes)

**Recommendation: vacuous pass with `reason: "not_applicable_too_short"`.**

A 1-cp stroke has no centerline geometry to measure asymmetry on. The
alternatives are wrong:

- *Hard-fail*: rejects every letter with a tittle (i, j) or umlaut dots
  (Ä Ö Ü ä ö ü). Obviously not the intent.
- *Exclude from gate*: equivalent pass/fail behavior to vacuous pass, but
  obscures the dot's presence in output.

The single-point comparison (does candidate dot ≈ reference dot in xy?) is a
separate metric (call it T0 or fold into T4 endpoint-distance). Out of scope
for T1.

### 1d — Insufficient measurable points

**Recommendation: `n_measured ≥ 10` required; below that, vacuous pass with
`reason: "insufficient_measured_points"`.**

Pearson on N < 3 is mathematically degenerate; on N < 10 it's noise. A stroke
where `_asymmetry_per_point` returns mostly `ok=False` (boundary walks hitting
canvas edge, degenerate tangents) shouldn't fail T1; it should signal "T1
doesn't apply to this stroke" and let other thresholds catch the real issue.

**Alternative:** hard-fail to flag the regression that dropped `n_measured`
from 80 → 3. Surfaces a real problem but the wrong layer. T1 is about drift
from reference, not about whether the asymmetry signal exists at all. Let
T1 vacuously pass; the `n_measured` count is in the output for inspection.

**Sibling case — low-variance asymmetry sequence.**

A separate vacuous-pass condition gates strokes whose asymmetry sequence
std falls below `G1_MIN_ASYMMETRY_STD = 0.05`. Rationale: uniform-width
strokes (l, I — vertical stems through uniform-width ink bands) produce
asymmetry sequences with magnitude near the perpendicular-walk's sub-pixel
rounding noise floor. Pearson on two such low-magnitude noisy sequences is
meaningless — the correlation is dominated by sub-pixel artifacts, not by
genuine geometric drift.

Empirically derived against the 2026-05-22 session-pair corpus: `l`'s
asymmetry std came in at 0.0438 with Pearson 0.1528 despite `edit_count=0`
(no actual edit operations recorded — likely an anchor-rebuild side effect).
`D s1` came in at 0.0521 with Pearson 0.4903, representing legitimate
closed-bowl polish (`edit_count=3`). Cutoff at 0.05 sits in the 0.008-wide
gap between the two — filters l (and the structurally similar tight-pair
cases D s0 std 0.0273, Ö s0 std 0.0420 which had Pearson 1.0 anyway) while
preserving D s1 as a real polish signal.

Strokes that hit this case return `reason="low_variance_asymmetry"`. They
don't count toward the threshold floor derivation in Section 3.

The existing 1e-12 constant-asymmetry-sequence check is a strict subcase
of the same idea but is kept for the more specific debug reason.

---

## Section 2 — Reference lookup

### 2a — What is the reference?

**Confirmed:** `PrimaeNative/Resources/Letters/<Weight>/<letter>/strokes.json`
at the comparison base.

For PR CI: reference = `main`'s version of the file (via `git show
origin/main:PATH` or a `main` worktree). Candidate = the PR branch's
working-tree version.

For local development: reference = `HEAD`'s version (via `git show
HEAD:PATH`); candidate = working tree.

For the Section-3 calibration: reference = `HEAD`'s shipped version;
candidate = fresh bake output written to tmpdir.

**Implementation note:** the gate function takes two polyline-arrays in
memory; sourcing them (git-show vs file-read vs fresh-bake) is the CLI
driver's job, not the gate's.

### 2b — CLI signature

**Recommendation: umbrella driver `scripts/run_gates.py --gate g1 [LETTERS...]`,
with gate logic as functions in `scripts/audit_invariants.py`
(`gate_g1(...)`).**

| Option | Trade-off |
|---|---|
| New script per gate (`scripts/g1_asymmetry_drift.py`) | Each gate fully independent; minimal coupling. Five copies of letter-enumeration + arg-parsing + output-formatting boilerplate. |
| Umbrella `scripts/run_gates.py --gate g1` **(recommended)** | Shared infrastructure; gates as importable functions. Five gates total, so the umbrella amortizes overhead. |
| `audit_invariants.py --gate g1` (subcommand) | Conflates "input-layer helpers" with "gate orchestrator"; the salvage chore deliberately scoped `audit_invariants.py` to helpers. Keep the orchestrator separate. |

Argument shape:
```
scripts/run_gates.py --gate g1 [LETTERS...]
                     [--candidate-ref REF]   # default: working tree
                     [--reference-ref REF]   # default: HEAD
                     [--weight regular|light]
                     [--threshold FLOAT]     # default: read from BAKE_INVARIANTS.md once calibrated
                     [--json]
```

### 2c — Output format

**Recommendation: human-readable stdout by default, machine-readable JSON
behind `--json`.**

Human stdout (for local dev):
```
G1 — asymmetry-profile drift from reference (threshold ≥ 0.98)

A         ✓ stroke 0: pearson=0.9999 n=100        ✓ stroke 1: pearson=0.9998 n=100
Ü         ✓ stroke 0: pearson=0.9999 n=100        ✓ stroke 1: vacuous (dot)        ✓ stroke 2: vacuous (dot)
R         ✗ stroke 0: pearson=0.8421 n=100  FAIL  ✓ stroke 1: pearson=0.9994 n=100

Summary: 58/59 pass, 1 fail (R)
```

JSON (for CI artifact):
```json
{
  "gate": "g1",
  "threshold": 0.98,
  "letters": {
    "A": { "pass": true, "strokes": [{"pearson": 0.9999, "n_measured": 100, "pass": true}, ...] },
    ...
  },
  "summary": { "pass": 58, "fail": 1, "total": 59 }
}
```

---

## Section 3 — Threshold calibration procedure (freeze-gate framing)

### 3a — Calibration source: the 2026-05-22 session-pair corpus

**Procedure.** For each letter in
`research_data/calibration_sessions/2026-05-22/` (13 letters with session
pairs captured):

1. Load `pre_polyline` of the earliest session JSON for that letter — this
   is "round-1", David's loaded state before any 2026-05-22 edits.
2. Load HEAD `strokes.json` for the same letter — this is "round-2", the
   state David approved.
3. Per stroke index up to `min(len(round1), len(round2))`, call
   `gate_g1_per_stroke(round1[i], round2[i], stroke_mask, bbox,
   threshold=1.0)` — threshold=1.0 so the result reports actual Pearson
   rather than pass/fail.
4. Collect `(letter, stroke, pearson)` tuples. Exclude vacuous-pass cases
   (`reason="not_applicable_too_short"` for 1-cp dots; `reason="low_variance_asymmetry"`
   for sub-pixel-noise-floor strokes like uniform stems).

**Threshold = `min(per-(letter, stroke) real Pearson)`** across the
non-vacuous strokes in the corpus.

**No safety margin.** There is no algorithmic noise floor to subtract
against — the reference is static (hand-calibrated, committed), not
regenerated by an algorithm with floating-point noise. The threshold sits
exactly at David's smallest approved polish edit.

**Why session-pair calibration is the right call here.** With the bake
pipeline retired for Regular (commit `6a85811c`), there is no "fresh-bake-
vs-shipped" measurement to anchor the threshold against. The session pairs
are the only empirically-grounded data the corpus provides about
"acceptable drift." A PR proposing edits smaller than David's smallest
previously-approved polish (Pearson ≥ threshold) passes silently; a PR
proposing edits *larger* (Pearson < threshold) gets flagged for manual
review.

The original draft of this section flagged session-pair calibration as
"calibrating against human corrections of algorithmic errors" — which
would be the wrong calibration target IF the bake were still producing
shipped output. Post-`6a85811c`, that concern is inverted: David's hand
calibrations ARE the shipping path, not corrections of it. The session
pairs document the magnitude of polish David approved, which is exactly
what the freeze gate needs to know.

### 3b — Threshold per-stroke or per-letter?

**Per-(letter, stroke) pair.** The threshold floor is
`min(per_stroke_pearson)` across all (letter, stroke) pairs in the
corpus. Finer-grained, catches the worst stroke.

**Calibration result (2026-05-23):** see
`research_data/phase2b_gates/g1_calibration_run.md` for the full per-stroke
table and derived threshold value. Threshold of record is recorded in
`docs/BAKE_INVARIANTS.md` §2 Threshold 1.

---

## Section 4 — Edge-case list

**`T1_ENDPOINT_SKIP=3` is already wired through.** Defined in
`scripts/audit_invariants.py:38` (post-salvage `c0711aab`) and consumed at
lines 71/76 of `_asymmetry_per_point` as the default value of the
`endpoint_skip` parameter. Per-stroke asymmetry sequences emerging from the
helper already have the first/last 3 cps marked `ok=False`; `gate_g1`'s
filter to the `ok=True` intersection naturally excludes them. **No new
endpoint-skip logic needed in `gate_g1_per_stroke`.**

Caveat: `T1_ENDPOINT_SKIP` excludes cps adjacent to a stroke's polyline
endpoints, not at arbitrary mid-stroke turns. For closed-bowl letters where
the bowl-stem joint is the *endpoint* of the bowl stroke (a separate stroke
from the stem), the joint *is* skipped. For continuous-walk letters where
M/N/W's peaks are mid-stroke turns, those turns stay in the sequence — which
is correct, because they're legitimate geometric features and not junctions.

### Letter-by-letter table

For each letter or family, expected G1 behavior:

| Letter / family | CPs per stroke | G1 behavior | Notes |
|---|---|---|---|
| **I** (uppercase) | 1 stroke, ~200 cp | Normal | Long vertical bar; single straight stroke. |
| **i_l, j_l** | stem + 1-cp tittle | Stem normal; tittle vacuous pass (1c) | i has descender = no, dot above. j has descender + dot. |
| **Ä Ö Ü ä ö ü** | base + 2× 1-cp dots | Base normal; 2 dots vacuous (1c) | Three strokes per letter; the two dot strokes each return vacuous pass. |
| **ß** | 1 single complex stroke | Normal | Bake-controlled; no junctions. |
| **R, b_l, d_l, p_l, q_l** | bowl + stem | Both normal; flag bowl-stem joint for monitoring | Investigation 3 noted visual oddities at the bowl-stem junction. Both candidate and reference share the same oddity → Pearson stays high. The `T1_ENDPOINT_SKIP = 3` exclusion in `_asymmetry_per_point` skips the 3 cps adjacent to each endpoint, which removes the junction-adjacent region from the asymmetry sequence entirely. |
| **B (uppercase)** | 3 strokes (stem + 2 bowls) | Normal | All 59 letters share the same freeze-gate treatment. |
| **M W V Z (continuous-walk)** | 1 stroke with multiple peaks/valleys | Normal | The `T1_ENDPOINT_SKIP=3` exclusion handles the interior peaks correctly (they're not endpoints, so they stay in the sequence). |
| **K, k_l, X, x_l, Y, y_l** | stem + diagonal(s); junction | Normal; junction-adjacent cps excluded by `T1_ENDPOINT_SKIP=3` | The diagonal endpoint that meets the stem is an endpoint of its own stroke, so the 3 cps at that end are excluded — junction noise doesn't enter the sequence. |
| **f_l, t_l** | stem + crossbar | Normal | Crossbar is a separate stroke. |
| **a_l, e_l, g_l, s_l, S** | closed-loop or S-curve | Normal | Same freeze-gate treatment. |
| **y_l, q_l, j_l (descenders)** | stem + descender hook | Normal | Hook is a separate stroke segment. |
| **l, I (uniform-width stems)** | 1 stroke through uniform ink band | Vacuous-pass via `low_variance_asymmetry` (1d) | Asymmetry signal below sub-pixel noise floor. T1 doesn't apply; other thresholds may. |

All 59 letters get the same freeze-gate treatment under T1: any PR modifying
a `strokes.json` must demonstrate Pearson ≥ threshold against the
pre-modification version (the canonical hand-calibrated reference at HEAD).
The old bake-controlled-vs-static distinction is obsolete (all 59 are static
post-`6a85811c`).

---

## Section 5 — Implementation outline (structure only, no code)

### File changes

**`scripts/audit_invariants.py`** — add two functions:

```
gate_g1_per_stroke(candidate_poly_rel, reference_poly_rel, mask, bbox,
                    n_resample=100, n_min_measured=10) -> dict
  # 1. Arc-length resample both polylines to n_resample points (Section 1b).
  # 2. Compute asymmetry sequence on each, via existing _asymmetry_per_point.
  # 3. Filter to ok=True samples (intersection of both sequences' valid indices).
  # 4. If len(valid) < n_min_measured: return vacuous pass (Section 1d).
  # 5. Compute Pearson r = corrcoef(cand_asyms, ref_asyms)[0, 1].
  # 6. Return { pearson, n_measured, n_cp_candidate, n_cp_reference, pass: pearson >= threshold, reason? }

gate_g1(candidate_strokes_rel, reference_strokes_rel, mask, bbox,
         threshold) -> dict
  # 1. Build per-stroke masks via existing build_per_stroke_masks.
  # 2. For each stroke index, run gate_g1_per_stroke against the
  #    candidate/reference stroke pair.
  # 3. Letter pass = all(per_stroke.pass). Letter score = min(per_stroke.pearson).
  # 4. Return { per_stroke: [...], letter_score, pass }
```

Approx LoC: **~80 lines** added to `audit_invariants.py`.

**`scripts/run_gates.py`** — new CLI driver:

```
- argparse: --gate g1 (more later), --candidate-ref, --reference-ref,
           --weight, --threshold, --json, LETTERS...
- letter enumeration: read --weight dir; default to all 59 letters
- source resolution:
    candidate_data = read working tree or git-show <ref>:PATH
    reference_data = git-show <ref>:PATH
- per letter:
    mask = generate_strokes_auto.rasterize(letter, font_path)
    bbox = generate_strokes_auto.bbox_from_mask(mask)
    result = gate_g1(candidate_strokes, reference_strokes, mask, bbox, threshold)
- aggregate, format (human or JSON), exit 0 if all pass else 1
```

Approx LoC: **~140 lines** for `run_gates.py`.

**`scripts/calibrate_g1_threshold.py`** — one-shot, **not committed to repo**
(or committed as a tagged-once-then-deleted artifact, David's call):

```
- For each letter in LETTERS (37 bake-controlled letters only):
    1. fresh-bake the letter to tmpdir (via existing bake entry point with --out tmpdir)
    2. read shipped strokes.json from working tree as reference
    3. run gate_g1_per_stroke for each stroke, collect Pearson values
- Compute min, max, count==1.0, summary stats
- Print recommended threshold = min - 0.02
- Print corpus state SHA (git rev-parse HEAD)
- Exit 0
```

Approx LoC: **~80 lines** for the calibration script.

**`docs/BAKE_INVARIANTS.md`** — replace `≥ TBD` in Threshold 1's spec with the
derived number; cite corpus state SHA. (~1-line edit per the spec text;
already-revised structure handles it.)

### Total new code

~300 lines across 2-3 new files + 1 doc edit. No modifications to the
salvaged helpers in `audit_invariants.py`.

---

## Section 6 — Verification plan

### Unit tests (synthetic input)

In a new `PrimaeNativeTests/AuditInvariantsPearsonTests.py` (or
`tests/test_gate_g1.py` if we add a Python test harness):

1. `pearson(seq, seq) == 1.0` (identical → perfect correlation).
2. `pearson(seq, -seq) == -1.0` (negated → perfect anti-correlation).
3. `pearson(seq, seq[::-1])` — depends on seq, just confirm finite.
4. Vacuous input (empty sequences) → vacuous-pass sentinel, not crash.
5. `n_measured < n_min_measured` → vacuous-pass sentinel.

### Integration test — corpus self-comparison

Run G1 against the shipped corpus with **reference = working tree =
candidate** (i.e., no diff). Every (letter, stroke) should return Pearson
= 1.0. **Any non-1.0 result means the resampling or asymmetry computation
is non-deterministic — flag and investigate before shipping G1.**

### Calibration run (replaces the original spot-check)

Under the freeze-gate framing in Section 3a, the session-pair measurement
IS the calibration, not a spot-check on top of a self-Pearson run. See
`g1_calibration_run.md` for the actual numbers, decision-rule outcome
(metric sensitivity confirmed: real polish edits land in the 0.2–0.95
range; noise-floor strokes correctly vacuous-pass via the
`low_variance_asymmetry` filter), and derived threshold.

### Pass criteria for G1 ship

- All unit tests pass.
- Self-comparison integration test: every letter/stroke = 1.0.
- Calibration run produces a defensible threshold via the session-pair
  procedure (Section 3a), surfaced to David for ship-it before being
  recorded in `BAKE_INVARIANTS.md`.
- CI green on the implementation commit.

---

## Decisions summary (post-reframing)

| Section | Decision | Alternatives considered |
|---|---|---|
| **1a** | Option A — per-stroke Pearson; letter pass = all strokes pass | B (concatenate), C (min aggregation) |
| **1b** | Arc-length resample both to N=100 before asymmetry computation | Hard-fail on mismatch; resample candidate to reference's length |
| **1c** | Vacuous pass for 1-cp strokes | Exclude; hard-fail |
| **1d** | Vacuous pass when `n_measured < 10`; surface count in output | Hard-fail |
| **1d (sibling)** | Vacuous pass when `max(cand_std, ref_std) < 0.05` (`low_variance_asymmetry`) — filters sub-pixel-noise-floor strokes like uniform-stem l, I | Skip filter (l contaminates threshold floor with noise); calibration-time exclusion (less methodologically clean than gate-time) |
| **2a** | Reference = `git show HEAD:PATH` (or `origin/main`) for CI; working tree for local | — |
| **2b** | Umbrella `scripts/run_gates.py --gate g1`; logic in `audit_invariants.py::gate_g1` | Per-gate script; subcommand of `audit_invariants.py` |
| **2c** | Stdout human-readable by default; `--json` flag for CI | One-or-the-other |
| **3a** | Freeze-gate framing: calibrate against 2026-05-22 session-pair corpus; threshold = `min(real Pearson)`; no safety margin | Original draft: fresh-bake-vs-shipped self-Pearson floor (obsolete post-`6a85811c`); ε-noise; hand-pick |
| **3b** | `min` over all (letter, stroke) pairs | `min` over letters' worst-stroke |
| **4** | All 59 letters get the same freeze-gate treatment; bake-controlled-vs-static distinction is obsolete | Original draft maintained a 37/22 split (now factually wrong) |
