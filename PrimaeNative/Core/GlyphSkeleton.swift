// GlyphSkeleton.swift
// PrimaeNative
//
// Pixel-skeletonizes a glyph (rasterize → Zhang-Suen thin → extract
// 8-connected graph) so the calibration overlay can snap anchors to
// the ink centerline and BFS-fill the path between them. Bbox-relative
// 0..1 coords throughout, top-down y to match strokes.json.

import CoreGraphics
import CoreText
import UIKit

struct GlyphSkeleton {
    let points: [CGPoint]
    let adjacency: [[Int]]
    /// Pre-merge thinned pixels for the dot viz — junction merge eats `points`.
    let vizPixels: [CGPoint]

    init(points: [CGPoint], adjacency: [[Int]], vizPixels: [CGPoint]) {
        self.points = points
        self.adjacency = adjacency
        self.vizPixels = vizPixels
    }

    init(points: [CGPoint], adjacency: [[Int]]) {
        self.init(points: points, adjacency: adjacency, vizPixels: points)
    }

    /// 256² thins in ~150ms cold and renders ~600 skeleton points,
    /// vs 512² which produced ~2400 points and pushed Canvas redraw
    /// past the frame budget. Combined with the moving-average
    /// smoothing in the calibrator, 256 is plenty smooth on curves.
    private static let rasterResolution = 256
    private static let rasterInset = 2

    /// Returns the index of the skeleton point closest to `bboxPoint`,
    /// or nil if the closest is farther than `maxDistance` (bbox units,
    /// 0..1).
    func nearestIndex(to bboxPoint: CGPoint, maxDistance: CGFloat) -> Int? {
        guard !points.isEmpty else { return nil }
        var bestIdx = -1
        var bestSq = CGFloat.infinity
        for (i, p) in points.enumerated() {
            let dx = p.x - bboxPoint.x
            let dy = p.y - bboxPoint.y
            let sq = dx * dx + dy * dy
            if sq < bestSq {
                bestSq = sq
                bestIdx = i
            }
        }
        guard bestIdx >= 0,
              bestSq.squareRoot() <= maxDistance else { return nil }
        return bestIdx
    }

    /// BFS shortest path (unit edge weights) returning the skeleton
    /// chain from `startIdx` to `endIdx` inclusive, or nil if the two
    /// indices are in disconnected components.
    func bfsPath(from startIdx: Int, to endIdx: Int) -> [CGPoint]? {
        guard startIdx != endIdx else { return [points[startIdx]] }
        guard points.indices.contains(startIdx),
              points.indices.contains(endIdx) else { return nil }
        var parent = Array(repeating: -1, count: points.count)
        parent[startIdx] = startIdx
        var queue = [startIdx]
        var head = 0
        while head < queue.count {
            let u = queue[head]; head += 1
            if u == endIdx { break }
            for v in adjacency[u] where parent[v] == -1 {
                parent[v] = u
                queue.append(v)
            }
        }
        guard parent[endIdx] != -1 else { return nil }
        var chain: [Int] = []
        var cur = endIdx
        while cur != startIdx {
            chain.append(cur)
            cur = parent[cur]
        }
        chain.append(startIdx)
        return chain.reversed().map { points[$0] }
    }

    // MARK: - Construction

    /// No memoization — at 256² resolution each rebuild is ~150ms, only
    /// fires on letter/script change in the calibrator, and removing
    /// the cache eliminates a class of "stale skeleton survives an
    /// algorithm change" bugs during iteration.
    static func make(letter: String, schriftArt: SchriftArt,
                     openTypeFeatures: [String] = []) -> GlyphSkeleton? {
        guard !letter.isEmpty else { return nil }
        return build(letter: letter, schriftArt: schriftArt,
                     openTypeFeatures: openTypeFeatures)
    }

    private static func build(letter: String, schriftArt: SchriftArt,
                              openTypeFeatures: [String]) -> GlyphSkeleton? {
        guard let font = PrimaeLetterRenderer.makeFont(
                size: 800, fontName: schriftArt.fontFileName,
                openTypeFeatures: openTypeFeatures),
              var glyph = PrimaeLetterRenderer.getGlyph(for: letter, in: font) else {
            return nil
        }
        let bbox = CTFontGetBoundingRectsForGlyphs(font, .default, &glyph, nil, 1)
        guard bbox.width > 0, bbox.height > 0,
              let cgPath = CTFontCreatePathForGlyph(font, glyph, nil) else {
            return nil
        }

        // Rasterize the glyph into a binary mask at fixed resolution.
        // 2-pixel inset keeps the ink from touching the raster border,
        // which Zhang-Suen leaves un-thinned.
        let res = rasterResolution
        let inset = rasterInset
        let drawable = CGFloat(res - 2 * inset)
        // bytesPerRow: 0 lets CG pick the system-preferred stride. Hardcoding
        // res silently fails on iOS when the value doesn't match the
        // platform's alignment; CGContext returns nil and the whole skeleton
        // build aborts. Read the actual stride back via `ctx.bytesPerRow`
        // for buffer indexing — it can exceed `res` if CG adds padding.
        guard let ctx = CGContext(
                data: nil, width: res, height: res,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: res, height: res))
        ctx.setFillColor(gray: 1, alpha: 1)
        let sx = drawable / bbox.width
        let sy = drawable / bbox.height
        ctx.translateBy(x: CGFloat(inset) - bbox.minX * sx,
                        y: CGFloat(inset) - bbox.minY * sy)
        ctx.scaleBy(x: sx, y: sy)
        ctx.addPath(cgPath)
        ctx.fillPath()
        guard let data = ctx.data else { return nil }
        let buf = data.assumingMemoryBound(to: UInt8.self)
        let stride = ctx.bytesPerRow

        // Bool grid; row = CG-y (BL origin); col = CG-x.
        var glyphMask = [[Bool]](repeating: [Bool](repeating: false, count: res),
                                 count: res)
        for r in 0..<res {
            for c in 0..<res {
                glyphMask[r][c] = buf[r * stride + c] > 127
            }
        }
        var mask = glyphMask  // mutable thinning copy; glyphMask kept as the
                              // reference shape so tip-extension knows when
                              // it has walked out of the ink.
        zhangSuenThin(&mask, rows: res, cols: res)
        // Zhang-Suen terminates the medial axis ~half-stroke-width before
        // the actual stroke end (the user's "skeleton stops short" arrows
        // on `k`'s top + bottom). Walk each tip along its direction
        // inside the glyph mask until it exits the ink.
        extendTipsToOutline(&mask, glyphMask: glyphMask,
                            rows: res, cols: res, maxExtension: 25)
        guard let raw = extractGraph(from: mask, res: res, inset: inset,
                                     drawable: drawable) else { return nil }
        // Spur threshold at ~3% bbox (8 pixels at 256 res). Catches the
        // typical Zhang-Suen artifact tails at corners (apex of A, K
        // vertex) without eating into legitimate stroke arms which are
        // 50+ pixels even on the smallest glyph.
        let pruned = prunedSpurs(raw, maxSpurLen: 8)
        let merged = mergedAdjacentJunctions(pruned)
        return GlyphSkeleton(points: merged.points,
                             adjacency: merged.adjacency,
                             vizPixels: pruned.points)
    }

    /// Merge junction nodes (degree-3+) that are direct neighbors in
    /// the graph into a single representative — the cluster's centroid.
    /// Eliminates the multi-pixel "junction zone" Zhang-Suen leaves
    /// where two strokes meet (the user's K-vertex, R-stem-meets-leg,
    /// A-crossbar-joint arrows). Edges from the cluster to the rest of
    /// the skeleton are redirected to the representative.
    static func mergedAdjacentJunctions(_ sk: GlyphSkeleton) -> GlyphSkeleton {
        let n = sk.points.count
        // Union-find over node indices, unioning junction nodes that
        // share an edge.
        var parent = Array(0..<n)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { r = parent[r] }
            var c = x
            while parent[c] != c {
                let nx = parent[c]
                parent[c] = r
                c = nx
            }
            return r
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        var didMerge = false
        for i in 0..<n where sk.adjacency[i].count >= 3 {
            for j in sk.adjacency[i] where j > i && sk.adjacency[j].count >= 3 {
                union(i, j)
                didMerge = true
            }
        }
        if !didMerge { return sk }
        // Group by cluster root.
        var clusters: [Int: [Int]] = [:]
        for i in 0..<n where sk.adjacency[i].count >= 3 {
            clusters[find(i), default: []].append(i)
        }
        // For each multi-node cluster, pick the centroid member.
        var remap = Array(0..<n)
        for members in clusters.values where members.count > 1 {
            var mx: CGFloat = 0, my: CGFloat = 0
            for m in members {
                mx += sk.points[m].x
                my += sk.points[m].y
            }
            mx /= CGFloat(members.count)
            my /= CGFloat(members.count)
            var best = members[0]
            var bestSq = CGFloat.infinity
            for m in members {
                let dx = sk.points[m].x - mx
                let dy = sk.points[m].y - my
                let sq = dx * dx + dy * dy
                if sq < bestSq { bestSq = sq; best = m }
            }
            for m in members where m != best {
                remap[m] = best
            }
        }
        // Build the compacted graph.
        var newIdx = [Int](repeating: -1, count: n)
        var newPts: [CGPoint] = []
        for i in 0..<n where remap[i] == i {
            newIdx[i] = newPts.count
            newPts.append(sk.points[i])
        }
        var newAdj = Array(repeating: [Int](), count: newPts.count)
        for i in 0..<n {
            let srcRoot = remap[i]
            let srcNew = newIdx[srcRoot]
            for j in sk.adjacency[i] {
                let dstRoot = remap[j]
                let dstNew = newIdx[dstRoot]
                if srcNew == dstNew { continue }
                if !newAdj[srcNew].contains(dstNew) {
                    newAdj[srcNew].append(dstNew)
                }
            }
        }
        return GlyphSkeleton(points: newPts, adjacency: newAdj)
    }

    /// For every degree-1 pixel in the thinned skeleton, walk along the
    /// direction (tip — its sole neighbor) and add pixels back into the
    /// skeleton as long as they stay inside the original glyph mask.
    /// Bounded by `maxExtension` so a runaway tip in an open shape can't
    /// march off the glyph indefinitely.
    private static func extendTipsToOutline(_ skeleton: inout [[Bool]],
                                            glyphMask: [[Bool]],
                                            rows: Int, cols: Int,
                                            maxExtension: Int) {
        var tips: [(r: Int, c: Int, dr: Int, dc: Int)] = []
        for r in 1..<(rows - 1) {
            for c in 1..<(cols - 1) where skeleton[r][c] {
                var count = 0
                var nr = 0, nc = 0
                for dr in -1...1 {
                    for dc in -1...1 where !(dr == 0 && dc == 0) {
                        if skeleton[r + dr][c + dc] {
                            count += 1
                            nr = r + dr
                            nc = c + dc
                        }
                    }
                }
                if count == 1 {
                    // Direction = tip - neighbor (unit vector in {-1,0,1}²).
                    tips.append((r, c, r - nr, c - nc))
                }
            }
        }
        for tip in tips {
            var r = tip.r, c = tip.c
            for _ in 0..<maxExtension {
                r += tip.dr
                c += tip.dc
                if r < 0 || r >= rows || c < 0 || c >= cols { break }
                if !glyphMask[r][c] { break }
                skeleton[r][c] = true
            }
        }
    }

    /// Remove short dead-end branches (degree-1 chains shorter than
    /// `maxSpurLen` that terminate at a junction). Zhang-Suen thinning
    /// leaves these at corners (the apex of `A`, the inside of `K`'s
    /// vertex) and BFS would otherwise route through them, producing a
    /// hook off the rendered stroke. Iterates until stable so a junction
    /// that turns into a tip after the first pass also gets cleaned up.
    /// Internal-not-private so tests can drive it with synthetic skeletons.
    static func prunedSpurs(_ sk: GlyphSkeleton,
                            maxSpurLen: Int) -> GlyphSkeleton {
        var current = sk
        while true {
            let next = pruneOnce(current, maxSpurLen: maxSpurLen)
            if next.points.count == current.points.count { return current }
            current = next
        }
    }

    private static func pruneOnce(_ sk: GlyphSkeleton,
                                  maxSpurLen: Int) -> GlyphSkeleton {
        let n = sk.points.count
        var prune = Set<Int>()
        for tip in 0..<n where sk.adjacency[tip].count == 1 {
            if prune.contains(tip) { continue }
            var prev = -1
            var cur = tip
            var chain: [Int] = []
            // Walk up to `maxSpurLen` nodes from the tip toward a junction.
            // If we reach a junction within the budget, the chain is a spur
            // (chain.count ≤ maxSpurLen). Beyond that we exit without
            // pruning and the branch is preserved.
            while chain.count < maxSpurLen {
                chain.append(cur)
                let next = sk.adjacency[cur].filter { $0 != prev }
                if next.count != 1 { break }      // dead end or branched chain
                let nxt = next[0]
                if sk.adjacency[nxt].count >= 3 {
                    prune.formUnion(chain)
                    break
                }
                prev = cur
                cur = nxt
            }
        }
        if prune.isEmpty { return sk }
        var remap = [Int](repeating: -1, count: n)
        var newPts: [CGPoint] = []
        for i in 0..<n where !prune.contains(i) {
            remap[i] = newPts.count
            newPts.append(sk.points[i])
        }
        var newAdj = Array(repeating: [Int](), count: newPts.count)
        for i in 0..<n where !prune.contains(i) {
            let ni = remap[i]
            for j in sk.adjacency[i] where !prune.contains(j) {
                newAdj[ni].append(remap[j])
            }
        }
        return GlyphSkeleton(points: newPts, adjacency: newAdj)
    }

    /// Zhang-Suen thinning to 1-pixel-wide skeleton. Two sub-iterations
    /// per pass; repeat until a pass changes nothing.
    private static func zhangSuenThin(_ mask: inout [[Bool]],
                                      rows: Int, cols: Int) {
        var changed = true
        while changed {
            changed = false
            for sub in 0...1 {
                var toClear: [(Int, Int)] = []
                for r in 1..<(rows - 1) {
                    for c in 1..<(cols - 1) {
                        if !mask[r][c] { continue }
                        // Neighborhood: P2..P9 clockwise from N.
                        let p2 = mask[r - 1][c]
                        let p3 = mask[r - 1][c + 1]
                        let p4 = mask[r][c + 1]
                        let p5 = mask[r + 1][c + 1]
                        let p6 = mask[r + 1][c]
                        let p7 = mask[r + 1][c - 1]
                        let p8 = mask[r][c - 1]
                        let p9 = mask[r - 1][c - 1]
                        let bp = (p2 ? 1 : 0) + (p3 ? 1 : 0) + (p4 ? 1 : 0)
                            + (p5 ? 1 : 0) + (p6 ? 1 : 0) + (p7 ? 1 : 0)
                            + (p8 ? 1 : 0) + (p9 ? 1 : 0)
                        if bp < 2 || bp > 6 { continue }
                        let seq: [Bool] = [p2, p3, p4, p5, p6, p7, p8, p9, p2]
                        var ap = 0
                        for i in 0..<8 where !seq[i] && seq[i + 1] { ap += 1 }
                        if ap != 1 { continue }
                        if sub == 0 {
                            // P2*P4*P6 == 0 and P4*P6*P8 == 0
                            if (p2 && p4 && p6) || (p4 && p6 && p8) { continue }
                        } else {
                            // P2*P4*P8 == 0 and P2*P6*P8 == 0
                            if (p2 && p4 && p8) || (p2 && p6 && p8) { continue }
                        }
                        toClear.append((r, c))
                    }
                }
                if !toClear.isEmpty {
                    for (r, c) in toClear { mask[r][c] = false }
                    changed = true
                }
            }
        }
    }

    /// Convert the 1-pixel skeleton mask to a (points, adjacency) graph
    /// in bbox-relative top-down coords.
    private static func extractGraph(from mask: [[Bool]], res: Int,
                                     inset: Int,
                                     drawable: CGFloat) -> GlyphSkeleton? {
        // Index map: pixel (r, c) → skeleton point index.
        var indexAt = [[Int]](repeating: [Int](repeating: -1, count: res),
                              count: res)
        var pts: [CGPoint] = []
        let drawableF = drawable
        let insetF = CGFloat(inset)
        for r in 0..<res {
            for c in 0..<res where mask[r][c] {
                indexAt[r][c] = pts.count
                // CGBitmapContext memory: row 0 is visual top of image;
                // we drew the CT glyph with its CT.maxY landing at high
                // CG-y (= low memory row). So memory row r maps directly
                // to bbox top-down y, no flip needed.
                let bx = (CGFloat(c) - insetF + 0.5) / drawableF
                let by = (CGFloat(r) - insetF + 0.5) / drawableF
                pts.append(CGPoint(x: bx, y: by))
            }
        }
        guard !pts.isEmpty else { return nil }
        var adj: [[Int]] = Array(repeating: [], count: pts.count)
        let neighborOffsets: [(Int, Int)] = [
            (-1, -1), (-1, 0), (-1, 1),
            ( 0, -1),          ( 0, 1),
            ( 1, -1), ( 1, 0), ( 1, 1),
        ]
        for r in 0..<res {
            for c in 0..<res {
                let idx = indexAt[r][c]
                if idx < 0 { continue }
                for (dr, dc) in neighborOffsets {
                    let nr = r + dr, nc = c + dc
                    if nr < 0 || nr >= res || nc < 0 || nc >= res { continue }
                    let nIdx = indexAt[nr][nc]
                    if nIdx >= 0 { adj[idx].append(nIdx) }
                }
            }
        }
        return GlyphSkeleton(points: pts, adjacency: adj)
    }
}
