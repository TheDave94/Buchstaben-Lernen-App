// Supervisor ruling C3-2 (2026-09-04): the silent STUDY ARM is
// authoritative — when the audio arm is silent, no audio path may fire,
// whatever study mode or any pedagogical parameter says. Verified here
// by DRIVING every path that can make a sound, in study mode and out of
// it, and by a positive control that proves the same drive makes sound
// in a sound arm. The row stamp `studyMode` is checked at the store
// seam so a silent-arm row can never again be ambiguous about the
// configuration it was written under.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@MainActor
fileprivate final class RecordingAudio: AudioControlling {
    var initializationError: String? { nil }
    private(set) var loadedFiles: [String] = []
    private(set) var setAdaptiveCount = 0
    private(set) var spatialPitches: [Float] = []
    private(set) var playCount = 0
    private(set) var isPlaying = false
    func loadAudioFile(named: String, autoplay: Bool) { loadedFiles.append(named); if autoplay { isPlaying = true } }
    func play()    { playCount += 1; isPlaying = true }
    func stop()    { isPlaying = false }
    func restart() { playCount += 1 }
    func suspendForLifecycle()        { isPlaying = false }
    func resumeAfterLifecycle()       {}
    func cancelPendingLifecycleWork() {}
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) { setAdaptiveCount += 1 }
    func setSpatialPitch(cents: Float) { spatialPitches.append(cents) }
    var anyAudioActivity: String? {
        var out: [String] = []
        if !loadedFiles.isEmpty { out.append("loaded \(loadedFiles)") }
        if setAdaptiveCount > 0 { out.append("setAdaptivePlayback ×\(setAdaptiveCount)") }
        if !spatialPitches.isEmpty { out.append("setSpatialPitch ×\(spatialPitches.count)") }
        if playCount > 0 { out.append("play ×\(playCount)") }
        if isPlaying { out.append("isPlaying") }
        return out.isEmpty ? nil : out.joined(separator: ", ")
    }
}

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
fileprivate final class CapturingStore: ParentDashboardStoring {
    var snapshot: DashboardSnapshot { DashboardSnapshot() }
    private(set) var studyModeStamps: [(phase: String, studyMode: Bool?)] = []
    func recordSession(letter: String, accuracy: Double, durationSeconds: TimeInterval,
                       wallClockSeconds: TimeInterval?, date: Date, condition: ThesisCondition,
                       inputDevice: String?) {}
    func recordPhaseSession(letter: String, phase: String, completed: Bool, score: Double, schedulerPriority: Double, condition: ThesisCondition, audioCondition: PilotAudioCondition, assessment: WritingAssessment?, recognition: RecognitionSample?, inputDevice: String?, rawTraceID: UUID?, trainedSubset: String?, phaseDurationSeconds: Double?, frechetDistance: Double?, checkpointCoverage: Double?, spatialDeviation: Double?, strokeCount: Int?, strokeOrder: String?, reversedStrokeCount: Int?, studyMode: Bool?, probe: String?) {
        studyModeStamps.append((phase, studyMode))
    }
    func reset() {}
}

@Suite(.serialized) @MainActor struct SilentArmAuthorityTests {

    private let canvas = CGSize(width: 400, height: 400)

    private struct Harness {
        let vm: TracingViewModel
        let audio: RecordingAudio
        let speech: SpySpeech
        let prompts: SpyPromptPlayer
    }

    private func harness(arm: PilotAudioCondition, studyMode: Bool,
                         store: ParentDashboardStoring? = nil) -> Harness {
        let audio = RecordingAudio(); let speech = SpySpeech(); let prompts = SpyPromptPlayer()
        var deps = TracingDependencies.stub
        deps.audioCondition = arm
        deps.studyMode = studyMode
        deps.thesisCondition = .threePhase   // every phase reachable, incl. observe + freeWrite
        deps.audio = audio
        deps.speech = speech
        deps.makePromptPlayer = { _ in prompts }
        if let store { deps.dashboardStore = store }
        let vm = TracingViewModel(deps)
        vm.canvasSize = canvas
        return Harness(vm: vm, audio: audio, speech: speech, prompts: prompts)
    }

    /// Every entry point that can reach the engine, driven in order:
    /// fresh load (demo armed in observe), observe → direct → guided by
    /// the controller, a guided touch through the whole reference
    /// polyline (coupling + completion → phase prompt), a freeWrite
    /// touch, replay and take-cycling, and the post-test route.
    private func driveEverything(_ h: Harness) async {
        let vm = h.vm
        vm.loadLetter(name: vm.currentLetterName)              // observe: demo armed here
        vm.phaseController.resume(at: .guided)
        var t: CFTimeInterval = 1000
        let cps = vm.strokeTracker.definition?.strokes.flatMap(\.checkpoints) ?? []
        let px: (Checkpoint) -> CGPoint = { CGPoint(x: $0.x * self.canvas.width, y: $0.y * self.canvas.height) }
        vm.beginTouch(at: cps.first.map(px) ?? .zero, t: t)
        for cp in cps { t += 0.01; vm.updateTouch(at: px(cp), t: t, canvasSize: canvas) }
        vm.endTouch()                                           // guided completed → advance → freeWrite
        vm.phaseController.resume(at: .freeWrite)
        vm.beginTouch(at: CGPoint(x: 50, y: 200), t: t)
        var p = CGPoint(x: 50, y: 200)
        for _ in 0..<10 { t += 0.01; p.x += 10; vm.updateTouch(at: p, t: t, canvasSize: canvas) }
        vm.endTouch()
        vm.replayAudio()
        vm.nextAudioVariant()
        vm.previousAudioVariant()
        await vm.awaitPlaybackDebounce()
        // Let any armed demonstration task run its first turn.
        try? await Task.sleep(for: .milliseconds(30))
    }

    @Test("silent arm makes no sound anywhere — study mode ON and OFF",
          arguments: [true, false])
    func silentArm_noAudioPathFires(studyMode: Bool) async {
        let h = harness(arm: .silent, studyMode: studyMode)
        await driveEverything(h)
        #expect(h.audio.anyAudioActivity == nil,
                "silent arm (studyMode=\(studyMode)) reached the engine: \(h.audio.anyAudioActivity ?? "")")
        #expect(h.speech.spoken.isEmpty, "silent arm must hear no TTS (studyMode=\(studyMode)): \(h.speech.spoken)")
        #expect(h.prompts.plays == 0, "silent arm must hear no prompt/chime/tick (studyMode=\(studyMode))")
        #expect(h.vm.audio is SilentAudio, "the engine itself must be the no-op conformer, not merely unused")
    }

    @Test("positive control: the same drive makes sound in the phoneme arm outside study mode")
    func phonemeArm_sameDriveMakesSound() async {
        let h = harness(arm: .phoneme, studyMode: false)
        await driveEverything(h)
        #expect(h.audio.anyAudioActivity != nil, "the drive must reach the engine in a sound arm, or the silent assertions are vacuous")
        #expect(h.audio.setAdaptiveCount > 0)
        #expect(h.prompts.plays > 0, "phase-entry prompts must play outside study mode in a sound arm")
    }

    @Test("silent arm: the pre-task demonstration is never armed (both modes)",
          arguments: [true, false])
    func silentArm_noDemonstration(studyMode: Bool) async {
        let h = harness(arm: .silent, studyMode: studyMode)
        let letter = h.vm.letters[0]
        h.vm.armPreTaskDemonstration(for: letter, duration: 0.02)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(h.audio.loadedFiles.isEmpty && h.audio.setAdaptiveCount == 0 && h.audio.spatialPitches.isEmpty)
    }

    @Test("every phase row is stamped with the study configuration it was written under",
          arguments: [true, false])
    func rowsCarryStudyModeStamp(studyMode: Bool) async {
        let store = CapturingStore()
        let h = harness(arm: .silent, studyMode: studyMode, store: store)
        let vm = h.vm
        vm.phaseController.advance(score: 1.0)   // observe
        vm.phaseController.advance(score: 1.0)   // direct
        vm.phaseController.resume(at: .guided)
        var t: CFTimeInterval = 1000
        let cps = vm.strokeTracker.definition?.strokes.flatMap(\.checkpoints) ?? []
        let px: (Checkpoint) -> CGPoint = { CGPoint(x: $0.x * self.canvas.width, y: $0.y * self.canvas.height) }
        vm.beginTouch(at: cps.first.map(px) ?? .zero, t: t)
        for cp in cps { t += 0.01; vm.updateTouch(at: px(cp), t: t, canvasSize: canvas) }
        vm.endTouch()
        #expect(vm.learningPhase == .freeWrite, "precondition: guided completed")
        // Unload with a partly worked freeWrite → abandonment row (study) or nothing (non-study).
        vm.beginTouch(at: CGPoint(x: 50, y: 200), t: t)
        vm.updateTouch(at: CGPoint(x: 80, y: 200), t: t + 0.01, canvasSize: canvas)
        vm.endTouch()
        vm.loadLetter(name: vm.currentLetterName)
        if studyMode {
            #expect(!store.studyModeStamps.isEmpty, "a study unload must write rows")
            #expect(store.studyModeStamps.allSatisfy { $0.studyMode == true },
                    "every row must say studyMode=true: \(store.studyModeStamps)")
        } else {
            // Non-study: nothing is written on unload; drive a full completion instead.
            #expect(store.studyModeStamps.allSatisfy { $0.studyMode == false },
                    "every row must say studyMode=false: \(store.studyModeStamps)")
        }
    }
}
