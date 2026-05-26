# G6 calibration findings — 2026-05-26

**Calibration data:** `research_data/calibration_sessions/2026-05-22/`
**Script:** `scripts/calibrate_g6_threshold.py`
**Outcome:** **Threshold = 4.50°** (max observed 0.50° at A s2→s0 first; +4.0° margin per the measurement-instrument framing in `phase2c_design.md` G6 section). Polish-preservation verified across 3 measurable junction rows; 0 vacuous-pass rows.

## Framing

G6 is the **T-junction analogue of G4** — a drift gate on per-junction attachment-tangent angle, scoped to MID-STROKE-ATTACHMENT junctions (one stroke's endpoint sits on another stroke's interior, NOT at the host's endpoint). Strict classifier by `host_cp_idx` (after N=100 resample): G4 owns `idx < 5` OR `idx > 94`; G6 owns `5 ≤ idx ≤ 94`. No overlap.

The 2026-05-22 session-pair corpus serves all gate calibrations. For G6, every (i, j, attach_at_first) triple in each letter is run through `gate_g6_per_junction(round1, round2, ...)` with threshold=∞ so the result reports actual drift values rather than pass/fail. The metric is the absolute drift |attachment_angle_r2 − attachment_angle_r1| where attachment_angle is the unsigned [0°, 90°] angle between the attaching stroke's tangent at its attaching endpoint and the host stroke's local tangent at the attachment point. Same `_stroke_tangent_at_endpoint` helper as G4 for the attaching side; new `_host_tangent_at_idx` helper for the host side.

## Calibration corpus

Session-pair corpus filtered to sessions where round-1 (pre-polish) and round-2 (HEAD strokes.json) stroke counts match. This excludes the umlaut-dot-addition workflow sessions in batch 2 (Ä's 12 sessions where r1 has 2–4 strokes and r2 has 4–5).

- Letters measured: **2** (A, p)
- Total measurable junction rows: **3**
- Vacuous-pass rows: **0**
- Skipped:
  - Ä: 2026-05-22T17-50-23Z.json: topology_change_r1=3_r2=5
  - Ä: 2026-05-22T17-51-26Z.json: topology_change_r1=2_r2=5
  - Ä: 2026-05-22T17-52-34Z.json: topology_change_r1=4_r2=5
  - Ä: 2026-05-22T17-55-43Z.json: topology_change_r1=3_r2=5
  - Ä: 2026-05-22T18-38-35Z.json: topology_change_r1=3_r2=5
  - Ä: 2026-05-22T18-39-59Z.json: topology_change_r1=3_r2=5
  - Ä: 2026-05-22T18-41-17Z.json: topology_change_r1=4_r2=5
  - Ä: 2026-05-22T18-41-45Z.json: topology_change_r1=4_r2=5
  - Ä: 2026-05-22T18-42-43Z.json: topology_change_r1=4_r2=5
  - Ä: 2026-05-22T18-43-03Z.json: topology_change_r1=4_r2=5
  - Ä: 2026-05-22T18-44-41Z.json: topology_change_r1=4_r2=5
  - Ä: 2026-05-22T18-44-48Z.json: topology_change_r1=4_r2=5
  - Ö: 2026-05-22T17-50-45Z.json: topology_change_r1=1_r2=3
  - Ö: 2026-05-22T17-52-59Z.json: topology_change_r1=1_r2=3
  - Ö: 2026-05-22T17-53-05Z.json: topology_change_r1=2_r2=3
  - Ö: 2026-05-22T17-55-09Z.json: topology_change_r1=2_r2=3
  - Ö: 2026-05-22T18-39-06Z.json: topology_change_r1=1_r2=3
  - Ö: 2026-05-22T18-40-12Z.json: topology_change_r1=1_r2=3

## Per-junction calibration table

| Letter | i→j | endpt | archetype | host_idx_r1 | host_idx_r2 | dist_r1 | dist_r2 | angle_r1 | angle_r2 | **drift** | edits | session |
|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| A | s2→s0 | first | crossbar | 40 | 40 | 6.01 | 6.26 | 68.05° | 68.55° | **0.498°** | 3 | 2026-05-22T17-36-21Z.json |
| A | s2→s1 | last | crossbar | 39 | 40 | 1.13 | 2.35 | 75.11° | 74.96° | **0.148°** | 3 | 2026-05-22T17-36-21Z.json |
| p | s1→s0 | first | bowl | 31 | 32 | 6.16 | 4.91 | 23.86° | 24.02° | **0.159°** | 8 | 2026-05-22T17-49-25Z.json |

## Summary statistics

- n junctions measured: **3**
- n vacuous-passed: **0**
- Drift distribution (°): min=0.148, median=0.159, max=0.498

### Per-archetype breakdown

| Archetype | n measured | n vacuous | drift max |
|---|---:|---:|---:|
| crossbar | 2 | 0 | 0.498° |
| bowl | 1 | 0 | 0.159° |
| umlaut | 0 | 0 | — |
| other | 0 | 0 | — |

## Threshold derivation

- max(per-junction attachment-kink drift): **0.498°** at A s2→s0 first
- safety margin: **+4.0°** (generous per measurement-instrument framing; thin n=3 corpus covers only 2 of 3 archetypes; G6's design driver is future-font measurement, not tightly-fit Regular protection)
- **threshold = max + margin = 4.50°**

This matches the G6.v2 sub-diagnostic 2026-05-26 finding (max=0.50°, threshold=4.50°). `G6_DEFAULT_THRESHOLD_DEG = 4.50` in `scripts/audit_invariants.py`.

## Identity check — gate T-junction count vs G6.v1 diagnostic

Ran `gate_g6(HEAD, HEAD, ...)` on every Regular letter to compare the gate's T-junction detection count against the G6.v1 pre-implementation diagnostic's count of 20 T-junctions across 15 letters.

- Gate detection count: **20 T-junctions across 15 letters**
- Diagnostic count (G6.v1, 2026-05-26): **20 T-junctions across 15 letters**
- Diff: **+0** junction(s), **+0** letter(s)

Counts agree. The gate's enumeration matches the diagnostic's enumeration; no divergence to investigate.

## Polish-preservation verification

All 3 measurable junctions show drift < 1° (max 0.498° at A s2→s0 first). Polish-preservation holds for the geometric class G6 measures, on the measurable subset of the corpus.

**Bowl-bearing absence vignette.** The bowl-bearing archetype (B, P, R, a, d, q, y — 7 of 8 bowl-bearing letters in the G6.v1 diagnostic) is conspicuously absent from this calibration corpus. The lone bowl-bearing representative is p; the other 7 letters have no 2026-05-22 session pairs. This is not random absence: those letters were authored via the calibrator override precisely because the auto-calibrator failed on their T-junction topology (R, b, d, P documented failure cluster per `docs/LESSONS.md` Part A §1-3; `research_data/spec_decision/framing.md:67-98`). Once correctly authored, they're stable; the 2026-05-22 polish sessions did not need to touch them. The absence is consistent with the measurement-instrument framing: G6 is for catching the class when it goes WRONG (the auto-calibrator-on-new-font case), not for tracking polish on Regular where the class is already correctly stable.

## Discovered scope constraint

The G6 corpus excludes umlaut sessions where pre/post stroke counts differ (12 of 12 Ä batch-2 sessions). These represent the umlaut-dot-addition workflow, not polish — the round-1 and round-2 stroke topologies are intentionally different, so the index-based junction comparison is not meaningful. This is a known structural property of the corpus, not a calibration weakness. Ä-style composite-umlaut T-junctions (diacritic dot attachments) remain unmeasured on this corpus; G3-curved or a future Phase 2c sub-investigation may revisit.

## Reference — design lock

- Scoping-level design lock: `research_data/phase2b_gates/phase2c_design.md` G6 section (Status: design locked 2026-05-26)
- Pre-implementation diagnostic (G6.v1): `/tmp/diagnostic_g6_mid_stroke_attachment.py` (2026-05-26)
- Sub-diagnostic (G6.v2): `/tmp/diagnostic_g6_drift_metrics.py` (2026-05-26)
- Implementation: `scripts/audit_invariants.py` `gate_g6` + helpers; `scripts/run_gates.py` `GATE_METADATA['g6']`
- Tests: `scripts/tests/test_gate_g6.py` (25 tests)
- Threshold of record: `G6_DEFAULT_THRESHOLD_DEG = 4.50` (set in `audit_invariants.py`)
