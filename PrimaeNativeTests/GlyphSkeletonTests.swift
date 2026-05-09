// Direct coverage for GlyphSkeleton's query layer (nearestIndex,
// bfsPath). Builds synthetic skeletons in memory so we don't need
// CoreText / fonts in the test process.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@Suite struct GlyphSkeletonTests {

    // MARK: - nearestIndex

    @Test func nearestIndex_emptySkeleton_returnsNil() {
        let sk = GlyphSkeleton(points: [], adjacency: [])
        #expect(sk.nearestIndex(to: CGPoint(x: 0.5, y: 0.5),
                                maxDistance: 1) == nil)
    }

    @Test func nearestIndex_picksClosestWithinThreshold() {
        // Points along a horizontal line; query in the middle.
        let pts = (0...4).map { CGPoint(x: CGFloat($0) * 0.2, y: 0.5) }
        let adj = Array(repeating: [Int](), count: pts.count)
        let sk = GlyphSkeleton(points: pts, adjacency: adj)
        let idx = sk.nearestIndex(to: CGPoint(x: 0.41, y: 0.5),
                                  maxDistance: 0.05)
        #expect(idx == 2, "0.41 is closest to point at x=0.4 (idx 2)")
    }

    @Test func nearestIndex_outsideThreshold_returnsNil() {
        let pts = [CGPoint(x: 0, y: 0)]
        let sk = GlyphSkeleton(points: pts, adjacency: [[]])
        #expect(sk.nearestIndex(to: CGPoint(x: 0.5, y: 0.5),
                                maxDistance: 0.1) == nil,
                "query 0.71 away from only point, threshold 0.1 → nil")
    }

    @Test func nearestIndex_exactlyAtThreshold_returnsPoint() {
        let pts = [CGPoint(x: 0, y: 0)]
        let sk = GlyphSkeleton(points: pts, adjacency: [[]])
        // Point is sqrt(0.03² + 0.04²) = 0.05 away. Should match at 0.05.
        let idx = sk.nearestIndex(to: CGPoint(x: 0.03, y: 0.04),
                                  maxDistance: 0.05)
        #expect(idx == 0)
    }

    // MARK: - bfsPath

    @Test func bfsPath_sameIndex_returnsSinglePoint() {
        let pts = [CGPoint(x: 0.5, y: 0.5)]
        let sk = GlyphSkeleton(points: pts, adjacency: [[]])
        let path = sk.bfsPath(from: 0, to: 0)
        #expect(path?.count == 1)
        #expect(path?.first == CGPoint(x: 0.5, y: 0.5))
    }

    @Test func bfsPath_linearChain_walksDirectly() {
        // 5 points in a line: 0—1—2—3—4
        let pts = (0...4).map { CGPoint(x: CGFloat($0) * 0.1, y: 0.5) }
        let adj: [[Int]] = [[1], [0, 2], [1, 3], [2, 4], [3]]
        let sk = GlyphSkeleton(points: pts, adjacency: adj)
        let path = sk.bfsPath(from: 0, to: 4)
        #expect(path?.count == 5)
        #expect(path?.first == pts[0])
        #expect(path?.last == pts[4])
        // Strictly increasing x — avoids float-equality flakiness on
        // 0.1*3 == 0.30000000000000004 etc.
        let xs = (path ?? []).map(\.x)
        let monotonic = zip(xs, xs.dropFirst()).allSatisfy { $0 < $1 }
        #expect(monotonic)
    }

    @Test func bfsPath_takesShortcutOverDetour() {
        // Diamond: 0 connects to 1 (long detour) and 2 (direct). Both
        // routes lead to 3. BFS should pick the shorter (0→2→3).
        //   1
        //  / \
        // 0   3
        //  \ /
        //   2
        // But edge 0—1 is longer than 0—2 in graph terms — they're
        // both length 1 in BFS hops, so BFS may pick either. Use a
        // chain length difference instead:
        //   0 — 1 — 2 — 3       (3 hops)
        //   0 — 4 — 3           (2 hops)
        let pts = (0...4).map { CGPoint(x: CGFloat($0), y: 0) }
        let adj: [[Int]] = [
            [1, 4],     // 0
            [0, 2],     // 1
            [1, 3],     // 2
            [2, 4],     // 3
            [0, 3],     // 4
        ]
        let sk = GlyphSkeleton(points: pts, adjacency: adj)
        let path = sk.bfsPath(from: 0, to: 3)
        #expect(path?.count == 3, "shortest path is 0→4→3 (3 nodes)")
    }

    @Test func bfsPath_disconnectedComponents_returnsNil() {
        // Two isolated nodes.
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]
        let adj: [[Int]] = [[], []]
        let sk = GlyphSkeleton(points: pts, adjacency: adj)
        #expect(sk.bfsPath(from: 0, to: 1) == nil)
    }

    @Test func bfsPath_outOfBoundsIndex_returnsNil() {
        let pts = [CGPoint(x: 0, y: 0)]
        let sk = GlyphSkeleton(points: pts, adjacency: [[]])
        #expect(sk.bfsPath(from: 0, to: 5) == nil)
        #expect(sk.bfsPath(from: -1, to: 0) == nil)
    }

    @Test func bfsPath_loop_findsAnyShortestRoute() {
        // 4-node ring: 0-1-2-3-0. Path 0→2 has two shortest routes
        // (via 1 or via 3); both are 3 nodes long. Either is OK.
        let pts = (0...3).map { CGPoint(x: CGFloat($0), y: 0) }
        let adj: [[Int]] = [[1, 3], [0, 2], [1, 3], [0, 2]]
        let sk = GlyphSkeleton(points: pts, adjacency: adj)
        let path = sk.bfsPath(from: 0, to: 2)
        #expect(path?.count == 3)
        #expect(path?.first == pts[0])
        #expect(path?.last == pts[2])
        // Middle node is whichever BFS visits first (1 or 3).
        let mid = path?[1]
        #expect(mid == pts[1] || mid == pts[3])
    }
}
