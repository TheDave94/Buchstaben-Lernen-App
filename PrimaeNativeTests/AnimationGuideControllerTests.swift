import Foundation
import CoreGraphics
import Testing
@testable import PrimaeNative

@MainActor
@Suite struct AnimationGuideControllerTests {

    private func sampleStrokes() -> LetterStrokes {
        // Minimal 2-checkpoint stroke so the built guide has a non-empty step list.
        LetterStrokes(
            letter: "Z",
            checkpointRadius: 0.05,
            strokes: [
                StrokeDefinition(id: 1, checkpoints: [
                    Checkpoint(x: 0.1, y: 0.5),
                    Checkpoint(x: 0.9, y: 0.5),
                ])
            ]
        )
    }

    @Test func initialState_guidePointIsNil() {
        let c = AnimationGuideController()
        #expect(c.guidePoint == nil)
    }

    @Test func stop_withNoAnimation_doesNotCrash() {
        let c = AnimationGuideController()
        c.stop()
        c.stop()
        #expect(c.guidePoint == nil)
    }

    @Test func start_setsGuidePointWithinShortWindow() async {
        let c = AnimationGuideController()
        c.start(strokes: sampleStrokes())
        for _ in 0..<20 {
            if c.guidePoint != nil { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        #expect(c.guidePoint != nil,
                "guidePoint should become non-nil within ~500 ms of start")
        c.stop()
    }

    @Test func stop_clearsGuidePoint() async {
        let c = AnimationGuideController()
        c.start(strokes: sampleStrokes())
        try? await Task.sleep(for: .milliseconds(80))
        c.stop()
        #expect(c.guidePoint == nil,
                "stop() must synchronously clear guidePoint")
    }

    @Test func startAfterDelay_doesNotFireEarly() async {
        let c = AnimationGuideController()
        c.startAfterDelay(0.2, strokes: sampleStrokes())
        try? await Task.sleep(for: .milliseconds(50))
        #expect(c.guidePoint == nil,
                "startAfterDelay must honor the delay before firing")
        c.stop()
    }

    @Test func onCycleComplete_firesAtLeastOnce() async {
        let c = AnimationGuideController()
        var cycles = 0
        c.onCycleComplete = { cycles += 1 }
        c.start(strokes: sampleStrokes())
        // Single checkpoint gets ~0.25 s step + 0.5 s pause ≈ 750 ms/cycle.
        for _ in 0..<60 {
            if cycles >= 1 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(cycles >= 1,
                "onCycleComplete should fire within ~3 s; observed \(cycles) cycles")
        c.stop()
    }

    /// A second `start` must cancel the first loop, or two guide dots run
    /// (and `onCycleComplete` fires twice per cycle). Counted through the
    /// injected sleeper: every loop parks in exactly one sleep at a time,
    /// so the number of sleeps in flight is the number of live loops.
    /// (The test used to contain no assertion at all — audit 2026-09-04.)
    @Test func start_replacesInFlightAnimation() async {
        final class Gate: @unchecked Sendable {
            let lock = NSLock(); var inFlight = 0; var peak = 0
            func enter() { lock.lock(); inFlight += 1; peak = max(peak, inFlight); lock.unlock() }
            func leave() { lock.lock(); inFlight -= 1; lock.unlock() }
            var current: Int { lock.lock(); defer { lock.unlock() }; return inFlight }
        }
        let gate = Gate()
        let c = AnimationGuideController(sleeper: { _ in
            gate.enter(); defer { gate.leave() }
            // Park until cancelled — a cancelled loop leaves, a live one stays.
            try await Task.sleep(for: .seconds(60))
        })
        c.start(strokes: sampleStrokes())
        for _ in 0..<20 { await Task.yield() }
        #expect(gate.current == 1, "one loop parked in its sleep, got \(gate.current)")
        c.start(strokes: sampleStrokes())
        for _ in 0..<50 { await Task.yield() }
        #expect(gate.current == 1, "the first loop must be cancelled by the second start; live loops = \(gate.current)")
        c.stop()
        for _ in 0..<50 { await Task.yield() }
        #expect(gate.current == 0, "stop must cancel the live loop; live loops = \(gate.current)")
    }
}
