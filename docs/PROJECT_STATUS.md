# Project Status — Stocktake 2026-05-24

Point-in-time audit of what's shipped, what's pending, and what's
stale. Differs from `docs/ROADMAP.md` (forward planning, owner
actions, effort estimates): this doc is the catch-up read after
returning to the project with a fresh head. It reconciles
committed documentation against today's reality, flags items
that exist only in conversation memory, and lists the questions
that can't be answered from docs alone.

Run `git log --oneline` for the granular history; this is the
narrative summary.

---

## 1. Shipped and operational

### 1.1 App + infrastructure (already in `README.md`)

- Full Primae rebrand (repo, Xcode project, bundle ID, every screen)
- Dark-mode parity via Asset-Catalog colorsets (38 tokens; flip via
  parent-area "Erscheinungsbild" picker)
- VM God-object decomposition (D1a/b/c): VM down from 2350 → ~2030
  lines
- CoreML classifier-closure protocol seam (D3) with 7 pipeline tests
- Spaced-retrieval scheduler (P1) + opt-in toggle
- Phoneme audio infrastructure (P6) — toggle wired; recordings
  pending (see 2.1)
- Apple Pencil 2 squeeze wiring (U5) — code shipped; device
  validation pending (see 2.2)
- Two CI workflows: `ios-build.yml` (iPad sim + self-hosted MacBook)
  and `bake-gates.yml` (new — see 1.3)

### 1.2 Bake-pipeline lifecycle

- **Druckschrift Regular = static artifacts** since commit `6a85811c`
  (2026-05-15). All 59 letters in `Letters/Regular/` ship as
  hand-calibrated `strokes.json` files. The bake pipeline at
  `scripts/generate_strokes_auto.py` is retired for Regular —
  preserved as scaffolding for Light template-warping and future
  fonts. `LETTERS` dict + arm/joint primitives stay in place.
- **Druckschrift Light** ships baked output for the 28 letters that
  pass on Regular's tuning constants; failures silently fall back to
  Regular polyline at runtime. Source: commit `dae2b3c0`.
- **Skeleton + skeletonAdj baked into strokes.json** (Phase 1.5
  per `STROKE_AUDIT.md`); Swift loader prefers baked.

### 1.3 Phase 2b Track B — drift-from-reference gate set (COMPLETE)

Operational closure of the bake-invariants gating story. All gate
designs + calibration results live in
`research_data/phase2b_gates/`.

| Gate | Status | Commit | Threshold | Doc(s) |
|---|---|---|---|---|
| G1 (asymmetry-profile drift) | Enforced | `e00a0d8d` | Pearson ≥ 0.2005 | `g1_design.md`, `g1_calibration_run.md` |
| G2 (turn-angle-profile drift) | Investigated, not viable | `a659b7f1` | n/a | `g2_design.md`, `g2_calibration_run.md` |
| G3 (perpendicular deviation on straight strokes) | Enforced | `4f84afc7` + `c4c143b8` | deviation ≤ 2.05 px | `g3_design.md`, `g3_calibration_run.md` |
| G4 (junction-tangent-kink drift) | Enforced | `cfc70a2d` | drift ≤ 4.43° | `g4_design.md`, `g4_calibration_run.md` |
| G5 (CI wiring) | Operational | `e238ad63` | n/a | `g5_design.md`, `g5_verification.md` |

The G5 verification PR (TheDave94/Primae#1, closed without merging
2026-05-24) confirmed end-to-end operation. Two sidebar fixes
landed during verification: scikit-image added to CI deps
(`987b0bc5`), G3 classifier extended with a signed-cumulative
criterion (`c4c143b8`) to filter smooth-long-curves that the
max+p95-only classifier wrongly admitted.

Lowercase l foot/curl open question resolved 2026-05-25 as an
intentional Druckschrift feature (see `g3_design.md` §"Finding —
Primae's lowercase l has a foot/curl"); G3 handles it correctly
via the signed-cumulative criterion.

### 1.4 Calibration corpus

`research_data/calibration_sessions/2026-05-22/` — 13 letters,
38 (pre, post) polyline pairs across two batches. Drives all
G1/G3/G4 thresholds. Versioning policy is append-only (per
`research_data/README.md`); future sessions create new dated
subfolders.

---

## 2. Active pending work

All five items below are in `docs/ROADMAP.md` and accurately
reflect actual state.

### 2.1 P6 — Phoneme audio recordings (P1, thesis-blocking)

- **What.** 90 recordings (30 letters × 3 takes) via ElevenLabs +
  drop into `PrimaeNative/Resources/Letters/<base>/`.
- **Why deferred.** Recording-time-bound (XL effort); needs
  voice-direction work.
- **Trigger to revisit.** Pure asset work, no device needed —
  schedule whenever.

### 2.2 U5 — Pencil 2 squeeze device validation (P3)

- **What.** Real iPad with Pencil 2nd gen, confirm squeeze +
  double-tap fire `replayAudio()`.
- **Why deferred.** Code wired; needs physical hardware to
  validate.
- **Trigger to revisit.** Before any external thesis-reviewer
  exposure.

### 2.3 U10 — VoiceOver walkthrough (P3)

- **What.** Real iPad with VoiceOver, walk every screen + Switch
  Control + Dynamic Type stress.
- **Why deferred.** Partial in-code audit shipped; device walkthrough
  is the load-bearing part.
- **Trigger to revisit.** Same as U5 — pre-external-review.

### 2.4 D8 — Canvas redraw frequency profile (P3, post-thesis polish)

- **What.** Instruments time-profile of a high-velocity guided
  session.
- **Why deferred.** No measured evidence of a problem.
- **Trigger to revisit.** Real-classroom lag report or
  device-test CI flagging a frame drop.

### 2.5 F1–F10 — Post-thesis features

Documented in `ROADMAP.md` §5. All gated on thesis ship.

---

## 3. Conversation-only items (NOT in committed docs)

These exist only in this session's transcript or in
`/root/.claude/projects/.../memory/`. They are the items most at
risk of being lost when memory resets.

### 3.1 Lowercase `g` stroke decomposition — confirmed-intentional

- **Where.** `g3_calibration_run.md` "Post-deployment refinement"
  and `g4_calibration_run.md` "Discovered scope constraint".
- **What it is.** g s1 is the entire bowl + descender as one
  continuous stroke; g s0 + s1 form a mid-stroke attachment
  rather than an end-to-end junction.
- **Status.** Visually confirmed correct during G5 verification
  (2026-05-24). Documented as a "for David's eye" item; no
  further action.

### 3.2 Ä s1 / Ä s2 borderline G3 classifications — RESOLVED 2026-05-26

- **Where.** `g3_calibration_run.md` "Borderline classifications"
  section; `phase2c_design.md` composite-umlaut investigation
  sub-item.
- **What it is.** Ä's base diagonals classify just outside G3's
  STRAIGHT class (Ä s1 p95 = 0.103 rad / 5.92° vs 0.100 rad /
  5.73° threshold; Ä s2 max = 0.290 rad / 16.62° vs π/12 / 15.00°
  threshold). Pure A's analogous strokes are well clear.
- **Status.** RESOLVED 2026-05-26 via the composite-umlaut
  investigation sub-item in Phase 2c. Original framing attributed
  the divergence to `bake_composite`; investigation falsified
  that attribution and corrected to calibrator-authored geometry
  (cp-count dispositive: `[200, 200, 181, 1, 1]` vs
  `[40, 40, 40]`). G3 classifier correctly reads the
  calibrator-authored marginal curvature. No code change. See
  `research_data/phase2b_gates/phase2c_design.md` composite-
  umlaut sub-item for the full finding.

### 3.3 Memory-only / userMemories items

`/root/.claude/projects/.../memory/MEMORY.md` carries 14 entries.
Most are operational reflexes (CI-wait scope, commit-boundary
hold, etc.) that don't translate to committed docs. The
project-state entry (`project_phase2b_track_b_state.md`) is the
only one carrying substantive project history; the contents of
that entry are now reflected in this PROJECT_STATUS.md and in
the per-gate calibration_run.md docs.

---

## 4. Stale documentation findings

Fix these in a separate commit after David reviews this stocktake.

### 4.1 `docs/ROADMAP.md` last-updated date — RESOLVED 2026-05-25

Header date bumped to 2026-05-25 (commit `1f9f5a0`); stroke-
geometry bullet at line 37 extended with Phase 2b Track B
summary (G1/G3/G4 enforced, G2 investigated-not-viable, G5
CI-wired). Curve-workstream "Open follow-up" sub-clause
preserved for the §4.2 decision.

### 4.2 `docs/ROADMAP.md` line 37 — curve workstream — RESOLVED 2026-05-25

Sub-clause rewritten to: "Open follow-up for the bake pipeline
(Light + future fonts only; Regular ships as hand-calibrated
artifact since `6a85811c`): Q-class topology (Q a_l ä_l g_l q_l
ü_l) and resolver work for Y/y/ß." Dropped l (resolved
2026-05-25 — see g3_design.md), dropped t/f/j/r/i (shipped via
the same `smoothed_medial_axis` architecture as l per
`generate_strokes_auto.py:353-415`).

### 4.3 `docs/BAKE_INVARIANTS.md` §6 header — RESOLVED 2026-05-25

Header renamed to "Enforcement tally — current state
(post-Phase 2b Track B, 2026-05-24)". "Net." paragraph rewritten
to past tense: Rules 1/2 measurement-backed via G1/G3/G4,
enforcement floor names the live gates, Threshold 2 marked
not-viable, Threshold 3-curved noted as the one pending gate.
Other Phase-2b future-tense references throughout the doc
remain pending the §4.6 sweep.

### 4.4 `docs/STROKE_AUDIT.md` status note — RESOLVED 2026-05-25

"Still open" block updated to mirror §4.2's wording: Q-class
topology and Y/y/ß resolver kept as bake-pipeline open work;
the curve workstream for l/t/f/j/r/i marked resolved (l per
2026-05-25 investigation; t/f/j/r/i shipped via same
architecture).

### 4.5 `docs/INVARIANTS.md`, `docs/STROKE_CALIBRATION.md`,
       `docs/RENDERING.md` — RESOLVED 2026-05-25

Per-doc resolution after per-claim diff audit:
- **INVARIANTS.md** — deleted. Claim "centerline mirrors inner
  counter, not outer silhouette" (asymmetric-bowl framing for
  D/P/b/R bowls) merged into `BAKE_INVARIANTS.md` §1 Rule 1 as
  a permanent construction invariant. Claim "SKELETT bootstrap
  read-only against editableStrokes" (12 write sites audited;
  Python simulator verified 0.00 px drift across 59 letters)
  merged into `LESSONS.md` Part B under a new ## Calibrator
  section.
- **STROKE_CALIBRATION.md** — SUPERSEDED header added pointing
  to `BAKE_INVARIANTS.md` §2 / §4. 80%-margin rule documented
  in the header as dropped-with-rationale (gate noise-floor
  margins ≠ comfortable-margin buffers; methodology-chapter
  relevance flagged).
- **RENDERING.md** — SUPERSEDED header added pointing to
  `BAKE_INVARIANTS.md` §5. The four "Open questions for
  renderer implementation" migrated to `docs/ROADMAP.md` §4
  Technical Debt as D9.

### 4.6 Phase 2b future-tense references throughout — RESOLVED 2026-05-25

Scope decision: Phase 2b ended with Track B. Swept 8 ambiguous
references in `BAKE_INVARIANTS.md` (lines 26, 134, 166, 232,
289, 392, 437, 549) to past tense for shipped portions or
"post-Phase-2b future work" for genuinely pending items
(Threshold 3-curved; `verify_bake.sh` CI lift). Avoided
"Phase 2c" naming pending §5.2. `g3_calibration_run.md:23`
verified accurate (past-tense factual claim) — no edit needed.
`framing.md` reported by the stocktake as having Phase 2b
mentions, but `grep` finds none today — discrepancy in
stocktake; either since-removed or mis-recalled. Also corrected
an inaccuracy I introduced in `d55f4da`'s Net-paragraph rewrite
(had claimed Threshold 6 was in CI — it is not; manual /
pre-commit only).

---

## 5. Open questions for David

Items where status can't be determined from docs alone. Each
needs your call before the project's "what's next" framing is
solid.

### 5.1 What's next after Phase 2c completion?

**Status: Phase 2c complete (2026-05-26); remaining options narrow to
thesis writing (b) or post-thesis polish.**

Phase 2c shipped as scoped in
`research_data/phase2b_gates/phase2c_design.md`:
- **G6 mid-stroke attachment tangent-drift gate** — shipped at
  commit `f6365b9`.
- **G3-curved** — investigated, not viable as a freeze-gate metric
  (see `research_data/phase2b_gates/g3_curved_not_viable.md`,
  commit `4a2a224`).
- **Composite-umlaut investigation** — closed; original "bake
  artifact" framing for Ä's borderline G3 classification was
  empirically false. Ä's base geometry is calibrator-authored
  intent (densified strokes prove the calibrator bypassed
  `bake_composite`), not a pipeline artifact (commit `0c89b0d`).

Engineering-push options now:
- (a) **Post-thesis polish** — Phase 2c is complete; remaining
  engineering work is limited and none of it thesis-blocking:
  - Composite-umlaut shipped Light-only items (Q-class bake
    topology for `Q, a_l, ä_l, g_l, q_l, ü_l`; ß Light resolver)
    — tracked in `docs/ROADMAP.md` line 37 (bake-pipeline open
    follow-up).
  - `verify_bake.sh` CI lift — operational CI hygiene; tracked in
    `docs/BAKE_INVARIANTS.md` §2 Threshold 6 + §6 tally.
  - G5.5 merge-base switch — contingency for a workflow that
    doesn't yet exist (frequent main rebases); tracked in
    `research_data/phase2b_gates/g5_design.md` G5.4.
  - D8 (Canvas redraw frequency profile) and D9 (renderer open
    questions) — tracked in `docs/ROADMAP.md` §4 Technical Debt.
- (b) **Thesis writing** — biggest remaining workstream. The
  `primae-thesis` content/*.typ files are KUG template stubs with
  placeholder italic prompts; no actual prose yet.
- (c) **Corpus growth** — RESOLVED, see §5.3 (corpus frozen for
  Regular's lifetime; trigger tied to new-font calibration).
- (d) Something else / TBD.

"Track A" (endpoint_trim bake fix) was a placeholder term used
in earlier session prompts; deprecated 2026-05-25 since
Phase 2c is now defined and the "Track A" term was never given
substantive content.

### 5.2 "Phase 2c" — is that the right name? — RESOLVED 2026-05-25

Yes — defined as the gate-coverage gap-closure umbrella in
`research_data/phase2b_gates/phase2c_design.md`. Scope: G6
mid-stroke attachment gate + G3-curved + composite-umlaut
investigation. Explicit out-of-scope items (Q-class bake
topology, ß resolver, `verify_bake.sh` CI lift, G5.5 merge-base
switch) each tracked separately. All "Phase 2c" placeholder
references swept to point at the design doc.

### 5.3 Calibration corpus growth — when? — RESOLVED 2026-05-26

`framing.md` says ~50-100 session pairs would be needed before
revisiting residual-model approaches. Current corpus has 38 pairs
(13 letters).

**David's stated position (2026-05-26):** no further calibration
sessions are planned for Regular. The corpus is treated as frozen
for Regular's lifetime. The "when do we hit 50-100 via natural
growth?" framing therefore dissolves — there is no scheduled
extension of Regular's corpus.

The 50-100-pair threshold remains a forward-pointer, but it now
becomes a question of whether a *future font's* calibration
(Primae Light, a future Schreibschrift weight, or another future
weight) accumulates that many pairs across its own corpus.
**Trigger condition for revisiting residual-model approaches:**
new-font calibration crossing the threshold.

**Methodology implication.** G6's n=3 calibration corpus —
calibration on 2 of 3 T-junction archetypes per
`research_data/phase2b_gates/g6_design.md` — is the concrete
instance of this constraint. "Corpus is what it is" for the gate
set as well: the n=3 limitation is shipped-as-is, and any future
revisit is coupled to whichever new font is next calibrated, not
to a scheduled Regular extension.

---

## 6. Files to read first when returning to this project

In order, for a future-you (or successor contributor) returning
cold:

1. **`README.md`** — what the app does (10 min).
2. **`CLAUDE.md`** — collaboration patterns + load-bearing docs +
   architecture conventions (5 min).
3. **This file (`docs/PROJECT_STATUS.md`)** — what shipped, what's
   pending, what's stale.
4. **`docs/ROADMAP.md`** — owner-action items, effort estimates,
   citations per pending feature.
5. **`docs/BAKE_INVARIANTS.md`** — the operative spec for the
   shipped corpus and the gate set.
6. **`research_data/phase2b_gates/README.md`** — gate set
   navigation; jump to specific `g{N}_*.md` from there.
7. **`docs/LESSONS.md`** — code-level invariants before touching
   `AudioEngine.swift` / `StrokeTracker.swift` / `load(letter:)`.

The thesis repo at `/opt/repos/primae-thesis/` is currently a
KUG template with placeholder content; no thesis prose has
started.
