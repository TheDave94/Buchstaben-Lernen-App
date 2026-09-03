// PhaseTransitionCoordinator.swift
// PrimaeNative
//
// Owns the post-phase pipeline: `advance()` scores the just-completed
// phase, queues post-freeWrite overlays, advances the controller, and
// either announces the next phase or runs the completion pipeline.
// `recordSessionCompletion()` writes the dashboard rows, then
// `commitCompletion(...)` writes durable progress, streaks, reward
// overlays, cloud sync, difficulty-tier adaptation, and the HUD.
//
// VM strong-owns the coordinator; coordinator weakly references the
// VM. The coordinator is stateless beyond the back-reference.

import Foundation
import QuartzCore

@MainActor
final class PhaseTransitionCoordinator {
    /// Weak back-reference set by `TracingViewModel.init` after
    /// `self.phaseTransitions = pc` — same two-phase pattern as
    /// `playback` and `touchDispatcher`.
    weak var vm: TracingViewModel?

    // MARK: - Public entry (forwarded from VM)

    /// Score the active phase, queue post-freeWrite overlays, advance
    /// the controller, and either announce the next phase or run the
    /// completion pipeline.
    func advance() {
        guard let vm else { return }
        let score: CGFloat
        switch vm.phaseController.currentPhase {
        case .observe:
            score = 1.0
        case .direct:
            score = 1.0  // pass/fail
        case .guided:
            score = vm.progress
        case .freeWrite:
            guard let def = vm.strokeTracker.definition else {
                vm.freeWriteRecorder.clearAll()
                score = 0
                break
            }
            // Multi-cell (pencil / word): pass each cell's frame so
            // points normalise into cell-local 0–1 space matching the
            // reference, and average the four Schreibmotorik dimensions
            // across cells. Single-cell falls through to the original
            // finger-mode contract.
            if vm.grid.cells.count > 1 {
                let cellRefs = vm.grid.cells.compactMap { cell -> (frame: CGRect, reference: LetterStrokes)? in
                    guard let ref = cell.tracker.definition else { return nil }
                    return (frame: cell.frame, reference: ref)
                }
                if cellRefs.isEmpty {
                    score = vm.freeWriteRecorder.assess(
                        reference: def, canvasSize: vm.canvasSize,
                        cellFrame: vm.grid.activeCell.frame
                    ).overallScore
                } else {
                    score = vm.freeWriteRecorder.assess(
                        cellReferences: cellRefs,
                        canvasSize: vm.canvasSize
                    ).overallScore
                }
            } else {
                score = vm.freeWriteRecorder.assess(
                    reference: def, canvasSize: vm.canvasSize,
                    cellFrame: nil
                ).overallScore
            }
        }

        let wasInFreeWrite = vm.phaseController.currentPhase == .freeWrite
        let wasInGuided = vm.phaseController.currentPhase == .guided

        if wasInGuided {
            // Capture the guided score before the advance so the Schule
            // world can show a feedback band on the transition.
            vm.freeWriteRecorder.lastGuidedScore = score
        }

        // FreeWrite final phase: defer the celebration / completion
        // until the CoreML recognizer returns — we don't yet know
        // whether the result triggers retry or "Geschafft!".
        if wasInFreeWrite {
            vm.runRecognizerForFreeWrite(score: score)
            return
        }

        if vm.phaseController.advance(score: score) {
            vm.resetForPhaseTransition()
            if vm.phaseController.currentPhase == .observe {
                vm.startGuideAnimation()
            }
            vm.toast(vm.phaseController.currentPhase.displayName)
            // Verbal phase prompt for non-reading children.
            vm.prompts.play(
                ChildSpeechLibrary.phaseEntryPromptKey(vm.phaseController.currentPhase),
                fallbackText: ChildSpeechLibrary.phaseEntry(vm.phaseController.currentPhase)
            )
        } else {
            // Non-freeWrite final phase (.guidedOnly / .control land
            // here at end-of-guided). No recognizer; celebrate.
            recordSessionCompletion()
        }
    }

    // MARK: - FreeWrite recognizer-gated completion

    /// Called once the recognizer returns. Routes to retry only when
    /// the model is *confident the letter is wrong* (orange tier:
    /// `!isCorrect && confidence > 0.7`); everything else celebrates so
    /// uncertain models can't lock the child out.
    func completePostFreeWriteRecognition(score: CGFloat,
                                          result: RecognitionResult?) {
        guard let vm else { return }
        // One binding decides and carries the value. The previous shape
        // computed a Bool from `if let r = result`, then re-unwrapped
        // `result!` in the branch the Bool guarded — safe, but the flag
        // was the only reason a force-unwrap was needed at all.
        //
        // Study sessions never retry: the recognizer forcing extra
        // freeWrite attempts would manipulate the time-to-complete
        // outcome and vary trial counts between children. The recognition
        // sample is still recorded (passive data).
        if let r = result, !vm.studyMode, !r.isCorrect, r.confidence > 0.7 {
            requestFreeWriteRetry(result: r)
        } else {
            celebrateFreeWrite(score: score, result: result)
        }
    }

    private func celebrateFreeWrite(score: CGFloat,
                                    result: RecognitionResult?) {
        guard let vm else { return }
        // Study sessions: no KP reference-line overlay (a learning
        // intervention), no recognition badge, no praise — all arms end
        // freeWrite identically with no post-trial feedback (audit C2).
        if !vm.studyMode {
            vm.overlayQueue.enqueue(.kpOverlay)
            if let r = result, r.confidence >= 0.4 {
                vm.overlayQueue.enqueueBeforeCelebration(.recognitionBadge(r))
            }
            // Schule freeWrite uses a generic "Gut gemacht!" — letter-naming
            // feedback ("Du hast ein K geschrieben!") belongs in Werkstatt
            // where naming what the model saw is the point. Celebration
            // "Super gemacht!" follows from `recordSessionCompletion`.
            vm.speech.speak("Gut gemacht!")
            if vm.enablePaperTransfer {
                vm.overlayQueue.enqueue(.paperTransfer(letter: vm.currentLetterName))
            }
        }
        // Final-phase advance — sets isLetterSessionComplete but
        // leaves currentPhase at .freeWrite; returns false.
        _ = vm.phaseController.advance(score: score)
        recordSessionCompletion()
    }

    private func requestFreeWriteRetry(result: RecognitionResult) {
        guard let vm else { return }
        // Visual badge stays so the child sees what the model thought.
        // No letter-naming verbal mirror in Schule — that belongs in
        // Werkstatt. "Probier's nochmal" below is the audio retry cue.
        if result.confidence >= 0.4 {
            vm.overlayQueue.enqueue(.recognitionBadge(result))
        }
        // Reset freeWrite state so the next stroke starts clean.
        vm.strokeTracker.reset()
        if vm.letters.indices.contains(vm.letterIndex) {
            vm.reloadStrokeCheckpoints(for: vm.letters[vm.letterIndex])
        }
        vm.freeWriteRecorder.clearAll()
        vm.freeWriteRecorder.startSession()
        vm.activePath.removeAll(keepingCapacity: true)
        vm.toast("Probier's nochmal")
        vm.speech.speak("Probier's nochmal")
    }

    // MARK: - Final-phase pipeline

    private func recordSessionCompletion() {
        guard let vm else { return }
        // Study sessions: no celebration overlay, chime, or phrase —
        // the proctor advances via the nav arrows (audit C1/C2). The
        // chime/prompt calls are doubly dead under studyMode (prompts
        // is NullPromptPlayer), but the overlay gate is load-bearing.
        if !vm.studyMode {
            vm.overlayQueue.enqueue(.celebration(stars: vm.phaseController.starsEarned))
            // Same chime + "Super gemacht!" regardless of star count so a
            // 1-star child still hears genuine encouragement.
            vm.prompts.playSuccessChime()
            vm.prompts.play(.celebration,
                            fallbackText: ChildSpeechLibrary.celebration)
        }
        let accuracy = Double(vm.phaseController.overallScore)
        let now = CACurrentMediaTime()
        let liveSlice = vm.letterLoadTime.map { now - $0 } ?? 0
        let duration = vm.letterActiveTimeAccumulated + liveSlice
        // Iterate the TYPED scores. `rawName` is applied once, at the
        // single point the string is actually needed (the store's `phase`
        // argument), so every branch below compares LearningPhase values
        // the compiler checks rather than strings it cannot.
        let phaseScores = vm.phaseController.phaseScores
        let didFreeWrite = phaseScores.keys.contains(.freeWrite)
        // Still needed as [String: Double] for `commitCompletion`, whose
        // signature is the persisted `LetterProgress.phaseScores` shape.
        let scores: [String: Double] = Dictionary(
            uniqueKeysWithValues: phaseScores.map { ($0.key.rawName, Double($0.value)) }
        )
        // Attach the latest recognition reading to the freeWrite row so
        // per-session recognition is recoverable from the CSV; other
        // phases pass nil.
        let freeWriteRecognition: RecognitionSample? = vm.lastRecognitionResult.map { rr in
            RecognitionSample(
                predictedLetter: rr.predictedLetter,
                confidence: Double(rr.confidence),
                isCorrect: rr.isCorrect
            )
        }
        // Capture the input mode so the export can distinguish a finger
        // session's pressureControl == 1.0 (no force data) from a
        // low-variance pencil session.
        let device = vm.detector.effectiveKind.rawValue
        // Capture the raw freeWrite trace BEFORE writing the records (so a
        // crash can't leave a record linked to a missing trace) and BEFORE
        // the buffer clears on the next letter load. freeWrite-only; nil if
        // no freeWrite phase ran or the buffer is empty.
        let freeWriteTraceID: UUID? = didFreeWrite ? vm.captureFreeWriteTrace() : nil
        // Measured-phase time: first-to-last raw freeWrite sample
        // (CACurrentMediaTime deltas), end-inclusive — see
        // `FreeWritePhaseRecorder.measuredSpanSeconds` for why the span
        // must not end at the final stroke's start.
        let freeWriteDuration: Double? = vm.freeWriteRecorder.measuredSpanSeconds
        // SECONDARY, sequence-sensitive process outcome (2026-09-03: no
        // longer primary — see PhaseSessionRecord.frechetDistance): the
        // raw discrete-Fréchet distance the scorer already computed for
        // this trial. Unlike `formAccuracy` it is unclamped, so it keeps
        // discriminating at both ends of the scale.
        let freeWriteFrechet: Double? = vm.lastFreeWriteFrechetDistance.map { Double($0) }
        // PRIMARY accuracy outcome (2026-09-03): raw, order-invariant
        // spatial deviation (symmetric Hausdorff) — see
        // FreeWriteScorer.rawSpatialDeviation and
        // PhaseSessionRecord.spatialDeviation.
        let freeWriteSpatialDeviation: Double? = vm.lastFreeWriteSpatialDeviation.map { Double($0) }
        // SECONDARY: checkpoint coverage of the freeWrite trace.
        // `resetForPhaseTransition` reset the tracker on entry to
        // freeWrite, so this reads the freeWrite pass alone and not the
        // guided pass before it. Saturates at 1.0 — kept for continuity
        // with earlier rounds, not as the primary.
        let freeWriteCoverage: Double? = didFreeWrite
            ? Double(vm.grid.aggregateProgress) : nil
        for (phase, phaseScore) in phaseScores {
            // One typed comparison gates all six measurement fields. A
            // wrong phase here is the defect PhaseRecordAttachmentTests
            // exists to catch; a wrong *spelling* is no longer possible.
            let isFreeWrite = phase == .freeWrite
            vm.dashboardStore.recordPhaseSession(
                letter: vm.currentLetterName,
                phase: phase.rawName,
                completed: true,
                score: Double(phaseScore),
                schedulerPriority: vm.lastScheduledLetterPriority,
                condition: vm.thesisCondition,
                audioCondition: vm.audioCondition,
                assessment: isFreeWrite ? vm.lastWritingAssessment : nil,
                recognition: isFreeWrite ? freeWriteRecognition : nil,
                inputDevice: device,
                rawTraceID: isFreeWrite ? freeWriteTraceID : nil,
                trainedSubset: vm.trainedSubset.rawValue,
                phaseDurationSeconds: isFreeWrite ? freeWriteDuration : nil,
                frechetDistance: isFreeWrite ? freeWriteFrechet : nil,
                checkpointCoverage: isFreeWrite ? freeWriteCoverage : nil,
                spatialDeviation: isFreeWrite ? freeWriteSpatialDeviation : nil
            )
        }
        commitCompletion(letter: vm.currentLetterName,
                         accuracy: accuracy,
                         duration: duration,
                         phaseScores: scores)
    }

    /// Shared completion side-effects: durable progress + streak +
    /// dashboard row, cloud sync, difficulty-tier adaptation, HUD.
    /// Single funnel for both the per-letter stroke-completion path and
    /// the multi-phase session completion path.
    func commitCompletion(letter: String,
                          accuracy: Double,
                          duration: TimeInterval,
                          phaseScores: [String: Double]? = nil) {
        guard let vm else { return }
        // Word sequences fan out per-cell for progress + streak (each
        // letter counts toward its own mastery), but use the word title
        // for the dashboard/adaptation row so analytics can distinguish
        // word sessions from single-letter sessions.
        let lettersToRecord: [String]
        let dashboardLabel: String
        let isWordSequence: Bool
        if case .word(let word) = vm.grid.sequence.kind {
            lettersToRecord = vm.grid.cells.map(\.item.letter)
            dashboardLabel = word
            isWordSequence = true
        } else {
            lettersToRecord = [letter]
            dashboardLabel = letter
            isWordSequence = false
        }

        let speed: Double? = vm.checkpointsPerSecond > 0 ? Double(vm.checkpointsPerSecond) : nil
        // Recognition lands async; pass whatever's latched so sessions
        // finishing after the recognizer returns still populate the
        // dashboard's confidence series.
        let rr = vm.lastRecognitionResult
        for l in lettersToRecord {
            vm.progressStore.recordCompletion(for: l, accuracy: accuracy,
                                              phaseScores: phaseScores, speed: speed,
                                              recognitionResult: rr)
        }
        // Variant tracking is single-letter only.
        if !isWordSequence, vm.showingVariant, vm.letters.indices.contains(vm.letterIndex),
           let variantID = vm.letters[vm.letterIndex].variants?.first {
            vm.progressStore.recordVariantUsed(for: letter, variantID: variantID)
        }
        // The store isn't @Observable; this mirror is the SwiftUI bridge.
        vm.refreshProgressMirror()
        // Study sessions: no streak accrual, no badge unlock overlays —
        // reward systems are off so all arms are identical (audit C2).
        if !vm.studyMode {
            let newRewards = vm.streakStore.recordSession(
                date: Date(),
                lettersCompleted: lettersToRecord,
                accuracy: accuracy
            )
            // Slot freshly-unlocked badges ahead of the celebration the
            // child is already expecting.
            for event in newRewards {
                vm.overlayQueue.enqueueBeforeCelebration(.rewardCelebration(event))
            }
        }
        // `wallClock` includes backgrounded time; `duration` excludes it.
        let wallClock = vm.letterLoadedDate.map { Date().timeIntervalSince($0) }
        let device = vm.detector.effectiveKind.rawValue
        vm.dashboardStore.recordSession(letter: dashboardLabel, accuracy: accuracy,
                                        durationSeconds: duration,
                                        wallClockSeconds: wallClock,
                                        date: Date(),
                                        condition: vm.thesisCondition,
                                        inputDevice: device)

        let adaptSample = AdaptationSample(letter: dashboardLabel,
                                           accuracy: CGFloat(accuracy),
                                           completionTime: duration)
        vm.adaptationPolicy.record(adaptSample)
        vm.currentDifficultyTier         = vm.adaptationPolicy.currentTier
        vm.strokeTracker.radiusMultiplier = vm.currentDifficultyTier.radiusMultiplier

        vm.showCompletionHUD()
    }
}
