"""Unit tests for G6 (Threshold 6 — T-junction attachment-tangent
drift from reference).

Test cases per `research_data/phase2b_gates/phase2c_design.md` G6
section and the implementation pattern from `test_gate_g4.py`:

- `_host_tangent_at_idx` (LSQ-based tangent on the host stroke at a
  given cp index; window-clipping near endpoints; degenerate input)
- `_unsigned_angle_deg` (signed→unsigned collapse to [0°, 90°])
- `_t_junction_detect` (MID-STROKE-ATTACHMENT classifier:
  5 ≤ host_cp_idx ≤ 94 AND distance ≤ 15 px)
- `gate_g6_per_junction` vacuous-pass states
- `gate_g6` letter-level reasons:
    no_pairs       — single-stroke letter
    no_t_junctions — multi-stroke, no junctions detected
    all_vacuous    — junctions detected but all hit vacuous reasons
- Identity case (both rounds identical) → drift = 0
- Polish drift: small angle change between rounds → measured drift
- Topology change: n_strokes differs between rounds → graceful
- Borderline-band classifier handoff to G4

Run: python3 scripts/tests/test_gate_g6.py
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


# Test bbox: 100×100 raster, normalized [0, 1] → px [0, 100].
BBOX = (0, 0, 100, 100)


def _horizontal_host():
    """Horizontal host stroke spanning x=0..1 at y=0.5 (bbox-rel)."""
    return [(0.0, 0.5), (1.0, 0.5)]


def _vertical_attach_at(x_rel: float, y_start: float = 0.5,
                         y_end: float = 1.0):
    """Vertical attach stroke from (x_rel, y_start) to (x_rel, y_end).
    'First' endpoint sits at y_start; the stroke goes upward from
    there. For T-junction tests with x_rel=0.5, the first endpoint
    lands at host's midpoint."""
    return [(x_rel, y_start), (x_rel, y_end)]


def _diagonal_attach(angle_deg: float, x_rel: float = 0.5,
                      y_start: float = 0.5, length: float = 0.4):
    """Diagonal attach stroke leaving (x_rel, y_start) at `angle_deg`
    above the negative-y axis (so 0° = straight up, 90° = horizontal
    +x, -90° = horizontal -x). Length is bbox-rel arc length."""
    theta = math.radians(angle_deg)
    dx = math.sin(theta) * length
    dy = -math.cos(theta) * length
    return [(x_rel, y_start), (x_rel + dx, y_start + dy)]


class TestHostTangentAtIdx(unittest.TestCase):

    def test_horizontal_host_tangent_at_middle(self):
        # Horizontal polyline; tangent at idx=50 should be parallel
        # to (1, 0) (sign arbitrary).
        poly = [(float(i), 0.0) for i in range(20)]
        t = ai._host_tangent_at_idx(poly, host_idx=10)
        self.assertIsNotNone(t)
        # Either (1, 0) or (-1, 0) — sign is arbitrary.
        self.assertAlmostEqual(abs(t[0]), 1.0, places=4)
        self.assertAlmostEqual(abs(t[1]), 0.0, places=4)

    def test_tangent_near_endpoint_clips_window(self):
        # idx=0 → window clips to [0..5); doesn't crash, returns a
        # tangent computed over the clipped window.
        poly = [(float(i), 0.0) for i in range(20)]
        t = ai._host_tangent_at_idx(poly, host_idx=0)
        self.assertIsNotNone(t)
        self.assertAlmostEqual(abs(t[0]), 1.0, places=4)

    def test_too_short_polyline_returns_none(self):
        # 1-point polyline can't fit a tangent.
        poly = [(0.0, 0.0)]
        t = ai._host_tangent_at_idx(poly, host_idx=0)
        self.assertIsNone(t)


class TestUnsignedAngleDeg(unittest.TestCase):

    def test_perpendicular_is_90(self):
        a = (1.0, 0.0)
        b = (0.0, 1.0)
        self.assertAlmostEqual(ai._unsigned_angle_deg(a, b), 90.0, places=4)

    def test_parallel_is_0(self):
        a = (1.0, 0.0)
        b = (1.0, 0.0)
        self.assertAlmostEqual(ai._unsigned_angle_deg(a, b), 0.0, places=4)

    def test_antiparallel_is_0_unsigned(self):
        a = (1.0, 0.0)
        b = (-1.0, 0.0)
        self.assertAlmostEqual(ai._unsigned_angle_deg(a, b), 0.0, places=4)

    def test_45_degrees(self):
        a = (1.0, 0.0)
        b = (1.0 / math.sqrt(2), 1.0 / math.sqrt(2))
        self.assertAlmostEqual(ai._unsigned_angle_deg(a, b), 45.0, places=3)

    def test_none_input_returns_none(self):
        self.assertIsNone(ai._unsigned_angle_deg(None, (1.0, 0.0)))
        self.assertIsNone(ai._unsigned_angle_deg((1.0, 0.0), None))


class TestTJunctionDetect(unittest.TestCase):

    def test_mid_stroke_attachment_detected(self):
        host = _horizontal_host()
        attach = _vertical_attach_at(0.5)
        det = ai._t_junction_detect(attach, host, attach_at_first=True,
                                      bbox=BBOX)
        self.assertIsNotNone(det)
        # Closest cp on host to (0.5, 0.5) in px = (50, 50) should be
        # mid-polyline (around idx=49 or 50, both equally close).
        self.assertGreaterEqual(det["host_cp_idx"], 5)
        self.assertLessEqual(det["host_cp_idx"], 94)
        self.assertLess(det["dist_px"], 1.0)  # well within ε=15

    def test_endpoint_band_rejection_first(self):
        # Attach near host's first endpoint (host[0] = (0, 50)).
        host = _horizontal_host()
        attach = _vertical_attach_at(0.02)  # endpoint near x=2 px → idx≈2
        det = ai._t_junction_detect(attach, host, attach_at_first=True,
                                      bbox=BBOX)
        # Should be classified as END-TO-END (G4 territory), not
        # MID-STROKE — returns None.
        self.assertIsNone(det)

    def test_endpoint_band_rejection_last(self):
        # Attach near host's last endpoint (host[-1] ≈ (100, 50)).
        host = _horizontal_host()
        attach = _vertical_attach_at(0.98)
        det = ai._t_junction_detect(attach, host, attach_at_first=True,
                                      bbox=BBOX)
        self.assertIsNone(det)

    def test_distance_too_far_rejection(self):
        # Attach far from host.
        host = _horizontal_host()
        attach = [(0.5, 0.0), (0.5, 0.2)]  # first endpoint at y=0 →
        # distance from host (y=0.5) ≈ 50 px > 15 px ε.
        det = ai._t_junction_detect(attach, host, attach_at_first=True,
                                      bbox=BBOX)
        self.assertIsNone(det)

    def test_too_short_attach_returns_none(self):
        host = _horizontal_host()
        attach = [(0.5, 0.5)]  # only 1 cp
        det = ai._t_junction_detect(attach, host, attach_at_first=True,
                                      bbox=BBOX)
        self.assertIsNone(det)


class TestGateG6PerJunctionIdentity(unittest.TestCase):

    def test_perpendicular_t_identity_drift_zero(self):
        host = _horizontal_host()
        attach = _vertical_attach_at(0.5)  # perpendicular T at mid-host
        result = ai.gate_g6_per_junction(
            attach, host, attach, host,
            attach_at_first=True, bbox=BBOX, threshold_deg=4.5)
        self.assertIsNone(result.get("reason"))
        self.assertAlmostEqual(result["kink_drift_deg"], 0.0, places=4)
        self.assertAlmostEqual(result["kink_cand_deg"], 90.0, places=2)
        self.assertAlmostEqual(result["kink_ref_deg"], 90.0, places=2)
        self.assertTrue(result["pass"])

    def test_skewed_t_45deg_identity_drift_zero(self):
        host = _horizontal_host()
        attach = _diagonal_attach(angle_deg=45.0)  # 45° from vertical
        result = ai.gate_g6_per_junction(
            attach, host, attach, host,
            attach_at_first=True, bbox=BBOX, threshold_deg=4.5)
        self.assertIsNone(result.get("reason"))
        self.assertAlmostEqual(result["kink_drift_deg"], 0.0, places=4)
        # Attach goes UP-RIGHT at 45° → outgoing tangent has equal
        # x and y components; unsigned angle with host (horizontal)
        # = 45°.
        self.assertAlmostEqual(result["kink_cand_deg"], 45.0, places=2)
        self.assertTrue(result["pass"])


class TestGateG6PerJunctionDrift(unittest.TestCase):

    def test_polish_drift_small(self):
        # Round 1: 45° attach. Round 2: 40° attach. Drift ≈ 5°.
        host = _horizontal_host()
        attach_r1 = _diagonal_attach(angle_deg=45.0)
        attach_r2 = _diagonal_attach(angle_deg=40.0)
        result = ai.gate_g6_per_junction(
            attach_r2, host, attach_r1, host,
            attach_at_first=True, bbox=BBOX, threshold_deg=4.5)
        self.assertIsNone(result.get("reason"))
        # Drift is the change in unsigned attachment angle.
        self.assertGreater(result["kink_drift_deg"], 3.0)
        self.assertLess(result["kink_drift_deg"], 7.0)

    def test_drift_above_threshold_fails(self):
        # 45° → 30° = 15° drift, well above 4.5° threshold.
        host = _horizontal_host()
        attach_r1 = _diagonal_attach(angle_deg=45.0)
        attach_r2 = _diagonal_attach(angle_deg=30.0)
        result = ai.gate_g6_per_junction(
            attach_r2, host, attach_r1, host,
            attach_at_first=True, bbox=BBOX, threshold_deg=4.5)
        self.assertIsNone(result.get("reason"))
        self.assertGreater(result["kink_drift_deg"], 4.5)
        self.assertFalse(result["pass"])


class TestGateG6PerJunctionVacuous(unittest.TestCase):

    def test_no_t_junction_either_round(self):
        # Both rounds: attach far from host. No junction.
        host = _horizontal_host()
        attach = [(0.5, 0.0), (0.5, 0.2)]  # far from y=0.5 host
        result = ai.gate_g6_per_junction(
            attach, host, attach, host,
            attach_at_first=True, bbox=BBOX, threshold_deg=4.5)
        self.assertEqual(result["reason"], "no_t_junction")
        self.assertTrue(result["pass"])

    def test_detection_mismatch_between_rounds(self):
        # Round 1: real T-junction mid-host. Round 2: attach moved to
        # endpoint band (G4 territory). Detection differs → vacuous.
        host = _horizontal_host()
        attach_r1 = _vertical_attach_at(0.5)   # mid-host → G6 detects
        attach_r2 = _vertical_attach_at(0.02)  # endpoint band → G4
        result = ai.gate_g6_per_junction(
            attach_r2, host, attach_r1, host,
            attach_at_first=True, bbox=BBOX, threshold_deg=4.5)
        self.assertEqual(result["reason"],
                          "t_junction_detection_mismatch_between_rounds")
        self.assertFalse(result["pass"])  # a lost T-junction FAILS (audit 2026-09-04)


class TestGateG6Letter(unittest.TestCase):

    def test_two_stroke_perpendicular_t_identity(self):
        # Letter with one clean T-junction; both rounds identical.
        host = _horizontal_host()
        attach = _vertical_attach_at(0.5)
        strokes = [host, attach]
        result = ai.gate_g6(strokes, strokes, bbox=BBOX, threshold=4.5)
        self.assertTrue(result["pass"])
        self.assertIsNone(result.get("letter_reason"))
        # One T-junction detected and measured: attach[0] meets host
        # mid-stroke. The reverse direction (host endpoints against
        # attach) should yield no_t_junction (skipped).
        self.assertGreaterEqual(result["n_t_junctions_measured"], 1)
        self.assertAlmostEqual(result["letter_score"], 0.0, places=4)

    def test_single_stroke_no_pairs(self):
        # Single stroke → no pairs to iterate → no_pairs.
        host = _horizontal_host()
        strokes = [host]
        result = ai.gate_g6(strokes, strokes, bbox=BBOX, threshold=4.5)
        self.assertTrue(result["pass"])
        self.assertEqual(result["letter_reason"], "no_pairs")
        self.assertEqual(result["n_pairs_iterated"], 0)
        self.assertEqual(result["n_t_junctions_detected"], 0)

    def test_no_t_junctions_multi_stroke(self):
        # Two strokes, far apart, no possible T-junction.
        s1 = [(0.0, 0.1), (1.0, 0.1)]
        s2 = [(0.0, 0.9), (1.0, 0.9)]
        strokes = [s1, s2]
        result = ai.gate_g6(strokes, strokes, bbox=BBOX, threshold=4.5)
        self.assertTrue(result["pass"])
        self.assertEqual(result["letter_reason"], "no_t_junctions")
        self.assertGreater(result["n_pairs_iterated"], 0)
        self.assertEqual(result["n_t_junctions_detected"], 0)

    def test_borderline_band_g4_handoff(self):
        # Attach hits host at idx=2 (within band 5) → classified as
        # END-TO-END (G4 territory) → G6 sees no T-junction.
        host = _horizontal_host()
        attach = _vertical_attach_at(0.02)  # near host's first endpoint
        strokes = [host, attach]
        result = ai.gate_g6(strokes, strokes, bbox=BBOX, threshold=4.5)
        self.assertTrue(result["pass"])
        self.assertEqual(result["letter_reason"], "no_t_junctions")
        self.assertEqual(result["n_t_junctions_detected"], 0)

    def test_topology_change_graceful(self):
        # Round 1: 2 strokes (host + perpendicular T attach).
        # Round 2: 3 strokes (same 2 + extra unrelated stroke far away).
        # Iteration caps at min(2, 3) = 2; the shared T-junction measures
        # cleanly; the extra stroke in round 2 is not addressed.
        host = _horizontal_host()
        attach = _vertical_attach_at(0.5)
        extra = [(0.0, 0.05), (0.05, 0.05)]  # tiny far-away segment
        r1 = [host, attach]
        r2 = [host, attach, extra]
        result = ai.gate_g6(r2, r1, bbox=BBOX, threshold=4.5)
        # Should still pass; the shared junction has 0° drift.
        self.assertTrue(result["pass"])
        self.assertGreaterEqual(result["n_t_junctions_measured"], 1)

    def test_all_vacuous_letter_reason(self):
        # Round 1: clean perpendicular T. Round 2: attach moved to
        # host's endpoint band so detection differs. Only junction
        # vacuous-passes → letter_reason = all_vacuous.
        host = _horizontal_host()
        attach_r1 = _vertical_attach_at(0.5)
        attach_r2 = _vertical_attach_at(0.02)  # endpoint band
        r1 = [host, attach_r1]
        r2 = [host, attach_r2]
        result = ai.gate_g6(r2, r1, bbox=BBOX, threshold=4.5)
        # The only junction changed topology between rounds: that is a
        # failure, not an all-vacuous pass (audit 2026-09-04).
        self.assertFalse(result["pass"])
        self.assertEqual(result["letter_reason"], "t_junction_topology_changed")
        self.assertGreater(result["n_t_junctions_detected"], 0)
        self.assertEqual(result["n_t_junctions_measured"], 0)


if __name__ == "__main__":
    unittest.main()
