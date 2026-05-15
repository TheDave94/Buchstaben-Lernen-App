#!/usr/bin/env python3
"""Import an iPad-calibrator aggregate export into per-letter
strokes.json files.

The calibrator's `Alle` export bundles every letter for the current
schriftArt into one JSON. This script splits that bundle into the
per-letter directory layout under `PrimaeNative/Resources/Letters/`,
preserving any existing skeleton / skeletonAdj / bridgeEdges fields
on each letter (the calibrator export does not include them, but
they're required by the calibrator's BFS routing for ANKER mode).

The export's letter strings arrive in Unicode NFD form for diacritics
(`A` + combining diaeresis = Ä decomposed). Linux filesystems treat
NFD and NFC paths as distinct, so a literal write creates a
sibling directory next to the existing NFC `Ä`. `normalize_letter_name`
normalises to NFC before path construction.

Usage:
    python3 scripts/calibration_to_override.py \\
        --input /path/to/strokes.json \\
        [--weight regular]  # default: derived from JSON 'schriftArt'
"""
from __future__ import annotations

import argparse
import json
import sys
import unicodedata
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
LETTERS_BASE = REPO_ROOT / "PrimaeNative/Resources/Letters"
LOWERCASE_SUFFIX = "_l"

SCHRIFTART_TO_WEIGHT_DIR = {
    "druckschrift": "Regular",
    "druckschrift_light": "Light",
}


def normalize_letter_name(name: str) -> str:
    """Normalize a letter string to Unicode NFC. The iPad calibrator
    export encodes diacritics in NFD (e.g. "Ä" as "A\\u0308"); shipped
    directories are NFC. Without this normalisation, a literal write
    creates an NFD-form sibling of the existing NFC directory."""
    return unicodedata.normalize("NFC", name)


def target_dir(letter: str, weight_dir: str) -> Path:
    """Resolve the per-letter resource directory for a given weight,
    honouring the lowercase-suffix convention (APFS / HFS+ case-
    insensitivity) and NFC normalisation for diacritics."""
    letter_nfc = normalize_letter_name(letter)
    if letter_nfc.isupper() or not letter_nfc.isalpha():
        return LETTERS_BASE / weight_dir / letter_nfc
    return LETTERS_BASE / weight_dir / f"{letter_nfc}{LOWERCASE_SUFFIX}"


def import_aggregate_export(input_path: Path,
                             weight_dir: str | None = None
                             ) -> dict:
    """Split the aggregate export into per-letter strokes.json files.

    Preserves skeleton / skeletonAdj / bridgeEdges fields from any
    existing per-letter file (the calibrator export omits them but
    the calibrator's runtime BFS routing requires them).

    Returns a summary dict: {written: [letter,...], skipped: [...]}.
    """
    data = json.loads(input_path.read_text())
    if weight_dir is None:
        schrift = data.get("schriftArt", "druckschrift")
        weight_dir = SCHRIFTART_TO_WEIGHT_DIR.get(schrift, "Regular")
    written: list[str] = []
    for entry in data["letters"]:
        letter = entry["letter"]
        letter_nfc = normalize_letter_name(letter)
        d = target_dir(letter_nfc, weight_dir)
        f = d / "strokes.json"
        old = json.loads(f.read_text()) if f.exists() else None
        new_doc: dict = {
            "letter": letter_nfc,
            "checkpointRadius": entry["checkpointRadius"],
            "strokes": entry["strokes"],
        }
        if old:
            for k in ("skeleton", "skeletonAdj", "bridgeEdges"):
                if k in old:
                    new_doc[k] = old[k]
        d.mkdir(parents=True, exist_ok=True)
        f.write_text(json.dumps(new_doc, indent=2,
                                  ensure_ascii=False) + "\n")
        written.append(letter_nfc)
    return {"written": written, "weight_dir": weight_dir}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Import an iPad-calibrator aggregate strokes.json "
                    "into per-letter files.")
    parser.add_argument("--input", required=True, type=Path,
                         help="Path to the aggregate strokes.json export.")
    parser.add_argument("--weight", choices=["regular", "light"],
                         default=None,
                         help="Override weight directory. Default: derived "
                              "from the export's `schriftArt` field.")
    args = parser.parse_args(argv)
    weight_dir = (args.weight.capitalize()
                   if args.weight else None)
    if not args.input.exists():
        print(f"input not found: {args.input}", file=sys.stderr)
        return 1
    summary = import_aggregate_export(args.input, weight_dir=weight_dir)
    print(f"wrote {len(summary['written'])} letters to "
          f"Letters/{summary['weight_dir']}/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
