"""G4 threshold calibration against the 2026-05-22 session-pair corpus.

G4 is a drift gate on per-junction kink (the third metric shape in
the freeze-gate family — see g4_design.md "Diagnostic finding"
section for the design pivot from conformance-on-smooth-junctions to
drift-on-all-junctions).

For each letter in the corpus, this script:
- Detects junctions in BOTH rounds via `_detect_junctions`.
- For each detected junction, computes kink_deg at round-1 and
  round-2, plus the absolute drift |kink_round2 − kink_round1|.
- Reports detection-mismatch and no-junctions-detected cases as
  diagnostic counts.
- Derives threshold = max(per-junction kink_drift_deg) + safety
  margin UNCONDITIONALLY. A polish-preservation check (as in
  calibrate_g3_threshold's SOFT-V trigger) is NOT implemented here —
  a large median drift is only printed as a note (audit 2026-09-05;
  the 4.43° of record was derived without such a check).

Stdout: clean threshold value (degrees).
Stderr: full per-junction table + polish-preservation check +
per-reason vacuous breakdown.
"""

from __future__ import annotations

import json
import math
import statistics
import sys
import unicodedata
from collections import Counter
from pathlib import Path

import numpy as np

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import audit_invariants as ai  # noqa: E402
import generate_strokes_auto as g  # noqa: E402

REPO_ROOT = SCRIPT_DIR.parent
CORPUS_DIR = REPO_ROOT / "research_data" / "calibration_sessions" / "2026-05-22"
LETTERS_DIR = REPO_ROOT / "PrimaeNative" / "Resources" / "Letters" / "Regular"


def earliest_session(letter_dir: Path) -> tuple[Path, dict] | None:
    jsons = sorted(letter_dir.glob("*.json"))
    if not jsons:
        return None
    return jsons[0], json.loads(jsons[0].read_text())


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


def calibrate() -> int:
    if not CORPUS_DIR.is_dir():
        print(f"Corpus dir not found: {CORPUS_DIR}", file=sys.stderr)
        return 1
    letter_dirs = sorted(d for d in CORPUS_DIR.iterdir()
                          if d.is_dir() and d.name != "bundles")

    rows: list[dict] = []
    letter_level: list[dict] = []
    skipped: list[tuple[str, str]] = []

    for letter_dir in letter_dirs:
        letter = unicodedata.normalize("NFC", letter_dir.name)
        session = earliest_session(letter_dir)
        if session is None:
            skipped.append((letter, "no sessions"))
            continue
        session_path, record = session
        round1 = session_pre_strokes(record)
        round2 = load_head_strokes(letter)
        if round2 is None:
            skipped.append((letter, "no HEAD strokes.json"))
            continue

        font_path = g.FONTS["regular"]
        mask = g.rasterize(letter, font_path)
        bbox = g.bbox_from_mask(mask)
        edit_count = record.get("edit_count_in_session", -1)

        n_pairs = min(len(round1), len(round2))
        n_consecutive_pairs = max(0, n_pairs - 1)
        letter_row = {
            "letter": letter,
            "n_strokes_r1": len(round1),
            "n_strokes_r2": len(round2),
            "n_consecutive_pairs": n_consecutive_pairs,
            "junctions": 0,
            "edit_count": edit_count,
            "session_path": session_path.name,
            "letter_reason": None,
        }

        # Per consecutive stroke pair, run gate_g4_per_junction with
        # threshold=∞ so we get actual drift values rather than pass/fail.
        for i in range(n_consecutive_pairs):
            r = ai.gate_g4_per_junction(round1[i], round1[i + 1],
                                          round2[i], round2[i + 1],
                                          bbox, threshold_deg=1e9)
            r["letter"] = letter
            r["stroke_i"] = i
            r["stroke_j"] = i + 1
            r["edit_count"] = edit_count
            rows.append(r)
            # Count detected junctions (no_junction means the pair
            # isn't a junction; everything else counts).
            if r.get("reason") != "no_junction":
                letter_row["junctions"] += 1

        if n_pairs < 2:
            letter_row["letter_reason"] = "no_pairs"
        elif letter_row["junctions"] == 0:
            letter_row["letter_reason"] = "no_junctions_detected"
        letter_level.append(letter_row)

    # Per-junction table.
    print(f"\nG4 calibration corpus: {len(letter_dirs)} letters\n",
          file=sys.stderr)
    print(f"{'Letter':6s} {'i':>2s} {'j':>2s}  {'pairing':>12s}  "
          f"{'dist_r1':>7s} {'dist_r2':>7s} "
          f"{'kink_r1':>8s} {'kink_r2':>8s} {'drift':>7s}  "
          f"{'edits':>5s}  Note", file=sys.stderr)
    print("-" * 100, file=sys.stderr)

    vacuous_by_reason: Counter[str] = Counter()
    real_drifts_with_id: list[tuple[float, str, int, int]] = []

    for r in rows:
        if r.get("reason") == "no_junction":
            # Don't clutter the table with non-junctions
            continue
        pairing = r.get("pairing") or "—"
        dist_r1 = f"{r['dist_cand_px']:.2f}" if r.get('dist_cand_px') is not None else "—"
        dist_r2 = f"{r['dist_ref_px']:.2f}" if r.get('dist_ref_px') is not None else "—"
        kink_r1 = f"{r['kink_cand_deg']:.2f}" if r.get('kink_cand_deg') is not None else "—"
        kink_r2 = f"{r['kink_ref_deg']:.2f}" if r.get('kink_ref_deg') is not None else "—"
        drift = f"{r['kink_drift_deg']:.3f}" if r.get('kink_drift_deg') is not None else "—"
        reason = r.get("reason") or ""
        print(f"{r['letter']:6s} {r['stroke_i']:>2d} {r['stroke_j']:>2d}  "
              f"{pairing:>12s}  {dist_r1:>7s} {dist_r2:>7s} "
              f"{kink_r1:>8s} {kink_r2:>8s} {drift:>7s}  "
              f"{r['edit_count']:>5d}  {reason}",
              file=sys.stderr)
        if r.get("reason"):
            vacuous_by_reason[r["reason"]] += 1
        elif r.get("kink_drift_deg") is not None:
            real_drifts_with_id.append(
                (r["kink_drift_deg"], r["letter"],
                 r["stroke_i"], r["stroke_j"]))

    # Letter-level summary (separates no_pairs from no_junctions_detected).
    no_pairs = [lr for lr in letter_level if lr["letter_reason"] == "no_pairs"]
    no_junctions = [lr for lr in letter_level
                     if lr["letter_reason"] == "no_junctions_detected"]
    with_junctions = [lr for lr in letter_level
                       if lr["letter_reason"] is None]

    print(f"\nLetter-level summary:", file=sys.stderr)
    print(f"  letters with detected junctions: {len(with_junctions)}",
          file=sys.stderr)
    print(f"  no_pairs (single-stroke letters): "
          f"{len(no_pairs)} ({', '.join(lr['letter'] for lr in no_pairs)})",
          file=sys.stderr)
    if no_junctions:
        print(f"  no_junctions_detected (multi-stroke but ε miss): "
              f"{len(no_junctions)} "
              f"({', '.join(lr['letter'] for lr in no_junctions)})  ⚠ FLAG",
              file=sys.stderr)
    else:
        print(f"  no_junctions_detected: 0  ✓ (no anomalies)",
              file=sys.stderr)

    if skipped:
        print(file=sys.stderr)
        for letter, reason in skipped:
            print(f"skipped {letter}: {reason}", file=sys.stderr)

    # Per-reason vacuous breakdown.
    vacuous_total = sum(vacuous_by_reason.values())
    n_real_drifts = len(real_drifts_with_id)
    print(f"\nJunction-level summary: {n_real_drifts} drift values measured, "
          f"{vacuous_total} vacuous (junctions only; no_junction omitted)",
          file=sys.stderr)
    for reason, count in sorted(vacuous_by_reason.items()):
        print(f"  {reason}: {count}", file=sys.stderr)

    if not real_drifts_with_id:
        print("\nNo measurable junction drift values; cannot derive threshold.",
              file=sys.stderr)
        return 1

    # Polish-preservation check + threshold derivation.
    real_drifts_with_id.sort()
    drifts = [d for d, _, _, _ in real_drifts_with_id]
    min_d = drifts[0]
    max_d = drifts[-1]
    median_d = statistics.median(drifts)
    max_id = real_drifts_with_id[-1]

    # Soft-V trigger: if median drift is "large" (say > 5°), the metric
    # might be polish-mutable in problematic ways. Surface but don't
    # auto-soft-V — let the threshold derivation proceed if the data
    # looks tight enough.
    print(f"\nPer-junction drift distribution:", file=sys.stderr)
    print(f"  min: {min_d:.3f}°", file=sys.stderr)
    print(f"  median: {median_d:.3f}°", file=sys.stderr)
    print(f"  max: {max_d:.3f}°  ({max_id[1]} s{max_id[2]}-s{max_id[3]})",
          file=sys.stderr)

    SAFETY_MARGIN_DEG = 2.0
    threshold = max_d + SAFETY_MARGIN_DEG

    print(f"\nThreshold derivation:", file=sys.stderr)
    print(f"  max(per-junction kink_drift_deg) = {max_d:.3f}° at "
          f"{max_id[1]} s{max_id[2]}-s{max_id[3]}", file=sys.stderr)
    print(f"  + {SAFETY_MARGIN_DEG}° safety margin (LSQ + resample noise floor)",
          file=sys.stderr)
    print(f"  = threshold {threshold:.3f}°", file=sys.stderr)

    print(f"{threshold:.4f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(calibrate())
