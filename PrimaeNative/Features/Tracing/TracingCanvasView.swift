import SwiftUI
import UIKit
import CoreText

struct TracingCanvasView: View {
    @Environment(TracingViewModel.self) private var vm
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    @ViewBuilder
    private func tracingCanvas(geo: GeometryProxy) -> some View {
        Canvas { context, fullSize in
            // Reserve the bottom band for the calibrator UI so the
            // glyph doesn't render under the translucent UI cards.
            // Reduces the geometry used for cell layout AND the
            // progress strip at the bottom — both then sit ABOVE
            // the UI region. StrokeCalibrationOverlay applies the
            // same inset to its skeleton/bbox/handle math so the
            // two layers stay aligned.
            let size: CGSize = vm.isCalibrating
                ? CGSize(width: fullSize.width,
                         height: max(0, fullSize.height
                                     - TracingViewModel.calibratorBottomInset))
                : fullSize
            // Word sequences use stored CoreText frames; other kinds
            // recompute from `size` to avoid first-render staleness
            // and to keep CoreText off the per-frame budget.
            let wordRendering = vm.gridWordRendering
            let frames: [CGRect]
            if wordRendering != nil {
                frames = vm.gridCells.map(\.frame)
            } else {
                frames = GridLayoutCalculator.cellFrames(
                    canvasSize: size, preset: vm.gridPreset)
            }
            let cellCount = min(frames.count, vm.gridCells.count)
            let activeIndex = vm.gridActiveCellIndex

            // Whole-word image: one blit at full canvas size so cursive
            // connectors flow across cell boundaries.
            if let wr = wordRendering {
                context.draw(Image(uiImage: wr.image),
                             in: CGRect(origin: .zero, size: size))
            }
            for i in 0..<cellCount {
                let cellFrame = frames[i]
                let cellSize  = cellFrame.size
                let ox        = cellFrame.minX
                let oy        = cellFrame.minY
                let cellLetter = vm.gridCellLetter(at: i) ?? vm.currentLetterName
                let isActiveCell = (i == activeIndex)

                // Background glyph as a vector path from the OTF
                // outline (resolution-independent). Skipped in word
                // mode — the whole-word image was drawn above.
                if wordRendering == nil,
                   let glyph = PrimaeLetterRenderer.glyphPath(
                       letter: cellLetter, size: cellSize, schriftArt: vm.schriftArt,
                       openTypeFeatures: PrimaeLetterRenderer.openTypeFeatures(
                           for: cellLetter, schriftArt: vm.schriftArt, variant: vm.showingVariant)) {
                    let positioned = glyph.applying(
                        CGAffineTransform(translationX: ox, y: oy))
                    context.fill(positioned, with: .color(.ink.opacity(0.78)))
                }

                // Ghost scaffolding follows GRRM: phase drives default
                // visibility (observe/guided on, freeWrite off); user
                // toggle adds in observe/guided only. Suppressed during
                // calibration where the fat blue paths obscure edits.
                if (vm.showGhostForPhase || (vm.showGhost && vm.learningPhase != .freeWrite)),
                   !vm.isCalibrating,
                   let rawStrokes = vm.gridCellStrokes(at: i),
                   !rawStrokes.strokes.isEmpty {
                    // Checkpoints are canvas-relative 0..1 (incl. the
                    // 10% glyph pad). Don't remap through
                    // normalizedGlyphRect — that would squeeze the
                    // strokes inside the ghost.
                    for stroke in rawStrokes.strokes {
                        guard stroke.checkpoints.count >= 2 else { continue }
                        let pts = stroke.checkpoints.map { cp in
                            CGPoint(x: ox + cp.x * cellSize.width,
                                    y: oy + cp.y * cellSize.height)
                        }
                        let ghostPath = smoothPath(through: pts)
                        context.stroke(ghostPath, with: .color(.canvasGhost.opacity(0.35)),
                                       style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                    }
                }

                // Stroke start dots; suppressed during calibration so
                // the calibrator's own numbered dots aren't doubled up.
                if vm.showCheckpoints, !vm.isCalibrating,
                   let rawStrokes = vm.gridCellStrokes(at: i),
                   !rawStrokes.strokes.isEmpty {
                    for (idx, stroke) in rawStrokes.strokes.enumerated() {
                        guard let first = stroke.checkpoints.first else { continue }
                        let isComplete = vm.isStrokeCompleted(idx)
                        let isActive = vm.activeStrokeIndex == idx
                        let screenX = ox + first.x * cellSize.width
                        let screenY = oy + first.y * cellSize.height
                        let pt = CGPoint(x: screenX, y: screenY)
                        let r: CGFloat = isActive ? 18 : 14
                        let dotRect = CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)
                        let dot = Path(ellipseIn: dotRect)
                        let color: Color = isComplete ? .green : (isActive ? .blue : .gray)
                        context.fill(dot, with: .color(color.opacity(0.75)))
                    }
                }

                // Retained ink from previously-completed cells stays
                // visible after the cursor has moved on.
                let retainedInk = vm.gridCells[i].activePath
                if retainedInk.count > 1 {
                    var path = Path()
                    path.addLines(retainedInk)
                    context.stroke(path, with: .color(.canvasInkStroke.opacity(0.9)),
                                   style: StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round))
                }

                // Active ink — only drawn on the active cell pass so
                // multi-cell layouts don't stroke the same pixels N
                // times.
                if isActiveCell, vm.activePath.count > 1 {
                    var path = Path()
                    path.addLines(vm.activePath)
                    let inkWidth: CGFloat = vm.pencilPressure.map { 8 + $0 * 14 } ?? 14
                    context.stroke(path, with: .color(.canvasInkStroke),
                                   style: StrokeStyle(lineWidth: inkWidth, lineCap: .round, lineJoin: .round))
                }

                // Lingering ink — snapshot of the just-completed trace
                // held visible for ~5 s after the phase transition so
                // the child sees their own work before it clears.
                if isActiveCell, vm.lingeringInk.count > 1 {
                    var path = Path()
                    path.addLines(vm.lingeringInk)
                    context.stroke(path, with: .color(.canvasInkStroke.opacity(0.85)),
                                   style: StrokeStyle(lineWidth: 14, lineCap: .round, lineJoin: .round))
                }

                // Animation guide dot — active cell only; suppressed
                // during calibration so it doesn't scan over edits.
                if isActiveCell, let point = vm.animationGuidePoint, !vm.isCalibrating {
                    let screenPt = CGPoint(
                        x: ox + point.x * cellSize.width,
                        y: oy + point.y * cellSize.height)
                    let r: CGFloat = 22
                    let dotRect   = CGRect(x: screenPt.x - r, y: screenPt.y - r, width: r * 2, height: r * 2)
                    let dot       = Path(ellipseIn: dotRect)
                    // Amber per design system (`--guide`), not blue.
                    context.fill(dot,   with: .color(.canvasGuide.opacity(0.85)))
                    context.stroke(dot, with: .color(.canvasPaper.opacity(0.60)), lineWidth: 2)
                }

                // Directional arrow — active cell only.
                if isActiveCell, let arrowIdx = vm.directArrowStrokeIndex, !vm.isCalibrating,
                   let rawStrokes = vm.gridCellStrokes(at: i),
                   arrowIdx < rawStrokes.strokes.count,
                   rawStrokes.strokes[arrowIdx].checkpoints.count >= 2 {
                    let stroke = rawStrokes.strokes[arrowIdx]
                    let c0 = stroke.checkpoints[0]
                    let c1 = stroke.checkpoints[1]
                    let from = CGPoint(x: ox + c0.x * cellSize.width,
                                       y: oy + c0.y * cellSize.height)
                    let to   = CGPoint(x: ox + c1.x * cellSize.width,
                                       y: oy + c1.y * cellSize.height)
                    var linePath = Path()
                    linePath.move(to: from)
                    linePath.addLine(to: to)
                    context.stroke(linePath, with: .color(.canvasGuide.opacity(0.9)),
                                   style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    let dx = to.x - from.x
                    let dy = to.y - from.y
                    let angle = atan2(dy, dx)
                    let tipLen: CGFloat = 18
                    let spread: CGFloat = .pi / 5
                    let b1 = CGPoint(x: to.x - tipLen * cos(angle - spread),
                                     y: to.y - tipLen * sin(angle - spread))
                    let b2 = CGPoint(x: to.x - tipLen * cos(angle + spread),
                                     y: to.y - tipLen * sin(angle + spread))
                    var headPath = Path()
                    headPath.move(to: to)
                    headPath.addLine(to: b1)
                    headPath.move(to: to)
                    headPath.addLine(to: b2)
                    context.stroke(headPath, with: .color(.canvasGuide.opacity(0.9)),
                                   style: StrokeStyle(lineWidth: 5, lineCap: .round))
                }
            }

            // Active-cell highlight in multi-cell layouts; a ring on a
            // single-cell canvas would be visual noise.
            if cellCount > 1, activeIndex < frames.count, !vm.isCalibrating {
                let activeFrame = frames[activeIndex].insetBy(dx: 2, dy: 2)
                let ringPath = Path(roundedRect: activeFrame,
                                    cornerSize: CGSize(width: 14, height: 14))
                context.stroke(ringPath, with: .color(.blue.opacity(0.55)),
                               style: StrokeStyle(lineWidth: 3))
            }

            // Canvas-wide progress (whole sequence).
            let clampedProgress = max(0, min(1, vm.progress))
            let trackRect = CGRect(x: 0, y: size.height - 8, width: size.width,                    height: 8)
            let fillRect  = CGRect(x: 0, y: size.height - 8, width: size.width * clampedProgress, height: 8)

            context.fill(Path(trackRect), with: .color(.black.opacity(0.1)))
            context.fill(Path(fillRect),  with: .color(differentiateWithoutColor ? .blue : .green))
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func freeWriteKPOverlay() -> some View {
        Canvas { context, size in
            // Reference strokes in blue (opacity 0.4, lineWidth 8).
            // `rawGlyphStrokes` is cell-fraction (mapped through the
            // glyph rect), so direct multiplication by `size` lands on
            // the visible ghost.
            if let rawStrokes = vm.rawGlyphStrokes,
               !rawStrokes.strokes.isEmpty {
                for stroke in rawStrokes.strokes {
                    guard stroke.checkpoints.count >= 2 else { continue }
                    var refPath = Path()
                    let first = stroke.checkpoints[0]
                    refPath.move(to: CGPoint(
                        x: first.x * size.width,
                        y: first.y * size.height))
                    for cp in stroke.checkpoints.dropFirst() {
                        refPath.addLine(to: CGPoint(
                            x: cp.x * size.width,
                            y: cp.y * size.height))
                    }
                    context.stroke(refPath, with: .color(.canvasGhost.opacity(0.4)),
                                   style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                }
            }

            // Child's freeWrite path. Break at every stroke-start so
            // multi-stroke letters (F, E, H) render as disjoint
            // strokes instead of one zig-zag with phantom diagonals.
            let pts = vm.freeWritePath
            let breaks = vm.freeWriteStrokeStartIndices
            if pts.count > 1 {
                var childPath = Path()
                let segmentStarts = ([0] + breaks.filter { $0 > 0 && $0 < pts.count })
                    .sorted()
                for (b, startIdx) in segmentStarts.enumerated() {
                    let endIdx = (b + 1 < segmentStarts.count) ? segmentStarts[b + 1] : pts.count
                    guard startIdx < endIdx else { continue }
                    childPath.move(to: CGPoint(
                        x: pts[startIdx].x * size.width,
                        y: pts[startIdx].y * size.height))
                    for i in (startIdx + 1)..<endIdx {
                        childPath.addLine(to: CGPoint(
                            x: pts[i].x * size.width,
                            y: pts[i].y * size.height))
                    }
                }
                context.stroke(childPath, with: .color(.canvasInkStroke),
                               style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
        }
        .background(.black.opacity(0.15))
        .contentShape(Rectangle())
        .onTapGesture { vm.overlayQueue.dismiss() }
        // Auto-dismiss owned by OverlayQueueManager.
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                tracingCanvas(geo: geo)
                    .modifier(TracingCanvasAccessibility(vm: vm))

                ProgressPill(progress: vm.progress,
                             differentiateWithoutColor: differentiateWithoutColor)
                    .equatable()
                    .padding(.leading, 12)
                    .padding(.bottom, 16)
            }
            .onAppear { vm.canvasSize = geo.size }
            .onChange(of: geo.size) { _, newSize in vm.canvasSize = newSize }
            // Overlay ordering: UnifiedTouchOverlay below,
            // PencilAwareCanvasOverlay above. Pencil's hitTest returns
            // self for pencil and nil otherwise; finger touches fall
            // through. A pencil-rejecting hitTest on the unified
            // overlay broke SwiftUI's pre-touch pass where `event` is
            // nil.
            .overlay(
                // Finger-only tracing. Disabled entirely during direct
                // phase so the SwiftUI dots overlay's tap gestures win
                // over the UIView's touch swallowing.
                UnifiedTouchOverlay(
                    canvasSize: geo.size,
                    onSingleTouchBegan:  { pt, t in
                        // Feed the detector hysteresis before tracing.
                        vm.fingerDidTouchDown()
                        vm.beginTouch(at: pt, t: t)
                    },
                    onSingleTouchMoved:  { pt, t, size in vm.updateTouch(at: pt, t: t, canvasSize: size) },
                    onSingleTouchEnded:  { vm.endTouch() },
                    // Two-finger swipe cycles audio variants.
                    onTwoFingerSwipeUp:   { vm.nextAudioVariant() },
                    onTwoFingerSwipeDown: { vm.previousAudioVariant() }
                )
                .allowsHitTesting(vm.learningPhase != .direct && !vm.isCalibrating)
            )
            .overlay(
                PencilAwareCanvasOverlay(
                    canvasSize: geo.size,
                    onBegan:  { pt, t in
                        // Feed the detector first so the preset flips
                        // before any grid-preset-dependent work runs.
                        vm.pencilDidTouchDown()
                        vm.beginTouch(at: pt, t: t)
                    },
                    onMoved:  { pt, t, pressure, azimuth, size in
                        vm.pencilPressure = pressure
                        vm.pencilAzimuth  = azimuth
                        vm.updateTouch(at: pt, t: t, canvasSize: size)
                    },
                    onEnded:  { vm.endTouch() },
                    onPencilSqueeze: { vm.replayAudio() }
                )
                // Suspend tracing during calibration so a drag doesn't
                // fire proximity audio on the underlying tracker.
                .allowsHitTesting(!vm.isCalibrating)
            )
            .overlay(
                Group {
                    // Calibrator owns the numbered-dot visualization;
                    // hide the direct-phase overlay while it's open.
                    if vm.learningPhase == .direct, !vm.isCalibrating {
                        DirectPhaseDotsOverlay()
                    }
                }
            )
            .overlay(
                Group {
                    if case .kpOverlay = vm.overlayQueue.currentOverlay {
                        freeWriteKPOverlay()
                    }
                }
            )
            .overlay(
                Group {
                    // Top-most layer so drag / tap edits aren't swallowed
                    // by the underlying tracing/pencil overlays. Other
                    // overlays already gate themselves on `!isCalibrating`.
                    #if !STUDY_BUILD
                    // Q2: studyMode already bypasses calibration overrides
                    // (TracingViewModel.resolvedStrokes), so in a study build
                    // the overlay's only remaining power is editing the
                    // stimulus. Calibration happens on the dev build.
                    if vm.isCalibrating {
                        StrokeCalibrationOverlay(canvasSize: geo.size)
                    }
                    #endif
                }
            )
        }
    }

    /// Catmull-Rom-to-Bezier smoothing. Replaces a polyline through the
    /// supplied points with a `Path` whose segments are cubic Beziers,
    /// so corners between adjacent samples round off instead of forming
    /// visible kinks.
    private func smoothPath(through pts: [CGPoint]) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: first)
        guard pts.count >= 2 else { return path }
        if pts.count == 2 {
            path.addLine(to: pts[1])
            return path
        }
        for i in 0..<(pts.count - 1) {
            let p0 = i == 0 ? pts[0] : pts[i - 1]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = i + 2 < pts.count ? pts[i + 2] : pts[i + 1]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6.0,
                             y: p1.y + (p2.y - p0.y) / 6.0)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6.0,
                             y: p2.y - (p3.y - p1.y) / 6.0)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }
}

// MARK: - Accessibility modifier

private struct TracingCanvasAccessibility: ViewModifier {
    var vm: TracingViewModel

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(vm.accessibilityCanvasLabel)
            .accessibilityValue(vm.accessibilityCanvasValue)
            .accessibilityHint("Ziehe mit einem Finger, um den Buchstaben nachzufahren. Nutze die Aktionen, um Buchstaben zu wechseln oder den Ton abzuspielen.")
            .accessibilityActions {
                Button("Buchstaben-Ton abspielen") { vm.replayAudio() }
                Button("Nächster Buchstabe")      { vm.nextLetter() }
                Button("Vorheriger Buchstabe")    { vm.previousLetter() }
                Button("Zufälliger Buchstabe")    { vm.randomLetter() }
                Button("Zurücksetzen")            { vm.resetLetter() }
                Button("Hilfslinien umschalten")  { vm.toggleGhost() }
            }
    }
}

// MARK: - Progress pill

/// Coloured progress capsule (blue → yellow → green); no visible
/// number — 5–6 yr-olds don't read percentages. Equatable so SwiftUI
/// skips body re-evaluation on unrelated VM changes.
private struct ProgressPill: View, Equatable {
    let progress: CGFloat
    let differentiateWithoutColor: Bool

    var body: some View {
        let p = max(0, min(1, progress))
        let tint: Color = p >= 0.99 ? .green : (p >= 0.5 ? .yellow : .blue)
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.gray.opacity(0.18))
            GeometryReader { geo in
                Capsule()
                    .fill(tint)
                    .frame(width: geo.size.width * p)
            }
            .frame(height: 8)
            #if DEBUG && !STUDY_BUILD
            debugPercentReadout(p)
            #endif
        }
        .frame(width: 88, height: 8)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke((differentiateWithoutColor ? Color.blue : tint).opacity(0.55), lineWidth: 1)
        )
        // Status is spoken via ChildSpeechLibrary; pill is decorative.
        .accessibilityHidden(true)
    }

    #if DEBUG && !STUDY_BUILD
    /// Numeric readout for tuning. Excluded from study builds as well as
    /// from Release.
    ///
    /// The docstring on this type says "no visible number — 5–6 yr-olds
    /// don't read percentages", and the original comment here said
    /// "Release strips this branch". That stopped being true the moment a
    /// Debug-Study configuration existed: a study build is a DEBUG build,
    /// so every child in the pilot would have seen a live percentage of
    /// their own accuracy on the canvas. That is text on a child-facing
    /// screen against the stated convention, and an uncontrolled
    /// feedback signal that varies with performance in a study whose
    /// post-trial feedback is otherwise stripped for exactly that reason
    /// (audit C2).
    ///
    /// Split into a named declaration rather than left inline so it emits
    /// a symbol the CI compile-out scan can assert on — present in the
    /// normal binary, absent from the study one.
    @ViewBuilder
    private func debugPercentReadout(_ p: CGFloat) -> some View {
        Text("\(Int(p * 100))%")
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(.primary)
            .padding(.leading, 8)
    }
    #endif
}

// MARK: - Direct phase dot overlay

/// Pulsing dot for the direct phase.
///
/// Driven by a 30 Hz `Timer.publish` because SwiftUI animation
/// primitives (withAnimation, .animation(_:value:), TimelineView,
/// keyframeAnimator) don't produce a visible pulse on iOS 26 + Swift
/// 6.2 + `.defaultIsolation(MainActor.self)` — see project memory
/// `feedback_swiftui_animation_regression`.
///
/// Reduce Motion intentionally NOT respected: the pulse is the
/// functional "tap me next" cue for non-reading children. The 35%
/// scale range is small enough that the parent area is unaffected.
/// `emphasis` expands the range to 1.0…1.55 after a wrong tap.
private struct PulsingDot: View {
    let isNext: Bool
    let isTapped: Bool
    let emphasis: Bool
    let label: String
    let radius: CGFloat

    @State private var scale: CGFloat = 1.0

    var body: some View {
        ZStack {
            Circle()
                .fill(isTapped ? Color.green : (isNext ? Color.blue : Color.gray))
                .opacity(0.85)
                .frame(width: radius * 2, height: radius * 2)
                .scaleEffect(scale)
            Text(label)
                .font(.system(size: radius * 0.85, weight: .bold))
                .foregroundStyle(.white)
        }
        .onReceive(
            Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()
        ) { date in
            guard isNext else { scale = 1.0; return }
            // 1.2 s wall-clock sine cycle, direct state mutation.
            let t = date.timeIntervalSinceReferenceDate
            let phase = (sin(t * .pi / 0.6) + 1) / 2
            let amplitude: CGFloat = emphasis ? 0.55 : 0.35
            scale = 1.0 + amplitude * CGFloat(phase)
        }
    }
}

/// Renders numbered start-dot circles for the direct phase and routes taps to the VM.
/// Sits above the touch overlays so SwiftUI tap gestures win over the tracing handler.
private struct DirectPhaseDotsOverlay: View {
    @Environment(TracingViewModel.self) private var vm
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Render every numbered start-dot so wrong-tap path is
                // reachable. Word-mode strokes are cell-local, so use
                // the active cell frame; single-cell falls through to
                // the whole canvas.
                let cellFrame = vm.multiCellActiveFrame
                ?? CGRect(origin: .zero, size: geo.size)
                if let rawStrokes = vm.rawGlyphStrokes,
                   !rawStrokes.strokes.isEmpty {
                    let nextIdx = vm.directNextExpectedDotIndex
                    // Render the next-expected dot last so its hit-test
                    // wins when two dots share a glyph point (A apex,
                    // F top-left, M peaks).
                    ForEach(Array(rawStrokes.strokes.enumerated()), id: \.offset) { idx, stroke in
                        if idx != nextIdx {
                            dotView(idx: idx,
                                    stroke: stroke,
                                    cellFrame: cellFrame)
                        }
                    }
                    if nextIdx < rawStrokes.strokes.count {
                        dotView(idx: nextIdx,
                                stroke: rawStrokes.strokes[nextIdx],
                                cellFrame: cellFrame)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func dotView(idx: Int, stroke: StrokeDefinition, cellFrame: CGRect) -> some View {
        if let first = stroke.checkpoints.first {
            // Checkpoints are 0..1 of cellFrame; offset to canvas
            // coords so word-mode draws in the active cell.
            let screenX = cellFrame.minX + first.x * cellFrame.width
            let screenY = cellFrame.minY + first.y * cellFrame.height
            let isTapped = vm.directTappedDots.contains(idx)
            let isNext   = !isTapped && idx == vm.directNextExpectedDotIndex
            let r: CGFloat = isNext ? 22 : 18
            // `.onTapGesture` MUST come before `.position` — `.position`
            // expands the view to the parent frame, so a later-attached
            // gesture hit-tests the whole canvas and only the top-most
            // dot's handler fires.
            PulsingDot(isNext: isNext,
                       isTapped: isTapped,
                       emphasis: isNext && vm.directPulsingDot,
                       label: "\(idx + 1)",
                       radius: r)
                .contentShape(Circle())
                .onTapGesture {
                    // Animation transaction lives at the call site —
                    // the VM doesn't import SwiftUI.
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.55)) {
                        vm.tapDirectDot(index: idx)
                    }
                }
                .position(x: screenX, y: screenY)
                .accessibilityLabel("Startpunkt \(idx + 1)")
                .accessibilityAddTraits(.isButton)
        }
    }
}

// MARK: - Unified touch overlay
// 1-finger tracing only; letter/audio/ghost nav moved to world-bar
// controls so palm rests don't trigger them.

private struct UnifiedTouchOverlay: UIViewRepresentable {
    let canvasSize: CGSize
    let onSingleTouchBegan: (CGPoint, CFTimeInterval) -> Void
    let onSingleTouchMoved: (CGPoint, CFTimeInterval, CGSize) -> Void
    let onSingleTouchEnded: () -> Void
    let onTwoFingerSwipeUp: () -> Void
    let onTwoFingerSwipeDown: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            canvasSize:           canvasSize,
            onSingleTouchBegan:   onSingleTouchBegan,
            onSingleTouchMoved:   onSingleTouchMoved,
            onSingleTouchEnded:   onSingleTouchEnded,
            onTwoFingerSwipeUp:   onTwoFingerSwipeUp,
            onTwoFingerSwipeDown: onTwoFingerSwipeDown
        )
    }

    func makeUIView(context: Context) -> TouchView {
        let view = TouchView(coordinator: context.coordinator)
        view.backgroundColor        = .clear
        // Multi-touch on so the 2-finger pan recognizer fires.
        view.isMultipleTouchEnabled = true
        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTwoFingerPan(_:))
        )
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        // Don't eat an in-progress 1-finger trace.
        pan.cancelsTouchesInView = false
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        return view
    }

    func updateUIView(_ uiView: TouchView, context: Context) {
        context.coordinator.canvasSize = canvasSize
    }

    final class TouchView: UIView {
        var coordinator: Coordinator
        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        // No hitTest override: pencil routing relies on overlay
        // ordering (PencilAwareCanvasOverlay sits above and rejects
        // non-pencil). A hitTest override broke SwiftUI's pre-touch
        // pass where `event` is nil.

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            coordinator.touchesBegan(touches, with: event, in: self)
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            coordinator.touchesMoved(touches, with: event, in: self)
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            coordinator.touchesEnded(touches, with: event)
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            coordinator.touchesEnded(touches, with: event)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var canvasSize: CGSize
        private let onSingleTouchBegan: (CGPoint, CFTimeInterval) -> Void
        private let onSingleTouchMoved: (CGPoint, CFTimeInterval, CGSize) -> Void
        private let onSingleTouchEnded: () -> Void
        private let onTwoFingerSwipeUp: () -> Void
        private let onTwoFingerSwipeDown: () -> Void

        private weak var trackedTouch: UITouch?
        private var twoFingerSwipeFired = false

        init(canvasSize: CGSize,
             onSingleTouchBegan: @escaping (CGPoint, CFTimeInterval) -> Void,
             onSingleTouchMoved: @escaping (CGPoint, CFTimeInterval, CGSize) -> Void,
             onSingleTouchEnded: @escaping () -> Void,
             onTwoFingerSwipeUp: @escaping () -> Void,
             onTwoFingerSwipeDown: @escaping () -> Void) {
            self.canvasSize           = canvasSize
            self.onSingleTouchBegan   = onSingleTouchBegan
            self.onSingleTouchMoved   = onSingleTouchMoved
            self.onSingleTouchEnded   = onSingleTouchEnded
            self.onTwoFingerSwipeUp   = onTwoFingerSwipeUp
            self.onTwoFingerSwipeDown = onTwoFingerSwipeDown
        }

        func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?, in view: UIView) {
            let allTouches    = event?.allTouches ?? touches
            let fingerTouches = allTouches.filter { $0.type != .pencil }
            guard fingerTouches.count == 1, trackedTouch == nil else { return }
            guard let t = fingerTouches.first else { return }
            trackedTouch = t
            onSingleTouchBegan(t.location(in: view), t.timestamp)
        }

        func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?, in view: UIView) {
            guard let tracked = trackedTouch, touches.contains(tracked) else { return }
            onSingleTouchMoved(tracked.location(in: view), tracked.timestamp, canvasSize)
        }

        func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let tracked = trackedTouch, touches.contains(tracked) else { return }
            trackedTouch = nil
            onSingleTouchEnded()
        }

        @objc func handleTwoFingerPan(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .began, .possible:
                twoFingerSwipeFired = false
            case .changed:
                // Fire once per gesture on threshold crossing so the
                // user doesn't have to lift fingers first.
                guard !twoFingerSwipeFired, let view = gesture.view else { return }
                let dy = gesture.translation(in: view).y
                let threshold: CGFloat = 50
                if dy < -threshold {
                    twoFingerSwipeFired = true
                    onTwoFingerSwipeUp()
                } else if dy > threshold {
                    twoFingerSwipeFired = true
                    onTwoFingerSwipeDown()
                }
            case .ended, .cancelled, .failed:
                twoFingerSwipeFired = false
            @unknown default:
                break
            }
        }

        // 1-finger and 2-finger gestures are disjoint, so simultaneous
        // recognition can't conflict.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

// MARK: - Apple Pencil overlay

private struct PencilAwareCanvasOverlay: UIViewRepresentable {
    let canvasSize: CGSize
    let onBegan:  (CGPoint, CFTimeInterval) -> Void
    let onMoved:  (CGPoint, CFTimeInterval, CGFloat, CGFloat, CGSize) -> Void
    let onEnded:  () -> Void
    /// Apple Pencil 2 squeeze handler — replays letter audio.
    /// nil on devices without `UIPencilInteraction`.
    let onPencilSqueeze: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onBegan: onBegan, onMoved: onMoved, onEnded: onEnded,
                    onPencilSqueeze: onPencilSqueeze)
    }

    func makeUIView(context: Context) -> TouchTrackingView {
        let v = TouchTrackingView()
        v.backgroundColor = .clear
        v.coordinator     = context.coordinator
        v.installPencilInteraction()
        return v
    }

    func updateUIView(_ uiView: TouchTrackingView, context: Context) {
        uiView.coordinator = context.coordinator
        uiView.canvasSize  = canvasSize
    }

    final class Coordinator: NSObject, UIPencilInteractionDelegate {
        let onBegan: (CGPoint, CFTimeInterval) -> Void
        let onMoved: (CGPoint, CFTimeInterval, CGFloat, CGFloat, CGSize) -> Void
        let onEnded: () -> Void
        let onPencilSqueeze: (() -> Void)?
        init(onBegan: @escaping (CGPoint, CFTimeInterval) -> Void,
             onMoved: @escaping (CGPoint, CFTimeInterval, CGFloat, CGFloat, CGSize) -> Void,
             onEnded: @escaping () -> Void,
             onPencilSqueeze: (() -> Void)?) {
            self.onBegan = onBegan
            self.onMoved = onMoved
            self.onEnded = onEnded
            self.onPencilSqueeze = onPencilSqueeze
        }

        // Pencil 2 double-tap maps to the same "replay audio" intent
        // as the squeeze so either gesture produces the same outcome.
        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            onPencilSqueeze?()
        }
    }

    final class TouchTrackingView: UIView {
        var coordinator: Coordinator?
        var canvasSize: CGSize = .zero
        private var pencilInteraction: UIPencilInteraction?

        /// Lazily install a UIPencilInteraction; safe to call repeatedly.
        func installPencilInteraction() {
            guard pencilInteraction == nil else { return }
            let interaction = UIPencilInteraction()
            interaction.delegate = coordinator
            addInteraction(interaction)
            pencilInteraction = interaction
        }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard let touch = event?.allTouches?.first else { return nil }
            return touch.type == .pencil ? self : nil
        }

        // Pencil callbacks are delivered on the main thread; no hop
        // needed.
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let t = touches.first, t.type == .pencil else { return }
            coordinator?.onBegan(t.location(in: self), t.timestamp)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let t = touches.first, t.type == .pencil else { return }
            let pressure = t.force / max(t.maximumPossibleForce, 1)
            coordinator?.onMoved(t.location(in: self), t.timestamp, pressure,
                                  t.azimuthAngle(in: self), canvasSize)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard touches.first?.type == .pencil else { return }
            coordinator?.onEnded()
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard touches.first?.type == .pencil else { return }
            coordinator?.onEnded()
        }
    }
}
