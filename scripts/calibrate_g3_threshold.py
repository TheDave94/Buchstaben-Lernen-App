"""G3 threshold calibration against the 2026-05-22 session-pair corpus.

Mirrors calibrate_g{1,2}_threshold.py. For each letter in the corpus,
the script:

  - Computes the round-2 straightness classification (the gate's
    applies-to filter).
  - Measures the candidate's perpendicular deviation from its own
    best-fit line at both round-1 and round-2.
  - Reports the pairwise round-1/round-2 deviations for STRAIGHT
    strokes (so polish-preservation can be verified before threshold
    derivation).
  - Computes the bbox-fraction (deviation_px / max(bbox_w, bbox_h))
    as a secondary diagnostic column.
  - Reports per-reason vacuous breakdown.
  - Derives threshold = max(per-stroke max(r1, r2)) + 1 px safety
    margin (per G3.7 step 5), IF polish-preservation holds.

Stdout: clean threshold value (for piping).
Stderr: full per-pair table + polish-preservation check + summary.
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


def classify(max_a: float, p95_a: float) -> str:
    """Four-outcome classification per g3_design.md G3.1 caveat."""
    max_high = max_a >= ai.G3_STRAIGHTNESS_MAX_ANGLE
    p95_high = p95_a >= ai.G3_STRAIGHTNESS_P95_ANGLE
    if not max_high and not p95_high:
        return "STRAIGHT"
    if not max_high and p95_high:
        return "SMOOTH-CURVED"
    if max_high and not p95_high:
        return "SHARP-CORNER"
    return "CORNERED"


def diagnostic_deviation(poly_rel: list[tuple[float, float]],
                          bbox: tuple[int, int, int, int]) -> float | None:
    """Compute perpendicular deviation without the straightness gate —
    used to report what the deviation would have been for vacuous-
    classified strokes. Returns None for too-short polylines."""
    if len(poly_rel) < 2:
        return None
    x_min, y_min, x_max, y_max = bbox
    bw = max(1, x_max - x_min)
    bh = max(1, y_max - y_min)
    rs = ai._arc_length_resample(poly_rel, ai.G3_RESAMPLE_N)
    px = [(x_min + rx * bw, y_min + ry * bh) for rx, ry in rs]
    measured = px[ai.G3_ENDPOINT_SKIP:len(px) - ai.G3_ENDPOINT_SKIP]
    if len(measured) < ai.G3_MIN_MEASURED:
        return None
    dev, _ = ai._perpendicular_deviation(measured)
    return dev


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
        bw_px = max(1, x_max - x_min)
        bh_px = max(1, y_max - y_min)
        bbox_scale = float(max(bw_px, bh_px))

        n_pairs = min(len(round1), len(round2))
        for i in range(n_pairs):
            # Call 1: round-1 candidate vs round-2 reference. Captures
            # the gate's classification verdict + dev_round1 (if
            # classification is STRAIGHT). Threshold=∞ so the result
            # reports the actual deviation rather than pass/fail.
            r1 = ai.gate_g3_per_stroke(round1[i], round2[i], bbox,
                                         threshold=1e9)
            # Call 2: round-2 candidate vs round-2 reference. Captures
            # dev_round2 (LSQ line through round-2's cps).
            r2 = ai.gate_g3_per_stroke(round2[i], round2[i], bbox,
                                         threshold=1e9)

            # Classification from round-2 reference (same in both calls).
            max_ref = r1["max_ref_angle"] if r1["max_ref_angle"] is not None else 0.0
            p95_ref = r1.get("p95_ref_angle") or 0.0
            cls = classify(max_ref, p95_ref) if r1.get("reason") != "not_applicable_too_short" \
                else "TOO-SHORT"

            # Diagnostic deviations (computed regardless of vacuous-pass
            # so the "what would it have been" column is populated for
            # non-STRAIGHT strokes too).
            dev_r1 = (r1.get("deviation_px")
                      if r1.get("deviation_px") is not None
                      else diagnostic_deviation(round1[i], bbox))
            dev_r2 = (r2.get("deviation_px")
                      if r2.get("deviation_px") is not None
                      else diagnostic_deviation(round2[i], bbox))

            rows.append({
                "letter": letter,
                "stroke": i,
                "max_ref": max_ref,
                "p95_ref": p95_ref,
                "classification": cls,
                "dev_r1_px": dev_r1,
                "dev_r2_px": dev_r2,
                "dev_r1_bf": (dev_r1 / bbox_scale) if dev_r1 is not None else None,
                "dev_r2_bf": (dev_r2 / bbox_scale) if dev_r2 is not None else None,
                "reason": r1.get("reason"),
                "edit_count": edit_count,
                "session_path": session_path.name,
            })
        if len(round1) != len(round2):
            print(f"  note: {letter} stroke count "
                  f"r1={len(round1)} r2={len(round2)} "
                  f"(comparing first {n_pairs} only)",
                  file=sys.stderr)

    # Per-pair table.
    print(f"\nG3 calibration corpus: {len(letter_dirs)} letters\n",
          file=sys.stderr)
    print(f"{'Letter':6s} {'Str':>3s} {'max_ref':>8s} {'p95_ref':>8s} "
          f"{'Classification':>14s}  "
          f"{'dev_r1':>7s} {'dev_r2':>7s} {'Δdev':>7s}  "
          f"{'bf_r1':>7s} {'bf_r2':>7s}  {'edits':>5s}  Note",
          file=sys.stderr)
    print("-" * 120, file=sys.stderr)

    vacuous_by_reason: Counter[str] = Counter()
    straight_rows: list[dict] = []

    for r in rows:
        max_str = f"{r['max_ref']:.4f}" if r['max_ref'] else "—"
        p95_str = f"{r['p95_ref']:.4f}" if r['p95_ref'] else "—"
        dev_r1_str = f"{r['dev_r1_px']:.2f}" if r['dev_r1_px'] is not None else "—"
        dev_r2_str = f"{r['dev_r2_px']:.2f}" if r['dev_r2_px'] is not None else "—"
        bf_r1_str = f"{r['dev_r1_bf']:.4f}" if r['dev_r1_bf'] is not None else "—"
        bf_r2_str = f"{r['dev_r2_bf']:.4f}" if r['dev_r2_bf'] is not None else "—"
        if r['dev_r1_px'] is not None and r['dev_r2_px'] is not None:
            delta = r['dev_r2_px'] - r['dev_r1_px']
            delta_str = f"{delta:+.2f}"
        else:
            delta_str = "—"
        reason = r['reason'] or ""
        print(f"{r['letter']:6s} {r['stroke']:>3d} {max_str:>8s} {p95_str:>8s} "
              f"{r['classification']:>14s}  "
              f"{dev_r1_str:>7s} {dev_r2_str:>7s} {delta_str:>7s}  "
              f"{bf_r1_str:>7s} {bf_r2_str:>7s}  {r['edit_count']:>5d}  {reason}",
              file=sys.stderr)
        if r['reason']:
            vacuous_by_reason[r['reason']] += 1
        if r['classification'] == "STRAIGHT" and r['dev_r1_px'] is not None and r['dev_r2_px'] is not None:
            straight_rows.append(r)

    if skipped:
        print(file=sys.stderr)
        for letter, reason in skipped:
            print(f"skipped {letter}: {reason}", file=sys.stderr)

    # Vacuous-by-reason breakdown.
    vacuous_total = sum(vacuous_by_reason.values())
    n_straight = len(straight_rows)
    print(f"\nClassification summary: {n_straight} STRAIGHT, "
          f"{vacuous_total} vacuous (of {len(rows)} stroke pairs)",
          file=sys.stderr)
    for reason, count in sorted(vacuous_by_reason.items()):
        print(f"  {reason}: {count}", file=sys.stderr)

    # Polish-preservation check (STRAIGHT class only).
    if not straight_rows:
        print("\nNo STRAIGHT-class strokes in corpus; cannot derive threshold.",
              file=sys.stderr)
        return 1

    preserved = sum(1 for r in straight_rows
                     if r['dev_r2_px'] <= r['dev_r1_px'])
    worsened = sum(1 for r in straight_rows
                    if r['dev_r2_px'] > r['dev_r1_px'])
    deltas = [r['dev_r2_px'] - r['dev_r1_px'] for r in straight_rows]
    median_delta = statistics.median(deltas)
    worst_idx = max(range(len(straight_rows)),
                     key=lambda i: deltas[i])
    worst = straight_rows[worst_idx]
    worst_delta = deltas[worst_idx]

    print(f"\nPolish-preservation check (STRAIGHT class only):",
          file=sys.stderr)
    print(f"  Strokes where dev_round2 ≤ dev_round1: "
          f"{preserved} (polish preserved or improved)", file=sys.stderr)
    print(f"  Strokes where dev_round2 > dev_round1: "
          f"{worsened} (polish increased deviation)", file=sys.stderr)
    print(f"  Total STRAIGHT strokes: {n_straight}", file=sys.stderr)
    print(f"  Median Δdev: {median_delta:+.4f} px", file=sys.stderr)
    print(f"  Max Δdev (most polish-increased deviation): "
          f"{worst_delta:+.4f} px at "
          f"{worst['letter']} s{worst['stroke']}", file=sys.stderr)

    if worsened >= preserved:
        print(f"\n⚠ SOFT-V TRIGGER: polish systematically INCREASES "
              f"deviation in {worsened}/{n_straight} STRAIGHT strokes.",
              file=sys.stderr)
        print(f"   Mirrors G2's outcome: metric measures real signal "
              f"but mismatches freeze-gate purpose.", file=sys.stderr)
        print(f"   HOLD and surface — do NOT derive threshold.",
              file=sys.stderr)
        # Do not emit threshold on stdout.
        return 1

    # Threshold derivation.
    max_devs_per_stroke = [max(r['dev_r1_px'], r['dev_r2_px'])
                            for r in straight_rows]
    max_max = max(max_devs_per_stroke)
    max_idx = max_devs_per_stroke.index(max_max)
    max_label = (f"{straight_rows[max_idx]['letter']} "
                 f"s{straight_rows[max_idx]['stroke']}")
    SAFETY_MARGIN_PX = 1.0
    threshold = max_max + SAFETY_MARGIN_PX

    print(f"\nThreshold derivation (STRAIGHT class only):", file=sys.stderr)
    print(f"  max(per-stroke max(r1, r2)) = {max_max:.4f} px at {max_label}",
          file=sys.stderr)
    print(f"  + {SAFETY_MARGIN_PX} px safety margin (per G3.7 step 5; "
          f"rasterization noise)", file=sys.stderr)
    print(f"  = threshold {threshold:.4f} px", file=sys.stderr)

    # Stdout: clean threshold value.
    print(f"{threshold:.4f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(calibrate())
