"""G2 threshold calibration against the 2026-05-22 session-pair corpus.

Mirrors `calibrate_g1_threshold.py`, but measures turn-angle drift
instead of asymmetry drift. Reports `max(|turn_angle|)` per stroke as a
resample-validation diagnostic (per `g2_design.md` G2.2 redline):
N=100 is validated if max stays below ~π/4 throughout; values near
π/2 or π signal that the resample is undersampling sharp peaks.

Stdout: clean threshold value (for piping).
Stderr: full per-pair table + per-reason vacuous breakdown + summary stats.
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


def classify(pearson: float | None) -> str:
    if pearson is None:
        return "vacuous"
    if pearson >= 0.99:
        return "tight"
    if pearson >= 0.95:
        return "moderate"
    return "substantial"


def calibrate() -> int:
    if not CORPUS_DIR.is_dir():
        print(f"Corpus dir not found: {CORPUS_DIR}", file=sys.stderr)
        return 1
    letter_dirs = sorted(d for d in CORPUS_DIR.iterdir()
                          if d.is_dir() and d.name != "bundles")
    rows: list[dict] = []
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
        x_min, y_min, x_max, y_max = bbox
        bw = max(1, x_max - x_min)
        bh = max(1, y_max - y_min)

        n_pairs = min(len(round1), len(round2))
        for i in range(n_pairs):
            result = ai.gate_g2_per_stroke(round1[i], round2[i],
                                            bbox, threshold=1.0,
                                            min_turn_angle_std=0.0)
            # Side-channel: max(|angle|) for resample-validation diagnostic.
            # Mirrors gate_g2_per_stroke's internal resample+angle path.
            cand_std = ref_std = max_abs_cand = max_abs_ref = None
            if len(round1[i]) >= 2 and len(round2[i]) >= 2:
                cand_rs = ai._arc_length_resample(round1[i],
                                                    ai.G2_RESAMPLE_N)
                ref_rs = ai._arc_length_resample(round2[i],
                                                   ai.G2_RESAMPLE_N)
                cand_px = [(x_min + rx * bw, y_min + ry * bh)
                           for rx, ry in cand_rs]
                ref_px = [(x_min + rx * bw, y_min + ry * bh)
                          for rx, ry in ref_rs]
                cand_a = ai._turn_angle_per_point(cand_px)
                ref_a = ai._turn_angle_per_point(ref_px)
                paired = [(a, b) for (a, ok_a), (b, ok_b)
                          in zip(cand_a, ref_a) if ok_a and ok_b]
                if len(paired) >= ai.G2_MIN_MEASURED:
                    arr = np.array(paired)
                    cand_std = float(arr[:, 0].std())
                    ref_std = float(arr[:, 1].std())
                    max_abs_cand = float(np.max(np.abs(arr[:, 0])))
                    max_abs_ref = float(np.max(np.abs(arr[:, 1])))
            rows.append({
                "letter": letter,
                "stroke": i,
                "pearson": result["pearson"],
                "n_measured": result["n_measured"],
                "reason": result.get("reason"),
                "n_cp_round1": result["n_cp_candidate"],
                "n_cp_round2": result["n_cp_reference"],
                "cand_std": cand_std,
                "ref_std": ref_std,
                "max_abs_cand": max_abs_cand,
                "max_abs_ref": max_abs_ref,
                "edit_count": edit_count,
                "session_path": session_path.name,
            })
        if len(round1) != len(round2):
            print(f"  note: {letter} stroke count "
                  f"r1={len(round1)} r2={len(round2)} "
                  f"(comparing first {n_pairs} only)",
                  file=sys.stderr)

    # Per-pair table.
    print(f"\nG2 calibration corpus: {len(letter_dirs)} letters\n",
          file=sys.stderr)
    print(f"{'Letter':6s} {'Str':>3s} {'Pearson':>8s} "
          f"{'cand_std':>9s} {'ref_std':>9s} "
          f"{'max|c|':>7s} {'max|r|':>7s} "
          f"{'edits':>6s}  {'Class':<12s} Note", file=sys.stderr)
    print("-" * 100, file=sys.stderr)
    real_pearsons_with_id: list[tuple[float, str, int]] = []
    vacuous_by_reason: Counter[str] = Counter()
    for r in rows:
        pearson_str = (f"{r['pearson']:.4f}" if r["pearson"] is not None
                       else "—")
        cand_std_str = (f"{r['cand_std']:.4f}" if r["cand_std"] is not None
                        else "—")
        ref_std_str = (f"{r['ref_std']:.4f}" if r["ref_std"] is not None
                       else "—")
        max_c_str = (f"{r['max_abs_cand']:.3f}" if r["max_abs_cand"] is not None
                     else "—")
        max_r_str = (f"{r['max_abs_ref']:.3f}" if r["max_abs_ref"] is not None
                     else "—")
        cls = classify(r["pearson"])
        reason = r["reason"] or ""
        print(f"{r['letter']:6s} {r['stroke']:>3d} {pearson_str:>8s} "
              f"{cand_std_str:>9s} {ref_std_str:>9s} "
              f"{max_c_str:>7s} {max_r_str:>7s} "
              f"{r['edit_count']:>6d}  {cls:<12s} {reason}",
              file=sys.stderr)
        if r["pearson"] is not None:
            real_pearsons_with_id.append(
                (r["pearson"], r["letter"], r["stroke"]))
        else:
            vacuous_by_reason[r["reason"] or "unknown"] += 1
    if skipped:
        print(file=sys.stderr)
        for letter, reason in skipped:
            print(f"skipped {letter}: {reason}", file=sys.stderr)

    real_pearsons = sorted(p for p, _, _ in real_pearsons_with_id)
    vacuous_total = sum(vacuous_by_reason.values())
    print(f"\nReal Pearson values: {len(real_pearsons)} "
          f"(vacuous: {vacuous_total} total)", file=sys.stderr)
    for reason, count in sorted(vacuous_by_reason.items()):
        print(f"  {reason}: {count}", file=sys.stderr)

    if not real_pearsons:
        print("\nNo real Pearson values; cannot derive threshold.",
              file=sys.stderr)
        return 1

    real_pearsons_with_id.sort()
    min_v = real_pearsons_with_id[0][0]
    min_label = (f"{real_pearsons_with_id[0][1]} stroke "
                 f"{real_pearsons_with_id[0][2]}")
    max_v = real_pearsons_with_id[-1][0]
    max_label = (f"{real_pearsons_with_id[-1][1]} stroke "
                 f"{real_pearsons_with_id[-1][2]}")
    median_v = statistics.median(real_pearsons)

    # Resample-validation diagnostic.
    max_angles_all = [r["max_abs_cand"] for r in rows
                      if r["max_abs_cand"] is not None] + \
                     [r["max_abs_ref"] for r in rows
                      if r["max_abs_ref"] is not None]
    if max_angles_all:
        max_max_angle = max(max_angles_all)
        print(f"\nResample-validation diagnostic:", file=sys.stderr)
        print(f"  max(|turn_angle|) across all strokes: "
              f"{max_max_angle:.3f} rad ({math.degrees(max_max_angle):.1f}°)",
              file=sys.stderr)
        if max_max_angle < math.pi / 4:
            print(f"  ✓ Below π/4 (45°) → N={ai.G2_RESAMPLE_N} validated",
                  file=sys.stderr)
        elif max_max_angle < math.pi / 2:
            print(f"  ⚠ Above π/4 but below π/2 → N may be marginal",
                  file=sys.stderr)
        else:
            print(f"  ✗ Near π/2 or above → N={ai.G2_RESAMPLE_N} "
                  f"likely undersampling; investigate", file=sys.stderr)

    print(f"\nReal Pearson summary:", file=sys.stderr)
    print(f"  min:    {min_v:.4f}  ({min_label})", file=sys.stderr)
    print(f"  median: {median_v:.4f}", file=sys.stderr)
    print(f"  max:    {max_v:.4f}  ({max_label})", file=sys.stderr)
    print(f"\nDerived threshold (= min): {min_v:.4f}", file=sys.stderr)

    print(f"{min_v:.4f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(calibrate())
