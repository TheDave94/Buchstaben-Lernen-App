// Proves H2: activeAudioFiles routes on the pilot audio arm, and the
// silent arm gates BOTH content (no file loaded) and coupling (no
// setAdaptivePlayback). The two sound arms share the identical coupling
// path — only the file list differs (§2.6 matching discipline).
//
// Engine-free: a recording AudioControlling stub captures loads +
// setAdaptivePlayback so the coupling gate is observable without
// AudioEngine.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@MainActor
fileprivate final class RecordingAudio: AudioControlling {
    var initializationError: String? { nil }
    private(set) var loadedFiles: [String] = []
    private(set) var setAdaptiveCount = 0
    private(set) var isPlaying = false
    func loadAudioFile(named: String, autoplay: Bool) { loadedFiles.append(named) }
    func play()    { isPlaying = true }
    func stop()    { isPlaying = false }
    func restart() {}
    func suspendForLifecycle()        { isPlaying = false }
    func resumeAfterLifecycle()       {}
    func cancelPendingLifecycleWork() {}
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) { setAdaptiveCount += 1 }
}

@Suite(.serialized) @MainActor struct AudioArmRoutingTests {

    private let canvas = CGSize(width: 400, height: 400)

    /// An asset with a distinct file in every slot so routing is
    /// unambiguous.
    private func asset(_ name: String = "A") -> LetterAsset {
        LetterAsset(
            id: name, name: name,
            audioFiles: ["\(name)_name.mp3"],
            strokes: LetterStrokes(letter: name, checkpointRadius: 0.1, strokes: [
                StrokeDefinition(id: 1, checkpoints: [Checkpoint(x: 0.1, y: 0.1),
                                                      Checkpoint(x: 0.9, y: 0.9)])
            ]),
            phonemeAudioFiles: ["\(name)_phoneme1.mp3"],
            arbitraryAudioFiles: ["\(name)_arb1.mp3"]
        )
    }

    private func makeVM(arm: PilotAudioCondition, phonemeToggle: Bool) -> TracingViewModel {
        var deps = TracingDependencies.stub
        deps.audioCondition = arm
        deps.enablePhonemeMode = phonemeToggle
        return TracingViewModel(deps)
    }

    // MARK: - activeAudioFiles routing per arm

    @Test("phoneme arm with toggle ON → phoneme files")
    func phoneme_toggleOn_returnsPhonemes() {
        let vm = makeVM(arm: .phoneme, phonemeToggle: true)
        #expect(vm.activeAudioFiles(for: asset()) == ["A_phoneme1.mp3"])
    }

    @Test("phoneme arm with toggle OFF → name audio (casual users unchanged)")
    func phoneme_toggleOff_returnsName() {
        let vm = makeVM(arm: .phoneme, phonemeToggle: false)
        #expect(vm.activeAudioFiles(for: asset()) == ["A_name.mp3"])
    }

    @Test("arbitrarySound arm → arbitrary slot (placeholder, no name fallback)")
    func arbitrary_returnsArbitrarySlot() {
        let vm = makeVM(arm: .arbitrarySound, phonemeToggle: true)
        #expect(vm.activeAudioFiles(for: asset()) == ["A_arb1.mp3"])
    }

    @Test("arbitrarySound arm with empty slot → [] (does NOT leak name audio)")
    func arbitrary_emptySlot_returnsEmpty() {
        let vm = makeVM(arm: .arbitrarySound, phonemeToggle: false)
        let bare = LetterAsset(id: "B", name: "B",
                               audioFiles: ["B_name.mp3"],
                               strokes: LetterStrokes(letter: "B", checkpointRadius: 0.1, strokes: []),
                               phonemeAudioFiles: ["B_phoneme1.mp3"])  // no arbitrary slot
        #expect(vm.activeAudioFiles(for: bare).isEmpty)
    }

    @Test("silent arm → [] regardless of toggle or bundled files")
    func silent_returnsEmpty() {
        let vmA = makeVM(arm: .silent, phonemeToggle: true)
        let vmB = makeVM(arm: .silent, phonemeToggle: false)
        #expect(vmA.activeAudioFiles(for: asset()).isEmpty)
        #expect(vmB.activeAudioFiles(for: asset()).isEmpty)
    }

    // MARK: - Silent gates content AND coupling

    /// A silent participant must hear nothing AND drive no coupling — no
    /// file loaded, no setAdaptivePlayback, no loop to leave running.
    @Test("silent arm: a touch loads no file and fires no coupling")
    func silent_touchGatesContentAndCoupling() {
        let audio = RecordingAudio()
        let vm = TracingViewModel(.stub.with(audioCondition: .silent).with(audio: audio))
        driveTouch(vm)
        #expect(audio.loadedFiles.isEmpty,
                "silent arm must load no audio file — found \(audio.loadedFiles)")
        #expect(audio.setAdaptiveCount == 0,
                "silent arm must fire no setAdaptivePlayback — coupling gate breached (\(audio.setAdaptiveCount))")
    }

    /// The coupling must remain intact for a sound arm — the silent gate
    /// is arm-specific, not a blanket kill.
    @Test("phoneme arm: a touch drives the coupling (setAdaptivePlayback fires)")
    func phoneme_touchDrivesCoupling() {
        let audio = RecordingAudio()
        let vm = TracingViewModel(.stub.with(audioCondition: .phoneme).with(audio: audio))
        driveTouch(vm)
        #expect(audio.setAdaptiveCount > 0,
                "phoneme arm must keep the adaptive-playback coupling")
    }

    /// Mirrors EndToEndTracingSessionTests.simulateFastTouch: a fast
    /// in-bounds drag so updateAdaptivePlayback is reached.
    private func driveTouch(_ vm: TracingViewModel) {
        let t0: CFTimeInterval = 1000
        vm.beginTouch(at: CGPoint(x: 50, y: 200), t: t0)
        var t = t0
        var p = CGPoint(x: 50, y: 200)
        for _ in 0..<15 { t += 0.001; p.x += 10; vm.updateTouch(at: p, t: t, canvasSize: canvas) }
    }
}
