# G5 verification — bake-gates.yml end-to-end smoke test

**Date:** 2026-05-24
**PR:** [TheDave94/Primae#1](https://github.com/TheDave94/Primae/pull/1)
(closed without merging; branch deleted)
**Outcome:** **Verified operational.** Workflow fires on PR-open
when strokes.json changes, runs G1/G3/G4 sequentially, catches
deliberate violations, exits non-zero, uploads JSON artifacts.

## The smoke test

The PR shifted cps[15:25] of A s0 (left diagonal) by 0.010
perpendicular to the stroke direction. Locally-predicted
outcome:

- G1: PASS (Pearson 0.8631 ≥ 0.2005)
- G3: FAIL (deviation 2.69 px > 2.05 px threshold)
- G4: PASS (junction kink drift 0.004° ≤ 4.43°)

## Two sidebar findings landed during verification

**Sidebar 1 — missing CI dep (commit `987b0bc5`).** First run
(2026-05-24 18:14) failed at G1's module load:
`ModuleNotFoundError: No module named 'skimage'`.
`scripts/generate_strokes_auto.py` imports `skimage.morphology`
at module level; gates don't use it directly, but `run_gates.py`
imports `generate_strokes_auto` for `rasterize`/`bbox_from_mask`.
Fix added `scikit-image>=0.21` to bake-gates.yml deps. Dep audit
confirmed no other missing imports.

**Sidebar 2 — classifier hole (commit `c4c143b8`).** After the
dep fix, second run (2026-05-24 18:34) reproduced the expected
A failure but also flagged Y s0, Y s1, and g s1 as G3 failures
(deviations 24-70 px) — letters not in the 2026-05-22 calibration
corpus. Visual rendering confirmed Y/g are correctly-drawn smooth
long curves; the G3 max+p95 classifier was admitting them as
STRAIGHT because smooth curves at N=100 resample have small
per-segment angles. Fix added a third criterion to the
straightness check: `|signed_cumulative_angle| < π/12`. The
threshold of record (2.05 px) is unchanged; Y/g were previously
wrongly admitted and are now correctly vacuous. See
`g3_design.md` "Refinement caught during G5 verification" and
`g3_calibration_run.md` "Post-deployment refinement" sections.

## Final verification run (2026-05-24 22:32)

**Run:**
[26374602741](https://github.com/TheDave94/Primae/actions/runs/26374602741)
on rebased verify branch after both sidebars landed on main.

| Step | Outcome | Detail |
|---|---|---|
| Checkout (fetch-depth 0) | ✓ | full history fetched |
| Fetch origin/main | ✓ | reference ref resolves correctly |
| Setup Python 3.12 | ✓ | |
| Install deps | ✓ | pillow + numpy + scipy + fonttools + scikit-image |
| G1 | ✓ | A s0 Pearson 0.8631; 59/59 letters pass |
| G1 JSON artifact | ✓ | uploaded |
| G3 | **✗** | **58/59 pass; A s0 fails (dev=2.68 px > 2.05 px) — only A fails** |
| G3 JSON artifact | ✓ | uploaded |
| G4 | − | skipped (sequential exit after G3 failure) |
| G4 JSON artifact | ✓ | uploaded |
| Upload artifacts | ✓ | `bake-gate-results.zip` |
| Job result | **failure** | merge-blocker semantics correct |

All predicted behaviors confirmed. Y and g are now correctly
vacuous as not-straight (signed-cumulative classifier change).
The workflow exits non-zero on G3 failure; the PR is blocked from
merge.

## Methodology trail markers (Phase 2b Track B)

This sidebar-2 finding is the **fifth instance** of
design-prediction-meets-data in Phase 2b Track B:

1. G2: predicted polish-stable; calibration falsified;
   soft-V outcome
2. G3: predicted max-only classifier adequate; implementation
   falsified; redesigned with combined max+p95
3. G4: predicted smooth pen-continuation cluster existed;
   pre-implementation diagnostic falsified; redesigned as
   drift gate
4. G4: predicted all consecutive-pair junctions are end-to-end;
   calibration's p finding refined this to "most are; mid-stroke
   attachments out of scope"
5. **G3 (this verification): predicted max+p95 was adequate for
   the full 59-letter corpus; G5 deployment-to-all-letters
   falsified the prediction; refined with signed-cumulative
   criterion**

The pattern is now load-bearing: design predictions are
falsifiable claims tested against data. Predictions are stated
explicitly before implementation; data verifies or falsifies
them; the design adapts.

## Files referenced

- Workflow: `.github/workflows/bake-gates.yml`
- Gate logic: `scripts/audit_invariants.py` (gate_g1 / gate_g3 /
  gate_g4)
- CLI driver: `scripts/run_gates.py`
- Sidebar fix commits: `987b0bc5` (dep), `c4c143b8` (classifier)
- Closed PR: [TheDave94/Primae#1](https://github.com/TheDave94/Primae/pull/1)
- Final passing run on verify branch (with G3 failing only on A):
  [26374602741](https://github.com/TheDave94/Primae/actions/runs/26374602741)
