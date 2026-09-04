import Testing
import Foundation
import QuartzCore
import CoreGraphics
@testable import PrimaeNative

@MainActor
fileprivate final class MockAudio: AudioControlling {
    var initializationError: String? { nil }
    private(set) var loadedFiles: [String] = []
    private(set) var playCount  = 0
    private(set) var stopCount  = 0
    private(set) var suspendForLifecycleCount  = 0
    private(set) var resumeAfterLifecycleCount = 0
    private(set) var cancelPendingLifecycleWorkCount = 0
    private(set) var setAdaptivePlaybackCount  = 0
    func loadAudioFile(named fileName: String, autoplay: Bool) { loadedFiles.append(fileName) }
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) { setAdaptivePlaybackCount += 1 }
    func play()    { playCount  += 1 }
    func stop()    { stopCount  += 1 }
    func restart() {}
    func suspendForLifecycle()        { suspendForLifecycleCount  += 1 }
    func resumeAfterLifecycle()       { resumeAfterLifecycleCount += 1 }
    func cancelPendingLifecycleWork() { cancelPendingLifecycleWorkCount += 1 }
}

@MainActor
@discardableResult
private func fastDrag(vm: TracingViewModel, audio: MockAudio,
    canvasSize: CGSize = CGSize(width: 400, height: 400),
    from: CGPoint = CGPoint(x: 100, y: 200), count: Int = 10,
    startTime: CFTimeInterval = 1000.0) -> CFTimeInterval {
    vm.beginTouch(at: from, t: startTime)
    var t = startTime; var p = from
    for _ in 0..<count { t += 0.001; p.x += 10; vm.updateTouch(at: p, t: t, canvasSize: canvasSize) }
    return t
}

@MainActor
@discardableResult
private func slowDrag(vm: TracingViewModel,
    canvasSize: CGSize = CGSize(width: 400, height: 400),
    from: CGPoint = CGPoint(x: 100, y: 200), count: Int = 10,
    startTime: CFTimeInterval = 1000.0) -> CFTimeInterval {
    vm.beginTouch(at: from, t: startTime)
    var t = startTime; var p = from
    for _ in 0..<count { t += 1.0; p.x += 1; vm.updateTouch(at: p, t: t, canvasSize: canvasSize) }
    return t
}

@Suite(.serialized) @MainActor struct TracingViewModelTests {

    fileprivate let audio: MockAudio
    fileprivate let vm: TracingViewModel
    /// Captured during VM init via the deps.makePlaybackController factory.
    /// Lets each test `await playback.pendingTransition?.value` to drain the
    /// debounced idle/active transition deterministically — no wall-clock
    /// sleeps. The injected sleeper resumes immediately so the transition
    /// task settles on the next runloop tick.
    fileprivate let playback: PlaybackController
    /// Same idea for the toast / completion HUD auto-clear timers.
    fileprivate let messages: TransientMessagePresenter

    init() {
        let mockAudio = MockAudio()
        let pcBox = Box<PlaybackController?>(nil)
        let mpBox = Box<TransientMessagePresenter?>(nil)
        var deps = TracingDependencies.stub
            .with(audio: mockAudio)
            .with(thesisCondition: .guidedOnly)
        deps.makePlaybackController = { audio, cb in
            let pc = PlaybackController(audio: audio, sleep: { _ in }, onIsPlayingChanged: cb)
            pcBox.value = pc
            return pc
        }
        deps.makeMessagePresenter = {
            let mp = TransientMessagePresenter(sleep: { _ in })
            mpBox.value = mp
            return mp
        }
        let model = TracingViewModel(deps)

        self.audio    = mockAudio
        self.vm       = model
        self.playback = pcBox.value!
        self.messages = mpBox.value!
    }

    /// Drain every async tail the VM might have spawned in response to the
    /// last interaction: the playback debounce task, the toast auto-clear
    /// task, and the completion HUD auto-clear task. Cheap because every
    /// sleeper here was injected to resume instantly.
    private func drainAsyncWork() async {
        await playback.pendingTransition?.value
        await messages.toastTask?.value
        await messages.completionTask?.value
    }

    @Test func slowVelocity_doesNotTriggerPlay() async {
        let playBefore = audio.playCount
        slowDrag(vm: vm)
        await drainAsyncWork()
        #expect(audio.playCount == playBefore)
        #expect(!vm.isPlaying)
    }
    @Test func fastVelocity_triggersPlayAfterDebounce() async {
        let playBefore = audio.playCount
        fastDrag(vm: vm, audio: audio)
        await drainAsyncWork()
        #expect(audio.playCount > playBefore)
        #expect(vm.isPlaying)
    }
    @Test func endTouch_stopsPlayback() async {
        fastDrag(vm: vm, audio: audio)
        await drainAsyncWork()
        let stopBefore = audio.stopCount
        vm.endTouch()
        await drainAsyncWork()
        #expect(audio.stopCount > stopBefore)
        #expect(!vm.isPlaying)
    }
    @Test func endTouch_withoutPriorTouch_doesNotCrash() {
        vm.endTouch()
        #expect(!vm.isPlaying)
    }
    @Test func appDidEnterBackground_suspendsClearsState() async {
        fastDrag(vm: vm, audio: audio)
        await drainAsyncWork()
        let suspendBefore = audio.suspendForLifecycleCount
        let stopBefore = audio.stopCount
        await vm.appDidEnterBackground()
        #expect(audio.suspendForLifecycleCount == suspendBefore + 1)
        #expect(audio.stopCount > stopBefore)
        #expect(!vm.isPlaying)
    }
    @Test func appDidBecomeActive_withResumeIntent_resumesAudio() async {
        fastDrag(vm: vm, audio: audio)
        await drainAsyncWork()
        await vm.appDidEnterBackground()
        let resumeBefore = audio.resumeAfterLifecycleCount
        vm.appDidBecomeActive()
        #expect(audio.resumeAfterLifecycleCount == resumeBefore + 1)
    }
    @Test func appDidBecomeActive_withoutResumeIntent_doesNotForcePlay() async {
        fastDrag(vm: vm, audio: audio)
        await drainAsyncWork()
        vm.endTouch(); await vm.appDidEnterBackground()
        let playBefore = audio.playCount
        vm.appDidBecomeActive()
        await drainAsyncWork()
        #expect(audio.playCount == playBefore)
    }
    @Test func strokeCompletion_forcesIdleAndSetsComplete() async {
        // Drive exactly along the loaded reference polyline so completion
        // is guaranteed by construction and asserted, not skipped: the
        // previous raster scan `return`ed silently when it missed, so this
        // test could never fail (2026-09-04).
        let canvas = CGSize(width: 400, height: 400)
        vm.canvasSize = canvas
        let cps = vm.strokeTracker.definition?.strokes.flatMap(\.checkpoints) ?? []
        let first = cps.first.map { CGPoint(x: $0.x * canvas.width, y: $0.y * canvas.height) } ?? .zero
        vm.beginTouch(at: first, t: 1000.0)
        var t: CFTimeInterval = 1000.0
        for cp in cps {
            t += 0.01
            vm.updateTouch(at: CGPoint(x: cp.x * canvas.width, y: cp.y * canvas.height), t: t, canvasSize: canvas)
        }
        await drainAsyncWork()
        #expect(vm.progress == 1.0, "tracing every checkpoint in order must complete the letter")
        #expect(!vm.isPlaying)
    }
    @Test func resetLetter_clearsProgressAndStops() async {
        fastDrag(vm: vm, audio: audio)
        await drainAsyncWork()
        let stopBefore = audio.stopCount
        vm.resetLetter()
        #expect(vm.progress == 0.0)
        #expect(!vm.isPlaying)
        #expect(audio.stopCount > stopBefore)
    }
    @Test func updateTouch_callsSetAdaptivePlayback() {
        let countBefore = audio.setAdaptivePlaybackCount
        fastDrag(vm: vm, audio: audio, count: 5)
        #expect(audio.setAdaptivePlaybackCount > countBefore)
    }
    @Test func rapidBgFgChurn_neverLeavesPlayingTrue() async {
        fastDrag(vm: vm, audio: audio)
        await drainAsyncWork()
        for _ in 0..<10 { await vm.appDidEnterBackground(); vm.appDidBecomeActive() }
        await vm.appDidEnterBackground()
        await drainAsyncWork()
        #expect(!vm.isPlaying)
    }
    @Test func nextLetter_resetsShowGhostToFalse() {
        vm.toggleGhost(); #expect(vm.showGhost)
        vm.nextLetter()
        #expect(!vm.showGhost)
    }
    @Test func previousLetter_resetsShowGhostToFalse() {
        vm.nextLetter(); vm.toggleGhost(); #expect(vm.showGhost)
        vm.previousLetter()
        #expect(!vm.showGhost)
    }
    @Test func resetLetter_doesNotChangeShowGhost() {
        vm.toggleGhost(); vm.resetLetter()
        #expect(vm.showGhost)
    }
    @Test func tracingViewModel_doesNotRetainSelf() async {
        // ARC release timing is independent of the controller debounces — no
        // injected sleeper helps here. Keep a small wall-clock buffer so any
        // in-flight Task that briefly retains the VM has time to settle
        // before we read the weak reference.
        weak var weakVM: TracingViewModel?
        await MainActor.run {
            let localVM = TracingViewModel(.stub)
            weakVM = localVM
            localVM.appDidBecomeActive()
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(weakVM == nil)
    }

    // MARK: - Stroke proximity

    @Test func stdDrag_checkpointProximity_progressGtZero() {
        fastDrag(vm: vm, audio: audio)
        #expect(vm.progress > 0, "Standard drag through checkpoint row must advance stroke progress")
    }

    @Test func stdDrag_checkpointHits_progressNeverDecreases() {
        let canvas = CGSize(width: 400, height: 400)
        var last: CGFloat = -1
        vm.beginTouch(at: CGPoint(x: 100, y: 200), t: 1000)
        var t = 1000.0; var p = CGPoint(x: 100, y: 200)
        for _ in 0..<10 {
            t += 0.001; p.x += 10
            vm.updateTouch(at: p, t: t, canvasSize: canvas)
            #expect(vm.progress >= last)
            last = vm.progress
        }
        #expect(last > 0)
    }

    // MARK: - progressStore forwarders

    /// `vm.allProgress` and `vm.progress(for:)` replaced direct
    /// `vm.progressStore.*` access in 8 view sites. `progress(for:)`
    /// returns the protocol default for a letter never seen, and a get
    /// on an unknown key must not insert into the underlying store —
    /// `allProgress.keys` stays stable across reads.
    @Test func progressForwarders_passThroughAndReadOnly() {
        let beforeKeys = Set(vm.allProgress.keys)
        let unknown = vm.progress(for: "ZZZZ-never-a-letter")
        // Default-initialised LetterProgress for an unknown key.
        #expect(unknown.completionCount == 0)
        #expect(unknown.bestAccuracy == 0.0)
        #expect(unknown.lastCompletedAt == nil)
        let afterKeys = Set(vm.allProgress.keys)
        #expect(beforeKeys == afterKeys,
                "progress(for:) must be read-only — getter on an unknown key must not mutate allProgress")
    }

    // MARK: - Multi-cell active-frame forwarder

    /// `vm.multiCellActiveFrame` returns nil for single-cell sessions
    /// and the active cell's frame for multi-cell. DirectPhaseDotsOverlay
    /// reads this to map glyph coordinates into the active cell instead
    /// of the canvas origin.
    @Test func multiCellActiveFrame_isNilForSingleLetter() {
        // Default VM init loads a single-letter session — frame should
        // be nil so the overlay falls back to full-canvas geometry.
        #expect(vm.multiCellActiveFrame == nil)
    }

    // MARK: - Active-time accumulator

    /// Backgrounding pauses the session-duration clock. The wall clock
    /// keeps ticking while iOS suspends the app (mach_absolute_time
    /// stops only in deep device sleep), so a "5-minute" session would
    /// otherwise silently include the backgrounded interval. Asserts
    /// the accumulator pauses on background and resumes on foreground.
    @Test func d1_activeTimeAccumulator_pausesOnBackground() async {
        // A live foreground window: letterLoadTime is set, accumulator is 0.
        #expect(vm.debugLetterLoadTime != nil)
        #expect(vm.debugLetterActiveTimeAccumulated == 0)
        await vm.appDidEnterBackground()
        // Backgrounding folds the live slice into the accumulator and
        // clears letterLoadTime so the clock stops ticking.
        #expect(vm.debugLetterLoadTime == nil)
        // `>= 0` held whether or not the fold-in ran — the accumulator
        // only ever adds elapsed time. `> 0` is what the docstring above
        // actually claims, and the live window was open (letterLoadTime
        // was non-nil) so the folded slice cannot be zero.
        #expect(vm.debugLetterActiveTimeAccumulated > 0)
        vm.appDidBecomeActive()
        // Foregrounding restarts the live window. Accumulator remains
        // at whatever it was (we don't reset it — it only resets on
        // letter load).
        #expect(vm.debugLetterLoadTime != nil)
    }
}
