# Phase 2b drift-from-reference gates — design + calibration

Design documents and calibration run results for the Phase 2b
drift-from-reference gates G1-G5 per `docs/BAKE_INVARIANTS.md` §0
(SPEC-VISUAL-APPROVAL). Each gate has a design doc (decisions +
alternatives + verification plan) and, once calibrated, a
calibration result doc (corpus measurement output, derived
threshold, sanity-check Pearson scores).

Cited by `docs/BAKE_INVARIANTS.md` Thresholds 1-4 and the thesis
methodology chapter (Track D). New gate designs land here BEFORE
implementation; calibration results land here in the same commit
that updates `BAKE_INVARIANTS.md` with the derived threshold.

## Contents

- `g1_design.md` — G1 (Threshold 1, asymmetry-profile drift)
  design proposal: metric shape, reference lookup, threshold
  calibration procedure, edge-case list, implementation outline,
  verification plan.
- `g1_calibration_run.md` *(arrives with the calibration commit)*
  — fresh-bake-vs-shipped self-Pearson floor across the 37
  bake-controlled letters, mandatory sanity-check on round-1 vs
  round-2 calibrator session pairs (A, W, m), derived production
  threshold, corpus state SHA.

G2-G5 design + calibration docs land here as each gate ships.
