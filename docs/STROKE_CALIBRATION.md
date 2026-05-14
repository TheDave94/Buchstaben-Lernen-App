# Stroke Calibration — six-rule pass/fail spec

A candidate polyline ships only if it passes all six rules. **Auto-reject any candidate that fails any rule.** If a candidate passes calibration but the visual still looks wrong, the calibration is incomplete — flag and propose a new rule before iterating further.

## Rule 1 — Centerline location

Mean asymmetry ≤ 0.10, p95 ≤ 0.20.

Per polyline point: `asymmetry = |d_inner − d_outer| / (d_inner + d_outer)` along the local cross-section normal, where `d_inner` and `d_outer` are distances to the inner counter and outer silhouette respectively.

## Rule 2 — Centerline shape

Pearson correlation of turn-angle profiles ≥ 0.85 between the polyline and the inner counter. At each inner-counter corner with turn angle > 60°, the polyline's nearest-point corner must be within ±20°. Polyline shape mirrors the inner counter, including sharp corners.

## Rule 3 — Stroke type purity

**Straight strokes**: 95th-percentile perpendicular deviation between the analytical line and the stem-ink medial axis, measured across **pure-stem rows only**, ≤ 1.5 px.

**Pure-stem rows** are rows (or columns, for primarily horizontal/diagonal strokes) where the stroke is the only one passing through — operationally: the medial axis pixels at that row span ≤ 1.5 × stem_width AND that row is not within stem_width of any other stroke's analytical path. Y-branched rows and junction-adjacent rows are excluded.

The exclusion of junction-adjacent rows makes Rule 3 robust to Y-junctions (bowl-stem, leg-stem) and vertex meetings (V/W/M/N apex corners), where the stem ink's medial axis branches into neighboring strokes' centerlines.

**Curved strokes**: no straight runs ≥ 5 consecutive points with cumulative turn-sum < 5°. Each stroke must be flagged 'straight' or 'curved' in the LETTERS spec.

## Rule 4 — End-to-end junction continuity

Endpoint pixel distance = 0; tangent delta ≤ 10°. For consecutive stroke pairs flagged end-to-end.

## Rule 5 — Y-junction continuity

At every Y-junction, the curved stroke's endpoint and the trunk stroke's endpoint are both the geometric intersection of their centerlines (extended tangentially if needed). The intersection pixel is shared by both polylines.

**Measurement**: gap between the two polylines' shared-end checkpoints = 0 px by construction. Threshold = 0 px (both polylines literally terminate at the same pixel).

**Fallback**: when the two tangent lines are near-parallel (angle < 10°), or the computed intersection lies outside the ink mask, or is more than stem_width away from the nominal anchor row — the implementation falls back to the literal resolved anchor pixel. Both polylines still terminate at the same pixel (gap = 0); only the geometric "intersection" interpretation is approximated. Fallback cases are documented in the bake's debug output for review.

## Rule 6 — Determinism

`scripts/verify_bake.sh` 3-trial byte-identity.

---

## Application

Produce a calibration report with the six rules × (measured, threshold, pass/fail). A candidate passes iff all six pass.

## Visual review cadence

David's eyes are required when:
- First letter shipped in a new geometric family (closed-bowl, bumps, circulars, umlauts, ß).
- New bake primitive introduced or modified.
- New calibration rule added or threshold changed.
- Candidate passes all six rules but Claude Code flags low confidence on shape match or any other rule.

Claude Code may ship autonomously when:
- Candidate passes all six rules with all metrics ≤ 80 % of threshold (comfortable margin).
- Letter is in a family with at least one already-visually-approved member.
- Re-bake of a previously approved spec with no algorithmic changes.

David retains spot-check veto: if a shipped letter reads wrong, the calibration grows a rule before further shipping.
