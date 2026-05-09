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
    /// Skeleton points in bbox-relative coordinates (0..1, top-down y).
    let points: [CGPoint]
    /// 8-neighbor adjacency: `adjacency[i]` lists indices j where
    /// `points[i]` and `points[j]` are 1-pixel-distant on the raster.
    let adjacency: [[Int]]

    /// 512² thins in ~1s cold on iPad and gives ~2px-per-bbox-percent
    /// resolution; 256 was visibly squiggly through the BFS-walked
    /// path on curved letters like `C` / `o`.
    private static let rasterResolution = 512
    private static let rasterInset = 4

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

    /// Memoized per (letter, schriftArt, features) key — extraction is
    /// hundreds of ms on a cold call, instantaneous on warm.
    private static var cache: [String: GlyphSkeleton] = [:]
    private static let cacheQueue = DispatchQueue(label: "GlyphSkeleton.cache")

    static func make(letter: String, schriftArt: SchriftArt,
                     openTypeFeatures: [String] = []) -> GlyphSkeleton? {
        guard !letter.isEmpty else { return nil }
        let key = "\(letter)|\(schriftArt.rawValue)|\(openTypeFeatures.sorted().joined(separator: ","))"
        if let hit = cacheQueue.sync(execute: { cache[key] }) {
            return hit
        }
        guard let built = build(letter: letter, schriftArt: schriftArt,
                                openTypeFeatures: openTypeFeatures) else {
            return nil
        }
        cacheQueue.sync { cache[key] = built }
        return built
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
        guard let ctx = CGContext(
                data: nil, width: res, height: res,
                bitsPerComponent: 8, bytesPerRow: res,
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

        // Bool grid; row = CG-y (BL origin); col = CG-x.
        var mask = [[Bool]](repeating: [Bool](repeating: false, count: res),
                            count: res)
        for r in 0..<res {
            for c in 0..<res {
                mask[r][c] = buf[r * res + c] > 127
            }
        }
        zhangSuenThin(&mask, rows: res, cols: res)
        return extractGraph(from: mask, res: res, inset: inset, drawable: drawable)
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
