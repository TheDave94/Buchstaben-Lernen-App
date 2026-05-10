import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@Suite struct GlyphSkeletonRidgeTests {

    typealias Sk = GlyphSkeleton

    // MARK: - chamferDistanceTransform

    @Test func dt_horizontalStripe_peaksAtCenterRow() {
        let rows = 9, cols = 12
        var mask = [[Bool]](repeating: [Bool](repeating: false, count: cols),
                            count: rows)
        for r in 2..<7 { for c in 1..<(cols - 1) { mask[r][c] = true } }
        let dt = Sk.chamferDistanceTransform(mask, rows: rows, cols: cols)
        // Center row 4 should have higher DT than its neighbours;
        // boundary rows have DT=0.
        for c in 3..<(cols - 3) {
            #expect(dt[4][c] > dt[3][c])
            #expect(dt[4][c] > dt[5][c])
        }
        for c in 0..<cols {
            #expect(dt[1][c] == 0, "row 1 is exterior")
            #expect(dt[7][c] == 0, "row 7 is exterior")
        }
    }

    @Test func dt_exteriorPixelsAreZero() {
        let mask = [[Bool]](repeating: [Bool](repeating: false, count: 5),
                            count: 5)
        let dt = Sk.chamferDistanceTransform(mask, rows: 5, cols: 5)
        for r in 0..<5 {
            for c in 0..<5 {
                #expect(dt[r][c] == 0)
            }
        }
    }

    // MARK: - strictLocalMaxRidge

    @Test func ridge_oddWidthStripe_givesSinglePixelCenterline() {
        // 5-row interior horizontal stripe → 1-row centerline.
        let rows = 9, cols = 14
        var mask = [[Bool]](repeating: [Bool](repeating: false, count: cols),
                            count: rows)
        for r in 2..<7 { for c in 1..<(cols - 1) { mask[r][c] = true } }
        let dt = Sk.chamferDistanceTransform(mask, rows: rows, cols: cols)
        let sk = Sk.strictLocalMaxRidge(dt: dt, glyphMask: mask,
                                        rows: rows, cols: cols)
        // For a 5-row interior, the center row is r=4. Strict-local-max
        // selects only that row.
        for r in 0..<rows {
            for c in 0..<cols {
                if sk[r][c] {
                    #expect(r == 4,
                            "skeleton must be on center row, got r=\(r), c=\(c)")
                }
            }
        }
        var centerCount = 0
        for c in 0..<cols where sk[4][c] { centerCount += 1 }
        #expect(centerCount > 0,
                "centerline must contain at least one pixel")
    }

    @Test func ridge_evenWidthStripe_centerlineIsAtMostTwoPixelsThick() {
        // 4-row interior stripe → 2-row plateau, so the ridge is 2 rows
        // wide (Zhang-Suen post-thin handles this in production).
        let rows = 8, cols = 14
        var mask = [[Bool]](repeating: [Bool](repeating: false, count: cols),
                            count: rows)
        for r in 2..<6 { for c in 1..<(cols - 1) { mask[r][c] = true } }
        let dt = Sk.chamferDistanceTransform(mask, rows: rows, cols: cols)
        let sk = Sk.strictLocalMaxRidge(dt: dt, glyphMask: mask,
                                        rows: rows, cols: cols)
        for r in 0..<rows {
            for c in 0..<cols {
                if sk[r][c] {
                    #expect(r == 3 || r == 4,
                            "skeleton must be on center rows 3/4, got r=\(r)")
                }
            }
        }
    }

    @Test func ridge_emptyMask_givesEmptySkeleton() {
        let mask = [[Bool]](repeating: [Bool](repeating: false, count: 5),
                            count: 5)
        let dt = Sk.chamferDistanceTransform(mask, rows: 5, cols: 5)
        let sk = Sk.strictLocalMaxRidge(dt: dt, glyphMask: mask,
                                        rows: 5, cols: 5)
        for r in 0..<5 {
            for c in 0..<5 {
                #expect(!sk[r][c])
            }
        }
    }

    @Test func ridge_squareBlock_marksDTPeak() {
        // Solid 7x7 interior block. DT peaks at the center; strict-max
        // selects at least the centermost pixel.
        let rows = 9, cols = 9
        var mask = [[Bool]](repeating: [Bool](repeating: false, count: cols),
                            count: rows)
        for r in 1..<8 { for c in 1..<8 { mask[r][c] = true } }
        let dt = Sk.chamferDistanceTransform(mask, rows: rows, cols: cols)
        let sk = Sk.strictLocalMaxRidge(dt: dt, glyphMask: mask,
                                        rows: rows, cols: cols)
        // The geometric center (4,4) must be on the skeleton.
        #expect(sk[4][4])
    }

    @Test func ridge_doesNotMarkBoundary() {
        let rows = 7, cols = 7
        var mask = [[Bool]](repeating: [Bool](repeating: false, count: cols),
                            count: rows)
        for r in 1..<6 { for c in 1..<6 { mask[r][c] = true } }
        let dt = Sk.chamferDistanceTransform(mask, rows: rows, cols: cols)
        let sk = Sk.strictLocalMaxRidge(dt: dt, glyphMask: mask,
                                        rows: rows, cols: cols)
        for r in 0..<rows {
            for c in 0..<cols where !mask[r][c] {
                #expect(!sk[r][c],
                        "exterior pixel marked as skeleton at (\(r),\(c))")
            }
        }
    }
}
