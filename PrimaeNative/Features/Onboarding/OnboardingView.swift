// COMPILED OUT OF THE STUDY BUILD.
// Onboarding — device ships already-onboarded (Q4)
// The symbol must be ABSENT from the study binary, which the CI
// identity scan asserts via SURFACES. Gating the whole file rather
// than the call site is what makes that assertion meaningful.
#if !STUDY_BUILD
// OnboardingView.swift
// PrimaeNative
//
// First-run flow. One step per learning phase (observe → direct →
// guided → freeWrite) plus welcome and reward intro, mirroring the
// four-phase model the child sees in the app.

import SwiftUI

// MARK: - Main container

struct OnboardingView: View {
    @Environment(TracingViewModel.self) private var vm

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.93, green: 0.95, blue: 1.0),
                         Color(red: 0.98, green: 0.94, blue: 0.96)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                OnboardingProgressBar(progress: vm.onboardingProgress)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .accessibilityLabel("Einführung")
                    .accessibilityValue("\(Int((vm.onboardingProgress * 100).rounded())) Prozent")

                Spacer()

                stepContent

                Spacer()

                Text("Für Eltern: gedrückt halten zum Überspringen")
                    .font(.footnote)
                    .foregroundStyle(Color.inkSoft)
                    .padding(.bottom, 24)
                    .contentShape(Rectangle())
                    .onLongPressGesture(minimumDuration: 1.5) { vm.skipOnboarding() }
                    .accessibilityLabel("Einführung überspringen")
                    .accessibilityHint("Gedrückt halten, nur für Erwachsene")
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch vm.onboardingStep {
        case .welcome:
            WelcomeStepView(onNext: { vm.advanceOnboarding() })
        case .traceDemo:
            TraceDemoStepView(onNext: { vm.advanceOnboarding() })
        case .directDemo:
            DirectDemoStepView(onNext: { vm.advanceOnboarding() })
        case .guidedDemo:
            GuidedDemoStepView(onNext: { vm.advanceOnboarding() })
        case .freeWriteDemo:
            FreeWriteDemoStepView(onNext: { vm.advanceOnboarding() })
        case .rewardIntro:
            RewardIntroStepView(onNext: { vm.advanceOnboarding() })
        case .complete:
            EmptyView()
        }
    }
}

// MARK: - Progress bar

private struct OnboardingProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.ink.opacity(0.08))
                    .frame(height: 6)
                Capsule()
                    .fill(Color.blue)
                    .frame(width: geo.size.width * max(0, min(1, progress)), height: 6)
                    .animation(.easeInOut(duration: 0.3), value: progress)
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

// MARK: - Shared A-letter stroke geometry

// All four phase demos draw the same three strokes of "A" in a 1×1
// unit box so the child sees a consistent glyph across onboarding.

private struct ADemoStroke {
    let from: CGPoint
    let to: CGPoint
}

private let aDemoStrokes: [ADemoStroke] = [
    ADemoStroke(from: CGPoint(x: 0.50, y: 0.00), to: CGPoint(x: 0.05, y: 1.00)),  // left leg
    ADemoStroke(from: CGPoint(x: 0.50, y: 0.00), to: CGPoint(x: 0.95, y: 1.00)),  // right leg
    ADemoStroke(from: CGPoint(x: 0.22, y: 0.62), to: CGPoint(x: 0.78, y: 0.62))   // crossbar
]

private func scaled(_ pt: CGPoint, in size: CGSize) -> CGPoint {
    // Pad inside the Canvas so endpoint dots (the largest is ~14 pt
    // radius in the direct demo) aren't clipped by the frame.
    let pad: CGFloat = 16
    return CGPoint(
        x: pad + pt.x * (size.width  - 2 * pad),
        y: pad + pt.y * (size.height - 2 * pad)
    )
}

// MARK: - Step 1: Welcome

private struct WelcomeStepView: View {
    @Environment(TracingViewModel.self) private var vm
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("✏️")
                .font(.system(size: 80))

            Text("Willkommen!")
                .font(.display(FontSize.xxl, weight: .bold))
                .foregroundStyle(Color.ink)

            Text("Lerne, Buchstaben zu schreiben!")
                .font(.display(FontSize.md))
                .foregroundStyle(Color.inkSoft)
                .multilineTextAlignment(.center)

            Button(action: onNext) {
                Text("Los geht's!")
                    .font(.body(FontSize.md, weight: .semibold))
                    .frame(maxWidth: 240)
            }
            .buttonStyle(StickerButtonStyle())
            .controlSize(.large)
            .accessibilityLabel("Los geht's")
            .accessibilityHint("Startet die Einführung")
        }
        .padding(32)
        .onAppear {
            vm.speech.stop()
            vm.speech.speak("Willkommen! Lerne mit mir, Buchstaben zu schreiben. Tippe auf Los geht's.")
        }
        .onDisappear { vm.speech.stop() }
    }
}

// MARK: - Step 2: Anschauen (observe)

private struct TraceDemoStepView: View {
    @Environment(TracingViewModel.self) private var vm
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("👁️")
                .font(.system(size: 64))

            Text("Anschauen")
                .font(.display(FontSize.xl, weight: .bold))
                .foregroundStyle(Color.ink)

            Text("Schau, wie der Buchstabe\ngeschrieben wird!")
                .font(.body(FontSize.base))
                .foregroundStyle(Color.inkSoft)
                .multilineTextAlignment(.center)

            TimelineView(.animation) { timeline in
                let elapsed = timeline.date.timeIntervalSinceReferenceDate
                let cycle = 3.0
                let progress = CGFloat((elapsed.truncatingRemainder(dividingBy: cycle)) / cycle)

                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.paper.opacity(0.6))
                        .frame(width: 200, height: 200)

                    Text("A")
                        .font(.system(size: 100, weight: .bold, design: .rounded))
                        .foregroundStyle(.gray.opacity(0.15))

                    ObserveDemoLayer(progress: progress)
                        .frame(width: 160, height: 160)
                }
            }
            .allowsHitTesting(false)

            Button("Weiter", action: onNext)
                .buttonStyle(StickerButtonStyle())
                .controlSize(.large)
                .accessibilityLabel("Weiter")
                .accessibilityHint("Geht zum nächsten Einführungsschritt")
        }
        .padding(32)
        .onAppear {
            vm.speech.stop()
            vm.speech.speak("Anschauen! Schau zuerst genau zu, wie der Buchstabe geschrieben wird.")
        }
        .onDisappear { vm.speech.stop() }
    }
}

private struct ObserveDemoLayer: View {
    let progress: CGFloat

    var body: some View {
        Canvas { context, size in
            for stroke in aDemoStrokes {
                var p = Path()
                p.move(to: scaled(stroke.from, in: size))
                p.addLine(to: scaled(stroke.to, in: size))
                context.stroke(p, with: .color(.gray.opacity(0.15)), lineWidth: 4)
            }

            let seg = progress * CGFloat(aDemoStrokes.count)
            for (idx, stroke) in aDemoStrokes.enumerated() {
                let t = max(0, min(1, seg - CGFloat(idx)))
                guard t > 0 else { continue }
                var p = Path()
                p.move(to: scaled(stroke.from, in: size))
                p.addLine(to: scaled(stroke.to, in: size))
                context.stroke(p.trimmedPath(from: 0, to: t),
                               with: .color(.canvasGhost),
                               style: StrokeStyle(lineWidth: 5, lineCap: .round))
            }

            let currentIdx = min(Int(seg), aDemoStrokes.count - 1)
            let stroke = aDemoStrokes[currentIdx]
            let t = max(0, min(1, seg - CGFloat(currentIdx)))
            // Through the same padded mapping as the strokes it rides on —
            // the raw unit→pixel mapping put the dot up to 16 pt off the
            // drawn stroke and clipped it at the layer edge (class two).
            let pt = scaled(CGPoint(
                x: stroke.from.x + (stroke.to.x - stroke.from.x) * t,
                y: stroke.from.y + (stroke.to.y - stroke.from.y) * t
            ), in: size)
            let r: CGFloat = 7
            context.fill(
                Circle().path(in: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)),
                with: .color(.canvasGuide))
        }
    }
}

// MARK: - Step 3: Richtung lernen (direct)

private struct DirectDemoStepView: View {
    @Environment(TracingViewModel.self) private var vm
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("☝️")
                .font(.system(size: 64))

            Text("Richtung lernen")
                .font(.display(FontSize.xl, weight: .bold))
                .foregroundStyle(Color.ink)

            Text("Tippe die Punkte\nder Reihe nach an!")
                .font(.body(FontSize.base))
                .foregroundStyle(Color.inkSoft)
                .multilineTextAlignment(.center)

            TimelineView(.animation) { timeline in
                let elapsed = timeline.date.timeIntervalSinceReferenceDate
                // Breathing pulse runs on the absolute clock so it
                // stays in phase with the real PulsingDot.
                let cycle = 5.0
                let progress = CGFloat((elapsed.truncatingRemainder(dividingBy: cycle)) / cycle)

                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.paper.opacity(0.6))
                        .frame(width: 200, height: 200)

                    Text("A")
                        .font(.system(size: 100, weight: .bold, design: .rounded))
                        .foregroundStyle(.gray.opacity(0.15))

                    DirectDemoLayer(progress: progress, clock: elapsed)
                        .frame(width: 160, height: 160)
                }
            }
            .allowsHitTesting(false)

            Button("Weiter", action: onNext)
                .buttonStyle(StickerButtonStyle())
                .controlSize(.large)
                .accessibilityLabel("Weiter")
                .accessibilityHint("Geht zum nächsten Einführungsschritt")
        }
        .padding(32)
        .onAppear {
            vm.speech.stop()
            vm.speech.speak("Richtung lernen! Tippe die Punkte der Reihe nach an. So lernst du, in welcher Richtung der Buchstabe geschrieben wird.")
        }
        .onDisappear { vm.speech.stop() }
    }
}

/// Mirrors the real direct phase: numbered dots (gray = future, blue
/// breathing pulse = next-expected, green = tapped); arrow flashes in
/// for ~1.2 s on each "tap".
private struct DirectDemoLayer: View {
    let progress: CGFloat
    /// Absolute reference-date clock — keeps the pulse in lockstep
    /// with the real `PulsingDot` (1.2 s sine, scale 1.0…1.35).
    let clock: TimeInterval

    var body: some View {
        Canvas { context, size in
            // Faint stroke guides — real canvas omits them, but at
            // 160 pt the preview needs them to make the dot-to-dot
            // relationship legible without animation.
            for stroke in aDemoStrokes {
                var p = Path()
                p.move(to: scaled(stroke.from, in: size))
                p.addLine(to: scaled(stroke.to, in: size))
                context.stroke(p, with: .color(.gray.opacity(0.10)), lineWidth: 3)
            }

            let total = CGFloat(aDemoStrokes.count)
            // Reserve the trailing 12 % as a quiet "complete → restart"
            // beat so the loop doesn't snap mid-arrow.
            let activePortion: CGFloat = 0.88
            let active = min(progress / activePortion, 1.0)
            let seg = active * total
            let currentIdx = min(Int(seg), Int(total) - 1)
            let sub = seg - CGFloat(currentIdx)
            let isCycleSettling = progress >= activePortion

            // Arrow appears the moment the dot turns green and stays
            // for the rest of the sub-step.
            let arrowOnsetSub: CGFloat = 0.0

            for (idx, stroke) in aDemoStrokes.enumerated() {
                let start = scaled(stroke.from, in: size)
                let end = scaled(stroke.to, in: size)

                let isTapped: Bool
                let isNext: Bool
                if isCycleSettling {
                    isTapped = true
                    isNext = false
                } else if idx < currentIdx {
                    isTapped = true; isNext = false
                } else if idx == currentIdx {
                    isTapped = false; isNext = true
                } else {
                    isTapped = false; isNext = false
                }

                // Wall-clock pulse — same shape/amplitude as the
                // real `PulsingDot` so the preview is faithful.
                let pulseScale: CGFloat
                if isNext {
                    let phase = (sin(clock * .pi / 0.6) + 1) / 2  // 0…1
                    pulseScale = 1.0 + 0.35 * CGFloat(phase)
                } else {
                    pulseScale = 1.0
                }

                let color: Color
                if isTapped { color = .green }
                else if isNext { color = .blue }
                else { color = .gray.opacity(0.45) }

                drawNumbered(context: context, at: start, color: color,
                             number: idx + 1, scale: pulseScale)

                // Arrow persists on every completed stroke so the
                // viewer can read the direction of all tapped
                // segments so far.
                let drawArrowForThis: Bool
                if isCycleSettling {
                    drawArrowForThis = true
                } else if idx < currentIdx {
                    drawArrowForThis = true
                } else if idx == currentIdx {
                    // `isTapped` is false in this branch by construction, so
                    // `&& isTapped` made the arrow impossible on the dot the
                    // viewer is looking at (class two, 2026-09-05).
                    drawArrowForThis = sub >= arrowOnsetSub
                } else {
                    drawArrowForThis = false
                }
                if drawArrowForThis {
                    drawArrow(context: context, from: start, to: end)
                }
            }
        }
    }

    private func drawNumbered(context: GraphicsContext, at pt: CGPoint, color: Color,
                              number: Int, scale: CGFloat = 1.0) {
        let r: CGFloat = 14 * scale
        context.fill(
            Circle().path(in: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)),
            with: .color(color.opacity(0.85)))
        let label = Text("\(number)")
            .font(.system(size: 13 * scale, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
        context.draw(label, at: pt, anchor: .center)
    }

    private func drawArrow(context: GraphicsContext, from: CGPoint, to: CGPoint) {
        let dx = to.x - from.x, dy = to.y - from.y
        let length = sqrt(dx * dx + dy * dy)
        guard length > 3 else { return }
        var line = Path()
        line.move(to: from)
        line.addLine(to: to)
        context.stroke(line, with: .color(.canvasGuide.opacity(0.9)),
                       style: StrokeStyle(lineWidth: 5, lineCap: .round))
        let angle = atan2(dy, dx)
        let tipLen: CGFloat = 11
        let spread: CGFloat = .pi / 5
        let b1 = CGPoint(x: to.x - tipLen * cos(angle - spread),
                         y: to.y - tipLen * sin(angle - spread))
        let b2 = CGPoint(x: to.x - tipLen * cos(angle + spread),
                         y: to.y - tipLen * sin(angle + spread))
        var head = Path()
        head.move(to: to); head.addLine(to: b1)
        head.move(to: to); head.addLine(to: b2)
        context.stroke(head, with: .color(.canvasGuide.opacity(0.9)),
                       style: StrokeStyle(lineWidth: 5, lineCap: .round))
    }
}

// MARK: - Step 4: Nachspuren (guided)

private struct GuidedDemoStepView: View {
    @Environment(TracingViewModel.self) private var vm
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("✏️")
                .font(.system(size: 64))

            Text("Nachspuren")
                .font(.display(FontSize.xl, weight: .bold))
                .foregroundStyle(Color.ink)

            Text("Fahre mit dem Finger\nüber die Linie!")
                .font(.body(FontSize.base))
                .foregroundStyle(Color.inkSoft)
                .multilineTextAlignment(.center)

            TimelineView(.animation) { timeline in
                let elapsed = timeline.date.timeIntervalSinceReferenceDate
                let cycle = 4.5
                let progress = CGFloat((elapsed.truncatingRemainder(dividingBy: cycle)) / cycle)

                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.paper.opacity(0.6))
                        .frame(width: 200, height: 200)

                    Text("A")
                        .font(.system(size: 100, weight: .bold, design: .rounded))
                        .foregroundStyle(.gray.opacity(0.15))

                    GuidedDemoLayer(progress: progress)
                        .frame(width: 160, height: 160)
                }
            }
            .allowsHitTesting(false)

            Button("Weiter", action: onNext)
                .buttonStyle(StickerButtonStyle())
                .controlSize(.large)
                .accessibilityLabel("Weiter")
                .accessibilityHint("Geht zum nächsten Einführungsschritt")
        }
        .padding(32)
        .onAppear {
            vm.speech.stop()
            vm.speech.speak("Nachspuren! Fahre mit dem Finger über die Linie. Versuche, immer auf der Linie zu bleiben.")
        }
        .onDisappear { vm.speech.stop() }
    }
}

/// Finger emoji follows each stroke leaving a green ink trail —
/// visual analog of the guided phase's checkpoint-rail tracing.
private struct GuidedDemoLayer: View {
    let progress: CGFloat

    var body: some View {
        Canvas { context, size in
            for stroke in aDemoStrokes {
                var p = Path()
                p.move(to: scaled(stroke.from, in: size))
                p.addLine(to: scaled(stroke.to, in: size))
                context.stroke(p, with: .color(.gray.opacity(0.18)),
                               style: StrokeStyle(lineWidth: 8, lineCap: .round))
            }

            let seg = progress * CGFloat(aDemoStrokes.count)
            let currentIdx = min(Int(seg), aDemoStrokes.count - 1)
            let sub = seg - CGFloat(currentIdx)

            for idx in 0..<currentIdx {
                let stroke = aDemoStrokes[idx]
                var p = Path()
                p.move(to: scaled(stroke.from, in: size))
                p.addLine(to: scaled(stroke.to, in: size))
                context.stroke(p, with: .color(.canvasInkStroke),
                               style: StrokeStyle(lineWidth: 6, lineCap: .round))
            }

            let stroke = aDemoStrokes[currentIdx]
            let start = scaled(stroke.from, in: size)
            let end = scaled(stroke.to, in: size)
            let fingerPt = CGPoint(
                x: start.x + (end.x - start.x) * sub,
                y: start.y + (end.y - start.y) * sub
            )
            var partial = Path()
            partial.move(to: start)
            partial.addLine(to: fingerPt)
            context.stroke(partial, with: .color(.canvasInkStroke),
                           style: StrokeStyle(lineWidth: 6, lineCap: .round))

            let finger = Text("👆").font(.system(size: 34))
            context.draw(finger, at: CGPoint(x: fingerPt.x, y: fingerPt.y + 6),
                         anchor: .center)
        }
    }
}

// MARK: - Step 5: Selbst schreiben (freeWrite)

private struct FreeWriteDemoStepView: View {
    @Environment(TracingViewModel.self) private var vm
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("🖊️")
                .font(.system(size: 64))

            Text("Selbst schreiben")
                .font(.display(FontSize.xl, weight: .bold))
                .foregroundStyle(Color.ink)

            Text("Zum Schluss schreibst du\nden Buchstaben alleine!")
                .font(.body(FontSize.base))
                .foregroundStyle(Color.inkSoft)
                .multilineTextAlignment(.center)

            TimelineView(.animation) { timeline in
                let elapsed = timeline.date.timeIntervalSinceReferenceDate
                let cycle = 5.0
                let progress = CGFloat((elapsed.truncatingRemainder(dividingBy: cycle)) / cycle)

                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.paper.opacity(0.6))
                        .frame(width: 200, height: 200)

                    Text("A")
                        .font(.system(size: 100, weight: .bold, design: .rounded))
                        .foregroundStyle(.gray.opacity(0.15))

                    FreeWriteDemoLayer(progress: progress)
                        .frame(width: 160, height: 160)
                }
            }
            .allowsHitTesting(false)

            Button("Weiter", action: onNext)
                .buttonStyle(StickerButtonStyle())
                .controlSize(.large)
                .accessibilityLabel("Weiter")
                .accessibilityHint("Geht zum nächsten Einführungsschritt")
        }
        .padding(32)
        .onAppear {
            vm.speech.stop()
            vm.speech.speak("Selbst schreiben! Zum Schluss schreibst du den Buchstaben ganz alleine. Du schaffst das!")
        }
        .onDisappear { vm.speech.stop() }
    }
}

/// Mirrors the freeWrite phase: faint blue reference + child's
/// wobbly green ink. A star pops in on completion to communicate
/// "complete → reward" without text.
private struct FreeWriteDemoLayer: View {
    let progress: CGFloat

    var body: some View {
        Canvas { context, size in
            // Faint blue reference — same role as the freeWriteKP
            // overlay's reference strokes (opacity 0.4, lineWidth 8).
            for stroke in aDemoStrokes {
                var p = Path()
                p.move(to: scaled(stroke.from, in: size))
                p.addLine(to: scaled(stroke.to, in: size))
                context.stroke(p, with: .color(.canvasGhost.opacity(0.4)),
                               style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
            }

            // Trailing 18 % is the "done" beat — all strokes visible,
            // star pops in.
            let writingPortion: CGFloat = 0.82
            let writing = min(progress / writingPortion, 1.0)
            let total = CGFloat(aDemoStrokes.count)
            let seg = writing * total
            let currentIdx = min(Int(seg), Int(total) - 1)
            let sub = seg - CGFloat(currentIdx)
            let isCelebrating = progress >= writingPortion

            // Completed strokes — solid green ink.
            for idx in 0..<currentIdx {
                let stroke = aDemoStrokes[idx]
                drawWobblyStroke(context: context, size: size,
                                 from: stroke.from, to: stroke.to,
                                 t: 1.0, seed: idx)
            }

            // Active stroke — wobbly green ink so it reads as
            // freehand, not as a snap-to-checkpoint trace.
            if !isCelebrating {
                let stroke = aDemoStrokes[currentIdx]
                drawWobblyStroke(context: context, size: size,
                                 from: stroke.from, to: stroke.to,
                                 t: sub, seed: currentIdx)

                // Pen tip — small green disc at the ink head.
                let from = scaled(stroke.from, in: size)
                let to = scaled(stroke.to, in: size)
                let tipPt = CGPoint(x: from.x + (to.x - from.x) * sub,
                                    y: from.y + (to.y - from.y) * sub)
                let r: CGFloat = 6
                context.fill(
                    Circle().path(in: CGRect(x: tipPt.x - r, y: tipPt.y - r,
                                             width: r * 2, height: r * 2)),
                    with: .color(.canvasInkStroke))
            } else if let stroke = aDemoStrokes.last {
                // Final stroke fully drawn during the celebration.
                drawWobblyStroke(context: context, size: size,
                                 from: stroke.from, to: stroke.to,
                                 t: 1.0, seed: aDemoStrokes.count - 1)

                // Star scale-up over the first half of the
                // celebration beat, hold for the rest.
                let celebT = (progress - writingPortion) / (1.0 - writingPortion)
                let starScale = min(CGFloat(celebT) * 2.0, 1.0)
                let starPt = CGPoint(x: size.width * 0.5, y: size.height * 0.18)
                context.draw(
                    Text("⭐")
                        .font(.system(size: 28 * starScale)),
                    at: starPt, anchor: .center)
            }
        }
    }

    /// Slightly-wobbly polyline over [0, t] of its length.
    /// Deterministic per-seed sine so the path looks the same every
    /// loop. Plain lerp would read as a guided rail.
    private func drawWobblyStroke(context: GraphicsContext, size: CGSize,
                                  from: CGPoint, to: CGPoint,
                                  t: CGFloat, seed: Int) {
        guard t > 0.001 else { return }
        let from = scaled(from, in: size)
        let to = scaled(to, in: size)
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = sqrt(dx * dx + dy * dy)
        guard length > 0.5 else { return }
        let perpX = -dy / length
        let perpY = dx / length
        let wobbleAmp: CGFloat = 1.6  // child writing is mostly straight
        let phaseShift = CGFloat(seed) * 1.3

        var path = Path()
        let steps = max(8, Int(length / 4))
        let lastIdx = max(1, Int((CGFloat(steps) * t).rounded()))
        for i in 0...min(lastIdx, steps) {
            let f = CGFloat(i) / CGFloat(steps)
            let baseX = from.x + dx * f
            let baseY = from.y + dy * f
            // Taper the wobble near endpoints — keeps start/end on
            // the reference, matching real freehand writing at this age.
            let edgeWindow = sin(f * .pi)  // 0 at ends, 1 in middle
            let wob = sin(f * 6.0 + phaseShift) * wobbleAmp * edgeWindow
            let x = baseX + perpX * wob
            let y = baseY + perpY * wob
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else      { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        context.stroke(path, with: .color(.canvasInkStroke),
                       style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
    }
}

// MARK: - Step 6: Reward Intro

private struct RewardIntroStepView: View {
    @Environment(TracingViewModel.self) private var vm
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("⭐")
                .font(.system(size: 64))

            Text("Sammle Sterne!")
                .font(.display(FontSize.xl, weight: .bold))
                .foregroundStyle(Color.ink)

            Text("Für jeden Buchstaben bekommst du\nbis zu 4 Sterne!")
                .font(.body(FontSize.base))
                .foregroundStyle(Color.inkSoft)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                ForEach(LearningPhase.allCases, id: \.self) { phase in
                    VStack(spacing: 6) {
                        Text(phase.icon)
                            .font(.display(FontSize.xl))
                        Text(phase.displayName)
                            .font(.caption)
                            .foregroundStyle(Color.inkSoft)
                    }
                }
            }
            .padding(.vertical, 8)

            Button("Fertig!", action: onNext)
                .buttonStyle(StickerButtonStyle())
                .controlSize(.large)
                .accessibilityLabel("Fertig")
                .accessibilityHint("Schließt die Einführung ab und beginnt die Buchstaben-Schule")
        }
        .padding(32)
        .onAppear {
            vm.speech.stop()
            vm.speech.speak("Sammle Sterne! Für jeden Buchstaben bekommst du bis zu vier Sterne. Tippe auf Fertig und los geht's!")
        }
        .onDisappear { vm.speech.stop() }
    }
}
#endif
