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
    @State private var topMode: TopMode = .skelett
    @State private var skelettTool: SkelettTool = .drag
    @State private var ankerTool: AnkerTool = .place
    /// Whole-state snapshots of `editableStrokes` pushed before every
    /// mutation. Capped at 10 entries; popping replaces the entire
    /// polyline state. Cleared on letter/script switch.
    /// Snapshots of (handles, editableStrokes) pushed before each
    /// mutation. SKELETT edits mutate handles (and downstream
    /// editableStrokes via resampling); ANKER edits mutate
    /// editableStrokes directly. Snapshotting both keeps undo
    /// consistent across modes.
    @State private var undoStack: [UndoSnapshot] = []

    private struct UndoSnapshot {
        let handles: [[CGPoint]]
        let editableStrokes: [[CGPoint]]
    }
    /// Handle the active SKELETT drag is moving (picked at touch-
    /// down by closest-handle hit-test, carried until touch-up).
    @State private var dragTargetSi: Int? = nil
    @State private var dragTargetCi: Int? = nil
    /// Touch-down position in bbox-rel; used to detect tap vs drag.
    @State private var dragStartPt: CGPoint? = nil
    /// True once movement from `dragStartPt` exceeds the drag-threshold
    /// (0.025 bbox-rel ≈ 12 px). Below this, the touch is treated as a
    /// tap — no handle movement, no undo snapshot. This kills the
    /// Pencil micro-jitter (5-15 px during natural taps) that was
    /// invisibly drifting handles.
    @State private var gestureExceededDragThreshold: Bool = false
    /// Captured at threshold-crossing: vector from current Pencil pt
    /// to the handle's original pt. Subsequent moves apply this
    /// offset so the handle tracks the Pencil 1:1 instead of jumping
    /// 12 px to the threshold-crossing position. Result: any motion
    /// past threshold yields the same magnitude of handle motion.
    @State private var dragHandleOffset: CGPoint? = nil
    /// True after any mutation to editableStrokes / handles /
    /// anchorsPerStroke since the last Speichern. Drives the auto-
    /// save guards before navigation (letter switch, schriftArt
    /// switch) and before the "Alle" export — without those guards
    /// in-memory edits silently disappear when loadFromVM
    /// overwrites editableStrokes, and the "Alle" export reads only
    /// persisted data so it would miss unsaved edits entirely.
    @State private var hasUnsavedEdits: Bool = false
    /// SKELETT mode: show "1, 2, 3 …" numbers inside each handle.
    /// Off by default — numbers are debug noise during skeleton
    /// editing.
    @State private var showSkelettNumbers: Bool = false
    /// Sparse editable handles per stroke. Derived from the file's
    /// polyline via RDP on SKELETT entry; the rendered curve is the
    /// Catmull-Rom spline through these handles. NOT persisted —
    /// `strokes.json` continues to hold the resampled checkpoints.
    @State private var handles: [[CGPoint]] = []
    /// Original checkpoint count per stroke, captured at load
    /// time. Save resamples the spline back to this count so the
    /// file's density is preserved (40-cp files stay at 40, 104-cp
    /// stay at 104).
    @State private var originalCpCounts: [Int] = []
    /// RDP epsilon in bbox-rel. Picked from the per-letter cp-count
    /// diagnostic (max=120 → mid bucket → 0.025).
    private let handleRdpEps: CGFloat = 0.025
    /// Catmull-Rom sampling density per handle pair when rendering
    /// the smooth path and computing closest-point hit-tests.
    private let splineSamplesPerSegment: Int = 80
    @State private var savedFlashUntil: Date? = nil
    @State private var showResetConfirm = false
    /// (letter, schriftArt) of the last reload — both invalidate so a
    /// font switch picks up the other script's saved strokes.
    @State private var loadedKey: LoadKey? = nil

    private struct LoadKey: Equatable {
        let letter: String
        let schriftArt: SchriftArt
    }

    /// Binary top-level layer toggle. SKELETT mode edits the polyline
    /// directly; ANKER mode places pedagogical routing waypoints that
    /// BFS-walk the skeleton between them.
    enum TopMode: String, CaseIterable {
        case skelett = "Skelett"
        case anker = "Anker"
    }

    /// Sub-tools active when `topMode == .skelett`. The polyline is
    /// shown as a Catmull-Rom spline through a small set of handles
    /// derived from the file's checkpoints via RDP; sub-tools edit
    /// the HANDLES, not the underlying checkpoints. Glätten was
    /// removed — the handle model makes it redundant (reduce local
    /// detail by deleting handles).
    enum SkelettTool: String, CaseIterable {
        case drag = "Ziehen"
        case insert = "Hinzufügen"
        case delete = "Entfernen"
    }

    /// Sub-tools active when `topMode == .anker`. Anchor placement +
    /// drag + delete mirrors the pre-refactor `.points/.drag/.delete`
    /// triple; the polyline is rebuilt by BFS-walking the skeleton
    /// between the anchors.
    enum AnkerTool: String, CaseIterable {
        case place = "Setzen"
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

    /// Reserved bottom area where `controlsLayer`'s cards sit. The
    /// canvas math treats `size.height` as `geo.size.height - this`
    /// so the glyph (and its descender) are drawn ENTIRELY above
    /// the UI bar instead of behind the translucent material.
    ///
    /// Components: 82pt topBar (segmented + pills row + chip row +
    /// internal padding) + 10pt gap + 52pt action bar + 20pt
    /// bottom inset + ~16pt safety margin = ~180pt.
    private let bottomUIInset: CGFloat = 180

    var body: some View {
        GeometryReader { geo in
            let size = CGSize(
                width: geo.size.width,
                height: max(0, geo.size.height - bottomUIInset))
            ZStack {
                addTapLayer(in: size)
                glyphRectDebugLayer(in: size)
                skeletonLayer(in: size)
                strokePathsLayer(in: size)
                if topMode == .skelett { handleLayer(in: size) }
                if topMode == .anker {
                    anchorsLayer(in: size)
                    polylineReferenceLayer(in: size)
                }
                if topMode == .skelett {
                    // Pencil-only canvas gesture, clipped to glyph bbox.
                    // Sits above visual layers so it gets first crack at
                    // touches in the canvas area; below controlsLayer
                    // so the mode/sub-tool buttons remain reachable.
                    PencilDragLayer(
                        glyphRectScreen: glyphRectScreen(in: size),
                        onBegan: { handleSkelettBegan(atScreen: $0, in: size) },
                        onChanged: { handleSkelettChanged(atScreen: $0, in: size) },
                        onEnded: { handleSkelettEnded(atScreen: $0, in: size) }
                    )
                }
                controlsLayer
            }
            .onAppear {
                loadFromVM()
                bootstrapAnchorsFromExistingStrokes()
                bootstrapHandles()
                refreshSkeleton()
            }
            .onChange(of: vm.currentLetterName) {
                // Persist before loadFromVM overwrites editableStrokes.
                // CRITICAL: vm.currentLetterName has ALREADY become the
                // new letter by the time this onChange closure fires —
                // saveToVM() would persist the previous letter's edits
                // under the new letter's key, corrupting both. Use the
                // explicit loadedKey.letter (still the previous letter)
                // as the save target instead. vm.schriftArt is unchanged
                // on a letter switch so the single-arg overload is fine.
                if hasUnsavedEdits, loaded, let prevKey = loadedKey {
                    vm.persistCalibratedStrokes(editableStrokes,
                                                 for: prevKey.letter)
                    hasUnsavedEdits = false
                }
                loadFromVM()
                bootstrapAnchorsFromExistingStrokes()
                bootstrapHandles()
                refreshSkeleton()
            }
            .onChange(of: vm.schriftArt) {
                // Same correctness issue as the letter-switch handler
                // PLUS vm.schriftArt has also already changed — use
                // both fields from loadedKey to target the previous
                // (letter, schriftArt) explicitly.
                if hasUnsavedEdits, loaded, let prevKey = loadedKey {
                    vm.persistCalibratedStrokes(editableStrokes,
                                                 for: prevKey.letter,
                                                 schriftArt: prevKey.schriftArt)
                    hasUnsavedEdits = false
                }
                loadFromVM(force: true)
                bootstrapAnchorsFromExistingStrokes()
                bootstrapHandles()
                refreshSkeleton()
            }
            .onChange(of: topMode) {
                if topMode == .anker { bootstrapAnchorsFromExistingStrokes() }
                if topMode == .skelett { bootstrapHandles() }
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
                hasUnsavedEdits = false
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
        if topMode == .anker && ankerTool == .place {
            // Anchor placement: any tap, no cp picking needed.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { location in
                    let bboxPt = screenToGlyph(location, in: size)
                    addAnchor(bboxPt)
                }
        }
        // SKELETT canvas gesture moved to PencilDragLayer (palm
        // rejection + bbox clip). Finger touches and out-of-bbox
        // contacts no longer fire the gesture.
    }

    /// Bbox-relative drag threshold. Movement below this is a tap;
    /// movement above this engages drag mode. 0.025 bbox-rel ≈ 12 px
    /// on a 1024² canvas — comfortably above Pencil micro-jitter
    /// (5-15 px) but small enough that intentional drags feel
    /// responsive.
    private let skelettDragThreshold: CGFloat = 0.025

    /// Glyph bbox in SwiftUI screen-coord space — passed to the
    /// PencilDragLayer for hit-test clipping.
    private func glyphRectScreen(in size: CGSize) -> CGRect {
        let gr = PrimaeLetterRenderer.normalizedGlyphRect(
            for: vm.currentLetterName,
            canvasSize: size,
            schriftArt: vm.schriftArt,
            openTypeFeatures: vm.currentGlyphFeatures)
            ?? CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        return CGRect(x: gr.minX * size.width,
                      y: gr.minY * size.height,
                      width: gr.width * size.width,
                      height: gr.height * size.height)
    }

    /// SKELETT touch-down. Pick the closest handle as the drag
    /// target but DON'T commit (no undo snapshot, no activeStroke
    /// switch yet). Commitment happens only when movement crosses
    /// `skelettDragThreshold`.
    private func handleSkelettBegan(atScreen screenPt: CGPoint, in size: CGSize) {
        let bboxPt = screenToGlyph(screenPt, in: size)
        dragStartPt = bboxPt
        gestureExceededDragThreshold = false
        dragHandleOffset = nil
        if skelettTool == .drag, let target = closestHandle(to: bboxPt) {
            dragTargetSi = target.si
            dragTargetCi = target.ci
        } else {
            dragTargetSi = nil
            dragTargetCi = nil
        }
    }

    /// SKELETT touch-move. Below drag threshold = no-op (tap in
    /// progress). At threshold crossing, capture the handle's offset
    /// from the Pencil so subsequent motion tracks the Pencil 1:1
    /// instead of snapping to it.
    private func handleSkelettChanged(atScreen screenPt: CGPoint, in size: CGSize) {
        let bboxPt = screenToGlyph(screenPt, in: size)
        guard let start = dragStartPt else { return }
        if !gestureExceededDragThreshold {
            let dx = bboxPt.x - start.x, dy = bboxPt.y - start.y
            let dist = (dx * dx + dy * dy).squareRoot()
            guard dist > skelettDragThreshold else { return }
            gestureExceededDragThreshold = true
            if skelettTool == .drag,
               let si = dragTargetSi, let ci = dragTargetCi,
               handles.indices.contains(si),
               handles[si].indices.contains(ci) {
                pushUndoSnapshot()
                if activeStroke != si { activeStroke = si }
                // Capture the offset from Pencil to handle at the
                // moment we engage drag. Subsequent moves preserve
                // this offset, so the handle's position relative to
                // its original anchor matches the Pencil's relative
                // motion — no 12-px snap.
                let h = handles[si][ci]
                dragHandleOffset = CGPoint(x: h.x - bboxPt.x,
                                           y: h.y - bboxPt.y)
            }
        }
        if skelettTool == .drag,
           let si = dragTargetSi, let ci = dragTargetCi,
           let offset = dragHandleOffset,
           handles.indices.contains(si),
           handles[si].indices.contains(ci) {
            handles[si][ci] = CGPoint(x: bboxPt.x + offset.x,
                                       y: bboxPt.y + offset.y)
            syncEditableForStroke(si)
        }
    }

    /// SKELETT touch-up. If the gesture never crossed the drag
    /// threshold, it was a tap → dispatch to `handleSkelettTap`.
    /// Otherwise the drag already committed the edit during
    /// `handleSkelettChanged`.
    private func handleSkelettEnded(atScreen screenPt: CGPoint, in size: CGSize) {
        let bboxPt = screenToGlyph(screenPt, in: size)
        if !gestureExceededDragThreshold {
            handleSkelettTap(at: bboxPt)
        }
        dragStartPt = nil
        dragTargetSi = nil
        dragTargetCi = nil
        gestureExceededDragThreshold = false
        dragHandleOffset = nil
    }

    private func handleSkelettTap(at bboxPt: CGPoint) {
        switch skelettTool {
        case .drag:
            // Tap (no drag) in drag mode = switch active stroke if
            // tap lands on an inactive handle.
            if let target = closestHandle(to: bboxPt),
               target.si != activeStroke {
                activeStroke = target.si
            }
        case .insert:
            insertHandleOnSpline(at: bboxPt)
        case .delete:
            if let target = closestHandle(to: bboxPt),
               handles.indices.contains(target.si),
               handles[target.si].count > 2 {
                pushUndoSnapshot()
                handles[target.si].remove(at: target.ci)
                syncEditableForStroke(target.si)
            }
        }
    }

    /// Closest-handle hit-test. Active stroke preferred — if any
    /// active-stroke handle is within ACTIVE_RADIUS, return it.
    /// Otherwise expand to all strokes.
    private func closestHandle(to pt: CGPoint) -> (si: Int, ci: Int)? {
        let activeRadius: CGFloat = 0.06
        var activeBest: (si: Int, ci: Int)? = nil
        var activeBestDist = CGFloat.infinity
        if handles.indices.contains(activeStroke) {
            for (ci, hp) in handles[activeStroke].enumerated() {
                let dx = hp.x - pt.x, dy = hp.y - pt.y
                let d = (dx * dx + dy * dy).squareRoot()
                if d < activeBestDist {
                    activeBestDist = d
                    activeBest = (activeStroke, ci)
                }
            }
        }
        if let best = activeBest, activeBestDist <= activeRadius {
            return best
        }
        var globalBest: (si: Int, ci: Int)? = nil
        var globalBestDist = CGFloat.infinity
        for (si, hs) in handles.enumerated() {
            for (ci, hp) in hs.enumerated() {
                let dx = hp.x - pt.x, dy = hp.y - pt.y
                let d = (dx * dx + dy * dy).squareRoot()
                if d < globalBestDist {
                    globalBestDist = d
                    globalBest = (si, ci)
                }
            }
        }
        return globalBest
    }

    /// Insert a new handle on the active stroke's spline at the
    /// closest point to the tap. Position in the handle array is
    /// determined by which handle-pair segment the tap projects
    /// onto.
    private func insertHandleOnSpline(at pt: CGPoint) {
        guard handles.indices.contains(activeStroke),
              handles[activeStroke].count >= 2 else { return }
        let hs = handles[activeStroke]
        // Sample the spline densely; find the closest sample to the
        // tap and convert that sample's index back to a handle-pair
        // boundary.
        let dense = denseSpline(hs)
        var bestIdx = 0
        var bestDist = CGFloat.infinity
        for (i, sp) in dense.enumerated() {
            let dx = sp.x - pt.x, dy = sp.y - pt.y
            let d = (dx * dx + dy * dy).squareRoot()
            if d < bestDist { bestDist = d; bestIdx = i }
        }
        // Threshold: only insert if the tap is within ~30 pt of the
        // path so a stray tap doesn't add a wild handle.
        guard bestDist <= 0.05 else { return }
        let segIdx = bestIdx / splineSamplesPerSegment
        // Insertion goes between handle segIdx and segIdx+1, so the
        // new handle sits at array index segIdx+1.
        let insertAt = min(hs.count, segIdx + 1)
        pushUndoSnapshot()
        handles[activeStroke].insert(dense[bestIdx], at: insertAt)
        syncEditableForStroke(activeStroke)
    }

    /// Bootstrap `handles` + `originalCpCounts` from the current
    /// `editableStrokes`. Called on letter switch, on SKELETT-mode
    /// entry, and after Save (so the next session starts from a
    /// regenerated handle set). Edge cases:
    ///   - 1-cp stroke (umlaut dot, i/j tittle): handles = [pt],
    ///     no editing on this stroke.
    ///   - 2-3 cp stroke: handles = all cps, RDP would over-
    ///     simplify.
    ///   - ≥4 cp stroke: RDP at ε=0.025, clamped to [4, 15].
    private func bootstrapHandles() {
        handles = editableStrokes.map { stroke in
            switch stroke.count {
            case 0: return []
            case 1, 2, 3: return stroke
            default:
                var hs = Self.rdpSimplify(stroke, eps: handleRdpEps)
                if hs.count > 15 {
                    // Keep first/last + 13 evenly-spaced interior.
                    var reduced: [CGPoint] = [hs[0]]
                    for k in 1..<14 {
                        let idx = Int(round(Double(k)
                            * Double(hs.count - 1) / 14.0))
                        reduced.append(hs[idx])
                    }
                    reduced.append(hs[hs.count - 1])
                    hs = reduced
                } else if hs.count < 4 {
                    let n = stroke.count
                    hs = [stroke[0], stroke[n / 3],
                          stroke[2 * n / 3], stroke[n - 1]]
                }
                return hs
            }
        }
        originalCpCounts = editableStrokes.map { $0.count }
        // editableStrokes is already the file's polyline; we don't
        // overwrite it on bootstrap. Sync happens on first edit.
    }

    /// Resample `handles[si]` back into `editableStrokes[si]` at
    /// `originalCpCounts[si]` density. Called after every handle
    /// mutation so the runtime preview / save reflect the edit.
    private func syncEditableForStroke(_ si: Int) {
        guard handles.indices.contains(si),
              originalCpCounts.indices.contains(si),
              editableStrokes.indices.contains(si) else { return }
        hasUnsavedEdits = true
        let hs = handles[si]
        let n = originalCpCounts[si]
        guard n > 0 else {
            editableStrokes[si] = hs
            return
        }
        switch hs.count {
        case 0:
            editableStrokes[si] = []
        case 1:
            editableStrokes[si] = Array(repeating: hs[0], count: n)
        case 2:
            var pts: [CGPoint] = []
            for k in 0..<n {
                let t = n == 1 ? 0 : CGFloat(k) / CGFloat(n - 1)
                pts.append(CGPoint(
                    x: hs[0].x + t * (hs[1].x - hs[0].x),
                    y: hs[0].y + t * (hs[1].y - hs[0].y)))
            }
            editableStrokes[si] = pts
        default:
            let dense = denseSpline(hs)
            editableStrokes[si] = resampleUniformBbox(dense, count: n)
        }
    }

    /// Catmull-Rom spline through `handles` at the configured
    /// samples-per-segment. Wraps the existing centripetal CR
    /// helper so caller doesn't need to know its sample count.
    private func denseSpline(_ hs: [CGPoint]) -> [CGPoint] {
        guard hs.count >= 3 else { return hs }
        return catmullRomSpline(hs,
                                samplesPerSegment: splineSamplesPerSegment)
    }

    /// Stamp the current (handles, editableStrokes) onto the undo
    /// stack before a mutation. Cap at 10 deep.
    private func pushUndoSnapshot() {
        undoStack.append(
            UndoSnapshot(handles: handles, editableStrokes: editableStrokes))
        if undoStack.count > 10 {
            undoStack.removeFirst()
        }
    }

    /// Restore the most-recent snapshot. Anchors are NOT included
    /// (transient per A1) — they re-bootstrap from the restored
    /// polyline next time ANKER mode is entered.
    private func popUndoSnapshot() {
        guard let last = undoStack.popLast() else { return }
        handles = last.handles
        editableStrokes = last.editableStrokes
        hasUnsavedEdits = true
        if activeStroke >= editableStrokes.count {
            activeStroke = max(0, editableStrokes.count - 1)
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
        hasUnsavedEdits = true
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
    /// Bridge edges (Phase 3 skeleton split) are unioned into the routing
    /// adjacency so anchor-snap BFS routes cleanly across former cluster
    /// gaps. They are NOT added to `vizPixels` — the red-dot viz keeps
    /// the visual split intact.
    private func makeBakedSkeleton() -> GlyphSkeleton? {
        guard let strokes = vm.glyphRelativeStrokes,
              let skel = strokes.skeleton,
              let adj = strokes.skeletonAdj,
              !skel.isEmpty,
              skel.count == adj.count else { return nil }
        let points = skel.map { CGPoint(x: $0.x, y: $0.y) }
        var augmented = adj
        if let bridges = strokes.bridgeEdges {
            for edge in bridges where edge.count == 2 {
                let i = edge[0]
                let j = edge[1]
                guard i >= 0, i < augmented.count,
                      j >= 0, j < augmented.count else { continue }
                if !augmented[i].contains(j) { augmented[i].append(j) }
                if !augmented[j].contains(i) { augmented[j].append(i) }
            }
        }
        return GlyphSkeleton(points: points, adjacency: augmented,
                             vizPixels: points)
    }

    /// Commit a dragged anchor and re-insert it at the spatially-
    /// closest segment so the polyline walks anchors in visible order
    /// rather than tap order.
    private func commitDragWithReorder(_ snapped: CGPoint, draggedIdx: Int) {
        guard var anchors = anchorsPerStroke[activeStroke] else { return }
        anchors[draggedIdx] = snapped
        hasUnsavedEdits = true
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
        hasUnsavedEdits = true
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
                                hasUnsavedEdits = true
                            }
                            .onEnded { value in
                                let final = screenToGlyph(value.location, in: size)
                                commitDragWithReorder(final, draggedIdx: idx)
                                rebuildStrokeFromAnchors()
                            }
                    )
                    .onTapGesture {
                        if topMode == .anker && ankerTool == .delete {
                            removeAnchor(strokeIdx: activeStroke, anchorIdx: idx)
                        }
                    }
            }
        }
    }

    /// Faint read-only checkpoint dots shown in ANKER mode so the
    /// underlying polyline remains visible while the user edits
    /// anchors. The polyline path itself is still drawn by
    /// `strokePathsLayer`; this adds the per-cp dots in a
    /// non-editable form.
    @ViewBuilder
    private func polylineReferenceLayer(in size: CGSize) -> some View {
        if editableStrokes.indices.contains(activeStroke) {
            let stroke = editableStrokes[activeStroke]
            let color = strokeColors[activeStroke % strokeColors.count]
            ForEach(Array(stroke.enumerated()), id: \.offset) { _, pt in
                let screenPt = glyphToScreen(pt, in: size)
                Circle()
                    .fill(color.opacity(0.35))
                    .frame(width: 6, height: 6)
                    .position(screenPt)
                    .allowsHitTesting(false)
            }
        }
    }

    /// SKELETT mode handle + inactive-path layer. Replaces the old
    /// 40-checkpoint dot grid. Handles are pure visual decoration
    /// here — the top-level gesture layer does all hit-testing.
    @ViewBuilder
    private func handleLayer(in size: CGSize) -> some View {
        // Inactive stroke paths: faint 2 pt outline so the letter
        // shape stays visible while the user edits the active one.
        ForEach(Array(editableStrokes.enumerated()), id: \.offset) { si, stroke in
            if si != activeStroke, stroke.count >= 2 {
                let color = strokeColors[si % strokeColors.count]
                let pts = stroke.map { glyphToScreen($0, in: size) }
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: first)
                    for pt in pts.dropFirst() { p.addLine(to: pt) }
                }
                .stroke(color.opacity(0.5),
                        style: StrokeStyle(lineWidth: 2,
                                           lineCap: .round,
                                           lineJoin: .round))
                .allowsHitTesting(false)
            }
        }
        // Handle dots: active stroke prominent (18 pt), inactive
        // strokes show all handles small (10 pt @ 40 %).
        ForEach(Array(handles.enumerated()), id: \.offset) { si, hs in
            let color = strokeColors[si % strokeColors.count]
            let isActive = si == activeStroke
            let diameter: CGFloat = isActive ? 18 : 10
            ForEach(Array(hs.enumerated()), id: \.offset) { ci, hp in
                let screenPt = glyphToScreen(hp, in: size)
                Circle()
                    .fill(color.opacity(isActive ? 1.0 : 0.4))
                    .frame(width: diameter, height: diameter)
                    .overlay(
                        Circle().stroke(Color.white,
                                        lineWidth: isActive ? 2 : 1)
                    )
                    .shadow(color: .black.opacity(0.4), radius: 1.5)
                    .position(screenPt)
                    .allowsHitTesting(false)
                if showSkelettNumbers && isActive {
                    Text("\(ci + 1)")
                        .font(.system(size: 10, weight: .bold,
                                      design: .monospaced))
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 1)
                        .position(x: screenPt.x, y: screenPt.y - 14)
                        .allowsHitTesting(false)
                }
            }
            // Active-stroke S-label near the first handle.
            if isActive, let first = hs.first {
                strokeLabel(si: si, pt: first, in: size)
            } else if let first = hs.first {
                strokeLabel(si: si, pt: first, in: size)
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

        // CHANGE 1: small unnumbered dots in SKELETT mode (gesture
        // routing now happens at the top-level layer, so dots are
        // pure visual decoration). Numbers come back when the user
        // toggles "Nummern" on.
        if topMode == .skelett {
            let diameter: CGFloat = isActive ? 12 : 8
            Circle()
                .fill(color.opacity(isActive ? 1.0 : 0.35))
                .frame(width: diameter, height: diameter)
                .overlay(
                    Circle().stroke(Color.white.opacity(isActive ? 0.9 : 0.4),
                                    lineWidth: 1)
                )
                .position(screenPt)
                .allowsHitTesting(false)
            if showSkelettNumbers && isActive {
                Text("\(ci + 1)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .shadow(color: .black, radius: 1)
                    .position(x: screenPt.x, y: screenPt.y - 12)
                    .allowsHitTesting(false)
            }
        } else {
            // ANKER mode: full-size numbered dots, unchanged
            // behavior. Anchors handle their own gestures via
            // anchorsLayer; these dots are read-only reference
            // markers, so they're non-interactive here too.
            let diameter: CGFloat = isActive ? 32 : 20
            let fontSize: CGFloat = isActive ? 12 : 9
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
                .allowsHitTesting(false)
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
            // Top: schriftart badge + status text + skeleton diagnostic.
            // All informational and small — they don't compete with tall
            // letters for canvas space. Schriftart moved here from the
            // bottom topBar so descenders aren't occluded.
            Label(vm.schriftArt.displayName, systemImage: "textformat")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 50)
                .accessibilityLabel("Schriftart: \(vm.schriftArt.displayName)")

            Text(statusHint)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())

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

            // Bottom: control stack (mode toggle + sub-tools + chips on
            // top, persistent action buttons below). Leaves the full
            // upper canvas free for tall uppercase letters.
            VStack(spacing: 10) {
                topBar
                    .padding(10)
                    .background(.ultraThinMaterial,
                                in: RoundedRectangle(cornerRadius: 10))
                bottomBar
                    .padding(10)
                    .background(.ultraThinMaterial,
                                in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(.bottom, 20)
        }
    }

    @ViewBuilder
    private var topBar: some View {
        VStack(spacing: 6) {
            // Row 1: Skelett/Anker segmented control + active sub-tool
            // pills, inline. Segmented is fixed-width so changing pill
            // count (4 in SKELETT vs 3 in ANKER) doesn't shift it.
            HStack(spacing: 10) {
                Picker("Modus", selection: $topMode) {
                    ForEach(TopMode.allCases, id: \.self) { tm in
                        Text(tm.rawValue).tag(tm)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .accessibilityLabel("Modus: Skelett oder Anker")

                if topMode == .skelett {
                    ForEach(SkelettTool.allCases, id: \.self) { t in
                        skelettToolButton(t)
                    }
                    numbersToggleButton
                } else {
                    ForEach(AnkerTool.allCases, id: \.self) { t in
                        ankerToolButton(t)
                    }
                }
                Spacer(minLength: 0)
            }

            // Row 2: stroke chips on their own slim row. Kept separate
            // from row 1 because chip count varies 1-4 per letter and
            // inline reflow with the pill row is unreliable on device.
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
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func skelettToolButton(_ t: SkelettTool) -> some View {
        let selected = skelettTool == t
        Button(t.rawValue) { skelettTool = t }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(selected ? Color.white.opacity(0.22) : Color.clear)
            .foregroundStyle(selected ? Color.white : Color.gray)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(selected ? Color.white.opacity(0.5) : Color.clear))
    }

    @ViewBuilder
    private var numbersToggleButton: some View {
        Button(showSkelettNumbers ? "Nummern ✓" : "Nummern") {
            showSkelettNumbers.toggle()
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(showSkelettNumbers ? Color.white.opacity(0.22) : Color.clear)
        .foregroundStyle(showSkelettNumbers ? Color.white : Color.gray)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(showSkelettNumbers
                                  ? Color.white.opacity(0.5) : Color.clear))
    }

    @ViewBuilder
    private func ankerToolButton(_ t: AnkerTool) -> some View {
        let selected = ankerTool == t
        Button(t.rawValue) { ankerTool = t }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(selected ? Color.white.opacity(0.22) : Color.clear)
            .foregroundStyle(selected ? Color.white : Color.gray)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(selected ? Color.white.opacity(0.5) : Color.clear))
    }

    /// One-line user-facing hint that always reflects (topMode,
    /// active sub-tool, range-selection state).
    private var statusHint: String {
        let strichLabel = "Strich \(activeStroke + 1)"
        switch topMode {
        case .skelett:
            let handleCount = handles.indices.contains(activeStroke)
                ? handles[activeStroke].count : 0
            switch skelettTool {
            case .drag:
                return "Skelett-Bearbeitung — \(strichLabel) (\(handleCount) Griffe): Griff ziehen"
            case .insert:
                return "Skelett-Bearbeitung — \(strichLabel): auf den Verlauf tippen, um einen Griff hinzuzufügen"
            case .delete:
                return "Skelett-Bearbeitung — \(strichLabel): Griff antippen, um zu entfernen"
            }
        case .anker:
            let count = anchorsPerStroke[activeStroke]?.count ?? 0
            switch ankerTool {
            case .place:
                return count < 2
                    ? "Anker setzen — \(strichLabel): \(count)/min 2"
                    : "Anker setzen — \(strichLabel): \(count) Anker, weitere durch Tippen ergänzen"
            case .drag:
                return "Anker setzen — \(strichLabel): Anker ziehen, um den Verlauf zu korrigieren"
            case .delete:
                return "Anker setzen — \(strichLabel): Anker antippen, um zu entfernen"
            }
        }
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

            Button("Undo") { popUndoSnapshot() }
                .buttonStyle(.bordered)
                .tint(.indigo)
                .disabled(undoStack.isEmpty)

            if editableStrokes.indices.contains(activeStroke) {
                Button {
                    pushUndoSnapshot()
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
                // Auto-save before reading from persistence. Without
                // this, loadAllEffectiveStrokes returns CalibrationStore
                // + bundle data only and the current letter's unsaved
                // SKELETT/ANKER edits are absent from the export.
                if hasUnsavedEdits { saveToVM() }
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
        // No edit-time rounding: quantising bbox-rel here used to snap to
        // 0.01 (≈ 8 px on a 1024-px canvas), making fine handle
        // positioning impossible. The single quantisation point is
        // CalibrationStore.persist's 3-decimal rounding at save time.
        guard let gr = PrimaeLetterRenderer.normalizedGlyphRect(
            for: vm.currentLetterName, canvasSize: size, schriftArt: vm.schriftArt,
            openTypeFeatures: vm.currentGlyphFeatures),
              gr.width > 0, gr.height > 0 else {
            let x = pt.x / size.width
            let y = pt.y / size.height
            return CGPoint(
                x: max(-0.05, min(1.05, x)),
                y: max(-0.05, min(1.05, y))
            )
        }
        let x = (pt.x / size.width - gr.minX) / gr.width
        let y = (pt.y / size.height - gr.minY) / gr.height
        return CGPoint(
            x: max(-0.10, min(1.10, x)),
            y: max(-0.10, min(1.10, y))
        )
    }

    // MARK: - Editing

    private func addStroke() {
        pushUndoSnapshot()
        editableStrokes.append([])
        activeStroke = editableStrokes.count - 1
        anchorsPerStroke[activeStroke] = []
        hasUnsavedEdits = true
        topMode = .anker
        ankerTool = .place
    }

    private func deleteStroke(_ idx: Int) {
        guard editableStrokes.indices.contains(idx) else { return }
        editableStrokes.remove(at: idx)
        hasUnsavedEdits = true
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
        undoStack.removeAll()
        handles.removeAll()
        originalCpCounts.removeAll()
        // Fresh from persistence/bundle — nothing unsaved yet.
        hasUnsavedEdits = false
    }

    private func applyToVM() {
        vm.applyCalibration(editableStrokes)
    }

    /// Persists per-script and applies to the live tracker.
    private func saveToVM() {
        vm.applyCalibration(editableStrokes)
        vm.persistCalibratedStrokes(editableStrokes, for: vm.currentLetterName)
        hasUnsavedEdits = false
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

// MARK: - Pencil-only canvas gesture (palm rejection + bbox clip)

/// SKELETT-mode canvas input. Uses a UILongPressGestureRecognizer
/// (minimumPressDuration=0) restricted to `.pencil` touches so palm
/// contacts never fire the gesture. The hosting UIView's `hitTest`
/// clips to the glyph bbox so Pencil touches outside the letter
/// (e.g. on the bottom bar buttons) fall through to SwiftUI layers
/// below.
private struct PencilDragLayer: UIViewRepresentable {
    let glyphRectScreen: CGRect
    let onBegan: (CGPoint) -> Void
    let onChanged: (CGPoint) -> Void
    let onEnded: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onBegan: onBegan, onChanged: onChanged, onEnded: onEnded)
    }

    func makeUIView(context: Context) -> UIView {
        let view = PencilHitTestView()
        view.backgroundColor = .clear
        view.bboxScreen = glyphRectScreen
        let r = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handle(_:)))
        r.minimumPressDuration = 0
        // Don't cancel the gesture on movement — we own tap-vs-drag.
        r.allowableMovement = .greatestFiniteMagnitude
        r.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.pencil.rawValue)
        ]
        view.addGestureRecognizer(r)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if let v = uiView as? PencilHitTestView {
            v.bboxScreen = glyphRectScreen
        }
        context.coordinator.onBegan = onBegan
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
    }

    final class Coordinator: NSObject {
        var onBegan: (CGPoint) -> Void
        var onChanged: (CGPoint) -> Void
        var onEnded: (CGPoint) -> Void

        init(onBegan: @escaping (CGPoint) -> Void,
             onChanged: @escaping (CGPoint) -> Void,
             onEnded: @escaping (CGPoint) -> Void) {
            self.onBegan = onBegan
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        @objc func handle(_ r: UILongPressGestureRecognizer) {
            let pt = r.location(in: r.view)
            switch r.state {
            case .began:
                onBegan(pt)
            case .changed:
                onChanged(pt)
            case .ended, .cancelled, .failed:
                onEnded(pt)
            default:
                break
            }
        }
    }
}

/// Hit-test only claims touches within the glyph bbox (plus a small
/// margin). Touches outside fall through to SwiftUI layers below so
/// the control bar buttons remain reachable.
private final class PencilHitTestView: UIView {
    var bboxScreen: CGRect = .zero

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let margin: CGFloat = 20
        let expanded = bboxScreen.insetBy(dx: -margin, dy: -margin)
        guard expanded.contains(point) else { return nil }
        return super.hitTest(point, with: event)
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
                Text("Letters/Regular/\(letterName)/strokes.json")
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
