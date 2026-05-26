"""Umbrella CLI driver for Phase 2b drift-from-reference gates.

Per `research_data/phase2b_gates/g1_design.md`. Each gate's logic lives
as a function in `scripts/audit_invariants.py` (`gate_g1`, future
`gate_g2`...); this script handles letter enumeration, candidate/
reference source resolution, mask rasterization, and output
formatting.

Usage:
  scripts/run_gates.py --gate g1 [LETTERS...]
                       [--candidate-ref REF | WORKTREE]
                       [--reference-ref REF]
                       [--weight regular|light]
                       [--threshold FLOAT]
                       [--json]

Defaults: candidate=WORKTREE, reference=HEAD, weight=regular,
threshold=0.98 (pre-calibration placeholder; production value will be
recorded in BAKE_INVARIANTS.md once G1 calibration ships).

Exit code: 0 if all letters pass; 1 if any letter fails.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

# Reuse the bake's rasterize + bbox_from_mask so gate input mirrors
# what the bake itself would see for the same letter glyph.
SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import audit_invariants as ai  # noqa: E402
import generate_strokes_auto as g  # noqa: E402

REPO_ROOT = SCRIPT_DIR.parent
LETTERS_DIR_DEFAULT = REPO_ROOT / "PrimaeNative" / "Resources" / "Letters"
WORKTREE_SENTINEL = "WORKTREE"


def folder_for(letter: str) -> str:
    """Map a letter character to its directory name on disk.

    Uppercase letters and uncased characters (ß) use bare-name folders;
    lowercase letters use `<letter>_l`. See
    `PrimaeNative/Resources/Letters/Regular/` for the convention.
    """
    return letter if letter.isupper() else f"{letter}_l"


def strokes_path(letter: str, weight: str,
                  letters_dir: Path = LETTERS_DIR_DEFAULT) -> Path:
    return (letters_dir / weight.capitalize() / folder_for(letter)
            / "strokes.json")


def load_strokes(letter: str, weight: str, ref: str,
                  letters_dir: Path = LETTERS_DIR_DEFAULT) -> dict | None:
    """Load a letter's strokes.json from a git ref or the working tree.

    Returns None if the source doesn't exist (missing letter, missing
    file at the ref, etc.).
    """
    path = strokes_path(letter, weight, letters_dir)
    if ref == WORKTREE_SENTINEL:
        if not path.exists():
            return None
        return json.loads(path.read_text())
    rel = path.relative_to(REPO_ROOT)
    result = subprocess.run(
        ["git", "show", f"{ref}:{rel.as_posix()}"],
        capture_output=True, text=True, cwd=REPO_ROOT)
    if result.returncode != 0:
        return None
    return json.loads(result.stdout)


def strokes_to_polylines(data: dict) -> list[list[tuple[float, float]]]:
    """Extract (x, y) tuples per stroke from a strokes.json dict."""
    return [[(c["x"], c["y"]) for c in s["checkpoints"]]
            for s in data["strokes"]]


def enumerate_letters(weight: str,
                       letters_dir: Path = LETTERS_DIR_DEFAULT
                       ) -> list[str]:
    """Every letter present on disk under `letters_dir/<Weight>/`."""
    weight_dir = letters_dir / weight.capitalize()
    if not weight_dir.is_dir():
        return []
    letters: list[str] = []
    for entry in sorted(weight_dir.iterdir()):
        if not entry.is_dir():
            continue
        name = entry.name
        if name.endswith("_l") and len(name) == 3:
            letters.append(name[0])
        else:
            letters.append(name)
    return letters


# Per-gate metadata. Adding G3/G4/G5 is a single-row table entry.
# `needs_mask`: G1 (asymmetry) and the future G3 (stem-width / perpendicular
# deviation) need the ink-mask raster; G2 (turn-angle) and the future G4
# (junction-tangent) are pure polyline computations.
GATE_METADATA: dict[str, dict] = {
    "g1": {
        "function_with_mask": ai.gate_g1,
        "function_without_mask": None,
        "needs_mask": True,
        "title": "asymmetry-profile drift from reference",
        # Drift gate: pass iff metric ≥ threshold.
        "comparison": "≥",
        "default_threshold": ai.G1_DEFAULT_THRESHOLD,
    },
    "g2": {
        "function_with_mask": None,
        "function_without_mask": ai.gate_g2,
        "needs_mask": False,
        "title": "turn-angle-profile drift from reference",
        "comparison": "≥",
        # G2 is investigated-not-viable; not enforced. No default
        # threshold; --threshold must be passed explicitly to run.
        "default_threshold": None,
    },
    "g3": {
        "function_with_mask": None,
        "function_without_mask": ai.gate_g3,
        "needs_mask": False,
        "title": "perpendicular deviation on straight strokes",
        # Conformance gate: pass iff metric ≤ threshold.
        "comparison": "≤",
        "default_threshold": ai.G3_DEFAULT_THRESHOLD,
    },
    "g4": {
        "function_with_mask": None,
        "function_without_mask": ai.gate_g4,
        "needs_mask": False,
        "title": "junction-tangent-kink drift from reference",
        # Drift gate on per-junction property: pass iff drift ≤ threshold.
        "comparison": "≤",
        "default_threshold": ai.G4_DEFAULT_THRESHOLD_DEG,
    },
    "g6": {
        "function_with_mask": None,
        "function_without_mask": ai.gate_g6,
        "needs_mask": False,
        "title": "T-junction attachment-tangent drift from reference",
        # Drift gate on per-junction property: pass iff drift ≤ threshold.
        "comparison": "≤",
        "default_threshold": ai.G6_DEFAULT_THRESHOLD_DEG,
    },
}


def run_gate_for_letter(letter: str, gate: str, weight: str,
                         candidate_ref: str, reference_ref: str,
                         threshold: float,
                         letters_dir: Path = LETTERS_DIR_DEFAULT
                         ) -> dict:
    """Dispatch to the gate function for `gate` against a single letter.

    The gate function comes from GATE_METADATA; mask is built only when
    the gate needs it.
    """
    meta = GATE_METADATA[gate]
    candidate = load_strokes(letter, weight, candidate_ref, letters_dir)
    reference = load_strokes(letter, weight, reference_ref, letters_dir)
    if candidate is None or reference is None:
        return {
            "letter": letter,
            "pass": False,
            "error": ("missing_candidate" if candidate is None
                      else "missing_reference"),
        }
    font_path = g.FONTS[weight]
    if not font_path.exists():
        return {"letter": letter, "pass": False,
                "error": f"missing_font:{font_path}"}
    mask = g.rasterize(letter, font_path)
    bbox = g.bbox_from_mask(mask)
    cand_polys = strokes_to_polylines(candidate)
    ref_polys = strokes_to_polylines(reference)
    if meta["needs_mask"]:
        result = meta["function_with_mask"](cand_polys, ref_polys,
                                              mask, bbox, threshold)
    else:
        result = meta["function_without_mask"](cand_polys, ref_polys,
                                                 bbox, threshold)
    result["letter"] = letter
    return result


def format_letter_human(result: dict) -> str:
    letter = result["letter"]
    if "error" in result:
        return f"{letter:6s} ERROR: {result['error']}"
    parts = [f"{'✓' if result['pass'] else '✗'} {letter:4s}"]
    # Drift-per-stroke (G1/G2) and conformance-per-stroke (G3) gates
    # produce a `per_stroke` key. Drift-per-junction (G4) gates produce
    # `per_junction` instead.
    if "per_junction" in result:
        if result.get("letter_reason"):
            parts.append(f"({result['letter_reason']})")
        for j in result["per_junction"]:
            idx = f"s{j['stroke_i']}-s{j['stroke_j']}"
            if j.get("reason"):
                parts.append(f"{idx}: vacuous ({j['reason']})")
            else:
                mark = "✓" if j["pass"] else "✗"
                parts.append(f"{idx}: {mark} drift={j['kink_drift_deg']:.2f}°"
                             f" (ref={j['kink_ref_deg']:.1f}°"
                             f" cand={j['kink_cand_deg']:.1f}°)")
        return "  " + "  ".join(parts)
    for s in result["per_stroke"]:
        idx = s["stroke"]
        if s.get("reason"):
            parts.append(f"s{idx}: vacuous ({s['reason']})")
        else:
            mark = "✓" if s["pass"] else "✗"
            # Drift gates report 'pearson'; conformance gates report
            # 'deviation_px'. Format whichever the gate produced.
            if "pearson" in s:
                parts.append(f"s{idx}: {mark} pearson={s['pearson']:.4f}"
                             f" n={s['n_measured']}")
            elif "deviation_px" in s:
                parts.append(f"s{idx}: {mark} dev={s['deviation_px']:.2f}px"
                             f" n={s['n_measured']}")
            else:
                parts.append(f"s{idx}: {mark} (unknown metric shape)")
    return "  " + "  ".join(parts)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("letters", nargs="*",
                        help="Letters to audit (default: all on disk)")
    parser.add_argument("--gate", required=True,
                        choices=list(GATE_METADATA.keys()),
                        help="Gate to run (more gates land in later Phase 2b commits)")
    parser.add_argument("--candidate-ref", default=WORKTREE_SENTINEL,
                        help="Git ref for candidate strokes.json "
                             "(default: WORKTREE = working tree)")
    parser.add_argument("--reference-ref", default="HEAD",
                        help="Git ref for reference strokes.json (default: HEAD)")
    parser.add_argument("--weight", default="regular",
                        choices=list(g.FONTS.keys()))
    parser.add_argument("--threshold", type=float, default=None,
                        help="Pass threshold (overrides the gate's "
                             "calibrated default). Each gate has a "
                             "post-calibration default in "
                             "GATE_METADATA; omit this flag to use it.")
    parser.add_argument("--letters-dir", type=Path,
                        default=LETTERS_DIR_DEFAULT)
    parser.add_argument("--json", action="store_true",
                        help="Emit machine-readable JSON instead of stdout report")
    args = parser.parse_args(argv)

    # Resolve --threshold default from GATE_METADATA. If the gate
    # has no calibrated default (G2: investigated-not-viable) and
    # --threshold wasn't passed, fail loudly rather than running
    # against a meaningless placeholder.
    if args.threshold is None:
        gate_default = GATE_METADATA[args.gate].get("default_threshold")
        if gate_default is None:
            print(f"Gate {args.gate} has no calibrated default threshold "
                  f"(investigated-not-viable). Pass --threshold "
                  f"explicitly to run it.", file=sys.stderr)
            return 1
        args.threshold = gate_default

    letters = args.letters or enumerate_letters(args.weight, args.letters_dir)
    if not letters:
        print(f"No letters found under "
              f"{args.letters_dir}/{args.weight.capitalize()}",
              file=sys.stderr)
        return 1

    results: list[dict] = []
    for letter in letters:
        results.append(run_gate_for_letter(
            letter, args.gate, args.weight,
            args.candidate_ref, args.reference_ref,
            args.threshold, args.letters_dir))

    n_pass = sum(1 for r in results if r.get("pass"))
    n_fail = len(results) - n_pass

    if args.json:
        out = {
            "gate": args.gate,
            "threshold": args.threshold,
            "candidate_ref": args.candidate_ref,
            "reference_ref": args.reference_ref,
            "weight": args.weight,
            "letters": {r["letter"]: r for r in results},
            "summary": {"pass": n_pass, "fail": n_fail,
                        "total": len(results)},
        }
        print(json.dumps(out, indent=2, ensure_ascii=False))
    else:
        meta = GATE_METADATA[args.gate]
        title = meta["title"]
        comparison = meta.get("comparison", "≥")
        header = (f"{args.gate.upper()} — {title} "
                  f"(threshold {comparison} {args.threshold})")
        print(header)
        print()
        for r in results:
            print(format_letter_human(r))
        print()
        print(f"Summary: {n_pass}/{len(results)} pass, {n_fail} fail")

    return 0 if n_fail == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
