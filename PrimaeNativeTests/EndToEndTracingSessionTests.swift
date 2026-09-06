import Testing
import Foundation
import QuartzCore
import CoreGraphics
@testable import PrimaeNative

@MainActor
fileprivate final class RecordingAudio: AudioControlling {
    var initializationError: String? { nil }
    enum Event: Equatable {
        case load(String), play, stop, suspend, resume, cancelPending, setAdaptive(speed: Float)
    }
    private(set) var events: [Event] = []
    private(set) var isPlaying = false
    func loadAudioFile(named: String, autoplay: Bool) { events.append(.load(named)) }
    func play()    { events.append(.play);    isPlaying = true  }
    func stop()    { events.append(.stop);    isPlaying = false }
    func restart() { events.append(.play) }
    func suspendForLifecycle()        { events.append(.suspend);       isPlaying = false }
    func resumeAfterLifecycle()       { events.append(.resume) }
    func cancelPendingLifecycleWork() { events.append(.cancelPending) }
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) { events.append(.setAdaptive(speed: speed)) }
    func hasEvent(_ e: Event) -> Bool { events.contains(e) }
    func reset() { events.removeAll(); isPlaying = false }
}

@Suite(.serialized) @MainActor struct EndToEndTracingSessionTests {

    fileprivate let audio: RecordingAudio
    fileprivate let vm: TracingViewModel
    let canvas = CGSize(width: 400, height: 400)

    init() {
        audio = RecordingAudio()
        vm = TracingViewModel(.stub.with(audio: audio))
    }

    // MARK: - Initial state

    @Test func initialState() {
        #expect(!vm.isPlaying)
        #expect(vm.progress == 0.0)
        #expect(!vm.currentLetterName.isEmpty)
        #expect(vm.currentLetterName == vm.currentLetterName.uppercased())
    }

    // MARK: - Audio load on init

    @Test func audioLoaded_onInit() {
        let loadEvents = audio.events.filter { if case .load = $0 { return true }; return false }
        #expect(!loadEvents.isEmpty, "Audio loadAudioFile must be called during init")
    }

    // MARK: - Fast touch triggers play after debounce

    @Test func fastTouch_triggersPlay() async {
        simulateFastTouch(t0: 1000)
        // An active sample plays synchronously. The pending transition is
        // the stall timeout (AE-2b, 2026-09-06): awaiting it is "the pen
        // stopped", after which the sound is off by design.
        #expect(audio.hasEvent(.play), "Fast touch must trigger audio.play()")
        #expect(vm.isPlaying, "playing right after the fast touch")
        await vm.awaitPlaybackDebounce()
        #expect(!vm.isPlaying, "a pen that stops falls silent (stall timeout)")
    }

    // MARK: - endTouch stops audio

    @Test func endTouch_stopsAudio() async {
        simulateFastTouch(t0: 1000)
        try? await Task.sleep(for: .milliseconds(150))
        audio.reset()
        vm.endTouch()
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        #expect(audio.hasEvent(.stop))
        #expect(!vm.isPlaying)
    }

    // MARK: - Adaptive playback during touch

    @Test func adaptivePlayback_calledDuringTouch() {
        simulateFastTouch(t0: 1000)
        let speeds = audio.events.compactMap { e -> Float? in
            if case .setAdaptive(let s) = e { return s }; return nil
        }
        #expect(!speeds.isEmpty, "setAdaptivePlayback must be called during touch")
        for speed in speeds {
            #expect(speed >= 0.5)
            #expect(speed <= 2.0)
        }
    }

    // MARK: - Full session

    @Test func fullSession_progressReachesOne() {
        traceReferencePolyline()
        #expect(vm.progress == 1.0, "tracing the reference polyline checkpoint by checkpoint must complete the letter")
    }

    @Test func fullSession_isPlayingFalseAfterCompletion() {
        traceReferencePolyline()
        #expect(vm.progress == 1.0, "precondition: the letter must actually complete for the assertion below to mean anything")
        #expect(!vm.isPlaying)
    }

    // MARK: - resetLetter restores initial state

    @Test func resetLetter_restoresInitialState() {
        traceReferencePolyline()
        #expect(vm.progress == 1.0, "precondition: complete the letter before resetting it")
        vm.resetLetter()
        #expect(vm.progress == 0.0)
        #expect(!vm.isPlaying)
        #expect(audio.hasEvent(.stop))
    }

    // MARK: - Accessibility strings throughout session

    @Test func accessibilityStrings_validThroughoutSession() {
        assertAccessibilityStringsValid(label: "initial")
        simulateFastTouch(t0: 1000)
        assertAccessibilityStringsValid(label: "during touch")
        vm.endTouch()
        assertAccessibilityStringsValid(label: "after endTouch")
        vm.resetLetter()
        assertAccessibilityStringsValid(label: "after reset")
    }

    // MARK: - Full bg/fg lifecycle around a session

    @Test func lifecycleAroundSession() async {
        simulateFastTouch(t0: 1000)
        try? await Task.sleep(for: .milliseconds(150))
        await vm.appDidEnterBackground()
        #expect(audio.hasEvent(.suspend))
        #expect(!vm.isPlaying)
        audio.reset()
        vm.appDidBecomeActive()
        #expect(audio.hasEvent(.resume))
        assertAccessibilityStringsValid(label: "after foreground return")
    }

    // MARK: - nextLetter changes state cleanly

    @Test func selectLetter_changesCurrentLetter() {
        vm.nextLetter()
        #expect(!vm.currentLetterName.isEmpty)
        #expect(vm.currentLetterName == vm.currentLetterName.uppercased())
        #expect(vm.progress == 0.0)
    }

    // MARK: - Stroke proximity

    @Test func stdDrag_checkpointProximity_progressPositive() {
        simulateFastTouch(t0: 1000)
        #expect(vm.progress > 0, "Fast touch through checkpoint row must advance stroke progress")
    }

    @Test func resetThenDrag_strokeProgress_recovers() {
        simulateFastTouch(t0: 1000)
        vm.resetLetter()
        #expect(vm.progress == 0)
        simulateFastTouch(t0: 2000)
        #expect(vm.progress > 0, "Progress must recover after reset when drag hits checkpoints")
    }

    // MARK: - Helpers

    private func simulateFastTouch(t0: CFTimeInterval) {
        vm.beginTouch(at: CGPoint(x: 50, y: 200), t: t0)
        var t = t0; var p = CGPoint(x: 50, y: 200)
        for _ in 0..<15 { t += 0.001; p.x += 10; vm.updateTouch(at: p, t: t, canvasSize: canvas) }
    }

    /// Drives one touch exactly along the tracker's loaded reference
    /// polyline — every update lands on the next checkpoint — so the
    /// letter completes regardless of how the fixture was mapped onto
    /// the canvas. Replaces a raster scan whose completion was never
    /// asserted: three tests here used to `return` silently when the
    /// scan missed, and no `progress == 1.0` assertion in the tree
    /// could then fail (2026-09-04). Callers assert `vm.progress == 1.0`.
    private func traceReferencePolyline() {
        // Set the size FIRST — the dispatcher re-maps checkpoints when
        // the size it is handed differs from `vm.canvasSize`.
        vm.canvasSize = canvas
        let cps = vm.strokeTracker.definition?.strokes.flatMap(\.checkpoints) ?? []
        var t: CFTimeInterval = 2000.0
        let first = cps.first.map { CGPoint(x: $0.x * canvas.width, y: $0.y * canvas.height) } ?? .zero
        vm.beginTouch(at: first, t: t)
        for cp in cps {
            t += 0.01
            vm.updateTouch(at: CGPoint(x: cp.x * canvas.width, y: cp.y * canvas.height),
                           t: t, canvasSize: canvas)
        }
    }

    private func assertAccessibilityStringsValid(label: String) {
        let pct = Int(vm.progress * 100)
        #expect(pct >= 0,   "[\(label)] pct < 0")
        #expect(pct <= 100, "[\(label)] pct > 100")
        #expect(!vm.currentLetterName.isEmpty, "[\(label)] letter name empty")
        #expect(!vm.progress.isNaN,            "[\(label)] progress NaN")
        #expect(!vm.progress.isInfinite,        "[\(label)] progress infinite")
        #expect(!(vm.isPlaying ? "Audio is currently playing" : "Audio is currently paused").isEmpty)
    }
}
