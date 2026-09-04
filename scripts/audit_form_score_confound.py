#!/usr/bin/env python3
"""Audit an EXISTING progress.json for the 2026-09-04 fix: the CoreML
confidence calibrator's practised-letter boost ("historicalFormScores")
was fed `recognitionAccuracy` — the recognizer's own past CONFIDENCE —
where the code documents needing historical geometric FORM accuracy
(`WritingAssessment.formAccuracy`). No channel carrying real form-
accuracy history existed before the fix (`formAccuracyHistory`, added
alongside it), so every boost decision made before the fix used the
wrong instrument.

This machine (a sandboxed advisor seat) has no real device/simulator
progress.json to inspect — this script exists so a real one CAN be
audited, e.g. one pulled from a physical iPad or a TestFlight/pilot
device's Application Support directory
(`.../Application Support/PrimaeNative/progress.json`).

What it reports, per letter with recognitionAccuracy history:
  - the recognitionAccuracy (confidence) samples on record
  - whether the OLD buggy boost condition would have fired:
    >= minimumHistorySamples (5) samples, mean >= historyStrongThreshold
    (0.80) — the exact ConfidenceCalibrator thresholds, duplicated here
    deliberately rather than imported, since this script has no Swift
    runtime to call into
  - formAccuracyHistory, if present (only exists on installs that ran
    at least one freeWrite completion AFTER the fix landed)

A letter flagged "BOOST WOULD HAVE FIRED" had its recognition confidence
(and therefore PhaseSessionRecord.recognitionConfidence /
recognitionConfidenceRaw for any session recorded after that point)
inflated by up to 10% (the configured `historyBoost`), based on the
recognizer's own past confidence rather than the child's actual
handwriting quality.
"""

import argparse
import json
import sys
from pathlib import Path

MINIMUM_HISTORY_SAMPLES = 5
HISTORY_STRONG_THRESHOLD = 0.80
HISTORY_BOOST = 0.10


def audit(store: dict) -> int:
    letters = store.get("letterProgress", {})
    if not letters:
        print("No letterProgress entries — nothing to audit.")
        return 0

    flagged = 0
    for letter in sorted(letters):
        p = letters[letter]
        rec_acc = p.get("recognitionAccuracy") or []
        form_hist = p.get("formAccuracyHistory") or []
        if not rec_acc and not form_hist:
            continue

        print(f"\n{letter}:")
        if rec_acc:
            print(f"  recognitionAccuracy (confidence): {[round(v, 3) for v in rec_acc]}")
        if form_hist:
            print(f"  formAccuracyHistory (post-fix):   {[round(v, 3) for v in form_hist]}")

        if len(rec_acc) >= MINIMUM_HISTORY_SAMPLES:
            mean_conf = sum(rec_acc) / len(rec_acc)
            if mean_conf >= HISTORY_STRONG_THRESHOLD:
                flagged += 1
                print(f"  BOOST WOULD HAVE FIRED — mean confidence {mean_conf:.3f} >= "
                      f"{HISTORY_STRONG_THRESHOLD}, {len(rec_acc)} samples "
                      f"(>= {MINIMUM_HISTORY_SAMPLES}). Recognition confidence for "
                      f"sessions recorded after this point was multiplied by up to "
                      f"{1 + HISTORY_BOOST:.2f}x on the recognizer's OWN past "
                      f"confidence, not on how well the child actually formed the "
                      f"letter.")
            else:
                print(f"  boost would NOT have fired — mean confidence {mean_conf:.3f} "
                      f"< {HISTORY_STRONG_THRESHOLD}")
        elif rec_acc:
            print(f"  boost would NOT have fired — only {len(rec_acc)} samples "
                  f"(< {MINIMUM_HISTORY_SAMPLES})")

    print(f"\n{flagged} letter(s) where the wrong-instrument boost would have fired "
          f"at least once.")
    return flagged


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("progress_json", type=Path,
                        help="Path to a progress.json (JSONProgressStore's on-disk file)")
    args = parser.parse_args()

    if not args.progress_json.exists():
        print(f"error: {args.progress_json} does not exist", file=sys.stderr)
        return 2

    store = json.loads(args.progress_json.read_text())
    audit(store)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
