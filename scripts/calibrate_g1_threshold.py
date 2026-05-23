"""G1 threshold calibration against the 2026-05-22 session-pair corpus.

Framing (per David's confirmation 2026-05-23): G1 is a FREEZE GATE
against the hand-calibrated Regular corpus. The bake pipeline is
retired for Regular (6a85811c); HEAD strokes.json is the canonical
reference. A future PR producing drift larger than David's previously-
approved polish edits should fail G1 and require manual review.

The 13-letter session-pair corpus from 2026-05-22 supplies the
calibration data. For each letter:

  round-1 polyline = pre_polyline of earliest session JSON
                     (what David started from)
  round-2 polyline = HEAD strokes.json
                     (what David approved)
  per-stroke Pearson via gate_g1_per_stroke(round1, round2, ...)

Threshold = min(real per-(letter, stroke) Pearson) across the corpus.
No noise margin — there's no algorithmic noise floor to subtract
against because the reference is static, not regenerated.

Stdout: clean threshold value (for piping).
Stderr: full per-pair table + summary stats.
"""

from __future__ import annotations

import json
import statistics
import sys
import unicodedata
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
    """Return (path, record) for the earliest-timestamped session JSON
    in `letter_dir`, or None if the directory has no JSONs."""
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
        stroke_masks = ai.build_per_stroke_masks(round2, mask, bbox)

        edit_count = record.get("edit_count_in_session", -1)
        x_min, y_min, x_max, y_max = bbox
        bw = max(1, x_max - x_min)
        bh = max(1, y_max - y_min)
        n_pairs = min(len(round1), len(round2))
        for i in range(n_pairs):
            result = ai.gate_g1_per_stroke(round1[i], round2[i],
                                            stroke_masks[i], bbox,
                                            threshold=1.0)
            # Recompute std side-channel for the surfacing table.
            # Mirrors gate_g1_per_stroke's internal resample+asymmetry
            # path so the std values reflect what the gate actually
            # sees (not the raw cp asymmetry).
            cand_std = ref_std = None
            if len(round1[i]) >= 2 and len(round2[i]) >= 2:
                cand_rs = ai._arc_length_resample(round1[i],
                                                    ai.G1_RESAMPLE_N)
                ref_rs = ai._arc_length_resample(round2[i],
                                                   ai.G1_RESAMPLE_N)
                cand_px = [(x_min + rx * bw, y_min + ry * bh)
                           for rx, ry in cand_rs]
                ref_px = [(x_min + rx * bw, y_min + ry * bh)
                          for rx, ry in ref_rs]
                cand_a = ai._asymmetry_per_point(stroke_masks[i], cand_px)
                ref_a = ai._asymmetry_per_point(stroke_masks[i], ref_px)
                paired = [(a, b) for (a, ok_a), (b, ok_b)
                          in zip(cand_a, ref_a) if ok_a and ok_b]
                if len(paired) >= ai.G1_MIN_MEASURED:
                    arr = np.array(paired)
                    cand_std = float(arr[:, 0].std())
                    ref_std = float(arr[:, 1].std())
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
                "edit_count": edit_count,
                "session_path": session_path.name,
            })
        # Surface stroke-count delta so adds (Ä Ö Ü dots) are visible.
        if len(round1) != len(round2):
            print(f"  note: {letter} stroke count "
                  f"r1={len(round1)} r2={len(round2)} "
                  f"(comparing first {n_pairs} only)",
                  file=sys.stderr)

    # Per-pair table.
    print(f"\nCalibration corpus: {len(letter_dirs)} letters\n",
          file=sys.stderr)
    print(f"{'Letter':6s} {'Str':>3s} {'Pearson':>8s} "
          f"{'cand_std':>9s} {'ref_std':>9s} "
          f"{'n_meas':>7s} {'edits':>6s}  {'Class':<12s} Note",
          file=sys.stderr)
    print("-" * 90, file=sys.stderr)
    real_pearsons: list[float] = []
    real_pearsons_with_id: list[tuple[float, str, int]] = []
    vacuous_count = 0
    for r in rows:
        pearson_str = (f"{r['pearson']:.4f}" if r["pearson"] is not None
                       else "—")
        cand_std_str = (f"{r['cand_std']:.4f}" if r["cand_std"] is not None
                        else "—")
        ref_std_str = (f"{r['ref_std']:.4f}" if r["ref_std"] is not None
                       else "—")
        cls = classify(r["pearson"])
        reason = r["reason"] or ""
        print(f"{r['letter']:6s} {r['stroke']:>3d} {pearson_str:>8s} "
              f"{cand_std_str:>9s} {ref_std_str:>9s} "
              f"{r['n_measured']:>7d} {r['edit_count']:>6d}  "
              f"{cls:<12s} {reason}",
              file=sys.stderr)
        if r["pearson"] is not None:
            real_pearsons.append(r["pearson"])
            real_pearsons_with_id.append(
                (r["pearson"], r["letter"], r["stroke"]))
        else:
            vacuous_count += 1
    if skipped:
        print(file=sys.stderr)
        for letter, reason in skipped:
            print(f"skipped {letter}: {reason}", file=sys.stderr)

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
    perfect_1 = sum(1 for p in real_pearsons if abs(p - 1.0) < 1e-9)
    near_1 = sum(1 for p in real_pearsons if p >= 0.99)
    tight = sum(1 for p in real_pearsons if p >= 0.99)
    moderate = sum(1 for p in real_pearsons if 0.95 <= p < 0.99)
    substantial = sum(1 for p in real_pearsons if p < 0.95)

    print(f"\nReal Pearson values: {len(real_pearsons)} "
          f"(vacuous: {vacuous_count})", file=sys.stderr)
    print(f"  min:    {min_v:.4f}  ({min_label})", file=sys.stderr)
    print(f"  median: {median_v:.4f}", file=sys.stderr)
    print(f"  max:    {max_v:.4f}  ({max_label})", file=sys.stderr)
    print(f"  count Pearson == 1.0:  {perfect_1}", file=sys.stderr)
    print(f"  count Pearson >= 0.99: {near_1}", file=sys.stderr)
    print(f"\nDistribution:", file=sys.stderr)
    print(f"  tight       (>= 0.99): {tight}", file=sys.stderr)
    print(f"  moderate    (0.95-0.99): {moderate}", file=sys.stderr)
    print(f"  substantial (< 0.95):   {substantial}", file=sys.stderr)
    print(f"\nDerived threshold (= min): {min_v:.4f}", file=sys.stderr)

    # Stdout: clean threshold for piping.
    print(f"{min_v:.4f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(calibrate())
