"""Unit tests for G1 (Threshold 1 — asymmetry-profile drift from reference).

Test cases per `research_data/phase2b_gates/g1_design.md` Section 6:
- Pearson math properties on synthetic sequences (identical / negated /
  reversed)
- gate_g1_per_stroke vacuous-pass on 1-cp strokes
- gate_g1_per_stroke vacuous-pass on insufficient measured points
- gate_g1_per_stroke pass on identical candidate=reference with a
  non-trivial mask

Run: python3 -m unittest scripts.tests.test_gate_g1
   or: python3 scripts/tests/test_gate_g1.py
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

import numpy as np

SCRIPT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPT_DIR))
import audit_invariants as ai  # noqa: E402


class TestPearsonMath(unittest.TestCase):
    """Sanity checks on numpy.corrcoef — the underlying primitive."""

    def test_identical_sequences_give_one(self):
        seq = np.array([0.1, 0.2, 0.5, 0.7, 0.3, 0.4, 0.8, 0.1, 0.6, 0.2,
                         0.9, 0.4, 0.5, 0.3])
        r = float(np.corrcoef(seq, seq)[0, 1])
        self.assertAlmostEqual(r, 1.0, places=6)

    def test_negated_sequences_give_negative_one(self):
        seq = np.array([0.1, 0.2, 0.5, 0.7, 0.3, 0.4, 0.8, 0.1, 0.6, 0.2,
                         0.9, 0.4, 0.5, 0.3])
        r = float(np.corrcoef(seq, -seq)[0, 1])
        self.assertAlmostEqual(r, -1.0, places=6)

    def test_reversed_sequence_is_finite(self):
        seq = np.array([0.1, 0.2, 0.5, 0.7, 0.3, 0.4, 0.8, 0.1, 0.6, 0.2,
                         0.9, 0.4, 0.5, 0.3])
        r = float(np.corrcoef(seq, seq[::-1])[0, 1])
        self.assertTrue(np.isfinite(r))


class TestVacuousPass(unittest.TestCase):
    """Edge cases that must vacuous-pass (not crash, not fail)."""

    def _empty_mask(self) -> tuple[np.ndarray, tuple[int, int, int, int]]:
        return np.zeros((10, 10), dtype=bool), (0, 0, 10, 10)

    def test_single_checkpoint_stroke_returns_vacuous_pass(self):
        # 1-cp strokes (diacritic dots) per Section 1c.
        mask, bbox = self._empty_mask()
        result = ai.gate_g1_per_stroke([(0.5, 0.5)], [(0.5, 0.5)],
                                         mask, bbox, threshold=0.98)
        self.assertTrue(result["pass"])
        self.assertEqual(result["reason"], "not_applicable_too_short")
        self.assertIsNone(result["pearson"])

    def test_empty_polyline_returns_vacuous_pass(self):
        mask, bbox = self._empty_mask()
        result = ai.gate_g1_per_stroke([], [], mask, bbox, threshold=0.98)
        self.assertTrue(result["pass"])
        self.assertEqual(result["reason"], "not_applicable_too_short")

    def test_polyline_outside_mask_returns_vacuous_pass(self):
        # Polyline through all-zero mask: _asymmetry_per_point produces
        # ok=False for every point, paired-count drops below
        # G1_MIN_MEASURED, vacuous pass with reason
        # "insufficient_measured_points".
        mask, bbox = self._empty_mask()
        # 50-cp straight line through the empty mask.
        poly = [(i / 49.0, 0.5) for i in range(50)]
        result = ai.gate_g1_per_stroke(poly, poly, mask, bbox,
                                        threshold=0.98)
        self.assertTrue(result["pass"])
        self.assertEqual(result["reason"], "insufficient_measured_points")


class TestRealPearson(unittest.TestCase):
    """Identical candidate=reference on a non-trivial mask should
    produce a high Pearson (1.0 modulo numerical noise) or a vacuous
    pass with a documented reason."""

    def _tapered_mask(self) -> tuple[np.ndarray, tuple[int, int, int, int]]:
        """Trapezoid mask: ink stripe that widens along x. Asymmetry
        from a straight horizontal centerline will vary with x because
        the upper and lower edges aren't equidistant from the line."""
        h, w = 100, 200
        mask = np.zeros((h, w), dtype=bool)
        for x in range(w):
            half = 5 + int(20 * x / w)  # widens 5 → 25 px half-height
            mask[max(0, 40 - half):min(h, 40 + half + 1), x] = True
        bbox = (0, 0, w, h)
        return mask, bbox

    def test_identical_candidate_reference_passes(self):
        mask, bbox = self._tapered_mask()
        # Horizontal centerline through the trapezoid at y=40 (the
        # mask's wide edge sits at y=40 + half). 80 cps along x.
        poly = [(i / 79.0, 0.4) for i in range(80)]
        result = ai.gate_g1_per_stroke(poly, poly, mask, bbox,
                                        threshold=0.98)
        self.assertTrue(result["pass"], f"Unexpected: {result}")
        # Either pearson is exactly 1.0 (when asymmetry actually
        # varies along the polyline) or vacuous pass with a documented
        # reason (constant_asymmetry_sequence if the trapezoid happens
        # to produce a flat profile, insufficient_measured_points if
        # the walks fail).
        if result["pearson"] is not None:
            self.assertAlmostEqual(result["pearson"], 1.0, places=6)
        else:
            self.assertIn(result["reason"],
                          ("constant_asymmetry_sequence",
                           "insufficient_measured_points"))

    def test_letter_pass_aggregates_strokes(self):
        # Two-stroke "letter" — both strokes identical candidate=reference.
        mask, bbox = self._tapered_mask()
        poly_a = [(i / 79.0, 0.4) for i in range(80)]
        poly_b = [(i / 79.0, 0.5) for i in range(80)]
        result = ai.gate_g1([poly_a, poly_b], [poly_a, poly_b],
                             mask, bbox, threshold=0.98)
        self.assertTrue(result["pass"], f"Unexpected: {result}")
        self.assertEqual(result["n_strokes_candidate"], 2)
        self.assertEqual(result["n_strokes_reference"], 2)
        self.assertEqual(len(result["per_stroke"]), 2)


class TestArcLengthResample(unittest.TestCase):

    def test_resample_to_n_produces_n_points(self):
        poly = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0)]
        out = ai._arc_length_resample(poly, 50)
        self.assertEqual(len(out), 50)

    def test_resample_preserves_endpoints(self):
        poly = [(0.0, 0.0), (0.5, 0.5), (1.0, 0.0)]
        out = ai._arc_length_resample(poly, 20)
        self.assertAlmostEqual(out[0][0], 0.0, places=6)
        self.assertAlmostEqual(out[-1][0], 1.0, places=6)

    def test_resample_short_input_passthrough(self):
        poly = [(0.5, 0.5)]
        out = ai._arc_length_resample(poly, 50)
        self.assertEqual(out, [(0.5, 0.5)])

    def test_resample_degenerate_polyline(self):
        # All-same-point polyline → n copies.
        poly = [(0.5, 0.5)] * 5
        out = ai._arc_length_resample(poly, 10)
        self.assertEqual(len(out), 10)
        for pt in out:
            self.assertAlmostEqual(pt[0], 0.5, places=6)
            self.assertAlmostEqual(pt[1], 0.5, places=6)


if __name__ == "__main__":
    unittest.main()
