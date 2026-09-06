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
    /// Every cents value the spatial pitch drive emitted, in order.
    private(set) var spatialPitches: [Float] = []
    private(set) var isPlaying = false
    /// `play()` arrivals — `isPlaying` alone can't tell "never played"
    /// from "played then stopped".
    private(set) var playCount = 0
    func loadAudioFile(named: String, autoplay: Bool) { loadedFiles.append(named) }
    func play()    { playCount += 1; isPlaying = true }
    func stop()    { isPlaying = false }
    func restart() {}
    func suspendForLifecycle()        { isPlaying = false }
    func resumeAfterLifecycle()       {}
    func cancelPendingLifecycleWork() {}
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) { setAdaptiveCount += 1 }
    func setSpatialPitch(cents: Float) { spatialPitches.append(cents) }
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
            phonemeAudioFiles: ["\(name)_phoneme1.mp3"]
        )
    }

    /// An asset with name audio but NO phoneme recording — the H5/P6
    /// coverage gap.
    private func assetNoPhoneme(_ name: String = "Q") -> LetterAsset {
        LetterAsset(
            id: name, name: name,
            audioFiles: ["\(name)_name.mp3"],
            strokes: LetterStrokes(letter: name, checkpointRadius: 0.1, strokes: []),
            phonemeAudioFiles: []
        )
    }

    private func makeVM(arm: PilotAudioCondition,
                        phonemeToggle: Bool,
                        studyMode: Bool = false,
                        audio: AudioControlling? = nil,
                        thesisCondition: ThesisCondition? = nil) -> TracingViewModel {
        var deps = TracingDependencies.stub
        deps.audioCondition = arm
        deps.enablePhonemeMode = phonemeToggle
        // Seeded via deps so the VM's didSet (UserDefaults write) never
        // fires — keeps the test from polluting global state.
        deps.studyMode = studyMode
        if let audio { deps.audio = audio }
        if let thesisCondition { deps.thesisCondition = thesisCondition }
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

    @Test("spatial arm → the shared carrier tone, never per-letter audio")
    func spatial_returnsCarrier() {
        let vm = makeVM(arm: .spatial, phonemeToggle: true)
        #expect(vm.activeAudioFiles(for: asset()) == [SpatialSonification.carrierToneFile])
    }

    @Test("spatial arm ignores letter assets entirely (no name-audio leak)")
    func spatial_letterIndependent() {
        let vm = makeVM(arm: .spatial, phonemeToggle: false)
        // Same carrier whether the letter is asset-rich or bare.
        #expect(vm.activeAudioFiles(for: asset()) == [SpatialSonification.carrierToneFile])
        #expect(vm.activeAudioFiles(for: assetNoPhoneme()) == [SpatialSonification.carrierToneFile])
    }

    @Test("silent arm → [] regardless of toggle or bundled files")
    func silent_returnsEmpty() {
        let vmA = makeVM(arm: .silent, phonemeToggle: true)
        let vmB = makeVM(arm: .silent, phonemeToggle: false)
        #expect(vmA.activeAudioFiles(for: asset()).isEmpty)
        #expect(vmB.activeAudioFiles(for: asset()).isEmpty)
    }

    // MARK: - H2.1 study-device phoneme force

    @Test("studyMode ON + phoneme arm + phoneme files → phonemes regardless of toggle")
    func studyMode_forcesPhonemes_bothToggleStates() {
        for toggle in [true, false] {
            let vm = makeVM(arm: .phoneme, phonemeToggle: toggle, studyMode: true)
            #expect(vm.activeAudioFiles(for: asset()) == ["A_phoneme1.mp3"],
                    "studyMode must force phonemes even with enablePhonemeMode=\(toggle)")
        }
    }

    @Test("studyMode ON + phoneme arm + NO phoneme files → NO audio at all (fail closed, never name/word audio)")
    func studyMode_phonemelessLetter_failsClosed() {
        // Ruling C3-6 (2026-09-04): a letter with no phoneme recording
        // must not degrade to the name/word population — for M the first
        // name file is the word "Meer". Nothing is loaded, and the
        // session is refused (next test).
        let vm = makeVM(arm: .phoneme, phonemeToggle: true, studyMode: true)
        #expect(vm.activeAudioFiles(for: assetNoPhoneme()).isEmpty)
    }

    @Test("studyMode ON + phoneme arm: a study letter without recordings refuses the whole session")
    func studyMode_phonemelessStudyLetter_refusesSession() {
        let audio = RecordingAudio()
        let vm = makeVM(arm: .phoneme, phonemeToggle: true, studyMode: true, audio: audio)
        // Fixture letter A carries a phoneme take → no failure.
        #expect(vm.studyPreconditionFailure == nil, "the fixture's own phoneme take must satisfy the precondition")
        // Swap in a phoneme-less A (a study letter) → hard stop.
        let base = vm.letters[0]
        vm.letters = [LetterAsset(id: base.id, name: base.name, audioFiles: base.audioFiles,
                                  strokes: base.strokes, phonemeAudioFiles: [])]
        #expect(vm.studyPreconditionFailure?.contains("A") == true,
                "a phoneme-arm study session without A's recording must be refused with the letter named")
        vm.phaseController.resume(at: .guided)
        let loadsBefore = audio.loadedFiles.count
        driveTouch(vm)
        #expect(vm.debugIsSingleTouchInteractionActive == false, "no trace may start while the precondition fails")
        #expect(audio.loadedFiles.count == loadsBefore && audio.setAdaptiveCount == 0,
                "a refused session must not touch the engine")
    }

    @Test("the precondition is phoneme-arm-and-study-mode specific",
          arguments: [(PilotAudioCondition.silent, true), (.spatial, true), (.phoneme, false)])
    func precondition_scope(arm: PilotAudioCondition, studyMode: Bool) {
        let vm = makeVM(arm: arm, phonemeToggle: true, studyMode: studyMode)
        let base = vm.letters[0]
        vm.letters = [LetterAsset(id: base.id, name: base.name, audioFiles: base.audioFiles,
                                  strokes: base.strokes, phonemeAudioFiles: [])]
        #expect(vm.studyPreconditionFailure == nil, "\(arm) / studyMode=\(studyMode) must not be blocked by missing phonemes")
    }

    @Test("studyMode OFF + phoneme arm → existing toggle behavior preserved")
    func studyMode_off_preservesToggle() {
        let on  = makeVM(arm: .phoneme, phonemeToggle: true,  studyMode: false)
        let off = makeVM(arm: .phoneme, phonemeToggle: false, studyMode: false)
        #expect(on.activeAudioFiles(for: asset())  == ["A_phoneme1.mp3"])
        #expect(off.activeAudioFiles(for: asset()) == ["A_name.mp3"])
    }

    @Test("studyMode does not override the silent or spatial arms")
    func studyMode_doesNotLeakAcrossArms() {
        let silent  = makeVM(arm: .silent, phonemeToggle: true, studyMode: true)
        let spatial = makeVM(arm: .spatial, phonemeToggle: true, studyMode: true)
        #expect(silent.activeAudioFiles(for: asset()).isEmpty)
        #expect(spatial.activeAudioFiles(for: asset()) == [SpatialSonification.carrierToneFile])
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
        // Since 2026-09-04 (C3-2) the injected engine is not merely
        // unused for the silent arm — it is replaced by a no-op conformer
        // at the seam, so no path can reach a real engine at all.
        #expect(vm.audio is SilentAudio)
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

    // MARK: - Spatial pitch drive (Y → cents; the arm's defining coupling)

    /// The spatial arm must drive pitch from pen Y on the per-tick path.
    /// Canvas is 400×400; a horizontal drag at y=100 (normalized 0.25)
    /// must emit +600 cents on every tick (220–880 Hz linear-in-cents,
    /// top = high, carrier at 440 Hz).
    @Test("spatial arm: a touch drives pitch from pen Y")
    func spatial_touchDrivesPitch() {
        let audio = RecordingAudio()
        let vm = TracingViewModel(.stub.with(audioCondition: .spatial).with(audio: audio))
        driveTouch(vm, y: 100)
        #expect(!audio.spatialPitches.isEmpty,
                "spatial arm must drive setSpatialPitch on the touch path")
        #expect(audio.spatialPitches.allSatisfy { abs($0 - 600) < 0.001 },
                "y=0.25 must map to +600 cents — got \(audio.spatialPitches)")
    }

    /// Matching discipline (reframed): the phoneme arm is matched on
    /// rate + pan but must NEVER drive pitch — pitch-drive is the spatial
    /// arm's treatment, and a stray pitch call would contaminate the
    /// phoneme arm's stimulus.
    @Test("phoneme arm: a touch never drives pitch")
    func phoneme_neverDrivesPitch() {
        let audio = RecordingAudio()
        let vm = TracingViewModel(.stub.with(audioCondition: .phoneme).with(audio: audio))
        driveTouch(vm)
        #expect(audio.setAdaptiveCount > 0)                 // coupling ran…
        #expect(audio.spatialPitches.isEmpty,               // …but no pitch
                "phoneme arm must not drive pitch — got \(audio.spatialPitches)")
    }

    @Test("silent arm: a touch never drives pitch either")
    func silent_neverDrivesPitch() {
        let audio = RecordingAudio()
        let vm = TracingViewModel(.stub.with(audioCondition: .silent).with(audio: audio))
        driveTouch(vm)
        #expect(audio.spatialPitches.isEmpty)
    }

    // MARK: - Pitch mapping (pure)

    @Test("Y→cents mapping: linear-in-cents across 220–880 Hz, top = high")
    func pitchMapping_endpointsAndLinearity() {
        #expect(SpatialSonification.pitchCents(forNormalizedY: 0.0)  ==  1200)  // top    = 880 Hz
        #expect(SpatialSonification.pitchCents(forNormalizedY: 0.5)  ==     0)  // middle = 440 Hz
        #expect(SpatialSonification.pitchCents(forNormalizedY: 1.0)  == -1200)  // bottom = 220 Hz
        #expect(SpatialSonification.pitchCents(forNormalizedY: 0.25) ==   600)  // linear in cents
        #expect(SpatialSonification.pitchCents(forNormalizedY: 0.75) ==  -600)
    }

    @Test("Y→cents mapping clamps out-of-canvas input")
    func pitchMapping_clamps() {
        #expect(SpatialSonification.pitchCents(forNormalizedY: -0.5) ==  1200)
        #expect(SpatialSonification.pitchCents(forNormalizedY:  1.5) == -1200)
    }

    // MARK: - Sound-off production (study mode, freeWrite / post-test)

    @Test("study mode, freeWrite: sound arms drive no coupling and never reach play()",
          arguments: [PilotAudioCondition.phoneme, .spatial])
    func studyFreeWrite_isSoundOff(arm: PilotAudioCondition) async {
        let audio = RecordingAudio()
        let vm = makeVM(arm: arm, phonemeToggle: true, studyMode: true, audio: audio)
        vm.phaseController.resume(at: .freeWrite)
        driveTouch(vm)
        // Drain the playback debounce so a deferred `.active` — the path
        // the guided positive control below proves is live for the same
        // drive — has had its chance to fire before asserting.
        await vm.awaitPlaybackDebounce()
        #expect(audio.setAdaptiveCount == 0)
        #expect(audio.spatialPitches.isEmpty)
        #expect(audio.playCount == 0, "the arm's sound must never start during study free production")
        #expect(audio.isPlaying == false)
    }

    @Test("study mode, guided: the same drive DOES couple and DOES play (gate is phase-specific)",
          arguments: [PilotAudioCondition.phoneme, .spatial])
    func studyGuided_stillCouples(arm: PilotAudioCondition) async {
        let audio = RecordingAudio()
        let vm = makeVM(arm: arm, phonemeToggle: true, studyMode: true, audio: audio)
        vm.phaseController.resume(at: .guided)
        driveTouch(vm)
        await vm.awaitPlaybackDebounce()
        #expect(audio.setAdaptiveCount > 0)
        // Positive control for the freeWrite test above: its
        // `playCount == 0` means nothing unless this identical drive
        // reaches `play()` when the gate is not in force.
        #expect(audio.playCount > 0, "the guided drive must reach play() — otherwise the freeWrite sound-off assertion is vacuous")
    }

    @Test("non-study freeWrite keeps the phonemic anchor (gate is study-mode only)")
    func nonStudyFreeWrite_stillCouples() {
        let audio = RecordingAudio()
        let vm = makeVM(arm: .phoneme, phonemeToggle: true, studyMode: false, audio: audio,
                        thesisCondition: .threePhase)
        vm.phaseController.resume(at: .freeWrite)
        #expect(vm.phaseController.currentPhase == .freeWrite,
                "the fixture's guidedOnly arm made resume(at: .freeWrite) a no-op — this asserted guided, not freeWrite (audit 2026-09-06)")
        driveTouch(vm)
        #expect(audio.setAdaptiveCount > 0)
    }

    // The three non-touch entries that reach `loadAudioFile(autoplay:
    // true)` — Pencil squeeze / VoiceOver action (`replayAudio`) and the
    // two-finger canvas swipe (`next`/`previousAudioVariant`) — bypass
    // the coupling gate entirely and would loop the arm's sound in any
    // phase, freeWrite and post-test included. Under studyMode they must
    // be inert in every phase; the arm's sound reaches the child only via
    // the coupling and the D9 demonstration.
    @Test("study mode: replay and take-cycling are inert in every phase",
          arguments: [LearningPhase.observe, .guided, .freeWrite])
    func study_replayAndVariantCycling_areInert(phase: LearningPhase) {
        let audio = RecordingAudio()
        let vm = makeVM(arm: .phoneme, phonemeToggle: true, studyMode: true, audio: audio)
        vm.phaseController.resume(at: phase)
        let loadsBefore = audio.loadedFiles.count
        let indexBefore = vm.audioIndex
        vm.replayAudio()
        vm.nextAudioVariant()
        vm.previousAudioVariant()
        #expect(audio.loadedFiles.count == loadsBefore,
                "study sessions must add no sound exposure outside the trace coupling and the D9 demo (phase \(phase))")
        #expect(vm.audioIndex == indexBefore, "the take that plays must stay deterministic in a study session")
    }

    @Test("non-study: replay still loads the arm's file (gate is study-mode only)")
    func nonStudy_replayStillLoads() {
        let audio = RecordingAudio()
        let vm = makeVM(arm: .phoneme, phonemeToggle: true, studyMode: false, audio: audio)
        let loadsBefore = audio.loadedFiles.count
        vm.replayAudio()
        #expect(audio.loadedFiles.count == loadsBefore + 1)
    }

    /// Mirrors EndToEndTracingSessionTests.simulateFastTouch: a fast
    /// in-bounds drag so updateAdaptivePlayback is reached. Horizontal
    /// drag at a fixed `y` so the pitch expectation is single-valued.
    private func driveTouch(_ vm: TracingViewModel, y: CGFloat = 200) {
        let t0: CFTimeInterval = 1000
        vm.beginTouch(at: CGPoint(x: 50, y: y), t: t0)
        var t = t0
        var p = CGPoint(x: 50, y: y)
        for _ in 0..<15 { t += 0.001; p.x += 10; vm.updateTouch(at: p, t: t, canvasSize: canvas) }
    }
}
