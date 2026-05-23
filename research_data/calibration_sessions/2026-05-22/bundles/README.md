# iPad export bundles

Original iPad-export snapshots from the calibrator's "Alle"
feature. These are the SOURCE artifacts behind the per-letter
strokes.json files committed under
PrimaeNative/Resources/Letters/Regular/.

Each bundle is the full 59-letter state at one moment in the
calibration session. Per-letter strokes.json files are
derivatives (extracted via scripts/calibration_to_override.py,
which preserves skeleton/skeletonAdj/bridgeEdges fields the
bundle doesn't carry).

## Files

- `bundle_2026-05-22_batch-1.json` — Round-2 post-batch-1 iPad
  state, before umlaut dots. Source for import commit b17ab215.
  Original filename: A_strokes_round2.json.
- `bundle_2026-05-22_batch-2.json` — Round-2 post-batch-2 iPad
  state, with umlaut dots added via "+ Punkt" feature. Source
  for import commit 4a3fd5b4. Original filename: I_strokes.json.

## Naming convention

Future bundles: `bundle_<YYYY-MM-DD>_<descriptor>.json` where
descriptor identifies the session context (batch-N, baseline,
pre-X-experiment, etc.).
