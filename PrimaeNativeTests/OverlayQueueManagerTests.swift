// Coverage for the overlay scheduler that serialises post-freeWrite
// feedback (KP overlay, recognition badge, paper transfer, celebration).
// Pins the canonical ordering rules — especially `enqueueBeforeCelebration`
// which lets a late-arriving CoreML recognition badge slot ahead of an
// already-queued celebration without resetting the queue.

import Testing
import Foundation
@testable import PrimaeNative

private func sampleResult(_ predicted: String = "A",
                          confidence: CGFloat = 0.9,
                          isCorrect: Bool = true) -> RecognitionResult {
    RecognitionResult(
        predictedLetter: predicted,
        confidence: confidence,
        topThree: [.init(letter: predicted, confidence: confidence)],
        isCorrect: isCorrect
    )
}

@Suite @MainActor struct OverlayQueueManagerTests {

    // MARK: - Default duration table

    @Test func defaultDuration_perCase() {
        #expect(CanvasOverlay.kpOverlay.defaultDuration == 3.0)
        #expect(CanvasOverlay.recognitionBadge(sampleResult()).defaultDuration == 3.0)
        #expect(CanvasOverlay.paperTransfer(letter: "A").defaultDuration == nil)
        #expect(CanvasOverlay.celebration(stars: 3).defaultDuration == nil)
    }

    // MARK: - Enqueue

    @Test func enqueue_intoEmptyQueue_showsImmediately() {
        let q = OverlayQueueManager()
        q.enqueue(.kpOverlay)
        #expect(q.currentOverlay == .kpOverlay)
        #expect(q.pendingCount == 0)
    }

    @Test func enqueue_whileOverlayActive_buffersBehind() {
        let q = OverlayQueueManager()
        q.enqueue(.kpOverlay)
        q.enqueue(.celebration(stars: 3))
        #expect(q.currentOverlay == .kpOverlay)
        #expect(q.pendingCount == 1)
    }

    @Test func enqueue_severalIntoEmptyQueue_firstShownRestQueued() {
        let q = OverlayQueueManager()
        q.enqueue(.kpOverlay)
        q.enqueue(.paperTransfer(letter: "B"))
        q.enqueue(.celebration(stars: 2))
        #expect(q.currentOverlay == .kpOverlay)
        #expect(q.pendingCount == 2)
    }

    // MARK: - enqueueBeforeCelebration

    @Test func enqueueBeforeCelebration_inserts_aheadOfQueuedCelebration() {
        let q = OverlayQueueManager()
        q.enqueue(.kpOverlay)
        q.enqueue(.paperTransfer(letter: "B"))
        q.enqueue(.celebration(stars: 3))
        // Late-arriving badge must sit ahead of both `paperTransfer` and
        // `celebration` so the canonical order is preserved
        // (kpOverlay → recognitionBadge → paperTransfer → celebration).
        // Inserting only ahead of `celebration` would push the badge past
        // the paper-transfer self-assessment.
        q.enqueueBeforeCelebration(.recognitionBadge(sampleResult("B")))
        #expect(q.currentOverlay == .kpOverlay)
        q.dismiss()
        #expect(q.currentOverlay == .recognitionBadge(sampleResult("B")))
        q.dismiss()
        #expect(q.currentOverlay == .paperTransfer(letter: "B"))
        q.dismiss()
        #expect(q.currentOverlay == .celebration(stars: 3))
    }

    @Test func enqueueBeforeCelebration_withoutQueuedCelebration_appends() {
        let q = OverlayQueueManager()
        q.enqueue(.kpOverlay)
        q.enqueueBeforeCelebration(.recognitionBadge(sampleResult("C")))
        #expect(q.currentOverlay == .kpOverlay)
        q.dismiss()
        #expect(q.currentOverlay == .recognitionBadge(sampleResult("C")))
    }

    @Test func enqueueBeforeCelebration_intoEmptyQueue_showsImmediately() {
        let q = OverlayQueueManager()
        q.enqueueBeforeCelebration(.recognitionBadge(sampleResult("D")))
        #expect(q.currentOverlay == .recognitionBadge(sampleResult("D")))
        #expect(q.pendingCount == 0)
    }

    /// When CoreML inference finishes after the celebration is already
    /// the active overlay, the badge must interrupt — push the celebration
    /// back to position 0 in the queue, become the new currentOverlay,
    /// and let the queue resume to the celebration after the badge
    /// auto-advances.
    @Test func enqueueBeforeCelebration_whenCelebrationAlreadyActive() {
        let q = OverlayQueueManager()
        q.enqueue(.celebration(stars: 2))
        // Celebration is now the active overlay (modal, no auto-advance).
        #expect(q.currentOverlay == .celebration(stars: 2))
        q.enqueueBeforeCelebration(.recognitionBadge(sampleResult("Z")))
        // Badge interrupts — celebration is queued behind it.
        #expect(q.currentOverlay == .recognitionBadge(sampleResult("Z")))
        #expect(q.pendingCount == 1)
        q.dismiss()
        #expect(q.currentOverlay == .celebration(stars: 2))
    }

    /// Same interrupt path when paperTransfer is the already-active modal.
    /// Badge must come ahead of paperTransfer so the canonical
    /// post-freeWrite order (kpOverlay → recognitionBadge → paperTransfer
    /// → celebration) is preserved no matter how late inference returns.
    @Test func enqueueBeforeCelebration_whenPaperTransferAlreadyActive() {
        let q = OverlayQueueManager()
        q.enqueue(.paperTransfer(letter: "Z"))
        #expect(q.currentOverlay == .paperTransfer(letter: "Z"))
        q.enqueueBeforeCelebration(.recognitionBadge(sampleResult("Z")))
        #expect(q.currentOverlay == .recognitionBadge(sampleResult("Z")))
        #expect(q.pendingCount == 1)
        q.dismiss()
        #expect(q.currentOverlay == .paperTransfer(letter: "Z"))
    }

    @Test func enqueueBeforeCelebration_picksFirstCelebrationWhenMany() {
        let q = OverlayQueueManager()
        q.enqueue(.kpOverlay)
        q.enqueue(.celebration(stars: 1))
        q.enqueue(.celebration(stars: 2)) // unusual but not invalid
        q.enqueueBeforeCelebration(.recognitionBadge(sampleResult("E")))
        // Badge should land ahead of the FIRST celebration: order should be
        // KP → badge → celebration(1) → celebration(2).
        #expect(q.currentOverlay == .kpOverlay)
        q.dismiss()
        #expect(q.currentOverlay == .recognitionBadge(sampleResult("E")))
        q.dismiss()
        #expect(q.currentOverlay == .celebration(stars: 1))
        q.dismiss()
        #expect(q.currentOverlay == .celebration(stars: 2))
    }

    // MARK: - Dismiss

    @Test func dismiss_advancesToNextQueued() {
        let q = OverlayQueueManager()
        q.enqueue(.kpOverlay)
        q.enqueue(.paperTransfer(letter: "F"))
        q.dismiss()
        #expect(q.currentOverlay == .paperTransfer(letter: "F"))
        #expect(q.pendingCount == 0)
    }

    @Test func dismiss_drainsToIdleWhenQueueEmpty() {
        let q = OverlayQueueManager()
        q.enqueue(.kpOverlay)
        q.dismiss()
        #expect(q.currentOverlay == nil)
        #expect(q.pendingCount == 0)
    }

    @Test func dismiss_whenIdle_isNoOp() {
        let q = OverlayQueueManager()
        q.dismiss()
        #expect(q.currentOverlay == nil)
        #expect(q.pendingCount == 0)
    }

    // MARK: - Reset

    @Test func reset_clearsActiveAndQueued() {
        let q = OverlayQueueManager()
        q.enqueue(.kpOverlay)
        q.enqueue(.paperTransfer(letter: "G"))
        q.enqueue(.celebration(stars: 1))
        q.reset()
        #expect(q.currentOverlay == nil)
        #expect(q.pendingCount == 0)
    }

    @Test func reset_whenIdle_isNoOp() {
        let q = OverlayQueueManager()
        q.reset()
        #expect(q.currentOverlay == nil)
        #expect(q.pendingCount == 0)
    }

    // MARK: - Auto-advance after timed overlay

    @Test func timedOverlay_autoAdvances() async {
        // Use the injected Sleeper seam so the test is deterministic —
        // the production wall-clock 0.05s wait + 0.2s assertion poll was
        // flaky on CI runners where Task scheduling overhead pushed the
        // sleep past the poll window. The fake sleeper resolves instantly
        // via Task.yield() so the auto-advance fires before we read the
        // queue state.
        let fakeSleeper: Sleeper = { _ in await Task.yield() }
        let q = OverlayQueueManager(sleeper: fakeSleeper)
        q.enqueue(.kpOverlay, duration: 0.05)
        q.enqueue(.celebration(stars: 1))
        // Yield until the auto-advance Task has had a chance to run.
        // Two yields covers the dispatch → sleep-await → resume → advance
        // cycle; bump to three for headroom on slow runners.
        for _ in 0..<3 { await Task.yield() }
        #expect(q.currentOverlay == .celebration(stars: 1))
    }

    @Test func modalOverlay_doesNotAutoAdvance() async {
        // Modal overlays (paperTransfer, celebration) carry nil duration
        // and must wait for an explicit dismiss — no timer should fire.
        // No sleeper involvement at all (the queue skips arming the
        // advance Task when duration is nil), so this stays fully
        // synchronous.
        let q = OverlayQueueManager()
        q.enqueue(.paperTransfer(letter: "H"))
        q.enqueue(.celebration(stars: 1))
        // A few yields prove the absence of a timer — without an arm,
        // nothing advances regardless of how much we yield.
        for _ in 0..<5 { await Task.yield() }
        #expect(q.currentOverlay == .paperTransfer(letter: "H"))
        #expect(q.pendingCount == 1)
    }
}
