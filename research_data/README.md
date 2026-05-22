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

## Audience

Future maintainer reviewing why decisions were made; thesis examiner
checking the empirical grounding of the methodology chapter.

## Versioning policy

Append-only. Each calibration session creates a new dated subfolder;
existing folders never edited after the round commits. Per-pair
files never edited (they're immutable evidence of what was saved on
which timestamp by which tool).
