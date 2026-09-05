"""Unit tests for G4 (Threshold 4 — junction-tangent-kink drift from
reference).

Test cases per `research_data/phase2b_gates/g4_design.md` G4'.1–G4'.7:
- Tangent computation at endpoints (LSQ-based, oriented outward)
- Kink_deg semantics (0° = pen-continuation, 90° = corner,
  180° = point-meeting)
- Junction detection (epsilon check, four endpoint pairings)
- Vacuous-pass cases: no-junction, junction-detection-mismatch-between-
  rounds, insufficient-measured-points
- Letter-level: no_pairs (single-stroke letters),
  no_junctions_detected (multi-stroke with all pairs > epsilon)
- Drift metric: |kink_cand - kink_ref|; identical polylines → drift 0

Run: python3 scripts/tests/test_gate_g4.py
"""

from __future__ import annotations

import math
import sys
import unittest
from pathlib import Path

import numpy as np

SCRIPT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPT_DIR))
import audit_invariants as ai  # noqa: E402


class TestTangentAtEndpoint(unittest.TestCase):
    """Direct tests of `_stroke_tangent_at_endpoint`."""

    def test_horizontal_stroke_from_first(self):
        # Stroke runs left-to-right at y=0. Outgoing from first cp
        # should point RIGHT (toward the stroke interior).
        poly = [(float(i), 0.0) for i in range(20)]
        t = ai._stroke_tangent_at_endpoint(poly, at_first=True)
        self.assertIsNotNone(t)
        self.assertAlmostEqual(t[0], 1.0, places=4)
        self.assertAlmostEqual(t[1], 0.0, places=4)

    def test_horizontal_stroke_from_last(self):
        # Same stroke, outgoing from last cp should point LEFT
        # (toward the stroke interior).
        poly = [(float(i), 0.0) for i in range(20)]
        t = ai._stroke_tangent_at_endpoint(poly, at_first=False)
        self.assertIsNotNone(t)
        self.assertAlmostEqual(t[0], -1.0, places=4)
        self.assertAlmostEqual(t[1], 0.0, places=4)

    def test_too_few_cps_returns_none(self):
        # Only 5 cps → after skip=3 + window=5 we'd need 8 cps from one
        # end; should return None.
        poly = [(float(i), 0.0) for i in range(5)]
        t = ai._stroke_tangent_at_endpoint(poly, at_first=True)
        self.assertIsNone(t)


class TestKinkDeg(unittest.TestCase):

    def test_anti_parallel_outgoing_gives_zero(self):
        # Pen-continuation: two outgoing tangents pointing opposite
        # ways (one toward (-x), the other toward (+x)).
        a = (-1.0, 0.0)
        b = (1.0, 0.0)
        k = ai._kink_deg(a, b)
        self.assertAlmostEqual(k, 0.0, places=4)

    def test_parallel_outgoing_gives_180(self):
        # Point-meeting: two outgoing tangents in the same direction
        # (both pointing up, e.g. bottom-of-U pattern).
        a = (0.0, 1.0)
        b = (0.0, 1.0)
        k = ai._kink_deg(a, b)
        self.assertAlmostEqual(k, 180.0, places=4)

    def test_perpendicular_outgoing_gives_90(self):
        # T-corner: one outgoing right, one outgoing up.
        a = (1.0, 0.0)
        b = (0.0, 1.0)
        k = ai._kink_deg(a, b)
        self.assertAlmostEqual(k, 90.0, places=4)


class TestJunctionDetection(unittest.TestCase):

    def _bbox(self) -> tuple[int, int, int, int]:
        return (0, 0, 100, 100)

    def test_two_strokes_meeting_at_endpoint(self):
        # Stroke A: left horizontal ending at (0.5, 0.5)
        # Stroke B: starts at (0.5, 0.5), goes right
        # Their last/first pairing has distance 0.
        stroke_a = [(0.0 + 0.025 * i, 0.5) for i in range(20)]  # ends at 0.475 wait
        stroke_a = [(0.025 * i, 0.5) for i in range(21)]  # ends at 0.5
        stroke_b = [(0.5 + 0.025 * i, 0.5) for i in range(21)]  # starts at 0.5
        junctions = ai._detect_junctions([stroke_a, stroke_b], self._bbox())
        self.assertEqual(len(junctions), 1)
        self.assertEqual(junctions[0]["pairing"], "last/first")
        self.assertLess(junctions[0]["dist_px"], 1.0)

    def test_separated_strokes_no_junction(self):
        # Two strokes far apart — no junction within epsilon.
        stroke_a = [(0.0 + 0.025 * i, 0.5) for i in range(20)]
        stroke_b = [(0.5 + 0.025 * i, 0.0) for i in range(20)]
        # dist between stroke_a's last (0.475, 0.5) and stroke_b's first
        # (0.5, 0.0) in 100×100 bbox is ~50 px > 15 px epsilon.
        junctions = ai._detect_junctions([stroke_a, stroke_b], self._bbox())
        self.assertEqual(len(junctions), 0)

    def test_short_strokes_filtered_before_pairing(self):
        # One stroke is 1-cp (dot); should be filtered.
        stroke_a = [(0.0 + 0.025 * i, 0.5) for i in range(20)]
        dot = [(0.5, 0.5)]
        junctions = ai._detect_junctions([stroke_a, dot], self._bbox())
        self.assertEqual(len(junctions), 0)


class TestG4VacuousPass(unittest.TestCase):

    def _bbox(self) -> tuple[int, int, int, int]:
        return (0, 0, 100, 100)

    def test_no_junction_pair(self):
        # Two distant strokes; no junction in either round.
        a = [(0.025 * i, 0.5) for i in range(20)]
        b = [(0.5 + 0.025 * i, 0.0) for i in range(20)]
        result = ai.gate_g4_per_junction(a, b, a, b, self._bbox(),
                                            threshold_deg=2.0)
        self.assertTrue(result["pass"])
        self.assertEqual(result["reason"], "no_junction")

    def test_detection_mismatch_between_rounds(self):
        # round-1 has a junction; round-2 doesn't.
        cand_a = [(0.025 * i, 0.5) for i in range(21)]  # ends at 0.5
        cand_b = [(0.5 + 0.025 * i, 0.5) for i in range(21)]  # starts at 0.5
        ref_a = [(0.025 * i, 0.5) for i in range(21)]
        ref_b = [(0.7 + 0.005 * i, 0.0) for i in range(21)]  # far from ref_a's end
        result = ai.gate_g4_per_junction(cand_a, cand_b, ref_a, ref_b,
                                            self._bbox(), threshold_deg=2.0)
        self.assertTrue(result["pass"])
        self.assertEqual(result["reason"],
                          "junction_detection_mismatch_between_rounds")


class TestG4DriftPass(unittest.TestCase):

    def _bbox(self) -> tuple[int, int, int, int]:
        return (0, 0, 100, 100)

    def test_identical_candidate_reference_zero_drift(self):
        # Stroke A ends at 0.5; stroke B starts at 0.5. Same in both
        # rounds → kink_drift = 0.
        a = [(0.025 * i, 0.5) for i in range(21)]
        b = [(0.5 + 0.025 * i, 0.5) for i in range(21)]
        result = ai.gate_g4_per_junction(a, b, a, b, self._bbox(),
                                            threshold_deg=2.0)
        # A clean identical pair must be a REAL measurement, never a vacuous
        # pass (the old ternary could not fail — audit 2026-09-04).
        self.assertIsNone(result.get("reason"), result)
        self.assertIsNotNone(result["kink_drift_deg"])
        self.assertAlmostEqual(result["kink_drift_deg"], 0.0, places=2)
        self.assertTrue(result["pass"])


class TestG4LetterAggregation(unittest.TestCase):

    def _bbox(self) -> tuple[int, int, int, int]:
        return (0, 0, 100, 100)

    def test_single_stroke_letter_no_pairs(self):
        # 1-stroke letter → no junctions possible.
        a = [(0.025 * i, 0.5) for i in range(20)]
        result = ai.gate_g4([a], [a], self._bbox(), threshold=2.0)
        self.assertTrue(result["pass"])
        self.assertEqual(result["letter_reason"], "no_pairs")
        self.assertEqual(result["per_junction"], [])

    def test_two_stroke_letter_no_junctions_detected(self):
        # Two strokes far apart → no junctions detected though
        # multi-stroke.
        a = [(0.025 * i, 0.5) for i in range(20)]
        b = [(0.5 + 0.025 * i, 0.0) for i in range(20)]
        result = ai.gate_g4([a, b], [a, b], self._bbox(), threshold=2.0)
        self.assertTrue(result["pass"])
        self.assertEqual(result["letter_reason"], "no_junctions_detected")
        self.assertEqual(result["per_junction"], [])

    def test_two_stroke_letter_with_junction_passes(self):
        a = [(0.025 * i, 0.5) for i in range(21)]
        b = [(0.5 + 0.025 * i, 0.5) for i in range(21)]
        result = ai.gate_g4([a, b], [a, b], self._bbox(), threshold=2.0)
        self.assertTrue(result["pass"])
        self.assertIsNone(result["letter_reason"])
        self.assertEqual(len(result["per_junction"]), 1)


if __name__ == "__main__":
    unittest.main()
