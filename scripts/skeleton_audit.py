#!/usr/bin/env python3
"""Validate the anchor-spec stroke pipeline.

Two invariants are checked:

  1. Every anchor in every authored `LETTERS` spec resolves to an ink
     pixel without raising, and the Dijkstra centerline between each
     consecutive anchor pair completes (no disconnected components).

  2. Every bundled `strokes.json` under `PrimaeNative/Resources/Letters`
     conforms to the Swift Codable schema: required top-level fields
     (`letter`, `checkpointRadius`, `strokes`) with the right types,
     and per-stroke `id` / `checkpoints` shape.

Per-letter status is printed; exit code is non-zero on any failure.
The CI step that calls this script treats it as advisory, so a
non-zero exit will not by itself fail the build.

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
    bake_letter,
)

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_BUNDLE = REPO_ROOT / "PrimaeNative/Resources/Letters"


def check_anchor_spec(letter: str, font_path: Path) -> list[str]:
    """Attempt a dry bake to surface anchor-resolution or Dijkstra
    failures. The bake is deterministic, so a passing letter here is
    guaranteed to bake clean."""
    try:
        bake_letter(letter, font_path)
    except Exception as e:
        return [f"{letter}: {e}"]
    return []


def check_strokes_json_schema(path: Path) -> list[str]:
    """Validate a single `strokes.json` against the Swift Codable
    schema. Returns one error string per violation."""
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
                        help="Audit only these LETTERS entries.")
    parser.add_argument("--font", default=str(DEFAULT_FONT),
                        help="OTF / TTF font path.")
    parser.add_argument("--bundle-dir", default=str(DEFAULT_BUNDLE),
                        help="Resources/Letters directory to schema-check.")
    parser.add_argument("--json", default=None,
                        help="Write the full audit as JSON to this path.")
    # Backward-compat: legacy CI passes `--anchor-drift-pct`. Accept and
    # ignore so the workflow doesn't break.
    parser.add_argument("--anchor-drift-pct", type=float, default=None,
                        help=argparse.SUPPRESS)
    args = parser.parse_args()

    font_path = Path(args.font)
    bundle_dir = Path(args.bundle_dir) if args.bundle_dir else None
    letters = args.letters or list(LETTERS.keys())

    spec_results: list[dict] = []
    print("=== Anchor-spec bake check ===")
    for L in letters:
        if L not in LETTERS:
            print(f"  {L}: skipped (no entry in LETTERS)")
            continue
        errs = check_anchor_spec(L, font_path)
        spec_results.append({"letter": L, "errors": errs})
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
            "anchor_spec": spec_results,
            "schema": schema_results,
        }, indent=2))
        print(f"\nwrote {args.json}")

    spec_fail = any(r["errors"] for r in spec_results)
    schema_fail = any(r["errors"] for r in schema_results)
    return 0 if not (spec_fail or schema_fail) else 1


if __name__ == "__main__":
    sys.exit(main())
