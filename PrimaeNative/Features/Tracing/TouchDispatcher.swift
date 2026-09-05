// TouchDispatcher.swift
// PrimaeNative
//
// Owns the in-flight touch session state and the
// `beginTouch` / `updateTouch` / `endTouch` flow. VM strong-owns the
// dispatcher; dispatcher weakly references the VM. State during a
// touch (audio, playback, haptics, recorder, tracker, grid, phase,
// letters, activePath, progress) lives on the VM.

import CoreGraphics
import Foundation
import QuartzCore

@MainActor
final class TouchDispatcher {

    // MARK: - Owned touch-session state

    /// True while a single-touch tracing gesture is in flight.
    private(set) var isSingleTouchInteractionActive = false
    /// Last seen touch point in canvas pixels.
    private(set) var lastPoint: CGPoint?
    private(set) var lastTimestamp: CFTimeInterval?
    /// Exponentially-smoothed touch velocity. Drives audio time-stretch
    /// and the "should playback be active" gate.
    private(set) var smoothedVelocity: CGFloat = 0

    // MARK: - Tunable knobs

    /// EWMA smoothing factor; calibrated for iPad-finger writing.
    var velocitySmoothingAlpha: CGFloat = 0.22
    /// Minimum smoothed velocity (pt/s) before playback goes `.active`.
    var playbackActivationVelocityThreshold: CGFloat = 22
    /// Sub-pixel hysteresis so digitiser noise on a held finger doesn't
    /// accumulate spurious motion.
    var minimumTouchMoveDistance: CGFloat = 1.5

    // MARK: - Back-reference

    /// Weak back-reference set by `TracingViewModel.init` after the
    /// dispatcher is assigned (two-phase init).
    weak var vm: TracingViewModel?

    /// FreeWrite has no canonical-stroke completion path, so on lift
    /// we schedule a quiet-window phase advance (~2 s); a re-touch
    /// cancels it.
    private var freeWriteAutoAdvanceTask: Task<Void, Never>?
    /// Device that began the current session; events from the other
    /// device are ignored until it ends (review 2026-09-05).
    private var sessionIsPencil = false
    private let freeWriteQuietSeconds: TimeInterval = 2.0

    /// Tracks the previous in-bounds state so the out-of-bounds warning
    /// fires only on the rising edge.
    private var wasInBounds: Bool = true

    // MARK: - Public API (forwarded from VM)

    func beginTouch(at p: CGPoint, t: CFTimeInterval) {
        guard let vm else { return }
        // A study session that cannot deliver its stimulus does not
        // trace at all — see TracingViewModel.studyPreconditionFailure.
        guard vm.sessionBlockReason == nil             else { return }
        guard vm.phaseController.isTouchEnabled       else { return }
        guard vm.phaseController.currentPhase != .direct else { return }  // handled by DirectPhaseDotsOverlay
        guard !isSingleTouchInteractionActive         else { return }
        // A freeWrite production that has been scored (quiet window
        // fired, recognizer in flight) accepts no more ink: its measures
        // were latched from the buffer as it was, and a later stroke used
        // to land in the raw trace but not in the row (review 2026-09-05).
        guard !(vm.didCompleteCurrentLetter && vm.phaseController.currentPhase == .freeWrite) else { return }

        // Re-touch cancels a pending freeWrite auto-advance.
        freeWriteAutoAdvanceTask?.cancel()
        freeWriteAutoAdvanceTask = nil
        // A real touch beginning always supersedes an in-flight
        // pre-task demonstration — see PreTaskDemonstration.
        vm.cancelPreTaskDemonstration()

        isSingleTouchInteractionActive = true
        sessionIsPencil                = vm.lastTouchDownWasPencil
        vm.playback.resumeIntent       = true
        lastPoint                      = p
        lastTimestamp                  = t
        vm.activePath                  = [p]
        // New touch supersedes any lingering snapshot from the
        // previous phase — clear so the two paths don't overlay.
        vm.lingeringInk = []
        wasInBounds                    = true
        // Stroke-boundary marker so the CoreML rasterizer breaks the
        // polyline at lifts (F→P confusion otherwise).
        if vm.phaseController.currentPhase == .freeWrite {
            vm.freeWriteRecorder.beginStroke()
            // The pen-down sample IS the stroke's start: without it the
            // trace began 1.5 pt into the stroke and the duration
            // excluded the pen-down→first-move interval (audit 2026-09-04).
            vm.freeWriteRecorder.record(point: p, timestamp: t,
                                        force: vm.pencilPressure ?? 0,
                                        canvasSize: vm.canvasSize)
        }
        // FreeWrite fades real-time feedback (Schmidt & Lee 2005
        // Guidance Hypothesis); gate haptics + ticks on intensity.
        if vm.feedbackIntensity > 0 { vm.haptics.fire(.strokeBegan) }
        // endTouch's stop() clears currentFile; reload before the next
        // play() would silently fail.
        if vm.letters.indices.contains(vm.letterIndex) {
            let files = vm.activeAudioFiles(for: vm.letters[vm.letterIndex])
            if files.indices.contains(vm.audioIndex) {
                vm.audio.loadAudioFile(named: files[vm.audioIndex], autoplay: false)
            }
        }
    }

    func updateTouch(at p: CGPoint, t: CFTimeInterval, canvasSize: CGSize) {
        guard let vm else { return }
        // The Pencil overlay stamps `pencilPressure` before every move; the
        // finger overlay never does. A move from the device that does not
        // own this session is dropped (and a stray pencil stamp cleared) so
        // a resting hand and the pen cannot interleave into one stroke.
        let eventIsPencil = vm.pencilPressure != nil
        if eventIsPencil != sessionIsPencil {
            if !sessionIsPencil { vm.pencilPressure = nil; vm.pencilAzimuth = 0 }
            return
        }
        guard isSingleTouchInteractionActive else { return }
        guard let lastPoint                  else { return }

        resyncCanvasSizeIfNeeded(canvasSize)

        let isWithinCanvasBounds =
            p.x >= 0 && p.y >= 0 && p.x <= canvasSize.width && p.y <= canvasSize.height

        // Out-of-bounds rising edge: stop audio, wipe partial stroke,
        // tell the child to retrace (visual + verbal — pre-readers
        // can't see the toast). Re-entry restarts the current stroke.
        if wasInBounds && !isWithinCanvasBounds {
            vm.audio.stop()
            vm.isPlaying = false
            vm.playback.cancelPending()
            vm.playback.forceIdle()
            if vm.phaseController.currentPhase == .freeWrite {
                // Free production: what was drawn stays in the record
                // (and on screen); the excursion simply ends this stroke,
                // so the re-entry does not fuse with it into one
                // mis-shaped stroke. No retry cue — the phase gives no
                // feedback (audit 2026-09-04).
                vm.freeWriteRecorder.beginStroke()
                vm.activePath.removeAll(keepingCapacity: true)
            } else {
                vm.strokeTracker.resetCurrentStroke()
                vm.activePath.removeAll(keepingCapacity: true)
                vm.toast("Probier's nochmal")
                vm.speech.speak("Probier's nochmal")
            }
        }
        wasInBounds = isWithinCanvasBounds

        let dx       = p.x - lastPoint.x
        let dy       = p.y - lastPoint.y
        let distance = hypot(dx, dy)

        if isWithinCanvasBounds && distance >= minimumTouchMoveDistance {
            vm.activePath.append(p)
            // FreeWrite scoring + KP overlay buffers.
            if vm.phaseController.currentPhase == .freeWrite {
                vm.freeWriteRecorder.record(point: p,
                                            timestamp: t,
                                            force: vm.pencilPressure ?? 0,
                                            canvasSize: canvasSize)
            }
        }

        if let lastTimestamp {
            let dt       = max(0.001, t - lastTimestamp)
            let velocity = distance / dt
            smoothedVelocity = smoothedVelocity == 0
                ? velocity
                : smoothedVelocity + velocitySmoothingAlpha * (velocity - smoothedVelocity)
        } else {
            self.lastTimestamp = t
        }

        // Canvas-normalised coords drive the audio stereo pan.
        let canvasNormalized = CGPoint(x: p.x / max(canvasSize.width, 1),
                                       y: p.y / max(canvasSize.height, 1))
        // Cell-normalised coords feed the active cell's tracker, whose
        // checkpoints live in cell-local 0–1 space.
        let activeFrame = vm.grid.activeCell.frame
        let normalized: CGPoint
        if activeFrame.width > 0 && activeFrame.height > 0 {
            normalized = CGPoint(
                x: (p.x - activeFrame.minX) / activeFrame.width,
                y: (p.y - activeFrame.minY) / activeFrame.height
            )
        } else {
            normalized = canvasNormalized
        }
        let prevStrokeIndex    = vm.strokeTracker.currentStrokeIndex
        let prevNextCheckpoint = vm.strokeTracker.progress.indices.contains(prevStrokeIndex)
            ? vm.strokeTracker.progress[prevStrokeIndex].nextCheckpoint : 0
        let wasComplete        = vm.strokeTracker.isComplete

        vm.strokeTracker.update(normalizedPoint: normalized)

        let isNowComplete = vm.strokeTracker.isComplete
        if !wasComplete && isNowComplete, vm.feedbackIntensity > 0 {
            vm.haptics.fire(.letterCompleted)
        }
        // Whole-sequence aggregate; reduces to overallProgress for
        // single-cell.
        vm.progress = vm.grid.aggregateProgress

        updateGuidedAndFreeWriteSpeed()

        fireMovementHaptics(prevStrokeIndex: prevStrokeIndex,
                            prevNextCheckpoint: prevNextCheckpoint)

        updateAdaptivePlayback(canvasNormalized: canvasNormalized)

        handleStrokeCompletionIfReached()

        self.lastPoint     = p
        self.lastTimestamp = t
    }

    func endTouch(fromPencil: Bool? = nil) {
        guard let vm else { return }
        // A lift from the device that does not own the session (the Pencil
        // lifting while a resting finger is the tracked touch) must not end
        // the finger's stroke (review 2026-09-05).
        if let fromPencil, isSingleTouchInteractionActive, fromPencil != sessionIsPencil { return }
        isSingleTouchInteractionActive = false
        lastPoint                      = nil
        lastTimestamp                  = nil
        vm.activePath.removeAll(keepingCapacity: true)
        smoothedVelocity               = 0
        vm.pencilPressure              = nil
        vm.pencilAzimuth               = 0
        vm.playback.resumeIntent       = false
        vm.playback.cancelPending()
        let cmd = vm.playback.transition(to: .idle)
        vm.playback.apply(cmd)
        if cmd == .none { vm.audio.stop(); vm.isPlaying = false }
        vm.playback.forceIdle()

        // FreeWrite advance: lift-then-quiet is the implicit "done"
        // signal; re-touch within the window cancels.
        if vm.phaseController.currentPhase == .freeWrite,
           !vm.didCompleteCurrentLetter,
           vm.freeWritePoints.count >= 2 {   // a one-sample contact (a palm) is not a production
            scheduleFreeWriteAutoAdvance()
        }
    }

    // MARK: - State-clearing entry points

    /// Reset all owned state. Called by VM transitions so a stale
    /// `lastPoint` can't bleed across sessions.
    func resetTouchState() {
        isSingleTouchInteractionActive = false
        lastPoint                      = nil
        lastTimestamp                  = nil
        smoothedVelocity               = 0
        freeWriteAutoAdvanceTask?.cancel()
        freeWriteAutoAdvanceTask = nil
    }

    /// Clear the velocity smoother without touching the active flag,
    /// for transitions that swap the tracker mid-gesture.
    func resetVelocity() {
        smoothedVelocity = 0
    }

    // MARK: - Private helpers

    /// Resync `vm.canvasSize` with what the overlay reports. Closes the
    /// rotation race where canvasSize.didSet has reloaded checkpoints
    /// but the overlay still carries the old size.
    private func resyncCanvasSizeIfNeeded(_ canvasSize: CGSize) {
        guard let vm else { return }
        guard canvasSize != vm.canvasSize,
              !vm.letters.isEmpty,
              vm.letterIndex < vm.letters.count else { return }
        // Assign the VM's size (its didSet re-flows the cells and reloads
        // the checkpoints in that order) instead of doing both here while
        // `vm.canvasSize` stayed stale — the scorer and the persisted
        // RawTrace read `vm.canvasSize` (review 2026-09-05).
        vm.canvasSize = canvasSize
    }

    /// Push the live "checkpoints per second" figure into the recorder
    /// during guided / freeWrite. Silent in observe / direct.
    private func updateGuidedAndFreeWriteSpeed() {
        guard let vm else { return }
        let currentPhase = vm.phaseController.currentPhase
        guard currentPhase == .guided || currentPhase == .freeWrite,
              let def = vm.strokeTracker.definition else { return }
        let completedCPs = def.strokes.enumerated().reduce(0) { acc, item in
            let (idx, stroke) = item
            guard vm.strokeTracker.progress.indices.contains(idx) else { return acc }
            return vm.strokeTracker.progress[idx].complete
                ? acc + stroke.checkpoints.count
                : acc + vm.strokeTracker.progress[idx].nextCheckpoint
        }
        vm.freeWriteRecorder.updateSpeed(completedCheckpoints: completedCPs)
    }

    /// Fire stroke-completion haptic + tick if the tracker crossed a
    /// boundary on this update. Per-checkpoint haptics were removed
    /// per user feedback — only stroke completion remains.
    private func fireMovementHaptics(prevStrokeIndex: Int,
                                     prevNextCheckpoint: Int) {
        guard let vm else { return }
        guard vm.feedbackIntensity > 0 else { return }
        let newStrokeIndex    = vm.strokeTracker.currentStrokeIndex
        let newNextCheckpoint = vm.strokeTracker.progress.indices.contains(prevStrokeIndex)
            ? vm.strokeTracker.progress[prevStrokeIndex].nextCheckpoint : 0
        guard prevNextCheckpoint != newNextCheckpoint
              || newStrokeIndex != prevStrokeIndex else { return }
        if vm.strokeTracker.progress.indices.contains(prevStrokeIndex)
            && vm.strokeTracker.progress[prevStrokeIndex].complete {
            vm.haptics.fire(.strokeCompleted)
            vm.prompts.playStrokeTick()
        }
    }

    /// Map smoothed velocity + canvas-x to audio time-stretch speed
    /// and stereo pan, then drive the playback state machine.
    private func updateAdaptivePlayback(canvasNormalized: CGPoint) {
        guard let vm else { return }
        // Silent arm: no audio content (activeAudioFiles returns [] so no
        // file ever loaded) AND no coupling. Short-circuit BEFORE any
        // setAdaptivePlayback so the coupling drive never fires and no
        // playback can resume. The two SOUND arms fall through to the
        // identical path below — only the loaded file differs, never the
        // coupling (§2.6 matching discipline).
        if vm.audioCondition == .silent {
            vm.playback.request(.idle, immediate: true)
            return
        }
        // Sound-off production (locked pilot design: "sound-off
        // post-test", DECISIONS.md header; thesis Ch.2 §2.5 / Ch.6). In
        // study mode the freeWrite phase — the study's outcome, and the
        // H6 post-test route, which enters freeWrite directly — must never
        // hear the arm's audio. `feedbackIntensity` (0.0 in freeWrite)
        // fades haptics + ticks only; this coupling was NOT gated, so a
        // sound arm kept playing during free production (thesis-side
        // audit, 2026-09-04). Study-mode only: outside the study the
        // phoneme stays the glyph's auditory anchor in every phase.
        if vm.studyMode, vm.phaseController.currentPhase == .freeWrite {
            vm.playback.request(.idle, immediate: true)
            return
        }
        let speed       = Self.mapVelocityToSpeed(smoothedVelocity)
        let azimuthBias = vm.pencilPressure != nil ? cos(vm.pencilAzimuth) * 0.2 : 0
        // Pan follows absolute x across the whole canvas (not the
        // active cell), so a right-hand cell sounds from the right.
        let hBias = Float(max(-1.0, min(1.0, (canvasNormalized.x * 2.0 - 1.0) + azimuthBias)))
        vm.audio.setAdaptivePlayback(speed: speed, horizontalBias: hBias)

        // Spatial arm only: pen Y additionally drives the carrier pitch
        // (220–880 Hz linear-in-cents, top = high — SpatialSonification).
        // The phoneme arm never reaches this, so its pitch stays at the
        // engine default 0 — the arms are matched on rate + pan and
        // differ in pitch-drive + sound identity (reframed §2.6).
        if vm.audioCondition == .spatial {
            vm.audio.setSpatialPitch(
                cents: SpatialSonification.pitchCents(forNormalizedY: canvasNormalized.y))
        }

        // No feedbackIntensity gate here: the letter sound is the
        // phonemic anchor for the glyph, not Schmidt & Lee guidance
        // feedback. Haptics + ticks that DO fade are gated separately.
        let shouldPlayForStroke = vm.strokeTracker.isNearStroke
        let shouldBeActive      = shouldPlayForStroke
                                  && smoothedVelocity >= playbackActivationVelocityThreshold
        vm.playback.request(shouldBeActive ? .active : .idle, immediate: shouldBeActive)
    }

    /// Advance the grid cursor when the active cell completes; if the
    /// whole sequence finishes, kick off the phase advance. Guards
    /// against vacuous completion on empty stroke definitions.
    private func handleStrokeCompletionIfReached() {
        guard let vm else { return }
        // Study freeWrite ends ONLY through the pen-lift quiet window
        // (`scheduleFreeWriteAutoAdvance`) — the contract this file's
        // own header states ("FreeWrite has no canonical-stroke
        // completion path") and APP_DOCUMENTATION §6.4.1 / Appendix A
        // document. The tracker keeps running in freeWrite (it feeds
        // `checkpointCoverage`), so without this gate an accurate,
        // canonical-order trace ended the trial the instant its last
        // checkpoint was hit — mid-gesture — while the recorder kept
        // appending until the recognizer returned: the SCORED trace and
        // the PERSISTED raw trace diverged, and the best writers' trials
        // were truncated (missing stroke tails, shorter
        // `phaseDurationSeconds`) in a way correlated with the outcome
        // itself. Study-mode only: the multi-cell word path outside the
        // study relies on this cell advance (2026-09-04).
        if vm.studyMode, vm.phaseController.currentPhase == .freeWrite { return }
        let hasStrokes = (vm.strokeTracker.definition?.strokes.isEmpty == false)
        guard hasStrokes, vm.strokeTracker.isComplete else { return }
        // Snapshot BEFORE advancing — after the grid moves the cursor,
        // `strokeTracker` aliases the next cell.
        let completingCellIndex = vm.grid.activeCellIndex
        let sequenceDone = vm.grid.advanceIfCompleted()
        if !sequenceDone {
            // Retain the just-completed cell's ink so the child sees
            // the letter they wrote as they move on.
            if vm.grid.cells.indices.contains(completingCellIndex) {
                vm.grid.cells[completingCellIndex].activePath = vm.activePath
            }
            vm.activePath.removeAll(keepingCapacity: true)
            // Per-cell audio: child hears "O → M → A" through "OMA".
            vm.autoplayActiveCellLetter()
        } else if !vm.didCompleteCurrentLetter {
            vm.didCompleteCurrentLetter = true
            if vm.feedbackIntensity > 0 { vm.haptics.fire(.letterCompleted) }
            // Stop audio before phase teardown so the letter sound
            // doesn't bleed into the next phase.
            vm.playback.request(.idle, immediate: true)
            // Single funnel for phase transitions.
            vm.advanceLearningPhase()
        }
    }

    /// Schedule the freeWrite quiet-window advance.
    /// `freeWriteQuietSeconds` of no re-touch advances the phase,
    /// runs the recognizer, and writes stars via `commitCompletion`.
    private func scheduleFreeWriteAutoAdvance() {
        freeWriteAutoAdvanceTask?.cancel()
        let seconds = freeWriteQuietSeconds
        freeWriteAutoAdvanceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self,
                  !Task.isCancelled,
                  let vm = self.vm,
                  vm.phaseController.currentPhase == .freeWrite,
                  !vm.didCompleteCurrentLetter,
                  !self.isSingleTouchInteractionActive else { return }
            self.freeWriteAutoAdvanceTask = nil
            vm.advanceLearningPhase()
        }
    }

    // MARK: - Pure helpers

    /// Map writing velocity to playback rate. Calibrated for iPad
    /// finger writing: ~50 pt/s (careful) → 0.5x, ~800 pt/s (quick) →
    /// 2.0x; linear interpolation between, clamped at the bounds.
    static func mapVelocityToSpeed(_ v: CGFloat) -> Float {
        let low: CGFloat = 50, high: CGFloat = 800
        if v <= low  { return 0.5 }
        if v >= high { return 2.0 }
        return Float(0.5 + 1.5 * ((v - low) / (high - low)))
    }
}
