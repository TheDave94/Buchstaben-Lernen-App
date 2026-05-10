import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@Suite struct StrokeCalibrationOverlayHelpersTests {

    typealias Calib = StrokeCalibrationOverlay

    // MARK: - rdpSimplify

    @Test func rdp_straightChain_returnsEndpointsOnly() {
        let pts = (0..<50).map { i -> CGPoint in
            CGPoint(x: CGFloat(i) / 49.0, y: 0.5)
        }
        let out = Calib.rdpSimplify(pts, eps: 0.012)
        #expect(out.count == 2)
        #expect(out.first == pts.first)
        #expect(out.last == pts.last)
    }

    @Test func rdp_subPixelJitter_returnsEndpointsOnly() {
        // 1px-at-256 lateral wobble is the Zhang-Suen artifact eps must swallow.
        let jitter: CGFloat = 1.0 / 256.0
        let pts = (0..<60).map { i -> CGPoint in
            let y = 0.5 + (i % 2 == 0 ? jitter : -jitter)
            return CGPoint(x: CGFloat(i) / 59.0, y: y)
        }
        let out = Calib.rdpSimplify(pts, eps: 0.012)
        #expect(out.count == 2)
    }

    @Test func rdp_arcKeepsInteriorPoints() {
        var pts: [CGPoint] = []
        for i in 0..<40 {
            let t = CGFloat(i) / 39.0 * .pi
            pts.append(CGPoint(x: 0.5 + 0.4 * cos(t),
                               y: 0.5 + 0.4 * sin(t)))
        }
        let out = Calib.rdpSimplify(pts, eps: 0.012)
        #expect(out.count > 2)
        #expect(out.count < pts.count)
        #expect(out.first == pts.first)
        #expect(out.last == pts.last)
    }

    @Test func rdp_twoPointInput_returnsUnchanged() {
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]
        let out = Calib.rdpSimplify(pts, eps: 0.01)
        #expect(out == pts)
    }

    @Test func rdp_emptyInput_returnsEmpty() {
        let out = Calib.rdpSimplify([], eps: 0.01)
        #expect(out.isEmpty)
    }

    @Test func rdp_coincidentEndpoints_handlesDegenerate() {
        // Closed loop forces the lenSq≈0 branch (radial fallback).
        var pts: [CGPoint] = []
        for i in 0..<20 {
            let t = CGFloat(i) / 19.0 * 2 * .pi
            pts.append(CGPoint(x: 0.5 + 0.3 * cos(t),
                               y: 0.5 + 0.3 * sin(t)))
        }
        pts[pts.count - 1] = pts[0]
        let out = Calib.rdpSimplify(pts, eps: 0.012)
        #expect(out.count > 2)
        #expect(out.first == pts.first)
        #expect(out.last == pts.last)
    }

    // MARK: - sharpTurnIndices

    @Test func sharpTurn_straightKey_returnsEmpty() {
        let key = (0..<5).map { CGPoint(x: CGFloat($0) * 0.1, y: 0) }
        let breaks = Calib.sharpTurnIndices(in: key,
                                            deflectionAtLeast: .pi / 3)
        #expect(breaks.isEmpty)
    }

    @Test func sharpTurn_rightAngleBend_breaksAtCorner() {
        let key: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1, y: 0),
            CGPoint(x: 1, y: 1),
        ]
        let breaks = Calib.sharpTurnIndices(in: key,
                                            deflectionAtLeast: .pi / 3)
        #expect(breaks == [1])
    }

    @Test func sharpTurn_gentleArc_doesNotBreak() {
        var key: [CGPoint] = []
        for i in 0..<12 {
            let t = CGFloat(i) / 11.0 * .pi
            key.append(CGPoint(x: cos(t), y: sin(t)))
        }
        let breaks = Calib.sharpTurnIndices(in: key,
                                            deflectionAtLeast: .pi / 3)
        #expect(breaks.isEmpty)
    }

    @Test func sharpTurn_obtuseTurn_doesNotBreak() {
        let key: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1, y: 0),
            CGPoint(x: 1 + cos(CGFloat.pi / 6), y: sin(CGFloat.pi / 6)),
        ]
        let breaks = Calib.sharpTurnIndices(in: key,
                                            deflectionAtLeast: .pi / 3)
        #expect(breaks.isEmpty)
    }

    @Test func sharpTurn_uTurn_breaks() {
        let key: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1, y: 0),
            CGPoint(x: 0, y: 0.001),
        ]
        let breaks = Calib.sharpTurnIndices(in: key,
                                            deflectionAtLeast: .pi / 3)
        #expect(breaks == [1])
    }

    @Test func sharpTurn_zeroLengthEdge_skips() {
        let key: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1, y: 1),
        ]
        let breaks = Calib.sharpTurnIndices(in: key,
                                            deflectionAtLeast: .pi / 3)
        #expect(breaks.isEmpty)
    }

    @Test func sharpTurn_shortKey_returnsEmpty() {
        let key: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1, y: 1),
        ]
        let breaks = Calib.sharpTurnIndices(in: key,
                                            deflectionAtLeast: .pi / 3)
        #expect(breaks.isEmpty)
    }
}
