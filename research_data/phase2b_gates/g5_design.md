# G5 — CI wiring for Phase 2b Track B gates — Design Proposal

**Spec ref:** `docs/BAKE_INVARIANTS.md` §0 (SPEC-VISUAL-APPROVAL
operational closure) and §2 Thresholds 1, 3, 4 enforcement labels
(currently "Available via gate_g{1,3,4}; CI wiring pending G5").
**Inherits from:** G1/G2/G3/G4 design + calibration docs (operative
gates are G1, G3, G4; G2 is preserved as not-viable and not enforced).
**Status:** design only. No code yet; awaits David approval /
redlines.

G5 doesn't introduce a new metric or design pattern. It
operationalizes the three calibrated gates as PR merge-blockers via
GitHub Actions. Smaller scope than G1–G4 design docs.

---

## Corpus context (inherited)

All 59 letters of Druckschrift Regular ship as hand-calibrated static
artifacts (commit `6a85811c`). G5 enforces the calibrated thresholds
(G1: 0.2005, G3: 2.05 px, G4: 4.43°) against any PR modifying the
corpus or the gate code.

---

## Purpose

After G5, the three operative Phase 2b Track B gates become **PR
merge-blockers** in GitHub Actions. A PR that modifies a letter's
`strokes.json` and produces drift/deviation outside the calibrated
thresholds will fail CI and block merge.

This is the operational closure of Phase 2b Track B: the gates are
no longer just measurement artifacts available locally — they
actively constrain what can be merged to `main`. The freeze-gate
property of the shipped corpus becomes a workflow-level invariant,
not just a doc-level claim.

---

## Design decisions

### G5.1 — Workflow structure: ONE job, three sequential steps

**Recommendation:** single job (e.g., `bake-gates`) with three
sequential steps invoking G1, G3, G4 in order. Trade-off: less
granular failure attribution than three parallel jobs, but single
failure surface is simpler for a single-maintainer thesis project.

Sequential ordering: G1 first (catches catastrophic drift), G3
second (catches straight-stroke wobble), G4 third (catches junction
kink drift). If G1 fails, the PR is unlikely to pass G3/G4 anyway;
exiting early is fine.

### G5.2 — Threshold source: defaults in GATE_METADATA

**Current state (will need fixing in G5 implementation):** the
`--threshold` CLI flag in `scripts/run_gates.py` defaults to a
single `PRE_CALIBRATION_THRESHOLD = 0.98` constant regardless of
gate. That's wrong for G3 (needs 2.05 px) and G4 (needs 4.43°).

**Recommendation:** add a `default_threshold` field to each entry in
`GATE_METADATA`:

```
"g1": {..., "default_threshold": 0.2005},
"g2": {..., "default_threshold": None},   # not enforced
"g3": {..., "default_threshold": 2.05},
"g4": {..., "default_threshold": 4.43},
```

CI invokes `run_gates.py --gate g1 --reference-ref origin/main`
without `--threshold`, relying on the GATE_METADATA default.
Explicit `--threshold` overrides the default (useful for local
threshold sweeps or temporary tightening during development).

**Rationale:** threshold changes become code changes — visible in
git history, requiring review, atomic with the code that depends on
them. CI and local invocations behave identically. Avoids
maintaining a separate config file or environment variables.

### G5.3 — Workflow trigger: path-filtered to gate-relevant changes

**Recommendation:** trigger on `pull_request` with `paths:` filter:

```yaml
on:
  pull_request:
    paths:
      - "PrimaeNative/Resources/Letters/Regular/**/strokes.json"
      - "scripts/audit_invariants.py"
      - "scripts/run_gates.py"
      - ".github/workflows/bake-gates.yml"
```

Strokes data + gate logic + workflow itself. Skips pedagogical-only
PRs (UI work, thesis edits, README changes). The gate-code paths are
included so a PR that tweaks the gate logic still runs the gates;
otherwise a refactor of `audit_invariants.py` could land without
verification.

### G5.4 — Reference: `origin/main` HEAD

**Recommendation:** `--reference-ref origin/main`. The reference is
the current shipped state of main at workflow-run time. If main has
moved since the PR branched, the PR is measured against the updated
state.

Alternative considered: merge-base (the commit where the PR branched
off main). Merge-base avoids measuring against unrelated changes
that landed after branching. For a single-maintainer thesis project
with simple workflow and infrequent main rebases, `origin/main` HEAD
is simpler. If main is frequently rebased and the PR's gate
behavior depends on which version of main it's compared against,
switch to merge-base in a future Phase 2c iteration.

### G5.5 — Letter scope: all letters on disk

**Recommendation:** run gates over every letter present under
`PrimaeNative/Resources/Letters/Regular/` (all 59 letters), not just
the letters modified in the PR.

**Rationale:**
- Each gate run takes ~seconds. The cost is negligible.
- Catches accidental regressions in untouched letters (a script
  that operates on one letter shouldn't silently corrupt another).
- Simpler workflow logic (no need to diff PR's changed paths and
  pass per-letter args).
- run_gates.py defaults to "all letters on disk" already; no
  workflow-side filtering needed.

### G5.6 — G2 skipped entirely in CI

**Recommendation:** G5's workflow does NOT invoke G2. G2's
investigated-not-viable status (see `g2_calibration_run.md`) means
no threshold exists; there's no merge-blocking criterion. Running
G2 would add noise (its output would always be diagnostic, never
fail).

The G2 implementation is preserved in-tree as future scaffolding,
with revisit triggers documented in `g2_design.md` (corpus expansion
or distribution-shift framing). When a revisit happens, G5's
workflow gets a new step.

### G5.7 — Exit code semantics

Workflow step fails iff its `run_gates.py` invocation exits
non-zero. `run_gates.py` already exits 1 on any letter's gate
failure (it returns the count of failed letters as `n_fail`; exit
`0 if n_fail == 0 else 1` per current implementation). Job fails iff
any step fails. PR is blocked from merge iff job fails.

No additional workflow-side exit-code handling needed.

### G5.8 — Output: stdout in logs + JSON artifact

**Recommendation:** each step prints stdout-readable summary in
workflow logs (for human reviewers checking the GitHub Actions UI).
A second invocation per gate with `--json` captures machine-readable
output as a workflow artifact.

```yaml
- name: G1 — asymmetry-profile drift
  run: python3 scripts/run_gates.py --gate g1 --reference-ref origin/main
- name: G1 — JSON output
  if: always()
  run: python3 scripts/run_gates.py --gate g1 --reference-ref origin/main --json > g1.json
# ... same for g3, g4
- name: Upload gate results
  if: always()
  uses: actions/upload-artifact@v4
  with:
    name: bake-gate-results
    path: g{1,3,4}.json
```

The `if: always()` ensures artifacts are uploaded even when the
human-readable step failed (so post-mortem analysis is possible).

Future use: thesis methodology chapter could cite a specific
artifact for evidence of the gate behaving as designed on a
historical PR.

---

## Implementation outline

New / modified files:

- **`.github/workflows/bake-gates.yml`** (NEW). Single job
  `bake-gates`, triggered on `pull_request` with path filter
  (G5.3). Steps:
  - Checkout (fetch full history so origin/main is available)
  - Setup Python + install deps (numpy, scipy, fonttools — should
    match the existing CI's Python env, or use a minimal install if
    no Python CI exists yet)
  - Run G1 / G3 / G4 sequentially per G5.1 + G5.8
  - Upload JSON artifacts

- **`scripts/audit_invariants.py`** updates:
  - `G4_DEFAULT_THRESHOLD_DEG = 4.43` (was placeholder 0.0)
  - Keep G3_DEFAULT_THRESHOLD = 0.0 (or remove — never used; the
    threshold is sourced from GATE_METADATA in the implementation)

- **`scripts/run_gates.py`** updates:
  - Add `default_threshold` field to each `GATE_METADATA` entry:
    `g1: 0.2005`, `g2: None`, `g3: 2.05`, `g4: 4.43`
  - argparse `--threshold` default becomes `None`. After parsing, if
    `args.threshold is None`, set it from
    `GATE_METADATA[args.gate]["default_threshold"]`. Raise a clear
    error if both are None (e.g., trying to run G2 without explicit
    threshold).
  - Remove the `PRE_CALIBRATION_THRESHOLD = 0.98` constant.

- **`docs/BAKE_INVARIANTS.md`** updates (post-implementation):
  - Threshold 1 / 3 / 4 enforcement labels change from "available
    via gate_g{N}; CI wiring pending G5" to "enforced via
    `.github/workflows/bake-gates.yml` (G5)".

Approx LoC: workflow file ~50 lines; run_gates.py threshold-defaults
refactor ~20 lines. Total ~70 LoC + the doc-label updates.

---

## Verification procedure

1. **Workflow file lints.** GitHub Actions schema validation (e.g.,
   via `actionlint` if available locally, or by pushing and watching
   GitHub's "Action failed: invalid workflow" report).

2. **Threshold-default refactor unit test.** Add a test to
   `test_gate_g1.py` (or wherever fits) verifying that the
   default_threshold values match what's recorded in
   BAKE_INVARIANTS.md. This catches silent threshold drift if a
   future PR changes the constant in one place but not the other.

3. **Manual smoke test: deliberately failing PR.** Create a branch
   that edits one cp in A's strokes.json to introduce a 5 px
   deviation. Push as PR. Verify:
   - CI fires (path filter matches).
   - G3 step fails (5 px > 2.05 px threshold).
   - PR is blocked from merge.
   - JSON artifact contains the failure detail.
   - Revert the test branch.

4. **Manual smoke test: deliberately passing PR.** Create a branch
   that adds a comment to BAKE_INVARIANTS.md. Push as PR. Verify:
   - CI doesn't fire OR fires and passes (path filter; if the doc
     change is the only change, doc-path isn't in the filter so CI
     skips).
   - Or alternatively, modify a single character in a strokes.json
     file (deterministically; e.g., a comment-equivalent if the JSON
     schema supports it, or a no-op whitespace change). CI fires and
     passes (no drift introduced).

---

## Methodology-chapter content

G5 is the operational closure of Phase 2b Track B. The four operative
artifacts of Track B — G1 (drift gate on asymmetry), G3 (conformance
gate on perpendicular deviation), G4 (drift gate on junction kink),
plus G2's investigated-not-viable record — represent the gate
SET. G5 is the wiring that turns the set into a workflow-level
invariant on `main`.

The thesis chapter punchline for Phase 2b Track B is short:

> The shipped corpus (`Letters/Regular/`) is frozen against drift
> larger than the maintainer's hand-approved polish edits in the
> 2026-05-22 session corpus. Any PR producing larger drift on any
> letter's measurable property (asymmetry profile, perpendicular
> deviation on straight strokes, kink drift at end-to-end junctions)
> fails CI and is blocked from merge.

G2 is documented as the case where the methodology surfaced a
mismatched metric before threshold derivation — the negative result
is preserved as honest evidence that the design process surfaces what
the design got wrong as well as what it got right.

---

## Questions flagged during drafting

**Q-A: Should the JSON artifact be retained indefinitely or
rotated?** GitHub Actions default artifact retention is 90 days.
Acceptable for thesis-cycle work; longer retention could be enabled
via repo settings if needed. **Recommendation:** default 90 days;
defer to GitHub's settings if longer retention is wanted.

**Q-B: Should the workflow run on `push` to main as well as
`pull_request`?** Running on push would catch direct pushes that
bypass PR review (e.g., admin override). For a single-maintainer
thesis project, PR-only is sufficient. **Recommendation:**
pull_request only; revisit if multi-maintainer setup ever happens.

---

## Decisions summary

| Section | Decision | Notes |
|---|---|---|
| **G5.1** | One job, three sequential steps (G1 → G3 → G4) | Simpler than parallel; sufficient for thesis-scale |
| **G5.2** | Threshold defaults via GATE_METADATA per-gate field; `--threshold` argparse default = None | Replaces single global PRE_CALIBRATION_THRESHOLD constant |
| **G5.3** | Path filter: strokes.json + gate code + workflow itself | Skips pedagogical / doc-only PRs but catches gate-logic changes |
| **G5.4** | Reference = `origin/main` HEAD | Simpler than merge-base; revisit if main-rebase-frequency demands |
| **G5.5** | All letters on disk (all 59) | Cost negligible; catches accidental regressions in untouched letters |
| **G5.6** | G2 not invoked in CI | Preserved as scaffolding; revisit triggers documented in g2_design.md |
| **G5.7** | Workflow fails iff any run_gates.py invocation exits non-zero | Uses existing exit-code semantics; no extra workflow logic |
| **G5.8** | Stdout in logs + JSON artifact via `actions/upload-artifact` | Both for human review and for thesis-citation purposes |

---

## Hold

Awaiting David's approval / redlines. No code, no commits beyond
this docs commit until then.

Open questions for explicit yes/no:

1. **G5.1** Single job with sequential G1/G3/G4 steps (vs three
   parallel jobs)? **Y/N**
2. **G5.2** Threshold defaults via GATE_METADATA per-gate field
   (replacing PRE_CALIBRATION_THRESHOLD)? **Y/N**
3. **G5.3** Path filter to strokes.json + gate code + workflow
   itself? **Y/N**
4. **G5.4** Reference = `origin/main` HEAD (vs merge-base)? **Y/N**
5. **G5.5** All-letters scope (vs modified-letters-only)? **Y/N**
6. **G5.6** G2 skipped entirely in CI? **Y/N**
7. **G5.7** Exit-code semantics: workflow fails iff any gate fails
   (using existing `run_gates.py` exit code)? **Y/N**
8. **G5.8** JSON artifact via `actions/upload-artifact`? **Y/N**
9. **Q-A / Q-B (questions flagged during drafting)** — anything to
   redline on default 90-day artifact retention or
   pull_request-only triggering?
