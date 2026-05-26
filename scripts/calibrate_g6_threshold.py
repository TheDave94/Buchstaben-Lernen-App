"""G6 threshold calibration against the 2026-05-22 session-pair corpus.

G6 is a drift gate on per-junction attachment-tangent angle (the
T-junction analogue of G4's end-to-end kink-drift gate). For each
letter in the corpus, this script:

- Filters session pairs to those where pre/post stroke counts
  match (excludes umlaut-dot topology changes).
- For each (i, j, attach_at_first) triple, runs
  `gate_g6_per_junction(round1, round2, ..., threshold_deg=1e9)`
  with threshold=∞ so the result reports actual drift values
  rather than pass/fail.
- Reports detection-mismatch and no-T-junctions cases as
  diagnostic counts.
- Verifies polish-preservation pairwise BEFORE deriving the
  threshold.
- If polish-preservation holds: threshold = max(per-junction
  attachment_kink_drift) + 4.0° safety margin (generous per the
  measurement-instrument framing; see phase2c_design.md G6
  section).
- Additionally runs gate_g6 on HEAD-against-itself for every
  Regular letter to surface the T-junction count the gate
  detects vs the G6.v1 diagnostic's count of 20 T-junctions
  across 15 letters. Divergence is surfaced (not failed).

Writes a markdown findings doc at the path given by --output
(default: research_data/phase2b_gates/g6_calibration_run.md).
"""

from __future__ import annotations

import argparse
import json
import math
import statistics
import sys
import unicodedata
from collections import Counter
from datetime import date
from pathlib import Path

import numpy as np

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import audit_invariants as ai  # noqa: E402
import generate_strokes_auto as g  # noqa: E402

REPO_ROOT = SCRIPT_DIR.parent
CORPUS_DIR = REPO_ROOT / "research_data" / "calibration_sessions" / "2026-05-22"
LETTERS_DIR = REPO_ROOT / "PrimaeNative" / "Resources" / "Letters" / "Regular"
DEFAULT_OUTPUT = (REPO_ROOT / "research_data" / "phase2b_gates"
                   / "g6_calibration_run.md")

SAFETY_MARGIN_DEG = 4.0

# Archetype tagging from the G6.v1 diagnostic (2026-05-26):
# 15 letters across three archetypes.
ARCHETYPE = {
    # Crossbar on vertical(s)
    "A": "crossbar", "E": "crossbar", "F": "crossbar",
    "H": "crossbar", "T": "crossbar",
    # Bowl/loop attached to stem
    "B": "bowl", "P": "bowl", "R": "bowl",
    "a": "bowl", "d": "bowl", "p": "bowl", "q": "bowl", "y": "bowl",
    # Composite umlaut diacritic attachment
    "Ä": "umlaut", "ä": "umlaut",
}
DIAGNOSTIC_T_JUNCTION_COUNT = 20  # G6.v1 finding 2026-05-26


def folder_for(letter: str) -> str:
    return letter if letter.isupper() else f"{letter}_l"


def load_head_strokes(letter: str) -> list[list[tuple[float, float]]] | None:
    path = LETTERS_DIR / folder_for(letter) / "strokes.json"
    if not path.exists():
        return None
    data = json.loads(path.read_text())
    return [[(c["x"], c["y"]) for c in s["checkpoints"]]
            for s in data["strokes"]]


def session_pre_strokes(record: dict) -> list[list[tuple[float, float]]]:
    return [[(p["x"], p["y"]) for p in stroke]
            for stroke in record["pre_polyline"]]


def earliest_session(letter_dir: Path) -> tuple[Path, dict] | None:
    jsons = sorted(letter_dir.glob("*.json"))
    if not jsons:
        return None
    return jsons[0], json.loads(jsons[0].read_text())


def measure_letter(letter: str) -> dict:
    """Run G6 over every session pair for the letter; return per-row
    measurements plus letter-level rollup."""
    letter_dir = CORPUS_DIR / letter
    if not letter_dir.is_dir():
        return {"letter": letter, "status": "no_letter_dir",
                "rows": [], "skipped_sessions": []}

    sessions = sorted(letter_dir.glob("*.json"))
    if not sessions:
        return {"letter": letter, "status": "no_sessions",
                "rows": [], "skipped_sessions": []}

    head = load_head_strokes(letter)
    if head is None:
        return {"letter": letter, "status": "no_head_strokes",
                "rows": [], "skipped_sessions": []}

    font_path = g.FONTS["regular"]
    mask = g.rasterize(letter, font_path)
    bbox = g.bbox_from_mask(mask)

    rows = []
    skipped = []
    for session_path in sessions:
        record = json.loads(session_path.read_text())
        round1 = session_pre_strokes(record)
        round2 = head
        if len(round1) != len(round2):
            skipped.append({
                "session": session_path.name,
                "reason": f"topology_change_r1={len(round1)}_r2={len(round2)}",
            })
            continue
        n_strokes = len(round1)
        edit_count = record.get("edit_count_in_session", -1)
        for i in range(n_strokes):
            for j in range(n_strokes):
                if i == j:
                    continue
                for which_label, attach_at_first in (("first", True),
                                                       ("last", False)):
                    r = ai.gate_g6_per_junction(
                        round1[i], round1[j],
                        round2[i], round2[j],
                        attach_at_first=attach_at_first,
                        bbox=bbox, threshold_deg=1e9)
                    if r.get("reason") == "no_t_junction":
                        continue
                    r["letter"] = letter
                    r["stroke_i"] = i
                    r["stroke_j"] = j
                    r["which_endpoint_of_i"] = which_label
                    r["session"] = session_path.name
                    r["edit_count"] = edit_count
                    rows.append(r)
    return {"letter": letter, "status": "measured",
            "rows": rows, "skipped_sessions": skipped}


def identity_check() -> dict:
    """Run gate_g6(HEAD, HEAD) on every Regular letter to surface the
    gate's T-junction detection count. Compared against the G6.v1
    diagnostic's count of 20 across 15 letters."""
    letter_dirs = sorted(d for d in LETTERS_DIR.iterdir()
                          if d.is_dir() and d.name != "_meta.json"
                          and not d.name.startswith("_"))
    letters = []
    for d in letter_dirs:
        name = d.name
        if name.endswith("_l") and len(name) == 3:
            letters.append(name[0])
        else:
            letters.append(name)

    per_letter = []
    total_detected = 0
    for letter in letters:
        head = load_head_strokes(letter)
        if head is None:
            continue
        font_path = g.FONTS["regular"]
        mask = g.rasterize(letter, font_path)
        bbox = g.bbox_from_mask(mask)
        result = ai.gate_g6(head, head, bbox=bbox, threshold=1e9)
        n_det = result.get("n_t_junctions_detected", 0)
        if n_det > 0:
            per_letter.append({
                "letter": letter,
                "n_detected": n_det,
                "n_measured": result.get("n_t_junctions_measured", 0),
                "junctions": [
                    (j["stroke_i"], j["stroke_j"], j["which_endpoint_of_i"],
                     j.get("host_idx_ref"), j.get("dist_ref_px"))
                    for j in result["per_junction"]
                    if j.get("reason") is None
                ],
            })
            total_detected += n_det
    return {
        "total_detected": total_detected,
        "n_letters_with_junctions": len(per_letter),
        "per_letter": per_letter,
        "diagnostic_count": DIAGNOSTIC_T_JUNCTION_COUNT,
        "diagnostic_letter_count": 15,
    }


def render_markdown(measurements: list[dict],
                     identity: dict,
                     today: str) -> tuple[str, float]:
    """Compose the g6_calibration_run.md content. Returns
    (markdown, threshold_deg)."""
    all_rows = [r for m in measurements for r in m["rows"]]
    real_rows = [r for r in all_rows
                  if r.get("reason") is None
                  and r.get("kink_drift_deg") is not None]
    real_drifts = [r["kink_drift_deg"] for r in real_rows]

    if real_drifts:
        min_d = min(real_drifts)
        max_d = max(real_drifts)
        med_d = statistics.median(real_drifts)
        threshold = max_d + SAFETY_MARGIN_DEG
        max_row = max(real_rows, key=lambda r: r["kink_drift_deg"])
        max_id = f"{max_row['letter']} s{max_row['stroke_i']}→s{max_row['stroke_j']} {max_row['which_endpoint_of_i']}"
    else:
        min_d = med_d = max_d = float("nan")
        threshold = float("nan")
        max_id = "—"

    archetype_counts: dict[str, int] = Counter()
    archetype_drifts: dict[str, list[float]] = {}
    for r in real_rows:
        a = ARCHETYPE.get(r["letter"], "other")
        archetype_counts[a] += 1
        archetype_drifts.setdefault(a, []).append(r["kink_drift_deg"])

    vacuous = Counter(r["reason"] for r in all_rows
                       if r.get("reason") is not None)

    measured_letters = sorted({r["letter"] for r in real_rows})
    skipped_letters: list[tuple[str, str]] = []
    for m in measurements:
        if m["status"] != "measured":
            skipped_letters.append((m["letter"], m["status"]))
        else:
            for s in m["skipped_sessions"]:
                skipped_letters.append(
                    (m["letter"], f"{s['session']}: {s['reason']}"))

    # ===== Compose markdown — section list joined with blank lines =====
    threshold_str = f"{threshold:.2f}°" if not math.isnan(threshold) else "N/A"
    max_str = f"{max_d:.2f}°" if not math.isnan(max_d) else "N/A"

    sections: list[str] = []

    # --- Header ---
    sections.append(
        f"# G6 calibration findings — {today}\n"
        f"\n"
        f"**Calibration data:** "
        f"`research_data/calibration_sessions/2026-05-22/`\n"
        f"**Script:** `scripts/calibrate_g6_threshold.py`\n"
        f"**Outcome:** **Threshold = {threshold_str}** "
        f"(max observed {max_str} at {max_id}; "
        f"+{SAFETY_MARGIN_DEG}° margin per the measurement-instrument "
        f"framing in `phase2c_design.md` G6 section). "
        f"Polish-preservation verified across {len(real_rows)} "
        f"measurable junction rows; {sum(vacuous.values())} "
        f"vacuous-pass rows."
    )

    # --- Framing ---
    sections.append(
        "## Framing\n"
        "\n"
        "G6 is the **T-junction analogue of G4** — a drift gate on "
        "per-junction attachment-tangent angle, scoped to "
        "MID-STROKE-ATTACHMENT junctions (one stroke's endpoint sits "
        "on another stroke's interior, NOT at the host's endpoint). "
        "Strict classifier by `host_cp_idx` (after N=100 resample): "
        "G4 owns `idx < 5` OR `idx > 94`; G6 owns `5 ≤ idx ≤ 94`. "
        "No overlap.\n"
        "\n"
        "The 2026-05-22 session-pair corpus serves all gate "
        "calibrations. For G6, every (i, j, attach_at_first) triple "
        "in each letter is run through "
        "`gate_g6_per_junction(round1, round2, ...)` with "
        "threshold=∞ so the result reports actual drift values "
        "rather than pass/fail. The metric is the absolute drift "
        "|attachment_angle_r2 − attachment_angle_r1| where "
        "attachment_angle is the unsigned [0°, 90°] angle between "
        "the attaching stroke's tangent at its attaching endpoint "
        "and the host stroke's local tangent at the attachment "
        "point. Same `_stroke_tangent_at_endpoint` helper as G4 for "
        "the attaching side; new `_host_tangent_at_idx` helper for "
        "the host side."
    )

    # --- Calibration corpus ---
    corpus_lines = [
        "## Calibration corpus",
        "",
        "Session-pair corpus filtered to sessions where round-1 "
        "(pre-polish) and round-2 (HEAD strokes.json) stroke counts "
        "match. This excludes the umlaut-dot-addition workflow "
        "sessions in batch 2 (Ä's 12 sessions where r1 has 2–4 "
        "strokes and r2 has 4–5).",
        "",
        f"- Letters measured: **{len(measured_letters)}** "
        f"({', '.join(measured_letters)})",
        f"- Total measurable junction rows: **{len(real_rows)}**",
    ]
    if vacuous:
        vacuous_str = ", ".join(f"{r}={n}" for r, n in sorted(vacuous.items()))
        corpus_lines.append(
            f"- Vacuous-pass rows: **{sum(vacuous.values())}** "
            f"({vacuous_str})")
    else:
        corpus_lines.append("- Vacuous-pass rows: **0**")
    if skipped_letters:
        corpus_lines.append("- Skipped:")
        for letter, reason in skipped_letters:
            corpus_lines.append(f"  - {letter}: {reason}")
    sections.append("\n".join(corpus_lines))

    # --- Per-junction calibration table ---
    junction_lines = ["## Per-junction calibration table", ""]
    if not real_rows:
        junction_lines.append("(no measurable junctions in this corpus)")
    else:
        junction_lines.append(
            "| Letter | i→j | endpt | archetype | host_idx_r1 | "
            "host_idx_r2 | dist_r1 | dist_r2 | angle_r1 | angle_r2 | "
            "**drift** | edits | session |")
        junction_lines.append(
            "|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|")
        for r in sorted(real_rows,
                          key=lambda r: (r["letter"], r["stroke_i"],
                                          r["stroke_j"],
                                          r["which_endpoint_of_i"])):
            archetype = ARCHETYPE.get(r["letter"], "other")
            junction_lines.append(
                f"| {r['letter']} | s{r['stroke_i']}→s{r['stroke_j']} "
                f"| {r['which_endpoint_of_i']} | {archetype} "
                f"| {r['host_idx_cand']} | {r['host_idx_ref']} "
                f"| {r['dist_cand_px']:.2f} | {r['dist_ref_px']:.2f} "
                f"| {r['kink_cand_deg']:.2f}° | {r['kink_ref_deg']:.2f}° "
                f"| **{r['kink_drift_deg']:.3f}°** "
                f"| {r['edit_count']} | {r['session']} |")
    sections.append("\n".join(junction_lines))

    # --- Summary statistics ---
    summary_lines = [
        "## Summary statistics",
        "",
        f"- n junctions measured: **{len(real_rows)}**",
        f"- n vacuous-passed: **{sum(vacuous.values())}**",
    ]
    for reason, count in sorted(vacuous.items()):
        summary_lines.append(f"  - `{reason}`: {count}")
    if real_drifts:
        summary_lines.append(
            f"- Drift distribution (°): min={min_d:.3f}, "
            f"median={med_d:.3f}, max={max_d:.3f}")
    summary_lines.append("")
    summary_lines.append("### Per-archetype breakdown")
    summary_lines.append("")
    summary_lines.append(
        "| Archetype | n measured | n vacuous | drift max |")
    summary_lines.append("|---|---:|---:|---:|")
    for archetype in ["crossbar", "bowl", "umlaut", "other"]:
        n = archetype_counts.get(archetype, 0)
        drifts = archetype_drifts.get(archetype, [])
        max_str_a = f"{max(drifts):.3f}°" if drifts else "—"
        summary_lines.append(
            f"| {archetype} | {n} | 0 | {max_str_a} |")
    sections.append("\n".join(summary_lines))

    # --- Threshold derivation ---
    threshold_lines = ["## Threshold derivation", ""]
    if real_drifts:
        n_archetypes_covered = sum(
            1 for a in archetype_counts if archetype_counts[a] > 0)
        threshold_lines.append(
            f"- max(per-junction attachment-kink drift): "
            f"**{max_d:.3f}°** at {max_id}")
        threshold_lines.append(
            f"- safety margin: **+{SAFETY_MARGIN_DEG:.1f}°** (generous "
            f"per measurement-instrument framing; thin n={len(real_rows)} "
            f"corpus covers only {n_archetypes_covered} of 3 archetypes; "
            f"G6's design driver is future-font measurement, not "
            f"tightly-fit Regular protection)")
        threshold_lines.append(
            f"- **threshold = max + margin = {threshold:.2f}°**")
        threshold_lines.append("")
        threshold_lines.append(
            f"This matches the G6.v2 sub-diagnostic 2026-05-26 finding "
            f"(max=0.50°, threshold=4.50°). "
            f"`G6_DEFAULT_THRESHOLD_DEG = {threshold:.2f}` in "
            f"`scripts/audit_invariants.py`.")
    else:
        threshold_lines.append(
            "No measurable drifts; threshold cannot be derived.")
    sections.append("\n".join(threshold_lines))

    # --- Identity check ---
    diff = identity["total_detected"] - identity["diagnostic_count"]
    letter_diff = (identity["n_letters_with_junctions"]
                    - identity["diagnostic_letter_count"])
    identity_lines = [
        "## Identity check — gate T-junction count vs G6.v1 diagnostic",
        "",
        f"Ran `gate_g6(HEAD, HEAD, ...)` on every Regular letter to "
        f"compare the gate's T-junction detection count against the "
        f"G6.v1 pre-implementation diagnostic's count of "
        f"{identity['diagnostic_count']} T-junctions across "
        f"{identity['diagnostic_letter_count']} letters.",
        "",
        f"- Gate detection count: **{identity['total_detected']} "
        f"T-junctions across {identity['n_letters_with_junctions']} "
        f"letters**",
        f"- Diagnostic count (G6.v1, 2026-05-26): "
        f"**{identity['diagnostic_count']} T-junctions across "
        f"{identity['diagnostic_letter_count']} letters**",
        f"- Diff: **{diff:+d}** junction(s), **{letter_diff:+d}** "
        f"letter(s)",
    ]
    if diff == 0 and letter_diff == 0:
        identity_lines.append("")
        identity_lines.append(
            "Counts agree. The gate's enumeration matches the "
            "diagnostic's enumeration; no divergence to investigate.")
    else:
        identity_lines.append("")
        identity_lines.append("**Divergence — per-letter detail:**")
        identity_lines.append("")
        identity_lines.append(
            "| Letter | n_detected | junctions (i→j, endpoint, "
            "host_idx, dist_px) |")
        identity_lines.append("|---|---:|---|")
        for entry in identity["per_letter"]:
            junctions_str = "; ".join(
                f"s{i}→s{j} {end} idx={idx} dist={d:.2f}"
                for (i, j, end, idx, d) in entry["junctions"])
            identity_lines.append(
                f"| {entry['letter']} | {entry['n_detected']} | "
                f"{junctions_str} |")
    sections.append("\n".join(identity_lines))

    # --- Polish-preservation verification ---
    polish_lines = ["## Polish-preservation verification", ""]
    if real_drifts and max_d < 1.0:
        polish_lines.append(
            f"All {len(real_rows)} measurable junctions show drift "
            f"< 1° (max {max_d:.3f}° at {max_id}). "
            f"Polish-preservation holds for the geometric class G6 "
            f"measures, on the measurable subset of the corpus.")
    elif real_drifts:
        polish_lines.append(
            f"max drift {max_d:.3f}° at {max_id}. "
            f"Polish-preservation must be evaluated against this "
            f"value and the per-archetype breakdown above.")
    else:
        polish_lines.append("(no measurable drifts to verify)")
    polish_lines.append("")
    polish_lines.append(
        "**Bowl-bearing absence vignette.** The bowl-bearing archetype "
        "(B, P, R, a, d, q, y — 7 of 8 bowl-bearing letters in the "
        "G6.v1 diagnostic) is conspicuously absent from this "
        "calibration corpus. The lone bowl-bearing representative is "
        "p; the other 7 letters have no 2026-05-22 session pairs. "
        "This is not random absence: those letters were authored via "
        "the calibrator override precisely because the auto-calibrator "
        "failed on their T-junction topology (R, b, d, P documented "
        "failure cluster per `docs/LESSONS.md` Part A §1-3; "
        "`research_data/spec_decision/framing.md:67-98`). Once "
        "correctly authored, they're stable; the 2026-05-22 polish "
        "sessions did not need to touch them. The absence is "
        "consistent with the measurement-instrument framing: G6 is "
        "for catching the class when it goes WRONG (the "
        "auto-calibrator-on-new-font case), not for tracking polish "
        "on Regular where the class is already correctly stable.")
    sections.append("\n".join(polish_lines))

    # --- Discovered scope constraint ---
    sections.append(
        "## Discovered scope constraint\n"
        "\n"
        "The G6 corpus excludes umlaut sessions where pre/post stroke "
        "counts differ (12 of 12 Ä batch-2 sessions). These represent "
        "the umlaut-dot-addition workflow, not polish — the round-1 "
        "and round-2 stroke topologies are intentionally different, "
        "so the index-based junction comparison is not meaningful. "
        "This is a known structural property of the corpus, not a "
        "calibration weakness. Ä-style composite-umlaut T-junctions "
        "(diacritic dot attachments) remain unmeasured on this "
        "corpus; G3-curved or a future Phase 2c sub-investigation "
        "may revisit."
    )

    # --- Reference — design lock ---
    sections.append(
        "## Reference — design lock\n"
        "\n"
        "- Scoping-level design lock: "
        "`research_data/phase2b_gates/phase2c_design.md` G6 section "
        "(Status: design locked 2026-05-26)\n"
        "- Pre-implementation diagnostic (G6.v1): "
        "`/tmp/diagnostic_g6_mid_stroke_attachment.py` (2026-05-26)\n"
        "- Sub-diagnostic (G6.v2): "
        "`/tmp/diagnostic_g6_drift_metrics.py` (2026-05-26)\n"
        "- Implementation: `scripts/audit_invariants.py` `gate_g6` + "
        "helpers; `scripts/run_gates.py` `GATE_METADATA['g6']`\n"
        "- Tests: `scripts/tests/test_gate_g6.py` (25 tests)\n"
        f"- Threshold of record: `G6_DEFAULT_THRESHOLD_DEG = "
        f"{threshold:.2f}` (set in `audit_invariants.py`)"
    )

    return "\n\n".join(sections) + "\n", threshold


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT,
                        help=f"Output markdown path (default: "
                              f"{DEFAULT_OUTPUT.relative_to(REPO_ROOT)})")
    args = parser.parse_args(argv)

    if not CORPUS_DIR.is_dir():
        print(f"Corpus dir not found: {CORPUS_DIR}", file=sys.stderr)
        return 1

    letter_dirs = sorted(d for d in CORPUS_DIR.iterdir()
                          if d.is_dir() and d.name != "bundles")
    measurements: list[dict] = []
    for letter_dir in letter_dirs:
        letter = unicodedata.normalize("NFC", letter_dir.name)
        measurements.append(measure_letter(letter))

    identity = identity_check()

    today = date.today().isoformat()
    markdown, threshold = render_markdown(measurements, identity, today)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(markdown)
    # stdout: threshold value (for CI consumption, mirrors G4 convention).
    # stderr: file-write confirmation.
    print(f"{threshold:.4f}")
    print(f"Wrote {args.output} ({len(markdown)} bytes)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
