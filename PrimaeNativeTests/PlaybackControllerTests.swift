// Direct tests for the playback state machine wrapper extracted from
// TracingViewModel. Confirms the LESSONS.md sync-load contract
// (immediate=true produces a synchronous audio side-effect) and the
// debounced idle/active timings match VM assumptions.

import Foundation
import Testing
@testable import PrimaeNative

@MainActor
final class PlaybackTestAudio: AudioControlling {
    var initializationError: String? { nil }
    private(set) var playCount = 0
    private(set) var stopCount = 0
    private(set) var cancelLifecycleCount = 0
    func loadAudioFile(named: String, autoplay: Bool) {}
    func play() { playCount += 1 }
    func stop() { stopCount += 1 }
    func restart() {}
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) {}
    func suspendForLifecycle() {}
    func resumeAfterLifecycle() {}
    func cancelPendingLifecycleWork() { cancelLifecycleCount += 1 }
}

/// Box a value type so closures that update test state compile under
/// @Sendable-like constraints without needing inout / Task-Local shenanigans.
@MainActor
final class Box<T> {
    var value: T
    init(_ v: T) { value = v }
}

@MainActor
@Suite struct PlaybackControllerTests {

    /// Build a controller + its spying audio. Default param omitted because
    /// `@MainActor final class PlaybackTestAudio`'s init is actor-isolated,
    /// which Swift 6 strict mode forbids in a default-argument expression.
    private func make() -> (PlaybackController, PlaybackTestAudio, Box<Bool>) {
        let audio = PlaybackTestAudio()
        let isPlaying = Box(false)
        let controller = PlaybackController(audio: audio,
                                             onIsPlayingChanged: { isPlaying.value = $0 })
        controller.appIsForeground = true
        controller.resumeIntent = true
        return (controller, audio, isPlaying)
    }

    @Test func immediateActiveTransition_playsSynchronously() {
        let (c, audio, isPlaying) = make()
        c.request(.active, immediate: true)
        #expect(audio.playCount == 1, "immediate=true must play synchronously")
        #expect(isPlaying.value == true)
    }

    @Test func immediateIdleTransition_stopsSynchronously() {
        let (c, audio, isPlaying) = make()
        c.request(.active, immediate: true)
        c.request(.idle, immediate: true)
        #expect(audio.stopCount == 1)
        #expect(isPlaying.value == false)
    }

    @Test func playIntentDebounce_coalescesRapidBurst() {
        // Fire 5 play-intents in quick succession; expect exactly 1 audible play.
        let (c, audio, _) = make()
        for _ in 0..<5 {
            c.request(.idle, immediate: true)
            c.request(.active, immediate: true)
        }
        // The first cycle plays; subsequent ones are inside the 0.1s dedup window,
        // so audio.playCount should NOT grow to 5.
        #expect(audio.playCount <= 2,
                "Play-intent dedup should coalesce rapid bursts; got \(audio.playCount)")
    }

    @Test func activeWithoutResumeIntent_doesNotPlay() {
        let (c, audio, _) = make()
        c.resumeIntent = false
        c.request(.active, immediate: true)
        // Machine forces active→idle when resumeIntent=false; audio.play should not fire.
        #expect(audio.playCount == 0)
    }

    @Test func activeWhileBackgrounded_doesNotPlay() {
        let (c, audio, _) = make()
        c.appIsForeground = false
        c.request(.active, immediate: true)
        #expect(audio.playCount == 0)
    }

    @Test func cancelPending_callsAudioCancelLifecycle() {
        let (c, audio, _) = make()
        c.cancelPending()
        #expect(audio.cancelLifecycleCount >= 1)
    }

    @Test func debouncedActive_firesAfterDelay() async {
        // Inject an instant sleep so the debounce fires deterministically — no wall clock.
        let audio = PlaybackTestAudio()
        let isPlaying = Box(false)
        let c = PlaybackController(audio: audio,
                                   activeDebounceSeconds: 0.05,
                                   idleDebounceSeconds: 0.10,
                                   sleep: { _ in },
                                   onIsPlayingChanged: { isPlaying.value = $0 })
        c.appIsForeground = true
        c.resumeIntent = true
        c.request(.active, immediate: false)
        #expect(audio.playCount == 0, "Debounced transition must NOT fire synchronously")
        await c.pendingTransition?.value
        #expect(audio.playCount == 1, "Debounced transition should fire after sleeper resumes")
    }

    /// The engine discards its file on stop(); a play() without a
    /// reload is a no-op. The reload hook must run before EVERY play,
    /// the immediate one and the deferred one (audit 2026-09-06).
    @Test func reloadHook_runsBeforeEveryPlay() async {
        let audio = PlaybackTestAudio()
        let order = Box<[String]>([])
        let c = PlaybackController(audio: audio, playIntentDebounceSeconds: 0.0,
                                   sleep: { _ in }, onIsPlayingChanged: { _ in })
        c.appIsForeground = true
        c.resumeIntent = true
        c.reloadBeforePlay = { order.value.append("reload:\(audio.playCount)") }
        c.request(.active, immediate: true)
        #expect(audio.playCount == 1)
        #expect(order.value == ["reload:0"], "reload must precede the first play")
        c.request(.idle, immediate: true)
        c.request(.active, immediate: true)
        #expect(audio.playCount == 2)
        #expect(order.value == ["reload:0", "reload:1"], "reload must precede the play after a stop")
    }

    /// A debounced idle request repeated on every move sample must not
    /// restart the timer, or continuous off-path movement never goes
    /// idle (audit 2026-09-06). An active request still cancels it.
    @Test func repeatedIdleRequest_keepsThePendingTimer() async {
        final class Gate: @unchecked Sendable {
            let lock = NSLock(); var sleeps = 0
            func hit() { lock.lock(); sleeps += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return sleeps }
        }
        let gate = Gate()
        let audio = PlaybackTestAudio()
        let c = PlaybackController(audio: audio, idleDebounceSeconds: 0.10,
                                   sleep: { _ in gate.hit(); try await Task.sleep(for: .seconds(60)) },
                                   onIsPlayingChanged: { _ in })
        c.appIsForeground = true
        c.resumeIntent = true
        c.request(.active, immediate: true)
        c.request(.idle, immediate: false)
        let first = c.pendingTransition
        #expect(first != nil)
        for _ in 0..<20 { c.request(.idle, immediate: false) }
        #expect(c.pendingTransition == first, "the same idle timer must survive repeated idle requests")
        for _ in 0..<200 where gate.count < 1 { await Task.yield() }
        #expect(gate.count == 1, "exactly one idle sleep in flight, got \(gate.count)")
        // Back on-path: the immediate active request cancels the pending idle.
        c.request(.active, immediate: true)
        #expect(c.pendingTransition == nil)
        #expect(audio.stopCount == 0, "idle never fired")
    }

    @Test func resetPlayIntentClock_allowsImmediateReplay() {
        let (c, audio, _) = make()
        c.request(.active, immediate: true)  // play #1
        c.request(.idle, immediate: true)
        c.resetPlayIntentClock()             // clear the 0.1s dedup window
        c.request(.active, immediate: true)  // should play again
        #expect(audio.playCount == 2,
                "After resetPlayIntentClock, a new play within the dedup window should still fire; got \(audio.playCount)")
    }
}
