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

    // MARK: - prunedSpurs

    @Test func prunedSpurs_noSpur_returnsUnchanged() {
        // T-junction: vertical line meeting a horizontal arm.
        // Indices: 0—1—2 (vertical), 1—3 (horizontal arm).
        // 3 tips, all on long branches → no pruning.
        let pts = [
            CGPoint(x: 0.5, y: 0.1),  // 0 — top
            CGPoint(x: 0.5, y: 0.5),  // 1 — junction
            CGPoint(x: 0.5, y: 0.9),  // 2 — bottom
            CGPoint(x: 0.9, y: 0.5),  // 3 — right tip
        ]
        let adj: [[Int]] = [[1], [0, 2, 3], [1], [1]]
        let sk = GlyphSkeleton(points: pts, adjacency: adj)
        let pruned = GlyphSkeleton.prunedSpurs(sk, maxSpurLen: 2)
        #expect(pruned.points.count == 4, "no spur shorter than 2 → unchanged")
    }

    @Test func prunedSpurs_shortSpurAtJunction_removed() {
        // Same T plus a 2-pixel spur off the junction (1—4—5).
        // Spur chain length = 2, threshold = 5 → prune.
        let pts = [
            CGPoint(x: 0.5, y: 0.1),  // 0 — top
            CGPoint(x: 0.5, y: 0.5),  // 1 — junction
            CGPoint(x: 0.5, y: 0.9),  // 2 — bottom
            CGPoint(x: 0.9, y: 0.5),  // 3 — right tip
            CGPoint(x: 0.5, y: 0.45), // 4 — spur middle
            CGPoint(x: 0.5, y: 0.40), // 5 — spur tip
        ]
        let adj: [[Int]] = [[1], [0, 2, 3, 4], [1], [1], [1, 5], [4]]
        let sk = GlyphSkeleton(points: pts, adjacency: adj)
        let pruned = GlyphSkeleton.prunedSpurs(sk, maxSpurLen: 5)
        #expect(pruned.points.count == 4,
                "spur chain (4, 5) pruned → 4 nodes left")
        // Junction now has degree 3 (no longer connected to spur).
        let junctionAdj = pruned.adjacency.first { $0.count == 3 }
        #expect(junctionAdj != nil)
    }

    @Test func prunedSpurs_longBranchKept() {
        // Junction with one arm longer than maxSpurLen — keep it.
        // 0—1—2 (vertical), 1—3—4—5—6 (long horizontal).
        let pts = [
            CGPoint(x: 0.5, y: 0.1),
            CGPoint(x: 0.5, y: 0.5),  // junction
            CGPoint(x: 0.5, y: 0.9),
            CGPoint(x: 0.6, y: 0.5),
            CGPoint(x: 0.7, y: 0.5),
            CGPoint(x: 0.8, y: 0.5),
            CGPoint(x: 0.9, y: 0.5),
        ]
        let adj: [[Int]] = [[1], [0, 2, 3], [1], [1, 4], [3, 5], [4, 6], [5]]
        let sk = GlyphSkeleton(points: pts, adjacency: adj)
        let pruned = GlyphSkeleton.prunedSpurs(sk, maxSpurLen: 3)
        #expect(pruned.points.count == 7, "long arm not pruned at threshold 3")
    }

    @Test func prunedSpurs_isolatedChain_notPruned() {
        // Isolated short chain with no junction (e.g. 'i' dot remnant).
        // Two tips, no degree-3 junction → safe, don't prune.
        let pts = [CGPoint(x: 0.5, y: 0.1), CGPoint(x: 0.5, y: 0.15)]
        let adj: [[Int]] = [[1], [0]]
        let sk = GlyphSkeleton(points: pts, adjacency: adj)
        let pruned = GlyphSkeleton.prunedSpurs(sk, maxSpurLen: 5)
        #expect(pruned.points.count == 2,
                "isolated dot not connected to a junction → preserved")
    }

    @Test func prunedSpurs_iteratesUntilStable() {
        // Two-level spur: short branch off a junction whose remaining
        // arm becomes a tip after first pass — second pass cleans it up.
        // 0—1 (long stem), 1—2—3 (junction-1 with mid spur),
        // 2—4 (junction-2 with another short branch)
        // After pruning 4, node 2 becomes degree-1 with a 2-len chain
        // back to node 1; second pass prunes that too.
        let pts = (0...4).map { CGPoint(x: 0, y: CGFloat($0) * 0.1) }
        // 0—1—2—3 (chain), 2—4 (branch tip)
        let adj: [[Int]] = [[1], [0, 2], [1, 3, 4], [2], [2]]
        let sk = GlyphSkeleton(points: pts, adjacency: adj)
        // Sanity: this is one long stem 0-1-2-3 with a side spur at 2.
        // Spur (4) is 1-len; first pass prunes it. Then 2 has degree 2
        // — straight chain 1-2-3 — no further pruning.
        let pruned = GlyphSkeleton.prunedSpurs(sk, maxSpurLen: 3)
        #expect(pruned.points.count == 4,
                "side spur (4) pruned; main chain 0-1-2-3 preserved")
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
