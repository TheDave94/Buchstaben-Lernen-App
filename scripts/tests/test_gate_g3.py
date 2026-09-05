"""Unit tests for G3 (Threshold 3 — perpendicular-deviation conformance
gate for straight strokes).

Test cases per `research_data/phase2b_gates/g3_design.md`:
- 1-cp / 0-cp strokes → vacuous (not_applicable_too_short)
- Non-straight reference → vacuous (not_applicable_not_straight)
- Insufficient measured points → vacuous (insufficient_measured_points)
- Straight polyline (perfectly straight) → deviation 0; passes
- Bent polyline → deviation > 0; fails if > threshold
- Mirror/reflection of a polyline produces the same deviation
  (deviation is unsigned, line orientation independent)

Run: python3 scripts/tests/test_gate_g3.py
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


class TestPerpendicularDeviation(unittest.TestCase):
    """Direct tests of the _perpendicular_deviation primitive."""

    def test_collinear_points_give_zero(self):
        # Points exactly on a horizontal line.
        poly = [(float(i), 0.0) for i in range(20)]
        dev, n = ai._perpendicular_deviation(poly)
        self.assertAlmostEqual(dev, 0.0, places=6)
        self.assertEqual(n, 20)

    def test_diagonal_collinear_gives_zero(self):
        # Points on a diagonal — exercises LSQ's orientation-independence.
        poly = [(float(i), float(i)) for i in range(20)]
        dev, n = ai._perpendicular_deviation(poly)
        self.assertAlmostEqual(dev, 0.0, places=6)

    def test_single_outlier_gives_measurable_but_absorbed_deviation(self):
        # LSQ fits absorb single outliers: the best-fit line tilts
        # toward the outlier, so the measured perpendicular distance
        # is smaller than the raw offset. Test that the deviation is
        # measurable (> 0) but well below the raw offset magnitude.
        # (The LSQ behavior is what we want for G3: a single noisy cp
        # doesn't fail the gate; only sustained deviation does.)
        poly = [(float(i), 0.0) for i in range(19)] + [(19.0, 5.0)]
        dev, n = ai._perpendicular_deviation(poly)
        self.assertGreater(dev, 0.1)   # measurable signal
        self.assertLess(dev, 5.0)      # but less than raw offset (LSQ absorbed)

    def test_mirror_reflection_gives_same_deviation(self):
        # A polyline and its y-flipped reflection should have identical
        # perpendicular deviation (the LSQ line flips with the points).
        poly = [(float(i), 0.5 * (i - 10) ** 2 / 10) for i in range(20)]
        mirror = [(x, -y) for (x, y) in poly]
        dev_a, _ = ai._perpendicular_deviation(poly)
        dev_b, _ = ai._perpendicular_deviation(mirror)
        self.assertAlmostEqual(dev_a, dev_b, places=6)


class TestG3VacuousPass(unittest.TestCase):

    def _bbox(self) -> tuple[int, int, int, int]:
        return (0, 0, 100, 100)

    def test_single_cp_stroke(self):
        result = ai.gate_g3_per_stroke([(0.5, 0.5)], [(0.5, 0.5)],
                                         self._bbox(), threshold=5.0)
        self.assertTrue(result["pass"])
        self.assertEqual(result["reason"], "not_applicable_too_short")
        self.assertIsNone(result["deviation_px"])

    def test_sharp_corner_reference_vacuous_via_max(self):
        # Reference polyline with a sharp 90° bend in the middle.
        # The per-segment angle at the bend exceeds π/12, so the
        # max-criterion triggers vacuous-as-not-straight.
        ref = [(0.1 + 0.02 * i, 0.5) for i in range(20)]  # right
        ref += [(0.5, 0.5 - 0.02 * i) for i in range(20)]  # then down
        candidate = ref  # same; gate checks reference straightness
        result = ai.gate_g3_per_stroke(candidate, ref, self._bbox(),
                                         threshold=5.0)
        self.assertTrue(result["pass"])
        self.assertEqual(result["reason"], "not_applicable_not_straight")
        self.assertGreaterEqual(result["max_ref_angle"],
                                  ai.G3_STRAIGHTNESS_MAX_ANGLE)

    def test_smooth_long_curve_reference_vacuous_via_signed_cum(self):
        """Reference polyline tracing a smooth L-curve where per-segment
        angles stay small (max + p95 both below thresholds) but
        cumulative net direction change exceeds π/12. Should
        vacuous-pass via the signed-cumulative criterion.

        Mirrors Y s0 / Y s1 / g s1 behavior in the full corpus —
        smooth curves whose per-segment angles fall below max/p95
        but accumulate ~30° net direction change. Added 2026-05-24
        during G5 verification."""
        # 60-cp gentle arc: ~30° total turn distributed across the
        # length. Per-segment ≈ 0.009 rad (well under p95 cutoff).
        n = 60
        ref = []
        for i in range(n):
            angle = (math.pi / 6) * (i / (n - 1))  # 0 → π/6 (30°)
            x = 0.2 + 0.6 * math.cos(angle - math.pi / 12)
            y = 0.5 + 0.6 * math.sin(angle - math.pi / 12)
            ref.append((x, y))
        candidate = ref
        result = ai.gate_g3_per_stroke(candidate, ref, self._bbox(),
                                         threshold=5.0)
        self.assertTrue(result["pass"])
        self.assertEqual(result["reason"], "not_applicable_not_straight")
        # Diagnostic: signed_cum triggered, NOT max or p95.
        self.assertLess(result["max_ref_angle"],
                         ai.G3_STRAIGHTNESS_MAX_ANGLE)
        self.assertLess(result["p95_ref_angle"],
                         ai.G3_STRAIGHTNESS_P95_ANGLE)
        self.assertGreaterEqual(abs(result["signed_cum_ref"]),
                                  ai.G3_STRAIGHTNESS_SIGNED_CUM_RAD)

    def test_straight_polyline_with_zero_mean_noise_still_passes(self):
        """A truly straight polyline with random per-segment noise
        should still classify as STRAIGHT — signed cumulative
        cancels zero-mean noise to ~0, demonstrating N-invariance."""
        import random
        random.seed(42)
        # Horizontal line with sub-pixel cp jitter
        n = 60
        poly = []
        for i in range(n):
            x = i / (n - 1)
            y = 0.5 + random.gauss(0, 0.002)  # zero-mean noise
            poly.append((x, y))
        result = ai.gate_g3_per_stroke(poly, poly, self._bbox(),
                                         threshold=10.0)
        # Zero-mean noise must NOT knock the stroke out of the STRAIGHT
        # class: the assertion used to sit inside an `if` that is false
        # on the correct path, so the test asserted nothing when G3
        # behaved (audit 2026-09-04).
        self.assertNotEqual(result.get("reason"), "not_applicable_not_straight",
                            f"zero-mean jitter classified as not straight: {result}")
        self.assertTrue(result["pass"], result)
        self.assertLess(abs(result.get("signed_cum_ref", 0.0)),
                        ai.G3_STRAIGHTNESS_SIGNED_CUM_RAD)

    def test_sustained_curvature_reference_vacuous_via_p95(self):
        # Reference polyline tracing a tight arc with per-segment
        # turn-angles ~0.15 rad sustained. Each per-segment angle is
        # below π/12 (so the max-criterion passes), but the p95
        # exceeds the p95-threshold of 0.1 rad → vacuous.
        # Mirrors D s1 / bowl behavior in the 2026-05-22 corpus.
        ref = []
        for i in range(50):
            angle = 0.15 * i  # cumulative angle along the arc
            x = 0.3 + 0.2 * math.cos(angle)
            y = 0.5 + 0.2 * math.sin(angle)
            ref.append((x, y))
        candidate = ref
        result = ai.gate_g3_per_stroke(candidate, ref, self._bbox(),
                                         threshold=5.0)
        self.assertTrue(result["pass"])
        self.assertEqual(result["reason"], "not_applicable_not_straight")
        # Diagnostic: confirm the p95 trigger fired, not the max trigger.
        self.assertLess(result["max_ref_angle"],
                         ai.G3_STRAIGHTNESS_MAX_ANGLE)
        self.assertGreaterEqual(result["p95_ref_angle"],
                                  ai.G3_STRAIGHTNESS_P95_ANGLE)

    def test_too_few_cps_after_skip(self):
        # Force the insufficient-measured branch by passing a small
        # n_resample. n_resample=15 with endpoint_skip=3 leaves 9
        # measured cps (15 - 2×3 = 9), below n_min_measured=10.
        poly = [(i / 19.0, 0.5) for i in range(20)]
        result = ai.gate_g3_per_stroke(poly, poly, self._bbox(),
                                         threshold=5.0,
                                         n_resample=15)
        self.assertTrue(result["pass"])
        self.assertEqual(result["reason"], "insufficient_measured_points")


class TestG3StraightStroke(unittest.TestCase):
    """G3 on an actually-straight stroke should produce small deviation
    and pass with a reasonable threshold."""

    def test_perfectly_straight_polyline_passes(self):
        # 50 cps along the horizontal at y=0.5 in [0, 1] coords.
        # In a 100×100 bbox, that's at pixel y=50, x from 0 to 100.
        bbox = (0, 0, 100, 100)
        poly = [(i / 49.0, 0.5) for i in range(50)]
        result = ai.gate_g3_per_stroke(poly, poly, bbox, threshold=1.0)
        # Reference is straight (turn-angle 0); deviation 0.
        if result.get("reason"):
            self.fail(f"Unexpected vacuous: {result['reason']}")
        self.assertAlmostEqual(result["deviation_px"], 0.0, places=4)
        self.assertTrue(result["pass"])

    def test_bent_polyline_high_deviation(self):
        # Bent in the middle: triangle wave. The bend is small enough
        # that turn-angle stays below the straightness threshold.
        bbox = (0, 0, 100, 100)
        poly = []
        for i in range(50):
            t = i / 49.0
            # Two flat halves with a small bump in the middle.
            if 0.45 < t < 0.55:
                y = 0.55  # ~5 px above the baseline at y=50
            else:
                y = 0.5
            poly.append((t, y))
        result = ai.gate_g3_per_stroke(poly, poly, bbox, threshold=5.0)
        # The early `return` on "not_applicable_not_straight" let a G3 that
        # classifies everything as not-straight pass this test green
        # (audit 2026-09-04). A ~5 px bump on a 100 px baseline is a
        # straight stroke with a measurable deviation — assert both.
        self.assertNotEqual(result.get("reason"), "not_applicable_not_straight",
                            f"the bump must not disqualify the stroke: {result}")
        self.assertIsNotNone(result["deviation_px"])
        self.assertGreater(result["deviation_px"], 1.0)


class TestG3LetterAggregation(unittest.TestCase):

    def test_letter_pass_aggregates_strokes(self):
        # Two-stroke "letter" with both strokes straight and identical.
        bbox = (0, 0, 100, 100)
        poly_a = [(i / 49.0, 0.5) for i in range(50)]
        poly_b = [(i / 49.0, 0.3) for i in range(50)]
        result = ai.gate_g3([poly_a, poly_b], [poly_a, poly_b],
                              bbox, threshold=1.0)
        self.assertTrue(result["pass"], f"Unexpected: {result}")
        self.assertEqual(result["n_strokes_candidate"], 2)
        self.assertEqual(result["n_strokes_reference"], 2)
        self.assertEqual(len(result["per_stroke"]), 2)


if __name__ == "__main__":
    unittest.main()
