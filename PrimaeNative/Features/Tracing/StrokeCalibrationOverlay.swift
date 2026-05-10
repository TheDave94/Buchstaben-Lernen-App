// StrokeCalibrationOverlay.swift
// PrimaeNative
//
// Debug-mode overlay for editing stroke checkpoint positions.
// Drag / add / delete dots, switch strokes, persist per-script.
// JSON export is the secondary backup action.

import SwiftUI

struct StrokeCalibrationOverlay: View {
    @Environment(TracingViewModel.self) private var vm

    let canvasSize: CGSize

    @State private var editableStrokes: [[CGPoint]] = []
    @State private var showExport = false
    @State private var exportText = ""
    @State private var loaded = false
    @State private var activeStroke = 0
    @State private var mode: CalibrationMode = .drag
    @State private var savedFlashUntil: Date? = nil
    @State private var showResetConfirm = false
    /// (letter, schriftArt) of the last reload — both invalidate so a
    /// font switch picks up the other script's saved strokes.
    @State private var loadedKey: LoadKey? = nil

    private struct LoadKey: Equatable {
        let letter: String
        let schriftArt: SchriftArt
    }

    enum CalibrationMode: String, CaseIterable {
        case points = "Anker"
        case drag = "Ziehen"
        case delete = "Löschen"
    }

    /// Bbox-relative anchors set in `.points` mode, per stroke index.
    /// The committed `editableStrokes[i]` is rebuilt from these anchors
    /// by BFS-walking the glyph skeleton between consecutive points.
    @State private var anchorsPerStroke: [Int: [CGPoint]] = [:]
    /// Glyph centerline graph for the current (letter, schriftArt).
    /// nil while loading or when extraction fails (anchors then fall
    /// back to pure spline interpolation).
    @State private var skeleton: GlyphSkeleton? = nil

    /// Distance gate for BFS-walking the skeleton between two anchors.
    /// An anchor placed farther than this from the centerline is treated
    /// as deliberately off-glyph (e.g. air-sweep on single-stroke `b`)
    /// and that segment falls back to the spline path.
    private let bfsGate: CGFloat = 0.08

    private let strokeColors: [Color] = [.red, .blue, .green, .orange, .purple, .pink, .cyan, .yellow]

    private var isSaved: Bool {
        guard let until = savedFlashUntil else { return false }
        return Date() < until
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                addTapLayer(in: size)
                glyphRectDebugLayer(in: size)
                skeletonLayer(in: size)
                strokePathsLayer(in: size)
                if mode != .points { dotsLayer(in: size) }
                if mode == .points { anchorsLayer(in: size) }
                controlsLayer
            }
            .onAppear {
                loadFromVM()
                bootstrapAnchorsFromExistingStrokes()
                refreshSkeleton()
            }
            .onChange(of: vm.currentLetterName) {
                loadFromVM()
                bootstrapAnchorsFromExistingStrokes()
                refreshSkeleton()
            }
            .onChange(of: vm.schriftArt) {
                loadFromVM(force: true)
                bootstrapAnchorsFromExistingStrokes()
                refreshSkeleton()
            }
            .onChange(of: mode) {
                if mode == .points { bootstrapAnchorsFromExistingStrokes() }
            }
        }
        .sheet(isPresented: $showExport) {
            ExportSheet(text: exportText, letterName: vm.currentLetterName)
        }
        .confirmationDialog(
            "Alle Kalibrierungen löschen?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Löschen", role: .destructive) {
                vm.clearAllCalibrations()
                editableStrokes = []
                loadedKey = nil
                loaded = false
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Entfernt jede gespeicherte Kalibrierung für die aktive Schriftart. Das Bundle übernimmt anschließend.")
        }
    }

    /// Uniform arc-length resample in bbox-relative coordinates.
    private func resampleUniformBbox(_ pts: [CGPoint], count: Int) -> [CGPoint] {
        guard pts.count >= 2, count >= 2 else { return pts }
        var cum: [CGFloat] = [0]
        for i in 1..<pts.count {
            let dx = pts[i].x - pts[i - 1].x
            let dy = pts[i].y - pts[i - 1].y
            cum.append(cum[i - 1] + (dx * dx + dy * dy).squareRoot())
        }
        let total = cum.last ?? 0
        guard total > 0 else { return [pts[0], pts[pts.count - 1]] }
        var out: [CGPoint] = []
        var j = 0
        for k in 0..<count {
            let target = total * CGFloat(k) / CGFloat(count - 1)
            while j < cum.count - 1 && cum[j + 1] < target { j += 1 }
            if j >= pts.count - 1 {
                out.append(pts[pts.count - 1])
                continue
            }
            let denom = cum[j + 1] - cum[j]
            if denom == 0 {
                out.append(pts[j])
                continue
            }
            let t = (target - cum[j]) / denom
            out.append(CGPoint(
                x: pts[j].x + t * (pts[j + 1].x - pts[j].x),
                y: pts[j].y + t * (pts[j + 1].y - pts[j].y)
            ))
        }
        return out
    }

    // MARK: - Canvas layers

    @ViewBuilder
    private func addTapLayer(in size: CGSize) -> some View {
        if mode == .points {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { location in
                    let bboxPt = screenToGlyph(location, in: size)
                    addAnchor(bboxPt)
                }
        }
    }

    private func addAnchor(_ pt: CGPoint) {
        // Anchors are kept at the user's raw tap (corners, baseline,
        // wherever they intend) — snapping happens only inside
        // rebuildStrokeFromAnchors when we look up BFS endpoints, so
        // the rendered path actually reaches the user's anchor instead
        // of stopping at the medial-axis terminus.
        var anchors = anchorsPerStroke[activeStroke] ?? []
        if let insertIdx = closestSegmentInsertIndex(for: pt, in: anchors,
                                                     threshold: 0.04) {
            anchors.insert(pt, at: insertIdx)
        } else {
            anchors.append(pt)
        }
        anchorsPerStroke[activeStroke] = anchors
        rebuildStrokeFromAnchors()
    }

    /// (Re)build the skeleton on letter / script change. Prefers the
    /// baked centerline from `strokes.json` (clean topology, generated
    /// offline by the Python pipeline); falls through to runtime
    /// extraction only when the bundle predates the bake.
    private func refreshSkeleton() {
        if let baked = makeBakedSkeleton() {
            #if DEBUG
            print("[StrokeCalibrationOverlay] baked skeleton for "
                  + "\(vm.currentLetterName) (\(baked.points.count) pts)")
            #endif
            skeleton = baked
            return
        }
        #if DEBUG
        print("[StrokeCalibrationOverlay] FALLBACK to runtime "
              + "GlyphSkeleton.make for \(vm.currentLetterName)")
        #endif
        skeleton = GlyphSkeleton.make(letter: vm.currentLetterName,
                                      schriftArt: vm.schriftArt,
                                      openTypeFeatures: vm.currentGlyphFeatures)
    }

    /// Lift the baked centerline + adjacency from the active letter's
    /// LetterStrokes into the GlyphSkeleton shape the calibrator expects.
    private func makeBakedSkeleton() -> GlyphSkeleton? {
        guard let strokes = vm.glyphRelativeStrokes,
              let skel = strokes.skeleton,
              let adj = strokes.skeletonAdj,
              !skel.isEmpty,
              skel.count == adj.count else { return nil }
        let points = skel.map { CGPoint(x: $0.x, y: $0.y) }
        return GlyphSkeleton(points: points, adjacency: adj,
                             vizPixels: points)
    }

    /// Commit a dragged anchor and re-insert it at the spatially-
    /// closest segment so the polyline walks anchors in visible order
    /// rather than tap order.
    private func commitDragWithReorder(_ snapped: CGPoint, draggedIdx: Int) {
        guard var anchors = anchorsPerStroke[activeStroke] else { return }
        anchors[draggedIdx] = snapped
        var others = anchors
        others.remove(at: draggedIdx)
        guard let bestInsertIdx = closestSegmentInsertIndex(
            for: snapped, in: others, threshold: 0.20) else {
            anchorsPerStroke[activeStroke] = anchors
            return
        }
        var newList = others
        newList.insert(snapped, at: bestInsertIdx)
        anchorsPerStroke[activeStroke] = newList
    }

    /// Index at which `pt` should be inserted to land on the closest
    /// existing anchor-to-anchor segment, or nil when farther than
    /// `threshold` from every segment.
    private func closestSegmentInsertIndex(for pt: CGPoint,
                                           in anchors: [CGPoint],
                                           threshold: CGFloat) -> Int? {
        guard anchors.count >= 2 else { return nil }
        var bestIdx: Int? = nil
        var bestDist = CGFloat.infinity
        for i in 0..<(anchors.count - 1) {
            let d = pointSegmentDistance(pt: pt,
                                         a: anchors[i],
                                         b: anchors[i + 1])
            if d < bestDist {
                bestDist = d
                bestIdx = i + 1   // insert after anchor i
            }
        }
        guard let idx = bestIdx, bestDist <= threshold else { return nil }
        return idx
    }

    private func pointSegmentDistance(pt: CGPoint, a: CGPoint, b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else {
            let ex = pt.x - a.x; let ey = pt.y - a.y
            return (ex * ex + ey * ey).squareRoot()
        }
        let t = max(0, min(1, ((pt.x - a.x) * dx + (pt.y - a.y) * dy) / lenSq))
        let projX = a.x + t * dx
        let projY = a.y + t * dy
        let ex = pt.x - projX; let ey = pt.y - projY
        return (ex * ex + ey * ey).squareRoot()
    }

    private func removeAnchor(strokeIdx: Int, anchorIdx: Int) {
        guard var anchors = anchorsPerStroke[strokeIdx],
              anchorIdx < anchors.count else { return }
        anchors.remove(at: anchorIdx)
        anchorsPerStroke[strokeIdx] = anchors
        if strokeIdx == activeStroke { rebuildStrokeFromAnchors() }
    }

    private func rebuildStrokeFromAnchors() {
        let anchors = anchorsPerStroke[activeStroke] ?? []
        while editableStrokes.count <= activeStroke {
            editableStrokes.append([])
        }
        guard anchors.count >= 2 else { return }

        // Interior anchors are routing waypoints only — visiting them as raw
        // points produces a snap-out/snap-in spike at each junction.
        var path: [CGPoint] = [anchors[0]]
        var bfsFilledSegments = 0
        let lastIdx = anchors.count - 1
        for i in 0..<lastIdx {
            let a = anchors[i], b = anchors[i + 1]
            if let sk = skeleton,
               let aIdx = sk.nearestIndex(to: a, maxDistance: bfsGate),
               let bIdx = sk.nearestIndex(to: b, maxDistance: bfsGate),
               let walked = sk.bfsPath(from: aIdx, to: bIdx),
               walked.count >= 2 {
                if let tail = path.last,
                   approxEqual(tail, walked[0]) {
                    path.append(contentsOf: walked.dropFirst())
                } else {
                    path.append(contentsOf: walked)
                }
                bfsFilledSegments += 1
            } else {
                path.append(b)
            }
        }
        // BFS ends on a snapped skeleton point; reach out to the raw anchor.
        if let tail = path.last, !approxEqual(tail, anchors[lastIdx]) {
            path.append(anchors[lastIdx])
        }

        let mostlyBfs = bfsFilledSegments * 2 >= (anchors.count - 1)
        let smoothed: [CGPoint]
        if mostlyBfs {
            smoothed = straightenedAndSmoothed(path)
        } else if path.count >= 3 {
            smoothed = catmullRomSpline(path)
        } else {
            smoothed = path
        }

        let segments = anchors.count - 1
        let denseCount = mostlyBfs
            ? min(200, max(60, path.count))
            : max(40, min(200, segments * 8))
        editableStrokes[activeStroke] = resampleUniformBbox(smoothed,
                                                            count: denseCount)
    }

    private func approxEqual(_ a: CGPoint, _ b: CGPoint) -> Bool {
        let dx = a.x - b.x, dy = a.y - b.y
        return dx * dx + dy * dy < 0.0001
    }

    private func straightenedAndSmoothed(_ path: [CGPoint]) -> [CGPoint] {
        guard path.count >= 3 else { return path }
        // eps≈3px at 256² raster — tuned to swallow Zhang-Suen lateral
        // jitter so straight strokes collapse to a 2-point chord.
        let key = Self.rdpSimplify(path, eps: 0.012)
        if key.count == 2 {
            return [path[0], path[path.count - 1]]
        }
        let breaks = Self.sharpTurnIndices(in: key,
                                           deflectionAtLeast: .pi / 3)
        let bps = [0] + breaks + [key.count - 1]
        var out: [CGPoint] = [key[0]]
        for k in 0..<(bps.count - 1) {
            let lo = bps[k], hi = bps[k + 1]
            if hi - lo == 1 {
                out.append(key[hi])
            } else {
                let sub = Array(key[lo...hi])
                let curve = catmullRomSpline(sub, samplesPerSegment: 16)
                out.append(contentsOf: curve.dropFirst())
            }
        }
        return out
    }

    static func rdpSimplify(_ pts: [CGPoint], eps: CGFloat) -> [CGPoint] {
        guard pts.count >= 3 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true
        keep[pts.count - 1] = true
        rdpRecurse(pts, lo: 0, hi: pts.count - 1, eps: eps, keep: &keep)
        return pts.indices.compactMap { keep[$0] ? pts[$0] : nil }
    }

    private static func rdpRecurse(_ pts: [CGPoint], lo: Int, hi: Int,
                                   eps: CGFloat, keep: inout [Bool]) {
        if hi - lo < 2 { return }
        let a = pts[lo], b = pts[hi]
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        var maxD: CGFloat = 0
        var maxI = lo
        if lenSq < 1e-12 {
            for i in (lo + 1)..<hi {
                let ex = pts[i].x - a.x, ey = pts[i].y - a.y
                let d = (ex * ex + ey * ey).squareRoot()
                if d > maxD { maxD = d; maxI = i }
            }
        } else {
            let len = lenSq.squareRoot()
            for i in (lo + 1)..<hi {
                let cross = (pts[i].x - a.x) * dy - (pts[i].y - a.y) * dx
                let d = abs(cross) / len
                if d > maxD { maxD = d; maxI = i }
            }
        }
        if maxD > eps {
            keep[maxI] = true
            rdpRecurse(pts, lo: lo, hi: maxI, eps: eps, keep: &keep)
            rdpRecurse(pts, lo: maxI, hi: hi, eps: eps, keep: &keep)
        }
    }

    static func sharpTurnIndices(in key: [CGPoint],
                                 deflectionAtLeast threshold: CGFloat) -> [Int] {
        guard key.count >= 3 else { return [] }
        var breaks: [Int] = []
        for i in 1..<(key.count - 1) {
            let a = key[i - 1], b = key[i], c = key[i + 1]
            let v1x = b.x - a.x, v1y = b.y - a.y
            let v2x = c.x - b.x, v2y = c.y - b.y
            let m1Sq = v1x * v1x + v1y * v1y
            let m2Sq = v2x * v2x + v2y * v2y
            if m1Sq < 1e-12 || m2Sq < 1e-12 { continue }
            let cosA = (v1x * v2x + v1y * v2y) / (m1Sq * m2Sq).squareRoot()
            let clamped = max(-1, min(1, cosA))
            let deflection = acos(clamped)
            if deflection >= threshold {
                breaks.append(i)
            }
        }
        return breaks
    }

    /// Centripetal Catmull-Rom (α=0.5) through every anchor with mirrored
    /// phantom endpoints. Centripetal parameterization avoids the overshoot
    /// uniform CR gets on tight turns (e.g. the bottom of `g`).
    private func catmullRomSpline(_ anchors: [CGPoint],
                                  samplesPerSegment: Int = 20) -> [CGPoint] {
        guard anchors.count >= 3 else { return anchors }
        let last = anchors.count - 1
        let ghost0 = CGPoint(x: 2 * anchors[0].x - anchors[1].x,
                             y: 2 * anchors[0].y - anchors[1].y)
        let ghostN = CGPoint(x: 2 * anchors[last].x - anchors[last - 1].x,
                             y: 2 * anchors[last].y - anchors[last - 1].y)
        let padded = [ghost0] + anchors + [ghostN]
        var out: [CGPoint] = [anchors[0]]
        for i in 0..<(padded.count - 3) {
            let p0 = padded[i], p1 = padded[i + 1]
            let p2 = padded[i + 2], p3 = padded[i + 3]
            let t0: CGFloat = 0
            let t1 = t0 + crKnot(p0, p1)
            let t2 = t1 + crKnot(p1, p2)
            let t3 = t2 + crKnot(p2, p3)
            for j in 1...samplesPerSegment {
                let t = t1 + (t2 - t1) * CGFloat(j) / CGFloat(samplesPerSegment)
                out.append(crEvaluate(p0, p1, p2, p3, t0, t1, t2, t3, t))
            }
        }
        return out
    }

    private func crKnot(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let d = (dx * dx + dy * dy).squareRoot()
        // sqrt of distance ⇒ alpha=0.5 (centripetal); floor avoids /0.
        return d > 0 ? d.squareRoot() : 0.0001
    }

    private func crEvaluate(_ p0: CGPoint, _ p1: CGPoint,
                            _ p2: CGPoint, _ p3: CGPoint,
                            _ t0: CGFloat, _ t1: CGFloat,
                            _ t2: CGFloat, _ t3: CGFloat,
                            _ t: CGFloat) -> CGPoint {
        func lerp(_ a: CGPoint, _ b: CGPoint,
                  _ ta: CGFloat, _ tb: CGFloat, _ t: CGFloat) -> CGPoint {
            let denom = tb - ta
            if denom == 0 { return a }
            let u = (tb - t) / denom
            let v = (t - ta) / denom
            return CGPoint(x: u * a.x + v * b.x, y: u * a.y + v * b.y)
        }
        let A1 = lerp(p0, p1, t0, t1, t)
        let A2 = lerp(p1, p2, t1, t2, t)
        let A3 = lerp(p2, p3, t2, t3, t)
        let B1 = lerp(A1, A2, t0, t2, t)
        let B2 = lerp(A2, A3, t1, t3, t)
        return lerp(B1, B2, t1, t2, t)
    }

    /// Seed `anchorsPerStroke` from existing checkpoint chains so a
    /// user opening the calibrator can refine instead of starting
    /// from zero. Bootstrap anchors snap to skeleton so re-opening a
    /// previously-calibrated letter immediately benefits from BFS-fill.
    private func bootstrapAnchorsFromExistingStrokes() {
        for (i, cps) in editableStrokes.enumerated() {
            guard !cps.isEmpty else { continue }
            if let existing = anchorsPerStroke[i], !existing.isEmpty { continue }
            let n = cps.count
            let raw: [CGPoint]
            if n <= 5 {
                raw = cps
            } else {
                let indices = [0, n / 4, n / 2, 3 * n / 4, n - 1]
                raw = indices.map { cps[$0] }
            }
            anchorsPerStroke[i] = raw
        }
    }


    @ViewBuilder
    private func skeletonLayer(in size: CGSize) -> some View {
        if let sk = skeleton, !sk.vizPixels.isEmpty {
            Canvas { context, canvasSize in
                var path = Path()
                for pt in sk.vizPixels {
                    let screenPt = glyphToScreen(pt, in: canvasSize)
                    path.addEllipse(in: CGRect(x: screenPt.x - 1.5,
                                               y: screenPt.y - 1.5,
                                               width: 3.0, height: 3.0))
                }
                context.fill(path, with: .color(.red.opacity(0.9)))
            }
            .allowsHitTesting(false)
        }
    }

    /// Dashed red outline of the renderer's `normalizedGlyphRect`.
    /// Spot-check that the inner glyph bbox actually wraps the glyph —
    /// misalignment here would explain ghost / stroke drift.
    @ViewBuilder
    private func glyphRectDebugLayer(in size: CGSize) -> some View {
        let gr = PrimaeLetterRenderer.normalizedGlyphRect(
            for: vm.currentLetterName,
            canvasSize: size,
            schriftArt: vm.schriftArt,
            openTypeFeatures: vm.currentGlyphFeatures) ?? CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        let rect = CGRect(
            x: gr.minX * size.width,
            y: gr.minY * size.height,
            width: gr.width * size.width,
            height: gr.height * size.height
        )
        Path { p in p.addRect(rect) }
            .stroke(Color.red.opacity(0.6),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func strokePathsLayer(in size: CGSize) -> some View {
        if editableStrokes.indices.contains(activeStroke) {
            let stroke = editableStrokes[activeStroke]
            let pts = stroke.map { glyphToScreen($0, in: size) }
            Path { path in
                guard let first = pts.first else { return }
                path.move(to: first)
                for pt in pts.dropFirst() { path.addLine(to: pt) }
            }
            // butt cap so two strokes meeting at a corner converge to a
            // sharp point — round caps overlap into a blob and look like
            // the strokes "merge along a line" rather than meet at one
            // point.
            .stroke(Color.black.opacity(0.55),
                    style: StrokeStyle(lineWidth: 9,
                                       lineCap: .butt,
                                       lineJoin: .round))
            Path { path in
                guard let first = pts.first else { return }
                path.move(to: first)
                for pt in pts.dropFirst() { path.addLine(to: pt) }
            }
            .stroke(Color.cyan,
                    style: StrokeStyle(lineWidth: 5,
                                       lineCap: .butt,
                                       lineJoin: .round))
            if pts.count >= 2 {
                directionArrow(from: pts[pts.count - 2], to: pts[pts.count - 1])
            }
        }
    }

    @ViewBuilder
    private func directionArrow(from a: CGPoint, to b: CGPoint) -> some View {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = (dx * dx + dy * dy).squareRoot()
        if len > 1 {
            let ux = dx / len, uy = dy / len
            let arrowLen: CGFloat = 14
            let arrowWidth: CGFloat = 9
            let tip = b
            let base = CGPoint(x: b.x - ux * arrowLen, y: b.y - uy * arrowLen)
            let perpX = -uy, perpY = ux
            let left = CGPoint(x: base.x + perpX * arrowWidth,
                               y: base.y + perpY * arrowWidth)
            let right = CGPoint(x: base.x - perpX * arrowWidth,
                                y: base.y - perpY * arrowWidth)
            Path { p in
                p.move(to: tip)
                p.addLine(to: left)
                p.addLine(to: right)
                p.closeSubpath()
            }
            .fill(Color.cyan)
            .overlay(
                Path { p in
                    p.move(to: tip)
                    p.addLine(to: left)
                    p.addLine(to: right)
                    p.closeSubpath()
                }
                .stroke(Color.black.opacity(0.6), lineWidth: 1.5)
            )
        }
    }

    /// Numbered control points the user places, drags, and deletes.
    @ViewBuilder
    private func anchorsLayer(in size: CGSize) -> some View {
        if let anchors = anchorsPerStroke[activeStroke], !anchors.isEmpty {
            let color = strokeColors[activeStroke % strokeColors.count]
            ForEach(Array(anchors.enumerated()), id: \.offset) { idx, pt in
                let screenPt = glyphToScreen(pt, in: size)
                Circle()
                    .fill(color)
                    .frame(width: 28, height: 28)
                    .overlay(Circle().stroke(.white, lineWidth: 3))
                    .overlay(
                        Text("\(idx + 1)")
                            .font(.system(size: 13, weight: .heavy, design: .monospaced))
                            .foregroundStyle(.white)
                    )
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .position(screenPt)
                    .gesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { value in
                                anchorsPerStroke[activeStroke]?[idx] =
                                    screenToGlyph(value.location, in: size)
                            }
                            .onEnded { value in
                                let final = screenToGlyph(value.location, in: size)
                                commitDragWithReorder(final, draggedIdx: idx)
                                rebuildStrokeFromAnchors()
                            }
                    )
                    .onTapGesture {
                        if mode == .delete {
                            removeAnchor(strokeIdx: activeStroke, anchorIdx: idx)
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private func dotsLayer(in size: CGSize) -> some View {
        ForEach(Array(editableStrokes.enumerated()), id: \.offset) { si, stroke in
            if si == activeStroke {
                // Full numbered checkpoint chain for the active stroke.
                ForEach(Array(stroke.enumerated()), id: \.offset) { ci, pt in
                    checkpointDot(si: si, ci: ci, pt: pt, in: size)
                    if ci == 0 {
                        strokeLabel(si: si, pt: pt, in: size)
                    }
                }
            } else if let first = stroke.first {
                // Inactive strokes: faded start dot as a tap-to-switch
                // target so the letter remains readable.
                checkpointDot(si: si, ci: 0, pt: first, in: size)
                strokeLabel(si: si, pt: first, in: size)
            }
        }
    }

    @ViewBuilder
    private func checkpointDot(si: Int, ci: Int, pt: CGPoint, in size: CGSize) -> some View {
        let screenPt = glyphToScreen(pt, in: size)
        let color = strokeColors[si % strokeColors.count]
        let isActive = si == activeStroke
        let diameter: CGFloat = isActive ? 32 : 20
        let fontSize: CGFloat = isActive ? 12 : 9

        // Inactive start dots stay small + faint so the glyph
        // underneath remains readable.
        Circle()
            .fill(color.opacity(isActive ? 1 : 0.35))
            .frame(width: diameter, height: diameter)
            .overlay(
                Text("\(ci + 1)")
                    .font(.system(size: fontSize, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
            )
            .shadow(color: .black.opacity(0.5), radius: 2)
            .position(screenPt)
            .gesture(
                // Dragging any dot switches the active stroke to it,
                // so cross-stroke edits don't require a separate tap.
                mode == .drag
                    ? DragGesture(minimumDistance: 0).onChanged { value in
                        if activeStroke != si { activeStroke = si }
                        editableStrokes[si][ci] = screenToGlyph(value.location, in: size)
                    }
                    : nil
            )
            .onTapGesture {
                if mode == .delete {
                    deleteCheckpoint(si: si, ci: ci)
                } else {
                    activeStroke = si
                }
            }
    }

    @ViewBuilder
    private func strokeLabel(si: Int, pt: CGPoint, in size: CGSize) -> some View {
        let screenPt = glyphToScreen(pt, in: size)
        let color = strokeColors[si % strokeColors.count]
        Text("S\(si + 1)")
            .font(.system(size: 14, weight: .heavy, design: .monospaced))
            .foregroundStyle(color)
            .shadow(color: .black, radius: 2)
            .position(x: screenPt.x - 24, y: screenPt.y - 24)
    }

    // MARK: - Controls

    @ViewBuilder
    private var controlsLayer: some View {
        VStack {
            topBar
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                // 50 pt keeps the bar flush under the debug chips and
                // above the glyph render area for all demo letters.
                .padding(.top, 50)

            if mode == .points {
                let count = anchorsPerStroke[activeStroke]?.count ?? 0
                let hint = count < 2
                    ? "Strich \(activeStroke + 1) — Anker setzen (\(count)/min 2)"
                    : "Strich \(activeStroke + 1) — \(count) Anker gesetzt; ziehen oder weitere Anker korrigieren den Verlauf"
                Text(hint)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
            }

            // Skeleton diagnostics: count + orientation legend so we can
            // verify the centerline extracted at the right position.
            let skLabel: String = {
                guard let sk = skeleton else { return "Skelett: nil" }
                return "Skelett: \(sk.points.count) Punkte (rot=oben, blau=unten)"
            }()
            Text(skLabel)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())

            Spacer()

            bottomBar
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(.bottom, 40)
        }
    }

    @ViewBuilder
    private var topBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Label(vm.schriftArt.displayName, systemImage: "textformat")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.12), in: Capsule())
                    .foregroundStyle(.white)
                    .accessibilityLabel("Schriftart: \(vm.schriftArt.displayName)")

                Spacer(minLength: 0)

                ForEach(CalibrationMode.allCases, id: \.self) { m in
                    modeButton(m)
                }
            }

            HStack(spacing: 8) {
                ForEach(Array(editableStrokes.indices), id: \.self) { si in
                    strokeChip(si: si)
                }

                Button {
                    addStroke()
                } label: {
                    Label("Strich", systemImage: "plus.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.green)

                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func modeButton(_ m: CalibrationMode) -> some View {
        let selected = mode == m
        Button(m.rawValue) { mode = m }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(selected ? Color.white.opacity(0.2) : Color.clear)
            .foregroundStyle(selected ? Color.white : Color.gray)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(selected ? Color.white.opacity(0.4) : Color.clear))
    }

    @ViewBuilder
    private func strokeChip(si: Int) -> some View {
        let color = strokeColors[si % strokeColors.count]
        let selected = activeStroke == si
        Button("S\(si + 1)") { activeStroke = si }
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(selected ? color.opacity(0.35) : Color.clear)
            .foregroundStyle(color)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(selected ? color : Color.clear, lineWidth: 1.5))
    }

    @ViewBuilder
    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button("Reset") { loadFromVM(force: true) }
                .buttonStyle(.bordered)
                .tint(.gray)

            Button("Undo") { undoLastCheckpoint() }
                .buttonStyle(.bordered)
                .tint(.indigo)
                .disabled(!canUndo)

            if editableStrokes.indices.contains(activeStroke) {
                Button {
                    deleteStroke(activeStroke)
                } label: {
                    Label("Strich \(activeStroke + 1)", systemImage: "trash")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }

            Spacer(minLength: 0)

            Button("Apply") { applyToVM() }
                .buttonStyle(.bordered)
                .tint(.blue)

            saveButton

            Button("JSON") {
                exportText = generateJSON()
                showExport = true
            }
            .buttonStyle(.bordered)
            .tint(.orange)

            Button("Alle") {
                exportText = generateAllJSON()
                showExport = true
            }
            .buttonStyle(.bordered)
            .tint(.brown)
            .accessibilityLabel("Alle gespeicherten Kalibrierungen exportieren")

            Button {
                showResetConfirm = true
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .tint(.gray)
            .accessibilityLabel("Alle Kalibrierungen löschen, Bundle übernimmt")
        }
    }

    @ViewBuilder
    private var saveButton: some View {
        let saved = isSaved
        let title = saved ? "Gespeichert ✓" : "Speichern"
        let icon = saved ? "checkmark.circle.fill" : "square.and.arrow.down.fill"
        Button {
            saveToVM()
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .bold))
        }
        .buttonStyle(.borderedProminent)
        .tint(saved ? Color.green : Color.purple)
        .animation(.easeInOut(duration: 0.15), value: saved)
    }

    // MARK: - Coordinate conversion

    /// Calibrations are bbox-relative 0..1 (within the glyph rect).
    /// Screen ↔ stored goes through `normalizedGlyphRect` so a checkpoint
    /// stays aligned with the visible glyph at any cell aspect ratio.
    private func glyphToScreen(_ pt: CGPoint, in size: CGSize) -> CGPoint {
        guard let gr = PrimaeLetterRenderer.normalizedGlyphRect(
            for: vm.currentLetterName, canvasSize: size, schriftArt: vm.schriftArt,
            openTypeFeatures: vm.currentGlyphFeatures) else {
            return CGPoint(x: pt.x * size.width, y: pt.y * size.height)
        }
        return CGPoint(
            x: (gr.minX + pt.x * gr.width) * size.width,
            y: (gr.minY + pt.y * gr.height) * size.height
        )
    }

    private func screenToGlyph(_ pt: CGPoint, in size: CGSize) -> CGPoint {
        guard let gr = PrimaeLetterRenderer.normalizedGlyphRect(
            for: vm.currentLetterName, canvasSize: size, schriftArt: vm.schriftArt,
            openTypeFeatures: vm.currentGlyphFeatures),
              gr.width > 0, gr.height > 0 else {
            let x = pt.x / size.width
            let y = pt.y / size.height
            return CGPoint(
                x: max(-0.05, min(1.05, (x * 100).rounded() / 100)),
                y: max(-0.05, min(1.05, (y * 100).rounded() / 100))
            )
        }
        let x = (pt.x / size.width - gr.minX) / gr.width
        let y = (pt.y / size.height - gr.minY) / gr.height
        return CGPoint(
            x: max(-0.10, min(1.10, (x * 100).rounded() / 100)),
            y: max(-0.10, min(1.10, (y * 100).rounded() / 100))
        )
    }

    // MARK: - Editing

    private func deleteCheckpoint(si: Int, ci: Int) {
        guard editableStrokes.indices.contains(si),
              editableStrokes[si].indices.contains(ci) else { return }
        editableStrokes[si].remove(at: ci)
        if editableStrokes[si].isEmpty {
            deleteStroke(si)
        }
    }

    private var canUndo: Bool {
        editableStrokes.indices.contains(activeStroke) && !editableStrokes[activeStroke].isEmpty
    }

    private func undoLastCheckpoint() {
        guard editableStrokes.indices.contains(activeStroke),
              !editableStrokes[activeStroke].isEmpty else { return }
        editableStrokes[activeStroke].removeLast()
        if editableStrokes[activeStroke].isEmpty {
            deleteStroke(activeStroke)
        }
    }

    private func addStroke() {
        editableStrokes.append([])
        activeStroke = editableStrokes.count - 1
        anchorsPerStroke[activeStroke] = []
        mode = .points
    }

    private func deleteStroke(_ idx: Int) {
        guard editableStrokes.indices.contains(idx) else { return }
        editableStrokes.remove(at: idx)
        activeStroke = max(0, min(activeStroke, editableStrokes.count - 1))
    }

    // MARK: - Data

    /// Load JSON for the current (letter, schriftArt). `force: true`
    /// reloads even when the pair is unchanged (Reset / explicit font
    /// switches); the default call avoids clobbering in-flight edits.
    private func loadFromVM(force: Bool = false) {
        let key = LoadKey(letter: vm.currentLetterName, schriftArt: vm.schriftArt)
        if !force, loaded, loadedKey == key { return }
        guard let raw = vm.glyphRelativeStrokes else { return }
        editableStrokes = raw.strokes.map { stroke in
            stroke.checkpoints.map { cp in
                CGPoint(x: CGFloat(cp.x), y: CGFloat(cp.y))
            }
        }
        // Anchors are stroke-layout-specific; clear when the underlying
        // strokes reload so old anchors don't paint on top of a fresh
        // letter / script.
        anchorsPerStroke.removeAll()
        activeStroke = 0
        loadedKey = key
        loaded = true
        savedFlashUntil = nil
    }

    private func applyToVM() {
        vm.applyCalibration(editableStrokes)
    }

    /// Persists per-script and applies to the live tracker.
    private func saveToVM() {
        vm.applyCalibration(editableStrokes)
        vm.persistCalibratedStrokes(editableStrokes, for: vm.currentLetterName)
        savedFlashUntil = Date().addingTimeInterval(1.2)
        Task {
            try? await Task.sleep(for: .milliseconds(1300))
            if let until = savedFlashUntil, Date() >= until {
                savedFlashUntil = nil
            }
        }
    }

    /// Bundle every letter's effective strokes (calibration if one
    /// was Saved, bundle default otherwise) so a calibration session
    /// can be exported even when individual letters were Applied but
    /// not Saved.
    private func generateAllJSON() -> String {
        let all = vm.loadAllEffectiveStrokes()
        var letters: [[String: Any]] = []
        let sortedKeys = all.keys.sorted()
        for letter in sortedKeys {
            guard let strokes = all[letter] else { continue }
            let strokesArr: [[String: Any]] = strokes.strokes.map { s in
                [
                    "id": s.id,
                    "checkpoints": s.checkpoints.map {
                        ["x": round($0.x * 1000) / 1000,
                         "y": round($0.y * 1000) / 1000]
                    }
                ]
            }
            letters.append([
                "letter": letter,
                "checkpointRadius": strokes.checkpointRadius,
                "strokes": strokesArr,
            ])
        }
        let payload: [String: Any] = [
            "schriftArt": vm.schriftArt.rawValue,
            "letterCount": letters.count,
            "letters": letters,
        ]
        guard let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    private func generateJSON() -> String {
        var dict: [String: Any] = [
            "letter": vm.currentLetterName,
            "checkpointRadius": 0.05
        ]
        let strokesArr: [[String: Any]] = editableStrokes.enumerated().compactMap { (i, pts) in
            guard !pts.isEmpty else { return nil }
            return [
                "id": i + 1,
                "comment": "Stroke \(i + 1)",
                "checkpoints": pts.map { ["x": round($0.x * 1000) / 1000, "y": round($0.y * 1000) / 1000] }
            ] as [String: Any]
        }
        dict["strokes"] = strokesArr
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}

// MARK: - Export sheet

private struct ExportSheet: View {
    let text: String
    let letterName: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private func shareURL() -> URL {
        let base = FileManager.default.temporaryDirectory
        let filename = letterName.isEmpty ? "strokes.json"
            : "\(letterName)_strokes.json"
        let url = base.appendingPathComponent(filename)
        try? text.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("JSON in diese Datei kopieren:")
                    .font(.subheadline)
                    .foregroundStyle(Color.inkSoft)
                Text("Letters/\(letterName)/strokes.json")
                    .font(.system(.body, design: .monospaced))
                    .bold()

                ScrollView {
                    if text.count > 20_000 {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(text.count) Zeichen — Vorschau gekürzt. "
                                 + "Über »Teilen« die ganze Datei sichern.")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(String(text.prefix(2_000))
                                 + "\n\n… (\(text.count - 2_000) weitere Zeichen)")
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Text(text)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }

                HStack(spacing: 12) {
                    Button(copied ? "Kopiert ✓" : "Kopieren") {
                        UIPasteboard.general.string = text
                        copied = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(copied ? .green : .blue)

                    ShareLink(
                        item: shareURL(),
                        preview: SharePreview("strokes.json")
                    ) {
                        Label("Teilen", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
            .navigationTitle("Stroke-JSON")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }
}
