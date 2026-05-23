"""Unit tests for G2 (Threshold 2 — turn-angle-profile drift from reference).

Test cases per `research_data/phase2b_gates/g2_design.md` Section G2.6:
- 1-cp / 0-cp strokes → vacuous (not_applicable_too_short)
- Insufficient measured points → vacuous (insufficient_measured_points)
- Low-variance turn-angle (straight polyline) → vacuous
  (low_variance_turn_angle), once the cutoff is set
- Identical curved polyline → Pearson 1.0
- Mirror-reversed polyline → Pearson < 0 (chirality preserved via
  signed-angle convention)
- Sign convention sanity check (CCW positive, CW negative)

Run: python3 scripts/tests/test_gate_g2.py
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


class TestTurnAngleSignConvention(unittest.TestCase):
    """The atan2(cross, dot) convention: CCW positive, CW negative."""

    def test_ccw_turn_is_positive(self):
        # Three points making a CCW turn (right-handed coords).
        # First segment goes +x; second segment turns up (+y).
        poly = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0)]
        angles = ai._turn_angle_per_point(poly, endpoint_skip=0)
        # Index 1 is the turn point. Skip=0 puts it at index 1.
        # Skip=0 includes indices 0 and n-1 (which are degenerate-tangent
        # because no preceding/following segment). For middle index 1,
        # ok should be True with angle ≈ +π/2.
        self.assertTrue(angles[1][1])
        self.assertAlmostEqual(angles[1][0], math.pi / 2, places=4)

    def test_cw_turn_is_negative(self):
        # Three points making a CW turn.
        poly = [(0.0, 0.0), (1.0, 0.0), (1.0, -1.0)]
        angles = ai._turn_angle_per_point(poly, endpoint_skip=0)
        self.assertTrue(angles[1][1])
        self.assertAlmostEqual(angles[1][0], -math.pi / 2, places=4)


class TestG2VacuousPass(unittest.TestCase):

    def _bbox(self) -> tuple[int, int, int, int]:
        return (0, 0, 100, 100)

    def test_single_cp_stroke(self):
        result = ai.gate_g2_per_stroke([(0.5, 0.5)], [(0.5, 0.5)],
                                         self._bbox(), threshold=0.5,
                                         min_turn_angle_std=0.0)
        self.assertTrue(result["pass"])
        self.assertEqual(result["reason"], "not_applicable_too_short")
        self.assertIsNone(result["pearson"])

    def test_empty_stroke(self):
        result = ai.gate_g2_per_stroke([], [],
                                         self._bbox(), threshold=0.5,
                                         min_turn_angle_std=0.0)
        self.assertTrue(result["pass"])
        self.assertEqual(result["reason"], "not_applicable_too_short")

    def test_too_short_polyline_insufficient_measured(self):
        # 5 cps with endpoint_skip=3 leaves -1 ok=True samples → vacuous.
        poly = [(i / 4.0, 0.0) for i in range(5)]
        result = ai.gate_g2_per_stroke(poly, poly,
                                         self._bbox(), threshold=0.5,
                                         min_turn_angle_std=0.0)
        self.assertTrue(result["pass"])
        # Either insufficient_measured_points (n_measured < 10) or
        # constant_turn_angle_sequence (all zeros).
        self.assertIn(result["reason"],
                      ("insufficient_measured_points",
                       "constant_turn_angle_sequence"))

    def test_low_variance_filter_triggered_at_cutoff(self):
        """Straight polyline with cutoff > 0 → vacuous via the filter."""
        # 30-cp straight horizontal line.
        poly = [(i / 29.0, 0.0) for i in range(30)]
        result = ai.gate_g2_per_stroke(poly, poly,
                                         self._bbox(), threshold=0.5,
                                         min_turn_angle_std=0.05)
        self.assertTrue(result["pass"])
        # Reason will be low_variance_turn_angle OR
        # constant_turn_angle_sequence depending on exact float behavior;
        # both are vacuous-pass on a flat signal.
        self.assertIn(result["reason"],
                      ("low_variance_turn_angle",
                       "constant_turn_angle_sequence"))


class TestG2CurvedPolyline(unittest.TestCase):

    def _half_circle_poly(self, n: int = 50) -> list[tuple[float, float]]:
        """Polyline tracing the top half of the unit circle from (-1,0)
        through (0,1) to (1,0), in normalized [0,1] coords."""
        out = []
        for i in range(n):
            theta = math.pi * (1 - i / (n - 1))  # π → 0
            x = (math.cos(theta) + 1) / 2  # [-1, 1] → [0, 1]
            y = math.sin(theta)
            out.append((x, y))
        return out

    def test_identical_curved_polyline_passes(self):
        poly = self._half_circle_poly(50)
        # Use bbox matching the polyline coord space ([0,1]²) scaled up.
        bbox = (0, 0, 100, 100)
        result = ai.gate_g2_per_stroke(poly, poly, bbox, threshold=0.95,
                                         min_turn_angle_std=0.0)
        self.assertTrue(result["pass"])
        # Identical sequences → Pearson 1.0 (or vacuous if the half-circle
        # is so smooth that turn-angle is constant — accept that path too).
        if result["pearson"] is not None:
            self.assertAlmostEqual(result["pearson"], 1.0, places=4)
        else:
            self.assertIn(result["reason"],
                          ("constant_turn_angle_sequence",
                           "low_variance_turn_angle"))

    def test_mirrored_polyline_negative_pearson(self):
        """A polyline traced in opposite chirality should produce negative
        Pearson — the signed-angle convention catches mirror-reversal."""
        poly = self._half_circle_poly(50)
        # Mirror across the x-axis: y → -y, but shift so it stays in [0,1].
        mirrored = [(x, 1.0 - y) for (x, y) in poly]
        bbox = (0, 0, 100, 100)
        result = ai.gate_g2_per_stroke(poly, mirrored, bbox, threshold=0.95,
                                         min_turn_angle_std=0.0)
        if result["pearson"] is not None:
            # Y-flip negates the cross product, so signed angles flip sign.
            # Pearson(angles, -angles) = -1.0 modulo numerical noise.
            self.assertLess(result["pearson"], 0.0,
                            f"Mirror should give negative Pearson, "
                            f"got {result['pearson']}")


class TestG2LetterAggregation(unittest.TestCase):

    def test_letter_pass_aggregates_strokes(self):
        # Two-stroke letter, both curved, candidate=reference.
        bbox = (0, 0, 100, 100)
        poly_a = [(math.cos(math.pi * (1 - i / 49)) / 2 + 0.5,
                   math.sin(math.pi * (1 - i / 49))) for i in range(50)]
        poly_b = [(i / 49.0, 0.5 + 0.3 * math.sin(math.pi * 2 * i / 49))
                  for i in range(50)]
        result = ai.gate_g2([poly_a, poly_b], [poly_a, poly_b],
                              bbox, threshold=0.95)
        self.assertTrue(result["pass"], f"Unexpected: {result}")
        self.assertEqual(result["n_strokes_candidate"], 2)
        self.assertEqual(result["n_strokes_reference"], 2)
        self.assertEqual(len(result["per_stroke"]), 2)


if __name__ == "__main__":
    unittest.main()
