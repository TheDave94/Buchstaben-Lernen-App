// SchuleWorldView.swift
// PrimaeNative
//
// World 1 — Buchstaben-Schule. Hosts `TracingCanvasView` full-bleed
// with minimal HUD: letter pill (top-left), phase dots + prev/next
// (bottom). Scoring/audio/recognition stay on `TracingViewModel`.

import SwiftUI

struct SchuleWorldView: View {
    @Environment(TracingViewModel.self) private var vm
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showLetterPicker = false

    var body: some View {
        if let failure = vm.sessionBlockReason {
            // Proctor-facing hard stop (ruling C3-6): the canvas is not
            // rendered at all, so a phoneme-arm session without its
            // recordings cannot be run and cannot be missed.
            ContentUnavailableView(
                "Studie kann nicht starten",
                systemImage: "exclamationmark.octagon.fill",
                description: Text(failure)
            )
        } else if vm.visibleLetterNames.isEmpty {
            ContentUnavailableView(
                "Buchstaben nicht geladen",
                systemImage: "exclamationmark.triangle",
                description: Text("Bitte die App neu starten.")
            )
        } else {
        ZStack {
            WorldPalette.background(for: .schule)
                .ignoresSafeArea()

            TracingCanvasView()
                .background(Color.canvasPaper)
                .clipShape(RoundedRectangle(cornerRadius: Radii.xl, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radii.xl, style: .continuous)
                        .stroke(Color.paperEdge, lineWidth: 1)
                )
                .padding(.horizontal, 16)
                .padding(.top, 64)
                .padding(.bottom, 86)
                .shadow(color: Color.ink.opacity(0.08), radius: 18, y: 4)

            if vm.learningPhase == .observe, !vm.isCalibrating {
                observeOverlay
            }

            // Post-freeWrite overlays serialise through the queue
            // (canonical order: kpOverlay → recognitionBadge →
            // paperTransfer → celebration). The KP overlay is rendered
            // inside `TracingCanvasView` to reach canvas geometry;
            // the modals below sit on top of the world chrome.
            queuedModalOverlay

            VStack {
                topRow
                // Feedback cards are reward-class UI — off in study
                // sessions so all arms end trials identically (audit C2).
                if let guided = vm.lastGuidedScore,
                   vm.learningPhase == .freeWrite, !vm.studyMode {
                    guidedFeedbackCard(score: guided)
                        .padding(.top, 8)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
                if let assessment = vm.lastWritingAssessment,
                   vm.learningPhase == .freeWrite, !vm.studyMode,
                   !isQueueShowingKPOverlay {
                    // Form-accuracy row between KP-overlay dismiss and
                    // the celebration. The opaque celebration modal
                    // covers this card when it appears.
                    formFeedbackCard(score: assessment.formAccuracy)
                        .padding(.top, 8)
                        .transition(reduceMotion ? .opacity : .opacity)
                }
                Spacer()
                bottomBar
            }
            .padding(.vertical, 16)

            if let toast = vm.toastMessage {
                VStack {
                    Text(toast)
                        .font(.body(FontSize.base, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(AppSurface.card, in: Capsule())
                        .overlay(Capsule().stroke(AppSurface.cardEdge, lineWidth: 1))
                        .shadow(color: Color.ink.opacity(0.10), radius: 6, y: 2)
                        .padding(.top, 80)
                    Spacer()
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale))
            }

            // LetterWheelPicker itself is compiled out of the study
            // build (see its header) — `showLetterPicker` can never
            // actually be true there once `letterPill` stops setting it
            // (see letterPill's own comment), but this construction
            // site needs its own guard regardless since the TYPE is
            // absent from the study binary.
            #if !STUDY_BUILD
            if showLetterPicker {
                LetterWheelPicker(
                    letters: vm.visibleLetterNames,
                    currentLetter: vm.currentLetterName,
                    starCount: { name in
                        // Read via `vm.allProgress` (the @Observable
                        // mirror) so the chip refreshes after a fresh
                        // completion without reopening the picker.
                        // Study sessions hide star chips (reward-class).
                        vm.studyMode ? 0 : LetterStars.stars(
                            for: (vm.allProgress[LetterProgress.canonicalKey(name)] ?? LetterProgress()).phaseScores)
                    },
                    onSelect: { letter in
                        vm.loadLetter(name: letter)
                        withAnimation { showLetterPicker = false }
                    },
                    onDismiss: {
                        withAnimation { showLetterPicker = false }
                    }
                )
                .zIndex(30)
            }
            #endif
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: vm.toastMessage)
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.78),
                   value: vm.overlayQueue.currentOverlay)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: showLetterPicker)
        }
    }

    // MARK: - Queue-driven modal overlays

    /// Renders whichever overlay the queue currently has on top —
    /// except the KP overlay (rendered inside `TracingCanvasView`).
    @ViewBuilder
    private var queuedModalOverlay: some View {
        switch vm.overlayQueue.currentOverlay {
        case .recognitionBadge(let result):
            // Enqueue sites are already `!studyMode`-gated (see
            // RecognitionFeedbackView.swift's header) — this can never
            // actually be `.recognitionBadge` under studyMode. The
            // `#else EmptyView()` branch is unreachable in practice, not
            // a behavior change; it exists because RecognitionFeedbackView
            // itself is compiled out of the study binary and this switch
            // must still type-check there.
            #if !STUDY_BUILD
            VStack {
                Spacer().frame(height: 88)
                RecognitionFeedbackView(
                    result: result,
                    expectedLetter: vm.currentLetterName,
                    onDismiss: { vm.overlayQueue.dismiss() }
                )
                Spacer()
            }
            .transition(reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .scale(scale: 0.9)))
            .zIndex(12)
            #else
            EmptyView()
            #endif
        case .paperTransfer(let letter):
            #if !STUDY_BUILD
            PaperTransferView(letter: letter) { score in
                vm.submitPaperTransfer(score: score)
            }
            .transition(.opacity)
            .zIndex(15)
            #else
            EmptyView()
            #endif
        case .celebration(let stars):
            #if !STUDY_BUILD
            CompletionCelebrationOverlay(starsEarned: stars, maxStars: vm.maxStars) {
                vm.loadRecommendedLetter()
            }
            .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
            .zIndex(20)
            #else
            EmptyView()
            #endif
        case .rewardCelebration(let event):
            // 2.5 s one-shot achievement celebration. Queue auto-
            // dismisses; tap-to-dismiss for impatient users.
            #if !STUDY_BUILD
            RewardCelebrationOverlay(event: event)
                .onTapGesture { vm.overlayQueue.dismiss() }
                .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                .zIndex(25)
            #else
            EmptyView()
            #endif
        case .retrievalPrompt(let letter, let distractors):
            // Spaced-retrieval prompt. Modal — child must answer
            // before tracing begins.
            #if !STUDY_BUILD
            RetrievalPromptView(
                target: letter,
                distractors: distractors,
                onPlayAudio: { vm.replayAudio() },
                onAnswer: { _, correct in
                    vm.submitRetrievalAnswer(letter: letter, correct: correct)
                }
            )
            .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
            .zIndex(22)
            #else
            EmptyView()
            #endif
        case .kpOverlay:
            // Rendered inside `TracingCanvasView` — it needs canvas
            // geometry and reference-stroke data.
            EmptyView()
        case .none:
            EmptyView()
        }
    }

    /// True while the queue is showing the KP (Knowledge of
    /// Performance) overlay — suppresses the inline form-accuracy
    /// card during that window.
    private var isQueueShowingKPOverlay: Bool {
        if case .kpOverlay = vm.overlayQueue.currentOverlay { return true }
        return false
    }

    // MARK: - Feedback cards

    private func guidedFeedbackCard(score: CGFloat) -> some View {
        feedbackCard(
            title: "Nachspuren fertig",
            score: score,
            subtitle: "So gut hast du die Linien getroffen."
        )
    }

    private func formFeedbackCard(score: CGFloat) -> some View {
        feedbackCard(
            title: "Selbst geschrieben",
            score: score,
            subtitle: "So ähnlich war deine Form dem Buchstaben."
        )
    }

    /// Verbal feedback band above the canvas after freeWrite.
    /// Child-facing — never shows numeric metrics; star count +
    /// colour swatch + short German encouragement only. Numeric
    /// scores live in the research dashboard and CSV/TSV export.
    private func feedbackCard(title: String, score: CGFloat, subtitle: String) -> some View {
        let tint: Color = score >= 0.7 ? .green : (score >= 0.5 ? .yellow : .orange)
        let starsEarned = score >= 0.85 ? 3 : (score >= 0.6 ? 2 : (score >= 0.35 ? 1 : 0))
        let praise: String
        switch starsEarned {
        case 3: praise = "Super gemacht!"
        case 2: praise = "Gut gemacht!"
        case 1: praise = "Schon ganz gut."
        default: praise = "Probier es nochmal."
        }
        return HStack(spacing: 14) {
            // Mood swatch — colour conveys quality without a number.
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(tint.opacity(0.22))
                RoundedRectangle(cornerRadius: 12)
                    .stroke(tint.opacity(0.55), lineWidth: 1)
                Image(systemName: starsEarned >= 2
                                  ? "hand.thumbsup.fill"
                                  : "sparkles")
                    .font(.display(FontSize.md))
                    .foregroundStyle(tint)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body(FontSize.sm, weight: .bold)).foregroundStyle(Color.ink)
                Text(praise).font(.body(FontSize.xs, weight: .medium)).foregroundStyle(AppSurface.caption)
            }
            Spacer()
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { idx in
                    let filled = idx < starsEarned
                    Image(systemName: filled ? "star.fill" : "star")
                        .font(.footnote)
                        .foregroundStyle(filled ? AppSurface.starGold : Color.starEmpty)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(AppSurface.card, in: RoundedRectangle(cornerRadius: Radii.md))
        .overlay(RoundedRectangle(cornerRadius: Radii.md).stroke(tint.opacity(0.55), lineWidth: 1))
        .shadow(color: Color.ink.opacity(0.08), radius: 6, y: 2)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(praise) \(subtitle)")
    }

    // MARK: - Top row (letter pill)

    private var topRow: some View {
        HStack {
            letterPill
            #if !STUDY_BUILD
            if vm.currentLetterHasVariants {
                variantToggle
            }
            #endif
            Spacer()
            // Persistent star badge is reward-class — off in study mode.
            if !vm.studyMode, totalStars > 0 {
                starCountBadge(count: totalStars)
            }
        }
        .padding(.horizontal, 16)
    }

    // COMPILED OUT OF THE STUDY BUILD. `currentLetterHasVariants`
    // already returns false under studyMode ("a child-reachable variant
    // toggle would swap F's scorer reference geometry mid-study" — its
    // own doc comment), so this was already runtime-unreachable there;
    // gating the declaration too closes the gap between "unreachable"
    // and "absent from the binary", matching the other compiled-out
    // overlay surfaces. The CI identity scan asserts this via SURFACES
    // (ios-build.yml).
    #if !STUDY_BUILD
    /// Toggle between the standard glyph and its alternate form
    /// (currently only Druckschrift k via OpenType `ss02`).
    private var variantToggle: some View {
        Button {
            vm.toggleVariant()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: vm.showingVariant ? "arrow.left.arrow.right.circle.fill"
                                                    : "arrow.left.arrow.right.circle")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(AppSurface.prompt)
                Text(vm.showingVariant ? "Variante" : "Standard")
                    .font(.body(FontSize.sm, weight: .semibold))
                    .foregroundStyle(Color.ink)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(AppSurface.card, in: Capsule())
            .overlay(Capsule().stroke(AppSurface.cardEdge, lineWidth: 1))
            .shadow(color: Color.ink.opacity(0.08), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Buchstaben-Variante umschalten")
        .accessibilityValue(vm.showingVariant ? "Variante" : "Standard")
    }
    #endif

    /// Total stars across all letters — same computation as the
    /// world rail's badge so the two displays always agree.
    private var totalStars: Int {
        vm.allProgress.values.reduce(0) { acc, prog in
            acc + LetterStars.stars(for: prog.phaseScores)
        }
    }

    /// Persistent header pill (star + running total). Mirrors the
    /// world-rail badge styling; placed top-right so accumulating
    /// stars are visible without world-switching.
    private func starCountBadge(count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "star.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(AppSurface.starGold)
            Text(count > 99 ? "99+" : "\(count)")
                .font(.display(FontSize.base, weight: .bold))
                .foregroundStyle(Color.ink)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(AppSurface.card, in: Capsule())
        .overlay(Capsule().stroke(AppSurface.cardEdge, lineWidth: 1))
        .shadow(color: Color.ink.opacity(0.08), radius: 5, y: 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) Sterne gesamt")
    }

    // The free-jump letter picker this pill opens is compiled out of
    // the study build (see LetterWheelPicker.swift's header) — a
    // direct-jump shortcut is the same class of risk `letterOrdering`'s
    // studyMode pin exists to prevent, and `nextLetter()`/
    // `previousLetter()` (the bottom-bar nav arrows) remain as the
    // sole, sequence-respecting way to move between letters there. The
    // current-letter TEXT stays visible either way — that's task
    // context (which letter am I tracing), not the picker affordance —
    // just non-interactive and without the "tap to change" chevron
    // under STUDY_BUILD.
    private var letterPill: some View {
        #if !STUDY_BUILD
        Button {
            withAnimation { showLetterPicker = true }
        } label: {
            HStack(spacing: 8) {
                Text(vm.currentLetterName)
                    .font(.display(FontSize.lg, weight: .bold))
                    .foregroundStyle(Color.ink)
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(AppSurface.prompt)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(AppSurface.card, in: Capsule())
            .overlay(Capsule().stroke(AppSurface.cardEdge, lineWidth: 1))
            .shadow(color: Color.ink.opacity(0.08), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            // Tap or long-press both open the picker. Long-press
            // matches the spec; tap keeps it obvious for a child.
            LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                withAnimation { showLetterPicker = true }
            }
        )
        .accessibilityLabel("Aktueller Buchstabe \(vm.currentLetterName)")
        .accessibilityHint("Tippen oder gedrückt halten, um einen anderen Buchstaben zu wählen")
        .accessibilityAddTraits(.isButton)
        #else
        Text(vm.currentLetterName)
            .font(.display(FontSize.lg, weight: .bold))
            .foregroundStyle(Color.ink)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(AppSurface.card, in: Capsule())
            .overlay(Capsule().stroke(AppSurface.cardEdge, lineWidth: 1))
            .shadow(color: Color.ink.opacity(0.08), radius: 5, y: 2)
            .accessibilityLabel("Aktueller Buchstabe \(vm.currentLetterName)")
        #endif
    }

    // MARK: - Observe overlay

    private var observeOverlay: some View {
        // Pre-reader UI — the spoken prompt + guide-dot animation
        // carry the phase cue. The on-screen overlay is two glyphs
        // (eye = watch, finger = tap to continue) in a brand pill.
        VStack {
            Spacer()
            HStack(spacing: 18) {
                Text("👁️").font(.system(size: 36))
                Text("👆").font(.system(size: 36))
            }
            .padding(.horizontal, 28).padding(.vertical, 16)
            .background(Color.brand, in: Capsule())
            .shadow(color: Color.brand.opacity(0.30), radius: 12, y: 4)
            .padding(.bottom, 100)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        // Under studyMode the tap is inert: every child watches the same
        // two animation cycles (and the arm's demonstration over them),
        // so model exposure does not vary with a child's impatience
        // (audit 3.14a, 2026-09-04). The nav arrows still move on.
        .onTapGesture { if !vm.studyMode { vm.completeObservePhase() } }
        .accessibilityLabel("Beobachtungsphase")
        .accessibilityHint("Tippe, um zur nächsten Phase zu wechseln")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Bottom bar (phase dots + letter nav)

    private var bottomBar: some View {
        HStack(spacing: 24) {
            navArrow(systemName: "chevron.left",
                     label: "Vorheriger Buchstabe") { vm.previousLetter() }
            PhaseDotIndicator(phase: vm.learningPhase, scores: vm.phaseScores,
                              activePhases: vm.activePhases)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(AppSurface.card, in: Capsule())
                .overlay(Capsule().stroke(AppSurface.cardEdge, lineWidth: 1))
                .shadow(color: Color.ink.opacity(0.08), radius: 5, y: 2)
            navArrow(systemName: "chevron.right",
                     label: "Nächster Buchstabe") { vm.nextLetter() }
        }
        .padding(.bottom, 8)
    }

    private func navArrow(systemName: String,
                          label: String,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color.ink)
                .frame(width: 44, height: 44)
                .background(AppSurface.card, in: Circle())
                .overlay(Circle().stroke(AppSurface.cardEdge, lineWidth: 1))
                .shadow(color: Color.ink.opacity(0.08), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
