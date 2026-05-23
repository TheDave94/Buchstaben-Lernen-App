# research_data/

Research artefacts that aren't bundled into the app but support the
thesis methodology. Kept in-tree so the corpus is git-versioned and
citeable.

## Contents

- `calibration_sessions/<YYYY-MM-DD>/` — captures from
  `CalibrationSessionLogger` (shipped in commit `40e275da`). Each
  dated batch is the output of one calibration round; per-letter
  subfolders contain `<timestamp>.json` files with pre/post polyline
  pairs plus metadata. See the round's own `README.md` for batch-
  specific notes.
- `spec_decision/` — empirical evidence and framing that drove the
  SPEC-VISUAL-APPROVAL choice for `docs/BAKE_INVARIANTS.md`. Contains
  the three Phase-2b investigations' findings condensed for thesis-
  ready citation.
- `phase2b_gates/` — design documents and calibration run results
  for the Phase 2b drift-from-reference gates G1-G5 per
  `docs/BAKE_INVARIANTS.md` §0 (SPEC-VISUAL-APPROVAL). Each gate
  has a design doc and, once calibrated, a calibration result doc.
  See the directory's own `README.md` for the full layout.

## Audience

Future maintainer reviewing why decisions were made; thesis examiner
checking the empirical grounding of the methodology chapter.

## Versioning policy

Append-only. Each calibration session creates a new dated subfolder;
existing folders never edited after the round commits. Per-pair
files never edited (they're immutable evidence of what was saved on
which timestamp by which tool).

## What lives here vs. what doesn't

research_data/ contains:
- Captured EVENT data that prose can't replace (session pairs,
  per-checkpoint edit traces)
- Decision documents and design rationale (spec_decision/,
  phase2b_gates/)
- Calibration run results when they're produced

research_data/ does NOT contain:
- Raw iPad export bundles (the per-letter derivatives in
  Letters/Regular/ are the canonical state; bundles are stale
  snapshots once their per-letter contents are extracted)
- Intermediate analysis files (one-shot scripts, temp diff
  dumps) — these get superseded by surfaced markdown reports
- Working-tree scratch (anything that lived in /tmp during
  a session)

Rule of thumb: if it documents an EVENT or DECISION, it belongs
here. If it's just a snapshot of state that's now reflected
elsewhere in the repo, it doesn't.
