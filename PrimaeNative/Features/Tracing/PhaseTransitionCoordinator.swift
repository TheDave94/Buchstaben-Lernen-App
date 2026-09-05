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
        // A completed letter session is never advanced again. The
        // study-mode unload/background path (below) can complete a
        // freeWrite trial while the dispatcher's quiet-window task is
        // still scheduled; without this guard that task would re-run the
        // recognizer and write every phase row a second time.
        guard !vm.phaseController.isLetterSessionComplete else { return }
        let score: CGFloat
        // Four structurally different instruments write into this one
        // `score`, per phase — see PhaseSessionRecord.score and
        // DECISIONS.md D12 (found 2026-09-04) for the full
        // characterization and why LearningPhaseController.overallScore
        // (the average of these) is systematically inflated, not just
        // an average of incomparable quantities.
        switch vm.phaseController.currentPhase {
        case .observe:
            score = 1.0
        case .direct:
            // Genuinely unconditional — no fail path is implemented
            // despite the "pass/fail" framing; wrong-order taps in
            // tapDirectDot() never reach this score.
            score = 1.0
        case .guided:
            score = vm.progress
        case .freeWrite:
            score = scoreFreeWrite()
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
            // Latched: the measures above were computed from the buffer as
            // it is now. Mark the production complete BEFORE the recognizer
            // await so no further ink can enter the buffer the later
            // capture reads (review 2026-09-05).
            vm.didCompleteCurrentLetter = true
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

    /// Score the freeWrite buffer against the loaded reference. Shared by
    /// `advance()` and the study-mode unload path so one trace is scored
    /// one way, whichever route records it. Sets the recorder's
    /// `lastAssessment` / `lastStrokeProcess` as a side effect.
    /// "pencil" when any sample of the current freeWrite trace carried
    /// force (only a Pencil reports it), "finger" when the trace exists
    /// and none did, nil when there is no trace to judge by.
    private func traceInputDevice() -> String? {
        guard let vm, !vm.freeWriteRecorder.forces.isEmpty else { return nil }
        return vm.freeWriteRecorder.forces.contains { $0 > 0 }
            ? InputPreset.Kind.pencil.rawValue : InputPreset.Kind.finger.rawValue
    }

    private func scoreFreeWrite() -> CGFloat {
        guard let vm else { return 0 }
        guard let def = vm.strokeTracker.definition else {
            // Do NOT clear the recorder here: both callers capture the
            // trace AFTER scoring, and a wipe turned a real production
            // into a completed, score-0 row with no raw trace
            // (audit 2026-09-04). The capture path clears it.
            return 0
        }
        // Multi-cell (pencil / word): pass each cell's frame so
        // points normalise into cell-local 0–1 space matching the
        // reference, and average the four Schreibmotorik dimensions
        // across cells. Single-cell falls through to the original
        // finger-mode contract. (Study sessions are always single-cell —
        // see `TracingViewModel.reapplyGridPreset`.)
        if vm.grid.cells.count > 1 {
            let cellRefs = vm.grid.cells.compactMap { cell -> (frame: CGRect, reference: LetterStrokes)? in
                guard let ref = cell.tracker.definition else { return nil }
                return (frame: cell.frame, reference: ref)
            }
            if cellRefs.isEmpty {
                return vm.freeWriteRecorder.assess(
                    reference: def, canvasSize: vm.canvasSize,
                    cellFrame: vm.grid.activeCell.frame,
                    now: vm.freeWriteTimestamps.last ?? CACurrentMediaTime()
                ).overallScore
            }
            return vm.freeWriteRecorder.assess(
                cellReferences: cellRefs,
                canvasSize: vm.canvasSize,
                now: vm.freeWriteTimestamps.last ?? CACurrentMediaTime()
            ).overallScore
        }
        // `now` = the last sample, not the moment of scoring: on the
        // unload/background routes that moment is proctor latency, which
        // used to depress rhythmScore (review 2026-09-05).
        return vm.freeWriteRecorder.assess(
            reference: def, canvasSize: vm.canvasSize,
            cellFrame: nil,
            now: vm.freeWriteTimestamps.last ?? CACurrentMediaTime()
        ).overallScore
    }

    // MARK: - Study-mode unload / background safety (2026-09-04)

    /// A finished freeWrite production (ink present, pen up) that has not
    /// been scored yet — the proctor tapped the next arrow inside the
    /// 2.0 s quiet window, or while the recognizer was in flight, or the
    /// app is being backgrounded — used to vanish: `load(letter:)` cleared
    /// the recorder and cancelled the recognizer token, so no score, no
    /// row and no raw trace were ever written. Scores and records it now,
    /// recognition nil. Returns true when it did so. Study mode only.
    @discardableResult
    func finalizeFinishedFreeWriteIfPending() -> Bool {
        guard let vm, vm.studyMode,
              vm.phaseController.currentPhase == .freeWrite,
              !vm.phaseController.isLetterSessionComplete,
              vm.freeWritePoints.count >= 2,   // a one-sample contact is not a production
              !vm.touchDispatcher.isSingleTouchInteractionActive else { return false }
        vm.abortInFlightRecognition()
        // Mark complete BEFORE recording so the dispatcher's quiet-window
        // task (if still scheduled) sees `didCompleteCurrentLetter` and
        // stands down; `resetTouchState` cancels it outright.
        vm.didCompleteCurrentLetter = true
        vm.touchDispatcher.resetTouchState()
        completePostFreeWriteRecognition(score: scoreFreeWrite(), result: nil)
        return true
    }

    /// Called by `TracingViewModel.load(letter:)` BEFORE the outgoing
    /// letter's state is reset. First closes the finished-freeWrite window
    /// above; otherwise, if the letter was worked but left mid-phase,
    /// writes ONE row for that phase with `completed: false` and the score
    /// so far (guided: checkpoint coverage; freeWrite: the assessment of
    /// the ink present, with its measures and raw trace). Nothing else —
    /// no progress, streak or completion side effects. This is the only
    /// writer of `completed == false`: the column, and the exported
    /// `phaseCompletionRate_*`, carried a constant `true` before. Study
    /// mode only; an untouched letter records nothing.
    func recordUnloadOfCurrentLetter(touchStillActive: Bool) {
        // After a participant reset nothing of the outgoing child may be
        // recorded — not even an abandonment row (review 2026-09-05).
        guard let vm, vm.studyMode, !vm.participantIdentityChanged,
              !vm.phaseController.isLetterSessionComplete else { return }
        if !touchStillActive, finalizeFinishedFreeWriteIfPending() { return }

        let phase = vm.phaseController.currentPhase
        let hasFreeWriteInk = !vm.freeWritePoints.isEmpty
        let hasInput = !vm.phaseController.phaseScores.isEmpty
            || vm.progress > 0
            || hasFreeWriteInk
            || !vm.directTappedDots.isEmpty
        guard hasInput else { return }

        vm.abortInFlightRecognition()
        let score: CGFloat
        switch phase {
        case .guided:           score = vm.progress
        case .freeWrite:        score = hasFreeWriteInk ? scoreFreeWrite() : 0
        case .observe, .direct: score = 0
        }
        let didFreeWrite = phase == .freeWrite && hasFreeWriteInk
        let m = captureFreeWriteMeasurements(didFreeWrite: didFreeWrite)
        vm.dashboardStore.recordPhaseSession(
            letter: vm.currentLetterName,
            phase: phase.rawName,
            completed: false,
            score: Double(score),
            schedulerPriority: vm.lastScheduledLetterPriority,
            condition: vm.thesisCondition,
            audioCondition: vm.audioCondition,
            assessment: m.assessment,
            recognition: m.recognition,   // computed above; was dropped (audit 2026-09-04)
            inputDevice: traceInputDevice() ?? vm.detector.effectiveKind.rawValue,
            rawTraceID: m.traceID,
            trainedSubset: vm.trainedSubset.rawValue,
            phaseDurationSeconds: m.duration,
            frechetDistance: nil,
            checkpointCoverage: m.coverage,
            spatialDeviation: m.spatialDeviation,
            strokeCount: m.strokeProcess?.strokeCount,
            strokeOrder: m.strokeProcess?.matchedReferenceOrderField,
            reversedStrokeCount: m.strokeProcess?.reversedStrokeCount,
            studyMode: vm.studyMode,
            probe: vm.currentProbe?.rawValue
        )
    }

    /// The freeWrite-only measurement fields of one row. Captured in the
    /// order that keeps a crash from leaving a record pointing at a
    /// missing trace (trace first). All nil when `didFreeWrite` is false.
    private struct FreeWriteMeasurements {
        var assessment: WritingAssessment?
        var recognition: RecognitionSample?
        var traceID: UUID?
        var duration: Double?
        var coverage: Double?
        var spatialDeviation: Double?
        var strokeProcess: StrokeProcessMeasures?
    }

    private func captureFreeWriteMeasurements(didFreeWrite: Bool) -> FreeWriteMeasurements {
        var m = FreeWriteMeasurements()
        guard let vm, didFreeWrite else { return m }
        m.assessment = vm.lastWritingAssessment
        // Attach the latest recognition reading to the freeWrite row so
        // per-session recognition is recoverable from the CSV.
        m.recognition = vm.lastRecognitionResult.map { rr in
            RecognitionSample(
                predictedLetter: rr.predictedLetter,
                confidence: Double(rr.confidence),
                // Was omitted here (2026-09-04): the exported
                // `recognition_confidence_raw` column — the documented
                // way to quantify the calibrator's effect (D11) — had
                // never carried a value on any phase row, while
                // `ProgressStore.recordRecognitionSample` did carry it.
                rawConfidence: rr.rawConfidence.map { Double($0) },
                isCorrect: rr.isCorrect
            )
        }
        // Capture the raw freeWrite trace BEFORE writing the records (so a
        // crash can't leave a record linked to a missing trace) and BEFORE
        // the buffer clears on the next letter load.
        m.traceID = vm.captureFreeWriteTrace()
        // Measured-phase time: first-to-last raw freeWrite sample
        // (CACurrentMediaTime deltas), end-inclusive — see
        // `FreeWritePhaseRecorder.measuredSpanSeconds` for why the span
        // must not end at the final stroke's start.
        m.duration = vm.freeWriteRecorder.measuredSpanSeconds
        // PRIMARY accuracy outcome: order-invariant spatial deviation
        // via stroke correspondence — see StrokeProcessMeasures and
        // PhaseSessionRecord.spatialDeviation.
        m.spatialDeviation = vm.lastFreeWriteSpatialDeviation.map { Double($0) }
        // SECONDARY: checkpoint coverage of the freeWrite trace.
        // `resetForPhaseTransition` reset the tracker on entry to
        // freeWrite, so this reads the freeWrite pass alone and not the
        // guided pass before it. Saturates at 1.0 — kept for continuity
        // with earlier rounds, not as the primary.
        m.coverage = Double(vm.grid.aggregateProgress)
        // SECONDARY process outcomes (2026-09-03): stroke count/order/
        // direction — see StrokeProcessMeasures.
        m.strokeProcess = vm.lastFreeWriteStrokeProcess
        return m
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
        vm.didCompleteCurrentLetter = false   // a retry re-opens the production
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
        // Capture the input mode so the export can distinguish a finger
        // session's pressureControl == 1.0 (no force data) from a
        // low-variance pencil session.
        let device = vm.detector.effectiveKind.rawValue
        // The freeWrite-only fields, trace captured first; all nil when
        // no freeWrite phase ran. `frechetDistance` is RETIRED
        // (2026-09-04) — always nil, kept as a parameter only for
        // Codable/protocol backward compat.
        let m = captureFreeWriteMeasurements(didFreeWrite: didFreeWrite)
        // Rows in canonical phase order (2026-09-04): iterating the
        // dictionary wrote the four rows of one letter in arbitrary order
        // under near-identical `recordedAt` stamps, so any consumer
        // sorting by time saw a per-letter order that changed run to run.
        for phase in LearningPhase.allCases {
            guard let phaseScore = phaseScores[phase] else { continue }
            // One typed comparison gates all measurement fields. A
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
                assessment: isFreeWrite ? m.assessment : nil,
                recognition: isFreeWrite ? m.recognition : nil,
                // The freeWrite row says what wrote THIS trace; the
                // detector's hysteresis can still say "pencil" for a
                // finger-written letter (audit 2026-09-05).
                inputDevice: isFreeWrite ? (traceInputDevice() ?? device) : device,
                rawTraceID: isFreeWrite ? m.traceID : nil,
                trainedSubset: vm.trainedSubset.rawValue,
                phaseDurationSeconds: isFreeWrite ? m.duration : nil,
                frechetDistance: nil,
                checkpointCoverage: isFreeWrite ? m.coverage : nil,
                spatialDeviation: isFreeWrite ? m.spatialDeviation : nil,
                strokeCount: isFreeWrite ? m.strokeProcess?.strokeCount : nil,
                strokeOrder: isFreeWrite ? m.strokeProcess?.matchedReferenceOrderField : nil,
                reversedStrokeCount: isFreeWrite ? m.strokeProcess?.reversedStrokeCount : nil,
                studyMode: vm.studyMode,
                probe: vm.currentProbe?.rawValue
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
        // The freeWrite phase's own geometric form accuracy (nil when no
        // freeWrite ran this session — `.control`/`.guidedOnly` land
        // here too) — the correct instrument for
        // `formAccuracyHistory`/the calibrator's practised-letter boost.
        // NOT the same value as `rr.confidence` (see recordCompletion's
        // doc comment for the 2026-09-04 fix this replaces).
        let formAccuracy = vm.lastWritingAssessment.map { Double($0.formAccuracy) }
        for l in lettersToRecord {
            vm.progressStore.recordCompletion(for: l, accuracy: accuracy,
                                              phaseScores: phaseScores, speed: speed,
                                              recognitionResult: rr, formAccuracy: formAccuracy)
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
                accuracy: accuracy,
                dailyGoalReached: vm.completionsToday >= vm.dailyGoal   // progress was committed above
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
                                        inputDevice: device,
                                        audioCondition: vm.audioCondition,
                                        studyMode: vm.studyMode,
                                        probe: vm.currentProbe?.rawValue)

        // Difficulty-tier adaptation — gated on studyMode, same shape as
        // the errorless-learning ramp (`load(letter:)`) and the
        // reward/streak block just above: "guided difficulty is held
        // constant" is the stated study design intent. Flagged
        // 2026-09-04 (DECISIONS.md D12) because this block itself ran
        // unconditionally with no LOCAL guard — but it never actually
        // drifted: `TracingViewModel.init` already substitutes
        // `FixedAdaptationPolicy(currentTier: .standard)` for
        // `vm.adaptationPolicy` whenever `studyMode` is true (or
        // condition is `.control`), and `FixedAdaptationPolicy.record`
        // is a no-op with a constant `currentTier` — so `record()` did
        // nothing and the two reassignments below were re-writing the
        // same `.standard` value every time. Confirmed by
        // `StudyCleanConfigTests.studyMode_fixesDifficulty`
        // (`vm.adaptationPolicy is FixedAdaptationPolicy`, already
        // green). This gate is therefore a no-op in the current build,
        // added for local self-evidence — the invariant no longer
        // depends on a reader also knowing the DI substitution in
        // `TracingViewModel.init` — and as a guard against a future
        // change to that substitution silently reintroducing real
        // drift.
        if !vm.studyMode {
            let adaptSample = AdaptationSample(letter: dashboardLabel,
                                               accuracy: CGFloat(accuracy),
                                               completionTime: duration)
            vm.adaptationPolicy.record(adaptSample)
            vm.currentDifficultyTier         = vm.adaptationPolicy.currentTier
            vm.strokeTracker.radiusMultiplier = vm.currentDifficultyTier.radiusMultiplier
        }

        vm.showCompletionHUD()
    }
}
