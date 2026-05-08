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
    /// (letter, schriftArt) of the last reload — both invalidate so a
    /// font switch picks up the other script's saved strokes.
    @State private var loadedKey: LoadKey? = nil

    private struct LoadKey: Equatable {
        let letter: String
        let schriftArt: SchriftArt
    }

    enum CalibrationMode: String, CaseIterable {
        case points = "Punkte"
        case drag = "Ziehen"
        case add = "Punkt"
        case delete = "Löschen"
    }

    /// Bbox-relative anchors set in `.points` mode, per stroke index.
    /// The committed `editableStrokes[i]` is rebuilt from these anchors
    /// by BFS-walking the glyph skeleton between consecutive points.
    @State private var anchorsPerStroke: [Int: [CGPoint]] = [:]

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
                strokePathsLayer(in: size)
                if mode != .points { dotsLayer(in: size) }
                anchorsLayer(in: size)
                controlsLayer
            }
            .onAppear { loadFromVM() }
            .onChange(of: vm.currentLetterName) { loadFromVM() }
            .onChange(of: vm.schriftArt) { loadFromVM(force: true) }
        }
        .sheet(isPresented: $showExport) {
            ExportSheet(text: exportText, letterName: vm.currentLetterName)
        }
    }

    /// Uniform arc-length resample in bbox-relative coordinates.
    /// Densifies the BFS-walked path so the tracker has ~40 evenly
    /// spaced checkpoints instead of one per skeleton pixel.
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
        if mode == .add {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { location in
                    let glyph = screenToGlyph(location, in: size)
                    addCheckpoint(glyph)
                }
        }
        if mode == .points {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { location in
                    let bboxPt = screenToGlyph(location, in: size)
                    addAnchor(bboxPt)
                }
        }
    }

    /// Append an anchor for the active stroke and rebuild the polyline
    /// between anchors via BFS along the glyph skeleton. With ≥ 2
    /// anchors the user sees the auto-completed centerline; one
    /// constraining anchor in the wrong region forces the BFS to take
    /// a different route between its neighbours.
    private func addAnchor(_ pt: CGPoint) {
        anchorsPerStroke[activeStroke, default: []].append(pt)
        rebuildStrokeFromAnchors()
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
        guard let raw = vm.glyphRelativeStrokes,
              let skel = raw.skeleton, !skel.isEmpty,
              let adj = raw.skeletonAdj, adj.count == skel.count,
              anchors.count >= 2 else {
            // Fewer than two anchors: just keep the anchors so the
            // user sees what they've set so far.
            editableStrokes[activeStroke] = anchors
            return
        }
        let snappedIdx = anchors.map { nearestSkelIndex($0, in: skel) }
        var fullPath: [Int] = []
        for i in 0..<(snappedIdx.count - 1) {
            let leg = bfsAlongSkeleton(from: snappedIdx[i],
                                       to: snappedIdx[i + 1],
                                       adj: adj)
            if leg.isEmpty { continue }
            if i == 0 {
                fullPath.append(contentsOf: leg)
            } else {
                fullPath.append(contentsOf: leg.dropFirst())
            }
        }
        let pathPts = fullPath.map { CGPoint(x: skel[$0].x, y: skel[$0].y) }
        // Dense final sample: 40 evenly-spaced checkpoints for the
        // tracker; each anchor stays roughly in place because BFS
        // walks the actual centerline.
        let dense = pathPts.count >= 2
            ? resampleUniformBbox(pathPts, count: 40)
            : pathPts
        editableStrokes[activeStroke] = dense
    }

    private func nearestSkelIndex(_ p: CGPoint, in skel: [Checkpoint]) -> Int {
        var bestIdx = 0
        var bestD2: CGFloat = .infinity
        for i in 0..<skel.count {
            let dx = skel[i].x - p.x
            let dy = skel[i].y - p.y
            let d2 = dx * dx + dy * dy
            if d2 < bestD2 {
                bestD2 = d2
                bestIdx = i
            }
        }
        return bestIdx
    }

    private func bfsAlongSkeleton(from start: Int, to end: Int,
                                  adj: [[Int]]) -> [Int] {
        if start == end { return [start] }
        var parent: [Int: Int] = [start: -1]
        var queue: [Int] = [start]
        var head = 0
        while head < queue.count {
            let cur = queue[head]; head += 1
            if cur == end { break }
            for n in adj[cur] where parent[n] == nil {
                parent[n] = cur
                queue.append(n)
            }
        }
        guard parent[end] != nil else { return [] }
        var path: [Int] = []
        var cur = end
        while cur != -1 {
            path.append(cur)
            cur = parent[cur] ?? -1
        }
        return path.reversed()
    }

    /// Dashed red outline of the renderer's `normalizedGlyphRect`.
    /// Spot-check that the inner glyph bbox actually wraps the glyph —
    /// misalignment here would explain ghost / stroke drift.
    @ViewBuilder
    private func glyphRectDebugLayer(in size: CGSize) -> some View {
        let gr = PrimaeLetterRenderer.normalizedGlyphRect(
            for: vm.currentLetterName,
            canvasSize: size,
            schriftArt: vm.schriftArt) ?? CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
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
        // Active stroke renders as a solid colored line so it's easy to
        // see whether the polyline matches the underlying ink. Other
        // strokes' starts still appear as faded chips for switch.
        if editableStrokes.indices.contains(activeStroke) {
            let stroke = editableStrokes[activeStroke]
            let color = strokeColors[activeStroke % strokeColors.count]
            Path { path in
                let pts = stroke.map { glyphToScreen($0, in: size) }
                guard let first = pts.first else { return }
                path.move(to: first)
                for pt in pts.dropFirst() { path.addLine(to: pt) }
            }
            .stroke(color.opacity(0.85),
                    style: StrokeStyle(lineWidth: 6,
                                       lineCap: .round,
                                       lineJoin: .round))
        }
    }

    /// Anchor markers for `.points` mode — large numbered dots that
    /// represent the user's BFS waypoints. Tap-to-delete behaviour
    /// piggybacks on `.delete` mode for symmetry with checkpoint dots.
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

            if mode == .add {
                Text("Tippe um Punkt zu setzen")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
            }

            if mode == .points {
                let count = anchorsPerStroke[activeStroke]?.count ?? 0
                let hint = count < 2
                    ? "Strich \(activeStroke + 1) — Punkt setzen (\(count)/min 2)"
                    : "Strich \(activeStroke + 1) — \(count) Punkte gesetzt; weitere Punkte korrigieren den Verlauf"
                Text(hint)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
            }

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
            for: vm.currentLetterName, canvasSize: size, schriftArt: vm.schriftArt) else {
            return CGPoint(x: pt.x * size.width, y: pt.y * size.height)
        }
        return CGPoint(
            x: (gr.minX + pt.x * gr.width) * size.width,
            y: (gr.minY + pt.y * gr.height) * size.height
        )
    }

    private func screenToGlyph(_ pt: CGPoint, in size: CGSize) -> CGPoint {
        guard let gr = PrimaeLetterRenderer.normalizedGlyphRect(
            for: vm.currentLetterName, canvasSize: size, schriftArt: vm.schriftArt),
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

    private func addCheckpoint(_ pt: CGPoint) {
        while editableStrokes.count <= activeStroke {
            editableStrokes.append([])
        }
        editableStrokes[activeStroke].append(pt)
    }

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
        mode = .add
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

    /// Apply the edits to the live tracker AND persist per-script.
    /// Primary save path; JSON export is the backup.
    private func saveToVM() {
        vm.applyCalibration(editableStrokes)
        vm.persistCalibratedStrokes(editableStrokes, for: vm.currentLetterName)
        savedFlashUntil = Date().addingTimeInterval(1.2)
        // Clear the badge after the flash window so a second save can
        // re-flash green instead of sticking.
        Task {
            try? await Task.sleep(for: .milliseconds(1300))
            if let until = savedFlashUntil, Date() >= until {
                savedFlashUntil = nil
            }
        }
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
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Button(copied ? "Kopiert ✓" : "In Zwischenablage kopieren") {
                    UIPasteboard.general.string = text
                    copied = true
                }
                .buttonStyle(.borderedProminent)
                .tint(copied ? .green : .blue)
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
