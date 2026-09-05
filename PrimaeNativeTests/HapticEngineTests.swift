import Testing
import CoreGraphics
import QuartzCore
@testable import PrimaeNative

// MARK: - NullHapticEngine tests

@Suite @MainActor struct NullHapticEngineTests {

    @Test func prepare_incrementsCallCount() {
        let engine = NullHapticEngine()
        #expect(engine.prepareCallCount == 0)
        engine.prepare()
        #expect(engine.prepareCallCount == 1)
        engine.prepare()
        #expect(engine.prepareCallCount == 2)
    }

    @Test func fire_recordsEvent() {
        let engine = NullHapticEngine()
        engine.fire(.strokeBegan)
        #expect(engine.firedEvents == [.strokeBegan])
    }

    @Test func fire_allEventTypes_recorded() {
        let engine = NullHapticEngine()
        let all: [HapticEvent] = [.strokeBegan, .checkpointHit, .strokeCompleted, .letterCompleted, .offPath]
        all.forEach { engine.fire($0) }
        #expect(engine.firedEvents == all)
    }

    @Test func fire_order_preserved() {
        let engine = NullHapticEngine()
        engine.fire(.strokeBegan)
        engine.fire(.checkpointHit)
        engine.fire(.strokeCompleted)
        #expect(engine.firedEvents[0] == .strokeBegan)
        #expect(engine.firedEvents[1] == .checkpointHit)
        #expect(engine.firedEvents[2] == .strokeCompleted)
    }

    @Test func fire_multipleCheckpoints_allRecorded() {
        let engine = NullHapticEngine()
        for _ in 0..<5 { engine.fire(.checkpointHit) }
        #expect(engine.firedEvents.filter { $0 == .checkpointHit }.count == 5)
    }
}

// MARK: - HapticEvent equatability

@Suite struct HapticEventEquatabilityTests {

    @Test func allCases_pairwiseDistinct() {
        // Exhaustive pairwise distinctness. (The previous form asserted
        // `c == c` for each case, which cannot fail — 2026-09-04.)
        let cases: [HapticEvent] = [.strokeBegan, .checkpointHit, .strokeCompleted, .letterCompleted, .offPath]
        for (i, a) in cases.enumerated() {
            for (j, b) in cases.enumerated() where i != j {
                #expect(a != b, "\(a) and \(b) must be distinct haptic events")
            }
        }
    }

    @Test func differentCases_notEqual() {
        #expect(HapticEvent.strokeBegan != .strokeCompleted)
        #expect(HapticEvent.checkpointHit != .letterCompleted)
    }
}

// MARK: - TracingViewModel haptic integration tests

@MainActor
private final class TrackingMockAudio: AudioControlling {
    var initializationError: String? { nil }
    func loadAudioFile(named: String, autoplay: Bool) {}
    func play() {}
    func stop() {}
    func restart() {}
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) {}
    func suspendForLifecycle() {}
    func resumeAfterLifecycle() {}
    func cancelPendingLifecycleWork() {}
}

@Suite @MainActor struct TracingViewModelHapticTests {

    /// Every VM in this suite names its `studyMode` rather than inheriting
    /// the fixture's. These tests come in a matched pair — three asserting
    /// that haptics fire and one asserting they do not — so which side of
    /// the flag is under test is the entire point and must be stated, not
    /// resolved from a default that differs between the normal and study
    /// binaries.
    private func makeVM(studyMode: Bool, haptics: NullHapticEngine) -> TracingViewModel {
        TracingViewModel(
            .stub
                .with(audio: TrackingMockAudio())
                .with(haptics: haptics)
                .with(studyMode: studyMode)
                .with(thesisCondition: .guidedOnly)
        )
    }

    /// Drives a complete trace along the stub letter's single horizontal
    /// stroke, hitting all 50 checkpoints, and returns the resulting
    /// progress. Shared by the completion test and its silenced twin so
    /// both exercise byte-identical gestures.
    @discardableResult
    private func traceWholeLetter(_ vm: TracingViewModel) -> CGFloat {
        let canvasSize = CGSize(width: 400, height: 400)
        let w = canvasSize.width, h = canvasSize.height
        // Align the VM's canvasSize with the size used in updateTouch so the
        // updateTouch canvas-mismatch guard doesn't reload (and reset) checkpoints
        // on every call, which would prevent progress from accumulating.
        vm.canvasSize = canvasSize
        // Trace along the stub letter's horizontal stroke at y=0.5,
        // hitting all 50 checkpoints from x=0.0 to x=0.98.
        let checkpointSequence: [CGPoint] = (0..<50).map { i in
            CGPoint(x: CGFloat(i) * 0.02 * w, y: 0.50 * h)
        }
        var t = CACurrentMediaTime()
        vm.beginTouch(at: checkpointSequence[0], t: t)
        for pt in checkpointSequence {
            t += 0.05
            vm.updateTouch(at: pt, t: t, canvasSize: canvasSize)
        }
        return vm.progress
    }

    // MARK: - Haptics fire outside a study session

    @Test func beginTouch_firesStrokeBegan() {
        let haptics = NullHapticEngine()
        let vm = makeVM(studyMode: false, haptics: haptics)
        haptics.reset()
        vm.beginTouch(at: CGPoint(x: 100, y: 100), t: CACurrentMediaTime())
        #expect(haptics.firedEvents.contains(.strokeBegan),
                "Expected strokeBegan, got \(haptics.firedEvents)")
    }

    @Test func prepare_calledOnInit() {
        let haptics = NullHapticEngine()
        _ = makeVM(studyMode: false, haptics: haptics)
        #expect(haptics.prepareCallCount == 1)
    }

    @Test func letterCompleted_firesLetterCompleted() throws {
        let haptics = NullHapticEngine()
        let vm = makeVM(studyMode: false, haptics: haptics)
        // A fixture without a letter must FAIL this positive control, not
        // skip it (audit 2026-09-04).
        try #require(!vm.currentLetterName.isEmpty, "the stub repository supplied no letter")
        haptics.reset()

        let progress = traceWholeLetter(vm)
        #expect(Double(progress) > 0.0,
                "Progress=0 means no checkpoints hit. Events: \(haptics.firedEvents)")
        #expect(haptics.firedEvents.contains(.letterCompleted),
                "Expected letterCompleted. progress=\(progress) events=\(haptics.firedEvents)")
    }

    // MARK: - ...and are silent inside one (C1)

    /// The negative twin of the three above: same engine, same gestures,
    /// opposite expectation.
    ///
    /// `StudyCleanConfigTests` already proves the VM *holds* a
    /// `NullHapticEngine` under studyMode, and that a session drives zero
    /// calls into an injected spy. Neither pins the specific interactions
    /// that DO fire haptics outside study mode, which is what a regression
    /// would actually change — a new fire() site added to `beginTouch` or
    /// the completion path would slip past both. C1's guarantee is that the
    /// silent arm is actually silent at the event level, and this is the
    /// haptic half of it.
    ///
    /// The progress assertion is load-bearing: without it the test passes
    /// vacuously whenever the trace fails to advance the tracker for some
    /// unrelated reason. It must be true that on the non-study path both
    /// `.strokeBegan` and `.letterCompleted` would have fired.
    @Test func studyMode_firesNoHaptics() {
        let haptics = NullHapticEngine()
        let vm = makeVM(studyMode: true, haptics: haptics)
        #expect(haptics.prepareCallCount == 0,
                "studyMode must not even prime the injected engine")
        // studyMode pins the four-phase flow whatever the injected
        // `.guidedOnly` says (2026-09-04), so a fresh study VM sits in
        // the touch-disabled observe phase. Same recipe as the passing
        // study suites (StudyCleanConfigTests): canvas FIRST — its didSet
        // re-lays out the grid and reloads the checkpoints — then guided,
        // then trace (CI runs 1637/1638).
        vm.canvasSize = CGSize(width: 400, height: 400)
        vm.phaseController.resume(at: .guided)

        let progress = traceWholeLetter(vm)
        // The load-bearing check. Under studyMode the four-phase flow is
        // pinned, so completing the guided trace ADVANCES to freeWrite —
        // and the phase transition resets `progress` to 0 (CI run 1641:
        // phase=.freeWrite, progress 0). Outside studyMode `.guidedOnly`
        // has no next phase and progress stays at 1, which is what the
        // three positive twins read. Here the proof that the trace really
        // advanced the tracker is the phase change itself.
        #expect(vm.phaseController.currentPhase == .freeWrite,
                "the trace must complete the guided phase, or this proves nothing — progress=\(progress) precondition=\(vm.studyPreconditionFailure ?? "nil") phase=\(vm.phaseController.currentPhase) letter=\(vm.currentLetterName) cells=\(vm.gridCells.count) strokes=\(vm.strokeTracker.definition?.strokes.count ?? -1)")
        #expect(haptics.firedEvents.isEmpty,
                "no haptics in a study session — got \(haptics.firedEvents)")
    }
}
