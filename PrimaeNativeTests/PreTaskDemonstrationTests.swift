// Proves the 2026-09-03 study-design instruction: both sound arms get
// a brief, non-trace-coupled demonstration before the tracing task,
// structurally matched in duration/form; the silent arm gets none
// added (its matched non-auditory equivalent is the unchanged
// ghost-letter animation, out of scope here — see
// PreTaskDemonstration.swift's header).
//
// `axisSweep` is pure and tested directly; the VM wiring is tested
// with a short `duration` override so these don't wait out the full
// 2 s production window.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@MainActor
fileprivate final class RecordingAudio: AudioControlling {
    var initializationError: String? { nil }
    private(set) var loadedFiles: [String] = []
    private(set) var autoplayFlags: [Bool] = []
    private(set) var setAdaptiveCount = 0
    private(set) var spatialPitches: [Float] = []
    private(set) var stopCount = 0
    var isPlaying = false
    func loadAudioFile(named: String, autoplay: Bool) {
        loadedFiles.append(named)
        autoplayFlags.append(autoplay)
        isPlaying = autoplay
    }
    func play()    { isPlaying = true }
    func stop()    { stopCount += 1; isPlaying = false }
    func restart() {}
    func suspendForLifecycle()        { isPlaying = false }
    func resumeAfterLifecycle()       {}
    func cancelPendingLifecycleWork() {}
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) { setAdaptiveCount += 1 }
    func setSpatialPitch(cents: Float) { spatialPitches.append(cents) }
}

// MARK: - Pure axis-sweep math

@Suite struct PreTaskDemonstrationSweepTests {

    @Test("axisSweep produces the requested number of samples")
    func sampleCount() {
        let samples = PreTaskDemonstration.axisSweep(steps: 10, duration: 2.0)
        #expect(samples.count == 10)
    }

    @Test("axisSweep elapsed times are monotonically non-decreasing and span the full duration")
    func elapsedSpansDuration() {
        let samples = PreTaskDemonstration.axisSweep(steps: 20, duration: 2.0)
        #expect(samples.first?.elapsed == 0)
        #expect(samples.last?.elapsed == 2.0)
        for i in 1..<samples.count {
            #expect(samples[i].elapsed >= samples[i - 1].elapsed)
        }
    }

    @Test("axisSweep Y is a full top→bottom→top pass: 0 at start/end, ~1 at the midpoint")
    func ySweepShape() {
        let samples = PreTaskDemonstration.axisSweep(steps: 41, duration: 2.0)
        #expect(abs(samples.first!.point.y - 0.0) < 0.001)
        #expect(abs(samples.last!.point.y - 0.0) < 0.001)
        let mid = samples[samples.count / 2]
        #expect(abs(mid.point.y - 1.0) < 0.01,
                "midpoint Y should be ~1.0 (bottom), got \(mid.point.y)")
    }

    @Test("axisSweep X is quarter-cycle out of phase with Y — not moving in lockstep")
    func xOutOfPhaseWithY() {
        let samples = PreTaskDemonstration.axisSweep(steps: 41, duration: 2.0)
        // At the point where Y is at its extremum (bottom, t=0.5), X
        // should be back near its own midpoint (0.5), not also at an
        // extremum — proving the two axes are audible moving
        // independently rather than only together.
        let mid = samples[samples.count / 2]
        #expect(abs(mid.point.x - 0.5) < 0.05,
                "X should be near center while Y is at its extremum, got \(mid.point.x)")
    }

    @Test("axisSweep returns empty for degenerate inputs")
    func degenerateInputs() {
        #expect(PreTaskDemonstration.axisSweep(steps: 1, duration: 2.0).isEmpty)
        #expect(PreTaskDemonstration.axisSweep(steps: 10, duration: 0).isEmpty)
    }
}

// MARK: - VM wiring

@Suite(.serialized) @MainActor struct PreTaskDemonstrationWiringTests {

    private func asset(_ name: String = "A") -> LetterAsset {
        LetterAsset(
            id: name, name: name,
            audioFiles: ["\(name)_name.mp3"],
            strokes: LetterStrokes(letter: name, checkpointRadius: 0.1, strokes: [
                StrokeDefinition(id: 1, checkpoints: [Checkpoint(x: 0.1, y: 0.1),
                                                      Checkpoint(x: 0.9, y: 0.9)])
            ]),
            phonemeAudioFiles: ["\(name)_phoneme1.mp3"]
        )
    }

    /// Poll up to ~1 s for a condition — the demo runs on a real Task,
    /// so its first effect lands a beat after `armPreTaskDemonstration`
    /// returns, not synchronously.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<40 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    @Test("non-study session: no demonstration for any arm")
    func nonStudy_noOp() async {
        let audio = RecordingAudio()
        let vm = TracingViewModel(.stub.with(audioCondition: .phoneme).with(audio: audio).with(studyMode: false))
        vm.armPreTaskDemonstration(for: asset(), duration: 0.05)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(audio.loadedFiles.isEmpty,
                "a non-study session must never trigger the pilot demonstration")
    }

    @Test("silent arm: no audio added, even in a study session")
    func silentArm_addsNoAudio() async {
        let audio = RecordingAudio()
        let vm = TracingViewModel(.stub.with(audioCondition: .silent).with(audio: audio).with(studyMode: true))
        vm.armPreTaskDemonstration(for: asset(), duration: 0.05)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(audio.loadedFiles.isEmpty,
                "silent arm's demonstration is the unchanged visual animation, not audio")
    }

    @Test("phoneme arm: sound-letter exposure plays the letter's phoneme once")
    func phonemeArm_playsPhonemeOnce() async {
        let audio = RecordingAudio()
        let vm = TracingViewModel(.stub.with(audioCondition: .phoneme).with(audio: audio).with(studyMode: true))
        vm.armPreTaskDemonstration(for: asset(), duration: 0.05)
        await waitUntil { !audio.loadedFiles.isEmpty }
        #expect(audio.loadedFiles == ["A_phoneme1.mp3"])
        #expect(audio.autoplayFlags == [true])
        // Not trace-coupled: the phoneme demo never drives the
        // per-tick pitch/pan coupling — it's a single scripted play.
        #expect(audio.setAdaptiveCount == 0)
        #expect(audio.spatialPitches.isEmpty)
    }

    @Test("spatial arm: axis demonstration loads the carrier and sweeps pitch/pan, then stops")
    func spatialArm_sweepsAndStops() async {
        let audio = RecordingAudio()
        let vm = TracingViewModel(.stub.with(audioCondition: .spatial).with(audio: audio).with(studyMode: true))
        vm.armPreTaskDemonstration(for: asset(), duration: 0.1)
        await waitUntil { !audio.loadedFiles.isEmpty }
        #expect(audio.loadedFiles == [SpatialSonification.carrierToneFile])
        // Let the short demo run to completion.
        await waitUntil { audio.stopCount > 0 }
        #expect(audio.setAdaptiveCount > 1,
                "the axis sweep should drive pan across multiple scripted samples")
        #expect(Set(audio.spatialPitches).count > 1,
                "the axis sweep should drive a RANGE of pitches, not a constant value — got \(audio.spatialPitches)")
        #expect(audio.stopCount == 1,
                "the demo must stop the looping carrier tone when the sweep finishes")
    }

    @Test("cancelPreTaskDemonstration before the task runs suppresses it entirely")
    func cancelBeforeRun_suppressesDemo() async {
        let audio = RecordingAudio()
        let vm = TracingViewModel(.stub.with(audioCondition: .phoneme).with(audio: audio).with(studyMode: true))
        vm.armPreTaskDemonstration(for: asset(), duration: 0.05)
        vm.cancelPreTaskDemonstration()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(audio.loadedFiles.isEmpty,
                "cancelling before the scheduled Task runs must leave no trace")
    }

    @Test("a real touch beginning cancels an in-flight demonstration")
    func realTouch_cancelsDemo() async {
        let audio = RecordingAudio()
        let vm = TracingViewModel(.stub.with(audioCondition: .spatial).with(audio: audio).with(studyMode: true))
        vm.armPreTaskDemonstration(for: asset(), duration: 2.0)
        await waitUntil { !audio.loadedFiles.isEmpty }
        let countAtTouch = audio.setAdaptiveCount
        // Touch is disabled during .observe (the phase the demo itself
        // runs in) — advance to .guided, where it IS enabled, to
        // isolate the cancellation behavior under test.
        vm.phaseController.resume(at: .guided)
        vm.beginTouch(at: CGPoint(x: 200, y: 200), t: 0)
        try? await Task.sleep(for: .milliseconds(150))
        // The real touch's OWN coupling may itself call setAdaptivePlayback
        // (it doesn't here — beginTouch only loads a file), so the
        // demonstration's cancellation is what matters: no further
        // growth beyond a couple of scheduler-race frames.
        #expect(audio.setAdaptiveCount <= countAtTouch + 1,
                "a real touch must cancel the scripted demo sweep, got \(audio.setAdaptiveCount) vs \(countAtTouch)")
    }
}
