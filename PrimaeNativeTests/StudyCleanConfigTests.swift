// Pins the studyMode "clean study configuration" (audit C1–C4 + A/E):
// silenced non-arm audio + haptics, gated rewards/adaptation/retry,
// pinned device settings, letter-tagged durations, and the trained-3
// practice pool. A studyMode session must be identical across arms
// except the arm's designated sound.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

// Recording speech spy — proves the VM never routes to the injected
// synthesizer under studyMode (the silencing happens at the injection
// seam, so the spy must stay untouched).
@MainActor
fileprivate final class SpySpeech: SpeechSynthesizing {
    private(set) var spoken: [String] = []
    func speak(_ text: String) { spoken.append(text) }
    func stop() {}
}

@MainActor
fileprivate final class SpyPromptPlayer: PromptPlaying {
    private(set) var plays = 0
    func play(_ key: PromptPlayer.PromptKey, fallbackText: String) { plays += 1 }
    func stop() {}
    func playSuccessChime() { plays += 1 }
    func playTapChime() { plays += 1 }
    func playWrongTapChime() { plays += 1 }
    func playStrokeTick() { plays += 1 }
}

@MainActor
fileprivate final class SpyHaptics: HapticEngineProviding {
    private(set) var fires = 0
    func prepare() {}
    func fire(_ event: HapticEvent) { fires += 1 }
}

// Records dashboard calls so the retry gate and stamping are observable.
@MainActor
fileprivate final class RecordingDashboardStore: ParentDashboardStoring {
    var snapshot: DashboardSnapshot { DashboardSnapshot() }
    private(set) var sessionCalls: [(letter: String, duration: TimeInterval)] = []
    private(set) var phaseCalls: [(letter: String, phase: String, completed: Bool, score: Double,
                                   trainedSubset: String?, phaseDurationSeconds: Double?,
                                   spatialDeviation: Double?, rawTraceID: UUID?, studyMode: Bool?, probe: String?)] = []
    func recordSession(letter: String, accuracy: Double,
                       durationSeconds: TimeInterval,
                       wallClockSeconds: TimeInterval?,
                       date: Date, condition: ThesisCondition,
                       inputDevice: String?) {
        sessionCalls.append((letter, durationSeconds))
    }
    func recordPhaseSession(letter: String, phase: String, completed: Bool, score: Double, schedulerPriority: Double, condition: ThesisCondition, audioCondition: PilotAudioCondition, assessment: WritingAssessment?, recognition: RecognitionSample?, inputDevice: String?, rawTraceID: UUID?, trainedSubset: String?, phaseDurationSeconds: Double?, frechetDistance: Double?, checkpointCoverage: Double?, spatialDeviation: Double?, strokeCount: Int?, strokeOrder: String?, reversedStrokeCount: Int?, studyMode: Bool?, probe: String?) {
        phaseCalls.append((letter, phase, completed, score, trainedSubset, phaseDurationSeconds,
                           spatialDeviation, rawTraceID, studyMode, probe))
    }
    func reset() {}
}

@Suite(.serialized) @MainActor struct StudyCleanConfigTests {

    // Nil defaults (not `= SpySpeech()`): default-argument expressions
    // evaluate in a nonisolated context, which can't call the spies'
    // @MainActor inits under the test target's Swift 5 mode.
    private func studyDeps(spySpeech: SpySpeech? = nil,
                           spyPrompts: SpyPromptPlayer? = nil,
                           spyHaptics: SpyHaptics? = nil) -> TracingDependencies {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        deps.speech = spySpeech ?? SpySpeech()
        let prompts = spyPrompts ?? SpyPromptPlayer()
        deps.makePromptPlayer = { _ in prompts }
        deps.haptics = spyHaptics ?? SpyHaptics()
        return deps
    }

    // MARK: - C1: silencing at the injection seam

    @Test("studyMode swaps speech/prompts/haptics for null implementations")
    func studyMode_injectsNullFeedback() {
        let vm = TracingViewModel(studyDeps())
        #expect(vm.speech is NullSpeechSynthesizer,
                "studyMode must silence TTS at the injection seam")
        #expect(vm.prompts is NullPromptPlayer,
                "studyMode must silence prompt MP3s/chimes at the injection seam")
        #expect(vm.haptics is NullHapticEngine,
                "studyMode must silence haptics at the injection seam")
    }

    @Test("studyMode session drives zero calls into the injected feedback spies")
    func studyMode_spiesStaySilent() {
        let speech = SpySpeech(); let prompts = SpyPromptPlayer(); let haptics = SpyHaptics()
        let vm = TracingViewModel(studyDeps(spySpeech: speech, spyPrompts: prompts, spyHaptics: haptics))
        // Drive a touch sequence (would fire stroke haptics/ticks and,
        // out of bounds, retry TTS in normal mode).
        let t0: CFTimeInterval = 1000
        vm.beginTouch(at: CGPoint(x: 50, y: 200), t: t0)
        var t = t0
        var p = CGPoint(x: 50, y: 200)
        for _ in 0..<15 { t += 0.001; p.x += 10; vm.updateTouch(at: p, t: t, canvasSize: CGSize(width: 400, height: 400)) }
        vm.endTouch()
        #expect(speech.spoken.isEmpty, "no TTS in a study session — got \(speech.spoken)")
        #expect(prompts.plays == 0, "no prompt/chime/tick audio in a study session")
        #expect(haptics.fires == 0, "no haptics in a study session")
    }

    @Test("non-studyMode keeps the injected speech/prompt/haptic implementations")
    func normalMode_keepsInjected() {
        let speech = SpySpeech()
        var deps = TracingDependencies.stub
        deps.speech = speech
        deps.studyMode = false
        let vm = TracingViewModel(deps)
        #expect((vm.speech as? SpySpeech) === speech,
                "non-study sessions must not silently swap the speech seam")
    }

    // MARK: - C3: adaptation + retry gates

    @Test("studyMode pins difficulty to FixedAdaptationPolicy at the standard tier")
    func studyMode_fixesDifficulty() {
        let vm = TracingViewModel(studyDeps())
        #expect(vm.adaptationPolicy is FixedAdaptationPolicy)
        #expect(vm.adaptationPolicy.currentTier == .standard)
    }

    @Test("studyMode: confident-wrong recognition celebrates (records) instead of retrying")
    func studyMode_neverRetries() {
        let store = RecordingDashboardStore()
        let vm = TracingViewModel(studyDeps().with(dashboardStore: store))
        let confidentWrong = RecognitionResult(predictedLetter: "X",
                                               confidence: 0.95,
                                               topThree: [], isCorrect: false)
        vm.phaseTransitions.completePostFreeWriteRecognition(score: 0.5, result: confidentWrong)
        #expect(!store.sessionCalls.isEmpty,
                "studyMode must complete (record) rather than force a retry")
    }

    @Test("non-studyMode: confident-wrong recognition still retries (behavior preserved)")
    func normalMode_stillRetries() {
        let store = RecordingDashboardStore()
        var deps = TracingDependencies.stub.with(dashboardStore: store)
        deps.studyMode = false
        let vm = TracingViewModel(deps)
        _ = vm
        let confidentWrong = RecognitionResult(predictedLetter: "X",
                                               confidence: 0.95,
                                               topThree: [], isCorrect: false)
        vm.phaseTransitions.completePostFreeWriteRecognition(score: 0.5, result: confidentWrong)
        #expect(store.sessionCalls.isEmpty,
                "outside studyMode the confident-wrong retry gate must keep firing")
    }

    // MARK: - C2: reward-class UI/overlays stay off

    @Test("studyMode: completing recognition enqueues no overlays (no KP, badge, celebration)")
    func studyMode_noOverlays() {
        let vm = TracingViewModel(studyDeps())
        let goodResult = RecognitionResult(predictedLetter: vm.currentLetterName,
                                           confidence: 0.95,
                                           topThree: [], isCorrect: true)
        vm.phaseTransitions.completePostFreeWriteRecognition(score: 0.9, result: goodResult)
        #expect(vm.overlayQueue.currentOverlay == nil,
                "study sessions must end trials with no overlay feedback")
    }

    // MARK: - C4: pinned device settings

    @Test("studyMode pins SchriftArt to Druckschrift and the letter ordering")
    func studyMode_pinsScriptAndOrdering() {
        var deps = studyDeps()
        deps.schriftArt = .schreibschrift
        deps.letterOrdering = .alphabetical
        let vm = TracingViewModel(deps)
        #expect(vm.schriftArt == .druckschrift)
        #expect(vm.letterOrdering == .motorSimilarity)
    }

    @Test("studyMode hides letter variants (F's stroke-order toggle)")
    func studyMode_disablesVariants() {
        let vm = TracingViewModel(studyDeps())
        vm.letters = [LetterAsset(id: "F", name: "F", baseLetter: "F", letterCase: .upper,
                                  audioFiles: [],
                                  strokes: LetterStrokes(letter: "F", checkpointRadius: 0.1, strokes: []),
                                  variants: ["variant"])]
        vm.letterIndex = 0
        #expect(vm.currentLetterHasVariants == false,
                "the child-reachable variant toggle must be gone under studyMode")
    }

    // MARK: - Item 1: trained-3 practice pool

    @Test("studyMode practice pool = the participant's trained 3 letters")
    func studyMode_poolIsTrainedThree() {
        var deps = studyDeps().with(trainedSubset: TrainedLetterSubset(rawValue: "AIM")!)
        deps.studyMode = true
        let vm = TracingViewModel(deps)
        vm.letters = TrainedLetterSubset.studyLetters.map {
            LetterAsset(id: $0, name: $0, baseLetter: $0, letterCase: .upper,
                        audioFiles: [],
                        strokes: LetterStrokes(letter: $0, checkpointRadius: 0.1, strokes: []))
        }
        #expect(Set(vm.visibleLetterNames) == ["A", "I", "M"])
    }

    // MARK: - Item 5: letter-tagged durations + export columns

    @Test("SessionDurationRecord carries the letter and exports it")
    func durationRows_carryLetter() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("study-config-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = JSONParentDashboardStore(fileURL: dir.appendingPathComponent("dash.json"))
        store.recordSession(letter: "M", accuracy: 0.8, durationSeconds: 42.5,
                            wallClockSeconds: 50, date: Date(), condition: .threePhase,
                            inputDevice: "finger")
        #expect(store.snapshot.sessionDurations.last?.letter == "M")

        let csv = String(data: ParentDashboardExporter.csvData(from: store.snapshot), encoding: .utf8)!
        #expect(csv.contains("date,recordedAt,durationSeconds,wallClockSeconds,condition,inputDevice,letter"),
                "durations header must gain the trailing letter column")
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("Per-phase CSV gains trainedSubset + phaseDurationSeconds columns")
    func phaseRows_exportNewColumns() {
        let record = PhaseSessionRecord(
            letter: "A", phase: "freeWrite", completed: true,
            score: 0.8, schedulerPriority: 0,
            audioCondition: .spatial,
            trainedSubset: "AIM", phaseDurationSeconds: 7.5)
        let snapshot = DashboardSnapshot(phaseSessionRecords: [record])
        let csv = String(data: ParentDashboardExporter.csvData(from: snapshot), encoding: .utf8)!
        #expect(csv.contains("audioCondition,trainedSubset,phaseDurationSeconds"))
        #expect(csv.contains("spatial,AIM,7.500"))
    }

    // MARK: - Study pins found by the 2026-09-04 audit
    //
    // Three ways a study session silently lost its primary outcome, each
    // now pinned at the VM: the pedagogical axis (an enrolled install
    // could draw a flow with no freeWrite phase), the grid preset (one
    // Apple Pencil touch switched freeWrite scoring onto the multi-cell
    // path that never sets `spatialDeviation`), and the freeWrite end
    // condition (checkpoint completion ended the trial mid-gesture).

    @Test("studyMode pins the pedagogical axis to the full four-phase flow")
    func studyMode_pinsThesisConditionToThreePhase() {
        // `.guidedOnly` is the flow an enrolled install can draw from
        // UUID byte 0 — and it has NO freeWrite phase. The VM must not
        // honour it under studyMode.
        var deps = studyDeps()
        deps.thesisCondition = .guidedOnly
        let vm = TracingViewModel(deps)
        #expect(vm.thesisCondition == .threePhase)
        #expect(vm.activePhases == LearningPhase.allCases,
                "a study flow without freeWrite has no primary outcome and no post-test")
    }

    @Test("non-studyMode honours the injected pedagogical condition (A/B flow preserved)")
    func normalMode_keepsThesisCondition() {
        var deps = TracingDependencies.stub
        deps.studyMode = false
        deps.thesisCondition = .guidedOnly
        let vm = TracingViewModel(deps)
        #expect(vm.thesisCondition == .guidedOnly)
        #expect(vm.activePhases == [.guided])
    }

    @Test("studyMode keeps ONE cell after an Apple Pencil touch; the device is still recorded")
    func studyMode_pencilKeepsSingleCell() {
        let vm = TracingViewModel(studyDeps())
        vm.canvasSize = CGSize(width: 800, height: 600)
        #expect(vm.gridCells.count == 1)
        vm.pencilDidTouchDown()
        #expect(vm.inputModeDetector.effectiveKind == .pencil,
                "the detector must stay honest — `inputDevice` is exported on every row")
        #expect(vm.gridCells.count == 1,
                "the 4-cell pencil layout routes freeWrite through assess(cellReferences:), which never sets the primary outcome")
        #expect(vm.gridPreset.kind == .finger)
    }

    @Test("non-studyMode still promotes to the 4-cell pencil layout (behaviour preserved)")
    func normalMode_pencilPromotesToFourCells() {
        var deps = TracingDependencies.stub
        deps.studyMode = false
        let vm = TracingViewModel(deps)
        vm.canvasSize = CGSize(width: 800, height: 600)
        vm.pencilDidTouchDown()
        #expect(vm.gridCells.count == InputPreset.pencil.cellCount)
    }

    /// Drives one touch exactly along the tracker's loaded reference
    /// polyline — every update lands on the next checkpoint — so the
    /// tracker completes regardless of how the fixture letter was mapped
    /// onto the canvas. Set `vm.canvasSize` BEFORE calling this: the
    /// dispatcher re-maps checkpoints when the reported size differs.
    private func traceReferencePolyline(_ vm: TracingViewModel, canvas: CGSize) {
        let cps = vm.strokeTracker.definition?.strokes.flatMap(\.checkpoints) ?? []
        var t: CFTimeInterval = 1000
        let first = cps.first.map { CGPoint(x: $0.x * canvas.width, y: $0.y * canvas.height) } ?? .zero
        vm.beginTouch(at: first, t: t)
        for cp in cps {
            t += 0.01
            vm.updateTouch(at: CGPoint(x: cp.x * canvas.width, y: cp.y * canvas.height),
                           t: t, canvasSize: canvas)
        }
    }

    @Test("studyMode freeWrite is NOT ended by checkpoint completion — only the pen-lift quiet window ends it")
    func studyMode_freeWriteIgnoresCheckpointCompletion() {
        let store = RecordingDashboardStore()
        let vm = TracingViewModel(studyDeps().with(dashboardStore: store))
        let canvas = CGSize(width: 400, height: 400)
        vm.canvasSize = canvas
        vm.phaseController.resume(at: .freeWrite)
        traceReferencePolyline(vm, canvas: canvas)
        // Precondition, asserted rather than skipped: the tracker still
        // runs in freeWrite (it feeds `checkpointCoverage`), so the trace
        // above must have completed the letter's checkpoints.
        #expect(vm.progress == 1.0, "fixture drive did not complete the checkpoints — the assertion below would be vacuous")
        #expect(vm.learningPhase == .freeWrite)
        #expect(!vm.didCompleteCurrentLetter,
                "the trial must stay open while the finger is down — checkpoint completion used to end it mid-gesture, truncating the best writers' traces")
        #expect(store.phaseCalls.isEmpty, "no row may be written mid-gesture")
    }

    @Test("studyMode guided still completes on checkpoint completion (gate is freeWrite-specific)")
    func studyMode_guidedStillCompletesOnCheckpoints() {
        let vm = TracingViewModel(studyDeps())
        let canvas = CGSize(width: 400, height: 400)
        vm.canvasSize = canvas
        vm.phaseController.resume(at: .guided)
        traceReferencePolyline(vm, canvas: canvas)
        #expect(vm.learningPhase == .freeWrite,
                "positive control: the same drive must still advance guided → freeWrite")
    }

    // MARK: - Unload / background safety (2026-09-04): no trial vanishes, abandonment is a row
    //
    // Before: `load(letter:)` cleared the recorder and cancelled the
    // recognizer token, so a freeWrite production the child had finished
    // but that had not been scored yet — the proctor tapped the next
    // arrow inside the 2.0 s quiet window, or while the recognizer was in
    // flight — left no score, no row and no raw trace. And `completed`
    // was hard-coded `true`, so a letter left mid-phase left nothing.

    /// A short in-bounds freeWrite stroke; not along the reference.
    private func driveFreeWriteInk(_ vm: TracingViewModel, canvas: CGSize) {
        var t: CFTimeInterval = 1000
        vm.beginTouch(at: CGPoint(x: 50, y: 200), t: t)
        var p = CGPoint(x: 50, y: 200)
        for _ in 0..<15 { t += 0.01; p.x += 10; vm.updateTouch(at: p, t: t, canvasSize: canvas) }
    }

    @Test("studyMode: a finished-but-unscored freeWrite is scored and recorded when the letter is unloaded")
    func studyMode_unloadFinalizesFinishedFreeWrite() {
        let store = RecordingDashboardStore()
        let traces = StubRawTraceStore()
        let vm = TracingViewModel(studyDeps().with(dashboardStore: store).with(rawTraceStore: traces))
        let canvas = CGSize(width: 400, height: 400)
        vm.canvasSize = canvas
        vm.phaseController.resume(at: .freeWrite)
        driveFreeWriteInk(vm, canvas: canvas)
        vm.endTouch()   // pen up → the 2.0 s quiet window is now pending
        #expect(store.phaseCalls.isEmpty, "precondition: nothing is recorded before the unload")
        vm.loadLetter(name: vm.currentLetterName)   // proctor moves on inside the window
        let fw = store.phaseCalls.first { $0.phase == LearningPhase.freeWrite.rawName }
        #expect(fw?.completed == true, "a finished production is a completed trial: \(String(describing: fw))")
        #expect(fw?.spatialDeviation != nil, "the primary outcome must be scored on the unload path")
        #expect(fw?.rawTraceID != nil, "the freeWrite row must link to its raw trace")
        #expect(traces.traces.count == 1, "the raw trace must be persisted before the buffer clears")
        #expect(store.phaseCalls.filter { $0.phase == LearningPhase.freeWrite.rawName }.count == 1,
                "exactly one freeWrite row — no double completion")
    }

    @Test("studyMode: unloading mid-stroke records the freeWrite trial as NOT completed, with its measures")
    func studyMode_unloadMidStrokeRecordsAbandonedFreeWrite() {
        let store = RecordingDashboardStore()
        let vm = TracingViewModel(studyDeps().with(dashboardStore: store))
        let canvas = CGSize(width: 400, height: 400)
        vm.canvasSize = canvas
        vm.phaseController.resume(at: .freeWrite)
        driveFreeWriteInk(vm, canvas: canvas)   // finger still down
        vm.loadLetter(name: vm.currentLetterName)
        let fw = store.phaseCalls.first { $0.phase == LearningPhase.freeWrite.rawName }
        #expect(fw?.completed == false, "an interrupted production is not a completed trial: \(String(describing: fw))")
        #expect(fw?.spatialDeviation != nil, "what was written is still measured and kept")
        #expect(fw?.rawTraceID != nil)
    }

    @Test("studyMode: unloading a partly traced guided phase records it as NOT completed with its coverage")
    func studyMode_unloadRecordsAbandonedGuided() {
        let store = RecordingDashboardStore()
        let vm = TracingViewModel(studyDeps().with(dashboardStore: store))
        let canvas = CGSize(width: 400, height: 400)
        vm.canvasSize = canvas
        vm.phaseController.resume(at: .guided)
        // Hit the first few checkpoints only.
        let cps = Array((vm.strokeTracker.definition?.strokes.flatMap(\.checkpoints) ?? []).prefix(5))
        var t: CFTimeInterval = 1000
        let px: (Checkpoint) -> CGPoint = { CGPoint(x: $0.x * canvas.width, y: $0.y * canvas.height) }
        vm.beginTouch(at: cps.first.map(px) ?? .zero, t: t)
        for cp in cps { t += 0.01; vm.updateTouch(at: px(cp), t: t, canvasSize: canvas) }
        vm.endTouch()
        let progress = vm.progress
        #expect(progress > 0 && progress < 1, "precondition: partly traced, got \(progress)")
        vm.loadLetter(name: vm.currentLetterName)
        let g = store.phaseCalls.first { $0.phase == LearningPhase.guided.rawName }
        #expect(g?.completed == false, "\(String(describing: g))")
        #expect(g.map { abs($0.score - Double(progress)) < 1e-9 } == true,
                "the abandoned guided row carries the coverage reached so far")
        #expect(store.phaseCalls.count == 1, "one row for the abandoned phase, nothing else")
    }

    @Test("studyMode: unloading an untouched letter records nothing")
    func studyMode_unloadUntouchedRecordsNothing() {
        let store = RecordingDashboardStore()
        let vm = TracingViewModel(studyDeps().with(dashboardStore: store))
        vm.loadLetter(name: vm.currentLetterName)
        vm.loadLetter(name: vm.currentLetterName)
        #expect(store.phaseCalls.isEmpty)
    }

    @Test("non-studyMode: unloading a worked letter records nothing (behaviour preserved)")
    func normalMode_unloadRecordsNothing() {
        let store = RecordingDashboardStore()
        var deps = TracingDependencies.stub.with(dashboardStore: store)
        deps.studyMode = false
        let vm = TracingViewModel(deps)
        let canvas = CGSize(width: 400, height: 400)
        vm.canvasSize = canvas
        driveFreeWriteInk(vm, canvas: canvas)   // stub starts in .guided; some progress
        vm.endTouch()
        vm.loadLetter(name: vm.currentLetterName)
        #expect(store.phaseCalls.isEmpty)
    }

    // MARK: - Probe tag on rows and the from-memory canvas (2026-09-04)

    @Test("a pretest probe's freeWrite row is tagged 'pretest'; a training freeWrite row is untagged")
    func probeTag_onRows() {
        let store = RecordingDashboardStore()
        let vm = TracingViewModel(studyDeps().with(dashboardStore: store))
        let canvas = CGSize(width: 400, height: 400)
        vm.canvasSize = canvas
        // Pretest on the trained fixture letter A, finished, then unloaded.
        vm.startColdProbe(letter: "A", kind: .pretest)
        #expect(vm.learningPhase == .freeWrite && vm.currentProbe == .pretest)
        driveFreeWriteInk(vm, canvas: canvas)
        vm.endTouch()
        vm.loadLetter(name: "A")                       // unload → finalised, tagged
        let probeRow = store.phaseCalls.first { $0.phase == LearningPhase.freeWrite.rawName }
        #expect(probeRow?.probe == StudyProbe.pretest.rawValue, "\(String(describing: probeRow))")
        #expect(probeRow?.completed == true)
        // Now a training pass's freeWrite on the same letter: no tag.
        vm.phaseController.resume(at: .freeWrite)
        driveFreeWriteInk(vm, canvas: canvas)
        vm.endTouch()
        vm.loadLetter(name: "A")
        let rows = store.phaseCalls.filter { $0.phase == LearningPhase.freeWrite.rawName }
        #expect(rows.count == 2)
        #expect(rows.last?.probe == nil, "a training freeWrite row must carry no probe tag: \(String(describing: rows.last))")
    }

    @Test("study freeWrite hides the filled reference glyph — production is from memory")
    func studyFreeWrite_hidesReferenceGlyph() {
        let vm = TracingViewModel(studyDeps())
        vm.phaseController.resume(at: .guided)
        #expect(vm.showsReferenceGlyph, "the model stays visible while tracing")
        vm.phaseController.resume(at: .freeWrite)
        #expect(!vm.showsReferenceGlyph, "the letter must not be on screen while the child writes it from memory")
        vm.startColdProbe(letter: vm.currentLetterName, kind: .pretest)
        #expect(!vm.showsReferenceGlyph, "cold probes are freeWrite too")
    }

    @Test("non-study freeWrite keeps the filled glyph (casual app unchanged)")
    func normalMode_keepsReferenceGlyph() {
        var deps = TracingDependencies.stub
        deps.studyMode = false
        deps.thesisCondition = .threePhase
        let vm = TracingViewModel(deps)
        vm.phaseController.resume(at: .freeWrite)
        #expect(vm.showsReferenceGlyph)
    }

    @Test("studyMode: backgrounding with a finished-but-unscored freeWrite records it before the stores drain")
    func studyMode_backgroundFinalizesFinishedFreeWrite() async {
        let store = RecordingDashboardStore()
        let vm = TracingViewModel(studyDeps().with(dashboardStore: store))
        let canvas = CGSize(width: 400, height: 400)
        vm.canvasSize = canvas
        vm.phaseController.resume(at: .freeWrite)
        driveFreeWriteInk(vm, canvas: canvas)
        vm.endTouch()
        await vm.appDidEnterBackground()
        let fw = store.phaseCalls.first { $0.phase == LearningPhase.freeWrite.rawName }
        #expect(fw?.completed == true, "\(String(describing: fw))")
        #expect(vm.isPhaseSessionComplete, "the letter session is closed so the quiet-window task cannot complete it a second time")
    }
}
