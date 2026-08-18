// OverlayQueueManager.swift
// PrimaeNative
//
// Serialises canvas overlays so the child never sees stacked
// feedback (Fréchet badge + KP diagram + recognition chip +
// celebration all at once). Each overlay runs for its own duration,
// then the queue auto-advances. While the queue is empty, the canvas
// returns to interactive state.
//
// The actual rendering still lives in the existing overlay views —
// this manager only arbitrates visibility and order.

import CoreGraphics
import Foundation

/// One queued canvas overlay. Canonical post-freeWrite order is
/// `kpOverlay → recognitionBadge → paperTransfer → celebration`; modal
/// overlays (paperTransfer, celebration, retrievalPrompt) use
/// `defaultDuration == nil` so they wait for an explicit `.dismiss()`.
enum CanvasOverlay: Equatable, Sendable {
    /// KP (Knowledge of Performance) overlay with the reference path
    /// drawn over the child's trace.
    case kpOverlay
    /// CoreML recognition badge when confidence ≥ 0.4.
    case recognitionBadge(RecognitionResult)
    /// Paper-transfer self-assessment modal. Modal: no auto-dismiss.
    case paperTransfer(letter: String)
    /// Phase- / letter-complete celebration. Modal.
    case celebration(stars: Int)
    /// Newly-unlocked achievement (firstLetter, 7-day streak, …).
    /// Auto-advances after 2.5 s so it doesn't block celebration; the
    /// persistent display lives in FortschritteWorldView.
    case rewardCelebration(RewardEvent)
    /// Spaced-retrieval recognition prompt. Plays the letter's audio
    /// and shows three candidates; outcome lands on
    /// `LetterProgress.retrievalAttempts`. Modal.
    case retrievalPrompt(letter: String, distractors: [String])

    /// Whether an in-flight instance of this overlay is INTERRUPTED by a
    /// later `enqueueBeforeCelebration` rather than allowed to finish.
    ///
    /// Deliberately NOT the same set as "modal" (`defaultDuration == nil`),
    /// which also contains `.retrievalPrompt`. Retrieval fires pre-trace
    /// and the interrupting caller runs post-freeWrite, so the two cannot
    /// be on screen together; naming the concept separately records that
    /// rather than leaving it to be re-derived from two inline case lists.
    var isBlocking: Bool {
        switch self {
        case .paperTransfer, .celebration:                      return true
        case .kpOverlay, .recognitionBadge,
             .rewardCelebration, .retrievalPrompt:              return false
        }
    }

    /// Default display duration. `nil` means modal — only an explicit
    /// `.dismiss()` advances the queue.
    var defaultDuration: TimeInterval? {
        switch self {
        case .kpOverlay:          return 3.0
        case .recognitionBadge:   return 3.0
        case .paperTransfer:      return nil   // modal: wait for child
        case .celebration:        return nil   // modal: wait for child
        case .rewardCelebration:  return 2.5
        case .retrievalPrompt:    return nil   // modal: wait for child
        }
    }
}

/// Per-VM overlay scheduler. Observable so SwiftUI views can bind
/// directly to `currentOverlay` and animate on change.
@MainActor
@Observable
final class OverlayQueueManager {

    // MARK: - State

    /// Overlay currently on screen, or nil when the queue is drained
    /// and the canvas is back to interactive.
    private(set) var currentOverlay: CanvasOverlay?

    /// FIFO queue of waiting overlays. Public via `pendingCount` only.
    /// `duration == nil` marks a modal overlay — the timer task does not
    /// fire and only an explicit `.dismiss()` advances the queue.
    private var queue: [(overlay: CanvasOverlay, duration: TimeInterval?)] = []

    /// Task driving the auto-advance timer. Cancelled on dismiss or reset
    /// so a manual dismissal doesn't race with the timeout.
    private var advanceTask: Task<Void, Never>?

    /// Injected sleeper for the timed-overlay auto-advance. Defaults to
    /// `realSleeper` (Task.sleep) in production; tests substitute a
    /// deterministic fake so the queue's timing contract can be exercised
    /// without real wall-clock waits.
    private let sleeper: Sleeper

    init(sleeper: @escaping Sleeper = realSleeper) {
        self.sleeper = sleeper
    }

    // MARK: - Public API

    /// Append `overlay` to the queue. If nothing is showing, display
    /// it immediately; otherwise it waits in FIFO order. Pass
    /// `duration = nil` to use the overlay's default.
    func enqueue(_ overlay: CanvasOverlay, duration: TimeInterval? = nil) {
        let d = duration ?? overlay.defaultDuration
        queue.append((overlay, d))
        if currentOverlay == nil {
            advance()
        }
    }

    /// Slot `overlay` into the queue ahead of the first queued
    /// `.paperTransfer` or `.celebration`, or append if neither is
    /// queued. Preserves canonical post-freeWrite order even when
    /// CoreML inference arrives late. If a blocking modal is already
    /// the active overlay, it is pushed back to queue position 0 and
    /// the inserted overlay becomes the new current overlay.
    func enqueueBeforeCelebration(_ overlay: CanvasOverlay,
                                   duration: TimeInterval? = nil) {
        let d = duration ?? overlay.defaultDuration
        // A blocking overlay on screen is interrupted: re-enqueue it at
        // the front, insert this one ahead of it.
        if let saved = currentOverlay, saved.isBlocking {
            advanceTask?.cancel()
            advanceTask = nil
            currentOverlay = nil
            queue.insert((saved, saved.defaultDuration), at: 0)
            queue.insert((overlay, d), at: 0)
            advance()
            return
        }
        if let idx = queue.firstIndex(where: { $0.overlay.isBlocking }) {
            queue.insert((overlay, d), at: idx)
        } else {
            queue.append((overlay, d))
        }
        if currentOverlay == nil {
            advance()
        }
    }

    /// Dismiss the current overlay early (e.g. child tapped through).
    /// Advances to the next in queue, or idles if the queue is empty.
    func dismiss() {
        advanceTask?.cancel()
        advanceTask = nil
        advance()
    }

    /// Clear the queue and any active overlay. Call on letter change
    /// or phase reset so stale feedback can't bleed across sessions.
    func reset() {
        advanceTask?.cancel()
        advanceTask = nil
        queue.removeAll(keepingCapacity: true)
        currentOverlay = nil
    }

    /// How many overlays are waiting behind the current one.
    var pendingCount: Int { queue.count }

    // MARK: - Internals

    private func advance() {
        if queue.isEmpty {
            currentOverlay = nil
            return
        }
        let next = queue.removeFirst()
        currentOverlay = next.overlay
        advanceTask?.cancel()
        // Modal overlays (`duration == nil`) wait for an explicit
        // `.dismiss()`; timed overlays auto-advance after their window.
        guard let duration = next.duration else {
            advanceTask = nil
            return
        }
        advanceTask = Task { [weak self, sleeper] in
            try? await sleeper(.seconds(duration))
            guard !Task.isCancelled else { return }
            self?.advance()
        }
    }
}
