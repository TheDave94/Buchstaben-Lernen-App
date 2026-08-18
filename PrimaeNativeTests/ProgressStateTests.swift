// VM progress-state invariants: finiteness, domain, reset, and the
// letter-name contract.
//
// Formerly `AccessibilityContractTests`, which was neither. Nine of its
// thirteen tests built ENGLISH strings locally and asserted against
// them — "0 percent complete", "Audio is currently paused" — none of
// which the app produces. `grep` for those literals across
// PrimaeNative/ returns nothing; the real accessibility value is
// `TracingViewModel.accessibilityCanvasValue` and it is German
// ("Nicht begonnen" / "Fertig" / "N Prozent fertig").
//
// Three of those tests could not fail:
//   - one asserted a string it had just built carried the suffix it had
//     just written into it;
//   - one wrote `let hint = vm.isPlaying ? "…playing" : "…paused"` and
//     then asserted `hint` contained "paused", one line after asserting
//     `!vm.isPlaying`;
//   - the single test that did call the real API asserted it was
//     != "Not started", an English string the German property can never
//     return.
//
// The accessibility surface is genuinely covered by
// `VoiceOverAccessibilityTests`, which exercises the real properties
// including both clamps and the 0 / 1 / 50 / 99 / 100 boundaries.
//
// What survived the deletion is what was always real: four assertions
// about VM progress state, which had nothing to do with accessibility
// and now say so.

import Testing
import CoreGraphics
@testable import PrimaeNative

@MainActor
fileprivate final class MockProgressStateAudio: AudioControlling {
    var initializationError: String? { nil }
    func loadAudioFile(named: String, autoplay: Bool) {}
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) {}
    func play() {}
    func stop() {}
    func restart() {}
    func suspendForLifecycle() {}
    func resumeAfterLifecycle() {}
    func cancelPendingLifecycleWork() {}
}

@Suite(.serialized) @MainActor struct ProgressStateTests {

    fileprivate let audio: MockProgressStateAudio
    fileprivate let vm: TracingViewModel

    init() {
        audio = MockProgressStateAudio()
        vm = TracingViewModel(.stub.with(audio: audio))
    }

    /// Drag the standard test path across the fixture letter's single
    /// horizontal stroke (y = 0.5 on a 400×400 canvas).
    private func standardDrag() {
        vm.beginTouch(at: CGPoint(x: 100, y: 200), t: 1000)
        var t = 1000.0
        var p = CGPoint(x: 100, y: 200)
        for _ in 0..<10 {
            t += 0.001
            p.x += 10
            vm.updateTouch(at: p, t: t, canvasSize: CGSize(width: 400, height: 400))
        }
    }

    // MARK: - Letter identity

    @Test func currentLetterName_isNonEmpty() {
        #expect(!vm.currentLetterName.isEmpty)
    }

    @Test func currentLetterName_isUppercase() {
        let name = vm.currentLetterName
        #expect(name == name.uppercased())
    }

    // MARK: - Progress domain

    @Test func progress_isFinite() {
        #expect(!vm.progress.isNaN)
        #expect(!vm.progress.isInfinite)
    }

    @Test func afterStdDrag_progressIsPositive() {
        standardDrag()
        #expect(vm.progress > 0)
    }

    @Test func afterReset_progressReturnsToZero() {
        standardDrag()
        #expect(vm.progress > 0, "precondition: the drag must move progress off zero")
        vm.resetLetter()
        #expect(vm.progress == 0)
    }
}
