// FreeformWritingView.swift
// PrimaeNative
//
// Blank-canvas writing mode — no reference, checkpoints, or phases.
// Lift (letter sub-mode) or "Fertig" (word sub-mode) runs CoreML.
// Deliberately silent so the recognition badge is the only feedback.
//
// COMPILED OUT OF THE STUDY BUILD. Its sole consumer, WerkstattWorldView,
// is already excluded — this closes the gap between "unreferenced from
// any study-build file" and "absent from the study binary" (Swift
// still compiles an unreferenced top-level type into the target). Same
// reasoning as the six CanvasOverlay surfaces already excluded. The CI
// identity scan asserts this via SURFACES (ios-build.yml).
#if !STUDY_BUILD
import SwiftUI
import UIKit

// MARK: - Surface palette

/// Freeform-mode tokens. Card / edge / prompt alias `AppSurface` so a
/// re-skin only touches one file.
private enum FreeformSurface {
    static let header   = Color(red: 0.94, green: 0.94, blue: 0.97)
    static let card     = AppSurface.card
    static let cardEdge = AppSurface.cardEdge
    /// Word-picker pill background, dark enough to keep the label
    /// legible (purple.opacity(0.12) failed WCAG AA).
    static let pillIdle = Color(red: 0.91, green: 0.85, blue: 0.97)
    /// Dark purple ≈ 7:1 contrast against `pillIdle`.
    static let pillIdleText = Color(red: 0.30, green: 0.13, blue: 0.45)
    static let prompt   = AppSurface.prompt
}

struct FreeformWritingView: View {
    @Environment(TracingViewModel.self) private var vm
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Recognition results already dismissed; without this the popup
    /// reappears on the next render. Reset on canvas clear.
    @State private var dismissedResultLetter: String? = nil

    /// Dynamic-Type-scaled target-word glyph size.
    @ScaledMetric(relativeTo: .title) private var targetWordFontSize: CGFloat = 30

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.canvasPaper
                    .ignoresSafeArea()

                // Header + canvas pinned to the top; footer is a
                // bottom-anchored overlay so a tall result panel can't
                // push the canvas up.
                VStack(spacing: 0) {
                    header
                    if vm.freeformSubMode == .word {
                        wordPickerStrip
                    }
                    freeformCanvas(size: geo.size)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity,
                       maxHeight: .infinity,
                       alignment: .top)
                .overlay(alignment: .bottom) {
                    footer
                }

                if shouldShowResultPopup, let r = vm.lastRecognitionResult {
                    resultPopup(result: r)
                        .transition(reduceMotion
                                    ? .opacity
                                    : .scale(scale: 0.92).combined(with: .opacity))
                        .zIndex(20)
                }
            }
        }
        // Canvas is hard-coded light; rest of the view inherits so
        // `.primary`/`.secondary` don't disappear into white in dark
        // mode.
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.82),
                   value: shouldShowResultPopup)
        .onChange(of: vm.freeformPoints.count) { _, newValue in
            // Re-arm the popup after the canvas clears.
            if newValue == 0 { dismissedResultLetter = nil }
        }
    }

    /// Letter mode only — word mode uses an inline chip row.
    private var shouldShowResultPopup: Bool {
        guard vm.freeformSubMode == .letter,
              let r = vm.lastRecognitionResult else { return false }
        return dismissedResultLetter != popupKey(for: r)
    }

    private func popupKey(for r: RecognitionResult) -> String {
        // Predicted letter + confidence + stroke count, so the same
        // letter shown twice in a row still re-pops.
        "\(r.predictedLetter)-\(Int((r.confidence * 100).rounded()))-\(vm.freeformStrokeSizes.count)"
    }

    // MARK: - Header (two rows: nav + prompt)

    private var header: some View {
        VStack(spacing: 8) {
            // Row 1: Zurück / Nochmal. Mode picker lives on the
            // WerkstattWorldView left rail.
            HStack(alignment: .center, spacing: 12) {
                Button {
                    vm.exitFreeformMode()
                } label: {
                    Label("Zurück", systemImage: "chevron.left")
                        .font(.body(FontSize.md, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(.gray)
                .accessibilityHint("Zurück zum geführten Modus")

                Spacer()

                Button {
                    vm.clearFreeformCanvas()
                } label: {
                    Label("Nochmal", systemImage: "arrow.counterclockwise")
                        .font(.body(FontSize.md, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .accessibilityHint("Leert das Blatt, damit du es nochmal versuchen kannst")
            }

            // Row 2: target prompt, separated from the nav row.
            HStack {
                Spacer()
                if vm.freeformSubMode == .word, let target = vm.freeformTargetWord {
                    HStack(spacing: 8) {
                        Text("Schreibe:")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(FreeformSurface.prompt)
                        Text(target.word)
                            .font(.system(size: targetWordFontSize, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.ink)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Zielwort \(target.word)")
                } else {
                    // Mirror the in-canvas prompt verbatim.
                    Text("Schreibe einen Buchstaben mit dem Finger oder dem Stift.")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(FreeformSurface.prompt)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(FreeformSurface.header)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(FreeformSurface.cardEdge.opacity(0.5))
                .frame(height: 1)
        }
    }

    // MARK: - Word picker strip

    private var wordPickerStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(FreeformWordList.all, id: \.self) { word in
                    let isSelected = vm.freeformTargetWord == word
                    Button {
                        vm.selectFreeformWord(word)
                    } label: {
                        Text(word.word)
                            .font(.system(.headline, design: .rounded).weight(.semibold))
                            .foregroundStyle(isSelected
                                             ? Color.canvasPaper
                                             : FreeformSurface.pillIdleText)
                            // 44 pt HIG touch target: headline + 2×14 pt.
                            .padding(.horizontal, 14).padding(.vertical, 14)
                            .background(
                                isSelected
                                    ? Color.purple
                                    : FreeformSurface.pillIdle,
                                in: Capsule()
                            )
                            .overlay(
                                Capsule()
                                    .stroke(isSelected
                                            ? Color.clear
                                            : FreeformSurface.pillIdleText.opacity(0.35),
                                            lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Zielwort \(word.word)")
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Blank canvas

    @ViewBuilder
    private func freeformCanvas(size: CGSize) -> some View {
        let canvasSize = CGSize(width: size.width, height: size.height * 0.65)
        ZStack {
            Canvas { context, canvasDrawSize in
                drawSegmentationGuides(context: context, size: canvasDrawSize)
                drawCommittedPoints(context: context, size: canvasDrawSize)
                drawActivePath(context: context, size: canvasDrawSize)
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .background(Color(white: 0.97))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
            .accessibilityLabel("Schreibfläche für freies Schreiben")
            .accessibilityHint("Ziehe mit einem Finger, um einen Buchstaben zu schreiben")
        }
        .overlay(
            FreeformTouchOverlay(
                canvasSize: canvasSize,
                onBegan: { p in vm.beginFreeformTouch(at: p) },
                onMoved: { p in vm.updateFreeformTouch(at: p, canvasSize: canvasSize) },
                onEnded: { vm.endFreeformTouch() }
            )
        )
        .frame(height: canvasSize.height)
    }

    private func drawCommittedPoints(context: GraphicsContext, size: CGSize) {
        // Per-stroke polylines so pen lifts stay visible as gaps.
        let all = vm.freeformPoints
        guard !all.isEmpty else { return }
        var cursor = 0
        for strokeLen in vm.freeformStrokeSizes {
            let endIdx = min(cursor + strokeLen, all.count)
            guard endIdx - cursor >= 2 else { cursor = endIdx; continue }
            var path = Path()
            path.addLines(Array(all[cursor..<endIdx]))
            context.stroke(path, with: .color(.black),
                           style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            cursor = endIdx
        }
    }

    private func drawActivePath(context: GraphicsContext, size: CGSize) {
        let pts = vm.freeformActivePath
        guard pts.count >= 2 else { return }
        var path = Path()
        path.addLines(pts)
        context.stroke(path, with: .color(.green),
                       style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
    }

    private func drawSegmentationGuides(context: GraphicsContext, size: CGSize) {
        guard vm.freeformSubMode == .word,
              let target = vm.freeformTargetWord else { return }
        let letterCount = max(target.word.count, 1)
        let step = size.width / CGFloat(letterCount)
        for i in 1..<letterCount {
            let x = step * CGFloat(i)
            var line = Path()
            line.move(to: CGPoint(x: x, y: 8))
            line.addLine(to: CGPoint(x: x, y: size.height - 8))
            context.stroke(line, with: .color(.gray.opacity(0.25)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 6]))
        }
    }

    // MARK: - Footer (feedback + submit)

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 10) {
            if vm.freeformSubMode == .word {
                wordFooter
            } else {
                letterFooter
            }
        }
        // `minHeight` reserves space for the tallest letterFooter
        // state so the footer doesn't reflow mid-stroke. Word-mode's
        // panel can grow, but only after the explicit "Fertig" tap.
        .frame(maxWidth: .infinity,
               minHeight: 130,
               alignment: .top)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 20)
    }

    @ViewBuilder
    private var letterFooter: some View {
        if vm.isRecognitionModelAvailable == false {
            statusBanner(
                icon: "exclamationmark.triangle.fill",
                tint: .red,
                title: "KI-Modell nicht verfügbar",
                subtitle: "Die Buchstaben-Erkennung wurde nicht gefunden. Freies Schreiben funktioniert, aber die Rückmeldung fehlt."
            )
        } else if vm.isRecognizing {
            statusBanner(
                icon: "sparkles",
                tint: .blue,
                title: "Wird erkannt…",
                subtitle: "Ich schaue mir deinen Buchstaben an."
            )
        } else if vm.isWaitingForRecognition {
            // Visible debounce window so the multi-stroke wait feels
            // intentional instead of laggy.
            statusBanner(
                icon: "hourglass",
                tint: Color(red: 0.40, green: 0.30, blue: 0.80),
                title: "Fertig mit dem Buchstaben?",
                subtitle: "Einen kleinen Moment — oder mach noch einen Strich, wenn du willst."
            )
        } else if let r = vm.lastRecognitionResult {
            letterResultPanel(result: r)
        } else if vm.hasRecognitionCompleted, !vm.freeformPoints.isEmpty {
            statusBanner(
                icon: "questionmark.circle.fill",
                tint: .orange,
                title: "Ich konnte nichts erkennen",
                subtitle: "Probiere es noch einmal — schreibe den Buchstaben groß und deutlich."
            )
        } else if vm.freeformPoints.isEmpty {
            Text("Schreibe einen Buchstaben mit dem Finger oder dem Stift.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(FreeformSurface.prompt)
        } else {
            Text("Hebe den Finger, um deinen Buchstaben erkennen zu lassen.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(FreeformSurface.prompt)
        }
    }

    private func statusBanner(icon: String,
                              tint: Color,
                              title: String,
                              subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.display(FontSize.xl))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body(FontSize.md, weight: .semibold)).foregroundStyle(Color.ink)
                Text(subtitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(FreeformSurface.prompt)
            }
            Spacer()
        }
        .padding(12)
        .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(tint.opacity(0.55), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title + ". " + subtitle)
    }

    /// Inline stub under the canvas after popup dismiss — predicted
    /// letter + headline only.
    private func letterResultPanel(result: RecognitionResult) -> some View {
        let raw = result.confidence
        let tint: Color = raw >= 0.7 ? .green : (raw >= 0.4 ? .yellow : .orange)
        let headline = headline(for: result)
        return HStack(spacing: 14) {
            Text(result.predictedLetter)
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .foregroundStyle(Color.ink)
                .frame(width: 72, height: 72)
                .background(tint.opacity(0.20), in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(tint.opacity(0.55), lineWidth: 1)
                )
            Text(headline)
                .font(.body(FontSize.md, weight: .semibold))
                .foregroundStyle(Color.ink)
            Spacer()
            // Re-open the popup on demand.
            Button {
                dismissedResultLetter = nil
            } label: {
                Image(systemName: "info.circle.fill")
                    .font(.display(FontSize.lg))
                    .foregroundStyle(tint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Bewertung erneut anzeigen")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(FreeformSurface.card, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(FreeformSurface.cardEdge, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(headline)
    }

    private func headline(for result: RecognitionResult) -> String {
        let raw = result.confidence
        if raw >= 0.7 {
            return "Du hast ein \(result.predictedLetter) geschrieben!"
        } else if raw >= 0.4 {
            return "Das sieht aus wie ein \(result.predictedLetter)."
        } else {
            return "Vielleicht ein \(result.predictedLetter) — ich bin nicht sicher."
        }
    }

    // MARK: - Result popup (child-facing written evaluation)

    /// Modal popup centred over the canvas. Drives off the form score
    /// so well-shaped letters get rewarded even when CoreML's
    /// confusable-pair penalty drops Klarheit; falls back to Klarheit
    /// when no reference glyph is bundled.
    private func resultPopup(result: RecognitionResult) -> some View {
        let formScore = vm.lastFreeformFormScore
        let scoreForMessage = formScore ?? result.confidence
        let tint: Color = scoreForMessage >= 0.7 ? .green
                       : (scoreForMessage >= 0.45 ? .yellow : .orange)
        let evaluation = formEvaluation(score: scoreForMessage,
                                        letter: result.predictedLetter,
                                        hasFormScore: formScore != nil)
        let stars = formStars(for: scoreForMessage)

        return ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismissPopup(for: result) }
                .accessibilityHidden(true)

            VStack(spacing: 18) {
                Text(result.predictedLetter)
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.ink)
                    .frame(width: 132, height: 132)
                    .background(tint.opacity(0.22),
                                in: RoundedRectangle(cornerRadius: 26))
                    .overlay(
                        RoundedRectangle(cornerRadius: 26)
                            .stroke(tint.opacity(0.55), lineWidth: 2)
                    )

                Text(headline(for: result))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Color.ink)
                    .multilineTextAlignment(.center)

                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { idx in
                        let filled = idx < stars
                        Image(systemName: filled ? "star.fill" : "star")
                            .font(.system(size: 26))
                            .foregroundStyle(filled ? AppSurface.starGold : Color.gray.opacity(0.45))
                    }
                }
                .accessibilityLabel("\(stars) von 3 Sternen für die Form")

                Text(evaluation)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(FreeformSurface.prompt)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)

                HStack(spacing: 14) {
                    Button {
                        vm.clearFreeformCanvas()
                        dismissPopup(for: result)
                    } label: {
                        Label("Nochmal", systemImage: "arrow.counterclockwise")
                            .font(.body(FontSize.md, weight: .semibold))
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)

                    Button {
                        dismissPopup(for: result)
                    } label: {
                        Label("Weiter", systemImage: "checkmark")
                            .font(.body(FontSize.md, weight: .semibold))
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                }

                // Numeric metrics live in the parent-gated research
                // dashboard; the child popup is metric-free.
            }
            .padding(28)
            .frame(maxWidth: 460)
            .background(FreeformSurface.card,
                        in: RoundedRectangle(cornerRadius: 28))
            .overlay(
                RoundedRectangle(cornerRadius: 28)
                    .stroke(FreeformSurface.cardEdge, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
            .padding(24)
        }
    }

    private func dismissPopup(for result: RecognitionResult) {
        dismissedResultLetter = popupKey(for: result)
    }

    /// Stars 0–3 — bands mirror the celebration overlay's tiering.
    private func formStars(for score: CGFloat) -> Int {
        switch score {
        case 0.85...:   return 3
        case 0.65..<0.85: return 2
        case 0.40..<0.65: return 1
        default:        return 0
        }
    }

    /// Child-friendly evaluation, varied per band. When
    /// `hasFormScore == false` we don't praise shape we couldn't
    /// measure.
    private func formEvaluation(score: CGFloat,
                                 letter: String,
                                 hasFormScore: Bool) -> String {
        if !hasFormScore {
            // Speak only to what the recogniser saw.
            return score >= 0.7
                ? "Super, ich erkenne dein \(letter) ganz klar!"
                : "Ich glaube, das ist ein \(letter). Probier es nochmal größer und deutlicher."
        }
        switch score {
        case 0.85...:
            return "Wunderschön! Dein \(letter) sieht fast aus wie im Buch. ⭐️"
        case 0.70..<0.85:
            return "Toll gemacht! Dein \(letter) ist sehr gut geworden."
        case 0.55..<0.70:
            return "Gut! Mit ein bisschen Übung wird dein \(letter) noch schöner."
        case 0.35..<0.55:
            return "Nicht schlecht! Probier dein \(letter) etwas größer und langsamer."
        default:
            return "Übe dein \(letter) noch ein bisschen — du schaffst das!"
        }
    }

    @ViewBuilder
    private var wordFooter: some View {
        if vm.isRecognitionModelAvailable == false {
            statusBanner(
                icon: "exclamationmark.triangle.fill",
                tint: .red,
                title: "KI-Modell nicht verfügbar",
                subtitle: "Die Buchstaben-Erkennung wurde nicht gefunden. Du kannst trotzdem das Wort schreiben."
            )
        } else if vm.isRecognizing {
            statusBanner(
                icon: "sparkles",
                tint: .blue,
                title: "Wort wird erkannt…",
                subtitle: "Ich schaue mir deine Buchstaben an."
            )
        } else if !vm.freeformWordResultSlots.isEmpty {
            wordResultPanel
        } else {
            HStack(spacing: 12) {
                Text(vm.freeformPoints.isEmpty
                     ? "Schreibe das Wort Buchstabe für Buchstabe."
                     : "Wenn du fertig bist, tippe auf Fertig.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(FreeformSurface.prompt)
                Spacer()
                Button {
                    vm.submitFreeformWord()
                } label: {
                    Label("Fertig", systemImage: "checkmark.seal.fill")
                        .font(.body(FontSize.md, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(vm.freeformPoints.count < 2)
                .accessibilityHint("Lässt alle geschriebenen Buchstaben erkennen und zeigt dir das Ergebnis")
            }
        }
    }

    @ViewBuilder
    private var wordResultPanel: some View {
        let target = vm.freeformTargetWord?.word ?? ""
        let targetChars = Array(target)
        // Slot-aligned so missing letters show as grey placeholders.
        let slots = vm.freeformWordResultSlots
        let recognized = slots.map { $0?.predictedLetter ?? "·" }.joined()
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(Array(targetChars.enumerated()), id: \.offset) { idx, ch in
                    letterChip(expected: String(ch),
                               result: idx < slots.count ? slots[idx] : nil)
                }
            }
            Text("Erkannt: \(recognized.isEmpty ? "—" : recognized)")
                .font(.body(FontSize.md, weight: .semibold))
                .foregroundStyle(Color.ink)
            Text(recognized.uppercased() == target.uppercased()
                 ? "🎉 Super, du hast das Wort richtig geschrieben!"
                 : "Gut versucht! Vergleiche mit dem Zielwort oben.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(FreeformSurface.prompt)
            HStack(spacing: 12) {
                Button {
                    vm.clearFreeformCanvas()
                } label: {
                    Label("Nochmal", systemImage: "arrow.counterclockwise")
                        .font(.body(FontSize.md, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)

                Button {
                    vm.exitFreeformMode()
                } label: {
                    Label("Zurück", systemImage: "chevron.left")
                        .font(.body(FontSize.md, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(.gray)
                Spacer()
            }
        }
        .padding(14)
        .background(FreeformSurface.card, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(FreeformSurface.cardEdge, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
    }

    @ViewBuilder
    private func letterChip(expected: String, result: RecognitionResult?) -> some View {
        let correct = result?.predictedLetter.caseInsensitiveCompare(expected) == .orderedSame
        let shown = result?.predictedLetter ?? "·"
        let tint: Color = result == nil ? .gray : (correct ? .green : .orange)
        VStack(spacing: 2) {
            Text(expected).font(.caption.weight(.semibold)).foregroundStyle(Color.ink)
            Text(shown)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(tint, in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityLabel("\(expected) wurde als \(shown) erkannt — \(correct ? "richtig" : "noch nicht richtig")")
    }

}

// MARK: - Freeform touch overlay (finger + pencil, no audio hookup)

private struct FreeformTouchOverlay: UIViewRepresentable {
    let canvasSize: CGSize
    let onBegan: (CGPoint) -> Void
    let onMoved: (CGPoint) -> Void
    let onEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onBegan: onBegan, onMoved: onMoved, onEnded: onEnded)
    }

    func makeUIView(context: Context) -> TouchView {
        let v = TouchView(coordinator: context.coordinator)
        v.backgroundColor = .clear
        v.isMultipleTouchEnabled = false
        return v
    }

    func updateUIView(_ uiView: TouchView, context: Context) {
        uiView.coordinator = context.coordinator
    }

    final class TouchView: UIView {
        var coordinator: Coordinator
        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let t = touches.first else { return }
            coordinator.onBegan(t.location(in: self))
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let t = touches.first else { return }
            coordinator.onMoved(t.location(in: self))
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            coordinator.onEnded()
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            coordinator.onEnded()
        }
    }

    final class Coordinator {
        let onBegan: (CGPoint) -> Void
        let onMoved: (CGPoint) -> Void
        let onEnded: () -> Void
        init(onBegan: @escaping (CGPoint) -> Void,
             onMoved: @escaping (CGPoint) -> Void,
             onEnded: @escaping () -> Void) {
            self.onBegan = onBegan
            self.onMoved = onMoved
            self.onEnded = onEnded
        }
    }
}
#endif
