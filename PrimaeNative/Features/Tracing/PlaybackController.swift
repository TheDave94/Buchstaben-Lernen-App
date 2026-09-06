// PlaybackController.swift
// PrimaeNative
//
// Audio-playback state machine, debounced transitions, and play-intent
// wall-time deduplication for rapid tap bursts.
//
// FRAGILE — see docs/LESSONS.md before touching audio:
//   - MainActor-bound; no audio command moves off the main thread.
//   - `request(_:immediate:)` with immediate=true is fully synchronous;
//     the VM's load(letter:) path depends on this sync contract.
//   - Debounce timings are asserted against in TracingViewModelTests.

import Foundation
import QuartzCore

@MainActor
final class PlaybackController {

    // MARK: - Injected

    private let audio: AudioControlling
    /// Invoked when the audible playing state changes. Settable
    /// post-init so the VM can wire `[weak self]` after `self.playback`
    /// is assigned (two-phase init seam).
    var onIsPlayingChanged: (Bool) -> Void
    /// Runs immediately before every `audio.play()`. The VM wires the
    /// arm-file reload here: `AudioEngine.stop()` discards its file and
    /// `play()` is a no-op without one, so a play after the idle
    /// transition (a mid-stroke pause) was silent until the next
    /// touch-down (audit 2026-09-06). Load then play in one synchronous
    /// block — `play()` cancels an in-flight fade-out, so the fade cannot
    /// discard the file just loaded.
    var reloadBeforePlay: (@MainActor () -> Void)?

    // MARK: - Tunable timings (live-adjustable from the debug audio panel)

    var activeDebounceSeconds: TimeInterval
    var idleDebounceSeconds: TimeInterval
    /// Coalesces rapid tap bursts into a single audible playback so each
    /// short cycle doesn't fire a fresh audio.play().
    var playIntentDebounceSeconds: CFTimeInterval

    // MARK: - State

    private var machine = PlaybackStateMachine()
    /// In-flight debounced transition. Read-only so tests can await it
    /// instead of sleeping past the debounce.
    private(set) var pendingTransition: Task<Void, Never>?
    /// Target of `pendingTransition`. A repeated debounced request for
    /// the SAME target keeps the running timer instead of restarting it:
    /// `updateAdaptivePlayback` issues `request(.idle, immediate: false)`
    /// on every move sample (8–16 ms apart), so a timer restarted per
    /// sample could only ever fire after the finger STOPPED moving —
    /// continuous off-path movement never went idle and the documented
    /// proximity gate (`isNearStroke`, APP_DOCUMENTATION §7.3) was
    /// activation-only (audit 2026-09-06).
    private var pendingTarget: PlaybackStateMachine.State?
    private var lastPlayIntentWallTime: CFTimeInterval = 0

    // MARK: - Sleep injection

    private let sleep: Sleeper

    // MARK: - Init

    init(audio: AudioControlling,
         activeDebounceSeconds: TimeInterval = 0.03,
         idleDebounceSeconds: TimeInterval = 0.12,
         playIntentDebounceSeconds: CFTimeInterval = 0.1,
         sleep: @escaping Sleeper = realSleeper,
         onIsPlayingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.audio = audio
        self.activeDebounceSeconds = activeDebounceSeconds
        self.idleDebounceSeconds = idleDebounceSeconds
        self.playIntentDebounceSeconds = playIntentDebounceSeconds
        self.sleep = sleep
        self.onIsPlayingChanged = onIsPlayingChanged
    }

    // MARK: - Machine access

    var state: PlaybackStateMachine.State { machine.state }

    var appIsForeground: Bool {
        get { machine.appIsForeground }
        set { machine.appIsForeground = newValue }
    }

    var resumeIntent: Bool {
        get { machine.resumeIntent }
        set { machine.resumeIntent = newValue }
    }

    func forceIdle() { machine.forceIdle() }

    /// Direct synchronous state transition (no debounce). Used by the
    /// app-lifecycle path where semantics require immediate effect.
    @discardableResult
    func transition(to target: PlaybackStateMachine.State) -> PlaybackStateMachine.Command {
        machine.transition(to: target)
    }

    /// Apply a command from `transition(to:)`. Lifts the audio call out so
    /// lifecycle callers can choose when to issue the audio side-effect.
    /// Whether the last command this controller issued to the engine was
    /// a play (true) or a stop (false).
    private var audioIsRunning = false
    /// A play that the dedup window swallowed while the engine was
    /// STOPPED. The window exists to coalesce rapid stop/play cycles
    /// into one `audio.play()`; dropping the play outright left a stroke
    /// that outlived the window silent with `isPlaying` true (class two,
    /// 2026-09-05). Deferred to the end of the window instead, and fired
    /// only if the machine is still active and the engine still silent.
    private var deferredPlay: Task<Void, Never>?

    func apply(_ cmd: PlaybackStateMachine.Command) {
        switch cmd {
        case .play:
            let now = CACurrentMediaTime()
            let sinceLast = now - lastPlayIntentWallTime
            if sinceLast < playIntentDebounceSeconds {
                onIsPlayingChanged(true)
                if !audioIsRunning { scheduleDeferredPlay(after: playIntentDebounceSeconds - sinceLast) }
                return
            }
            deferredPlay?.cancel(); deferredPlay = nil
            lastPlayIntentWallTime = now
            reloadBeforePlay?()
            audio.play()
            audioIsRunning = true
            onIsPlayingChanged(true)
        case .stop:
            deferredPlay?.cancel(); deferredPlay = nil
            audio.stop()
            audioIsRunning = false
            onIsPlayingChanged(false)
        case .none:
            break
        }
    }

    private func scheduleDeferredPlay(after delay: TimeInterval) {
        deferredPlay?.cancel()
        let sleeper = sleep
        deferredPlay = Task { [weak self] in
            try? await sleeper(.seconds(max(0, delay)))
            guard !Task.isCancelled, let self,
                  self.machine.state == .active, !self.audioIsRunning else { return }
            self.lastPlayIntentWallTime = CACurrentMediaTime()
            self.reloadBeforePlay?()
            self.audio.play()
            self.audioIsRunning = true
            self.onIsPlayingChanged(true)
        }
    }

    /// Request a transition to the target state. With `immediate=true` the
    /// corresponding audio command fires synchronously before return. Without
    /// immediate, the transition is debounced by the active/idle timing.
    func request(_ target: PlaybackStateMachine.State, immediate: Bool) {
        if !immediate, pendingTransition != nil, pendingTarget == target { return }
        pendingTransition?.cancel()
        pendingTransition = nil
        pendingTarget = nil

        let wouldChange: Bool
        if target == .active && (!machine.appIsForeground || !machine.resumeIntent) {
            wouldChange = machine.state != .idle
        } else {
            wouldChange = machine.state != target
        }

        if immediate {
            apply(machine.transition(to: target))
            return
        }

        guard wouldChange else { return }

        let delay = target == .active ? activeDebounceSeconds : idleDebounceSeconds
        let sleeper = sleep
        pendingTarget = target
        pendingTransition = Task { [weak self] in
            try? await sleeper(.seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.pendingTransition = nil
            self.pendingTarget = nil
            self.apply(self.machine.transition(to: target))
        }
    }

    /// Cancel any in-flight debounced transition AND any pending audio
    /// lifecycle work (AVAudioSession deactivation etc.).
    func cancelPending() {
        deferredPlay?.cancel(); deferredPlay = nil
        pendingTransition?.cancel()
        pendingTransition = nil
        pendingTarget = nil
        audio.cancelPendingLifecycleWork()
    }

    /// Reset the play-intent wall clock (used on app-background to avoid
    /// a stale "just played" debouncing a legitimate resume).
    func resetPlayIntentClock() {
        lastPlayIntentWallTime = 0
    }
}
