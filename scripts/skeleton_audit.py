#!/usr/bin/env python3
"""Validate the polyline-based stroke pipeline.

Two invariants are checked:

  1. Every author-placed polyline tuple in `LETTERS` lies inside the
     rasterised glyph's ink mask. Off-ink tuples are the primary
     failure mode of the polyline architecture and must be fixed by
     re-eyeballing the offending coordinate.

  2. Every bundled `strokes.json` under `PrimaeNative/Resources/Letters`
     conforms to the Swift Codable schema: required top-level fields
     (`letter`, `checkpointRadius`, `strokes`) with the right types,
     and per-stroke `id` / `checkpoints` shape.

Per-letter status is printed; exit code is non-zero only when any
check fails. The CI step that calls this script treats it as
advisory, so a non-zero exit will not fail the build by itself.

Usage:
    python3 scripts/skeleton_audit.py
    python3 scripts/skeleton_audit.py --letters M N W
    python3 scripts/skeleton_audit.py --json /tmp/audit.json
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from generate_strokes_auto import (  # noqa: E402
    LETTERS,
    DEFAULT_FONT,
    bbox_from_mask,
    output_dir_for,
    rasterize,
    validate_polylines_in_ink,
)

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_BUNDLE = REPO_ROOT / "PrimaeNative/Resources/Letters"


def check_polyline_in_ink(letter: str, font_path: Path) -> list[str]:
    """Render the glyph and report every authored polyline tuple whose
    raster pixel falls outside the ink mask. Returns one human-readable
    error per offending tuple, or `[]` if the letter is clean."""
    try:
        mask = rasterize(letter, font_path)
    except Exception as e:
        return [f"{letter}: rasterise failed — {e}"]
    try:
        bbox = bbox_from_mask(mask)
    except Exception as e:
        return [f"{letter}: bbox failed — {e}"]
    return validate_polylines_in_ink(letter, LETTERS[letter], mask, bbox)


def check_strokes_json_schema(path: Path) -> list[str]:
    """Validate a single `strokes.json` against the Swift Codable
    schema. Returns one error string per violation; `[]` on success."""
    errors: list[str] = []
    try:
        data = json.loads(path.read_text())
    except Exception as e:
        return [f"{path}: invalid JSON — {e}"]
    if not isinstance(data, dict):
        return [f"{path}: top-level value is not an object"]
    if not isinstance(data.get("letter"), str):
        errors.append(f"{path}: 'letter' missing or not a string")
    if not isinstance(data.get("checkpointRadius"), (int, float)):
        errors.append(f"{path}: 'checkpointRadius' missing or not a number")
    strokes = data.get("strokes")
    if not isinstance(strokes, list) or not strokes:
        errors.append(f"{path}: 'strokes' missing or empty")
    else:
        for si, s in enumerate(strokes):
            if not isinstance(s, dict):
                errors.append(f"{path}: stroke {si} is not an object")
                continue
            if not isinstance(s.get("id"), int):
                errors.append(f"{path}: stroke {si} 'id' missing or not int")
            cps = s.get("checkpoints")
            if not isinstance(cps, list) or not cps:
                errors.append(f"{path}: stroke {si} 'checkpoints' "
                              "missing or empty")
                continue
            for ci, c in enumerate(cps):
                if not (isinstance(c, dict)
                        and isinstance(c.get("x"), (int, float))
                        and isinstance(c.get("y"), (int, float))):
                    errors.append(f"{path}: stroke {si} cp {ci} "
                                  "missing numeric x / y")
                    break
    return errors


def main() -> int:
    """CLI entry point — runs both checks and prints a summary."""
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--letters", nargs="*", default=None,
                        help="Audit only these LETTERS entries. "
                             "Default: every authored letter.")
    parser.add_argument("--font", default=str(DEFAULT_FONT),
                        help="OTF / TTF font path.")
    parser.add_argument("--bundle-dir", default=str(DEFAULT_BUNDLE),
                        help="Resources/Letters directory to schema-check.")
    parser.add_argument("--json", default=None,
                        help="Write the full audit as JSON to this path.")
    # Backward-compat: CI passes `--anchor-drift-pct` from the old
    # audit. Accept and ignore so the workflow doesn't break.
    parser.add_argument("--anchor-drift-pct", type=float, default=None,
                        help=argparse.SUPPRESS)
    args = parser.parse_args()

    font_path = Path(args.font)
    bundle_dir = Path(args.bundle_dir) if args.bundle_dir else None
    letters = args.letters or list(LETTERS.keys())

    polyline_results: list[dict] = []
    print("=== Polyline-in-ink check ===")
    for L in letters:
        if L not in LETTERS:
            print(f"  {L}: skipped (no entry in LETTERS)")
            continue
        errs = check_polyline_in_ink(L, font_path)
        polyline_results.append({"letter": L, "errors": errs})
        if errs:
            for e in errs:
                print(f"  {e}")
        else:
            print(f"  {L}: ok")

    schema_results: list[dict] = []
    if bundle_dir and bundle_dir.exists():
        print()
        print(f"=== strokes.json schema check ({bundle_dir}) ===")
        for path in sorted(bundle_dir.rglob("strokes.json")):
            errs = check_strokes_json_schema(path)
            schema_results.append({"path": str(path), "errors": errs})
            if errs:
                for e in errs:
                    print(f"  {e}")
        bad = sum(1 for r in schema_results if r["errors"])
        print(f"  {len(schema_results)} files checked, {bad} with errors")

    if args.json:
        Path(args.json).write_text(json.dumps({
            "polyline_in_ink": polyline_results,
            "schema": schema_results,
        }, indent=2))
        print(f"\nwrote {args.json}")

    poly_fail = any(r["errors"] for r in polyline_results)
    schema_fail = any(r["errors"] for r in schema_results)
    return 0 if not (poly_fail or schema_fail) else 1


if __name__ == "__main__":
    sys.exit(main())
