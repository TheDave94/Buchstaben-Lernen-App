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
    private(set) var phaseCalls: [(letter: String, phase: String, trainedSubset: String?, phaseDurationSeconds: Double?)] = []
    func recordSession(letter: String, accuracy: Double,
                       durationSeconds: TimeInterval,
                       wallClockSeconds: TimeInterval?,
                       date: Date, condition: ThesisCondition,
                       inputDevice: String?) {
        sessionCalls.append((letter, durationSeconds))
    }
    func recordPhaseSession(letter: String, phase: String, completed: Bool, score: Double, schedulerPriority: Double, condition: ThesisCondition, audioCondition: PilotAudioCondition, assessment: WritingAssessment?, recognition: RecognitionSample?, inputDevice: String?, rawTraceID: UUID?, trainedSubset: String?, phaseDurationSeconds: Double?, frechetDistance: Double?, checkpointCoverage: Double?) {
        phaseCalls.append((letter, phase, trainedSubset, phaseDurationSeconds))
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
}
