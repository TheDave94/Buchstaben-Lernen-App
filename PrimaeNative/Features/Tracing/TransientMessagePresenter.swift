// TransientMessagePresenter.swift
// PrimaeNative
//
// Two short-lived UI messages: a 1.3 s toast and a 1.8 s celebration
// HUD (also dismissable on tap). Sleep is injectable for tests.

import Foundation

@MainActor
@Observable
final class TransientMessagePresenter {

    // MARK: - Published state (bound by views)

    /// Currently displayed short toast, or nil. Auto-clears ~1.3 s after `show(toast:)`.
    private(set) var toastMessage: String? = nil

    /// Currently displayed completion HUD message, or nil. Auto-clears ~1.8 s after
    /// `show(completion:)` or when the user calls `dismissCompletion()`.
    private(set) var completionMessage: String? = nil

    // MARK: - Timings

    let toastDuration:      TimeInterval = 1.3
    let completionDuration: TimeInterval = 1.8

    // MARK: - Tasks (exposed read-only so tests can await pending auto-clears)

    private(set) var toastTask:      Task<Void, Never>?
    private(set) var completionTask: Task<Void, Never>?

    // MARK: - Sleep injection

    private let sleep: Sleeper

    init(sleep: @escaping Sleeper = realSleeper) {
        self.sleep = sleep
    }

    // MARK: - API

    /// Display a transient toast. Cancels and replaces any in-flight toast.
    func show(toast text: String) {
        toastMessage = text
        toastTask?.cancel()
        let sleeper = sleep
        let duration = toastDuration
        toastTask = Task { [weak self] in
            try? await sleeper(.seconds(duration))
            // Equality-guard so a newer message queued during sleep isn't clobbered.
            guard let self, !Task.isCancelled, self.toastMessage == text else { return }
            self.toastMessage = nil
            self.toastTask    = nil
        }
    }

    /// Display a completion HUD message. Cancels and replaces any existing one.
    func show(completion text: String) {
        completionTask?.cancel()
        completionMessage = text
        let sleeper = sleep
        let duration = completionDuration
        completionTask = Task { [weak self] in
            try? await sleeper(.seconds(duration))
            guard let self, !Task.isCancelled, self.completionMessage == text else { return }
            self.completionMessage = nil
        }
    }

    /// Dismiss the completion HUD immediately (user-driven tap).
    func dismissCompletion() {
        completionTask?.cancel()
        completionMessage = nil
    }

    /// Clear the HUD without cancelling — for resetLetter paths that
    /// keep the task slot ready for a subsequent show.
    func clearCompletionState() {
        completionTask?.cancel()
        completionMessage = nil
    }
}
