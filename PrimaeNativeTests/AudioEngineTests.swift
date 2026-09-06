// NOTE: Intentionally uses XCTest — requires real hardware (XCTSkip in setUp), uses expectation/wait. Do not migrate to Swift Testing.
//
// Tests exercise AudioEngine directly via forged AVAudioSession notification userInfo payloads,
// asserting state machine transitions on isPlaying and #if DEBUG accessors.
// Observers in AudioEngine are registered with object: nil on .main queue; tests run on main
// thread by default so drainMain() (RunLoop.main.run) is sufficient to flush synchronous delivery.

import XCTest
import AVFoundation
@testable import PrimaeNative

final class AudioEngineTests: XCTestCase {

    private var engine: AudioEngine?

    // MARK: - Class-level session setup
    // Activate once per suite to avoid interrupting the shared session on every test setUp.

    override class func setUp() {
        super.setUp()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // XCTSkip is not available at class level; individual tests will skip via instance setUp.
            print("AudioEngineTests: AVAudioSession.setActive failed at class setUp: \(error)")
        }
    }

    override class func tearDown() {
        try? AVAudioSession.sharedInstance().setActive(false)
        super.tearDown()
    }

    // MARK: - Instance setup

    @MainActor override func setUp() async throws {
        // Do NOT call super.setUp(): XCTestCase.setUp() is `async throws` in Swift 6,
        // but calling it via `try await` from @MainActor triggers "sending non-Sendable
        // XCTestCase" and without `try await` triggers "call can throw/is async". The
        // default implementation is a no-op so omitting the super call is safe.
        continueAfterFailure = false
        // Guard: skip on headless CI — AVAudioEngine crashes AudioConverterService in simulator
        #if targetEnvironment(simulator)
        throw XCTSkip("AudioEngine tests require real hardware — skipped in simulator")
        #else
        guard AVAudioSession.sharedInstance().isOtherAudioPlaying || !AVAudioSession.sharedInstance().currentRoute.outputs.isEmpty else {
            throw XCTSkip("AVAudioSession has no viable route on this runner")
        }
        #endif
        // setUp is async throws so @MainActor isolation is preserved for this @MainActor class.
        engine = AudioEngine()
        // Ensure AVAudioEngine is in a known running state before any test that checks isRunning.
        // resumeAfterLifecycle() calls startIfNeeded() which starts the engine if not yet running.
        engine?.resumeAfterLifecycle()
    }

    @MainActor override func tearDown() async throws {
        // Cancel any pending debounce work before nil-ing engine to avoid DispatchWorkItem
        // firing after tearDown on a deallocated engine.
        engine?.cancelPendingLifecycleWork()
        engine = nil
        // Do NOT call super.tearDown() — same reason as setUp() above.
    }

    // MARK: - Direct methods: stop() / play() / restart()

    @MainActor func testStop_setsIsPlayingFalse() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        engine.stop()
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(engine.debugShouldResumePlayback)
    }

    @MainActor func testStop_isIdempotent() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        engine.stop()
        engine.stop()
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(engine.debugShouldResumePlayback)
    }

    @MainActor func testPlay_withNoFile_doesNotCrash() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        engine.play()
        // No file loaded — isPlaying stays false, but shouldResumePlayback must be set
        XCTAssertFalse(engine.isPlaying)
        XCTAssertTrue(engine.debugShouldResumePlayback,
                      "play() must set shouldResumePlayback=true even without a loaded file")
    }

    @MainActor func testRestart_withNoFile_doesNotCrashAndSetsShouldResume() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        // restart() is a distinct code path: clears gate flags, calls prepareCurrentTrack, attemptResumePlayback
        engine.restart()
        XCTAssertFalse(engine.isPlaying)
        XCTAssertTrue(engine.debugShouldResumePlayback,
                      "restart() must set shouldResumePlayback=true")
        XCTAssertFalse(engine.debugInterruptionResumeGateRequired,
                       "restart() must clear interruptionResumeGateRequired")
    }

    // MARK: - loadAudioFile edge cases

    @MainActor func testLoadAudioFile_missingFile_doesNotCrash() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        engine.loadAudioFile(named: "nonexistent_totally_fake_file_xyz.mp3", autoplay: false)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(engine.debugShouldResumePlayback)
    }

    /// AE-2: the loaded file's gain reaches the engine (the carrier is the
    /// target, so unity); a missing file leaves the previous gain alone.
    @MainActor func testLoadAudioFile_setsLoudnessGain() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        engine.loadAudioFile(named: SpatialSonification.carrierToneFile, autoplay: false)
        XCTAssertEqual(engine.loudnessGain, 1.0, accuracy: 0.02,
                       "the carrier defines the loudness target and must play at unity")
    }

    @MainActor func testLoadAudioFile_missingFile_autoplayTrue_doesNotCrash() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        // autoplay=true with missing file must not crash or corrupt state
        engine.loadAudioFile(named: "nonexistent_totally_fake_file_xyz.mp3", autoplay: true)
        XCTAssertFalse(engine.isPlaying)
        // shouldResumePlayback is only set inside the do-block after successful file open,
        // so missing file leaves it unchanged from prior state.
    }

    // MARK: - Interruption: .began

    @MainActor func testInterruptionBegan_stopsPlayback() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        postInterruption(type: .began)
        XCTAssertFalse(engine.isPlaying, "isPlaying must be false after interruption began")
        XCTAssertTrue(engine.debugInterrupted, "interrupted flag must be set")
        XCTAssertFalse(engine.debugInterruptionShouldResume,
                       "interruptionShouldResume must be false after .began")
        XCTAssertTrue(engine.debugInterruptionResumeGateRequired,
                      "interruptionResumeGateRequired must be set after .began")
    }

    @MainActor func testInterruptionBegan_isIdempotent() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        postInterruption(type: .began)
        let interruptedAfterFirst = engine.debugInterrupted
        postInterruption(type: .began)
        XCTAssertEqual(engine.debugInterrupted, interruptedAfterFirst,
                       "Double .began must not corrupt interrupted flag")
        XCTAssertFalse(engine.isPlaying)
    }

    // MARK: - Interruption: .ended

    @MainActor func testInterruptionEnded_shouldResumeFalse_remainsPaused() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        postInterruption(type: .began)
        postInterruption(type: .ended, shouldResume: false)
        XCTAssertFalse(engine.isPlaying, "Must stay paused when shouldResume=false")
        XCTAssertFalse(engine.debugInterrupted, "interrupted flag must clear on .ended")
        XCTAssertFalse(engine.debugInterruptionShouldResume,
                       "interruptionShouldResume must be false")
    }

    @MainActor func testInterruptionEnded_shouldResumeTrue_setsFlag() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        postInterruption(type: .began)
        postInterruption(type: .ended, shouldResume: true)
        // Even without a loaded file, the flag must reflect the system's intent
        XCTAssertFalse(engine.debugInterrupted, "interrupted must clear on .ended")
        XCTAssertTrue(engine.debugInterruptionShouldResume,
                      "interruptionShouldResume must be true when OS signals .shouldResume")
    }

    @MainActor func testInterruptionEnded_withoutPrecedingBegan_isHarmless() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        postInterruption(type: .ended, shouldResume: true)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(engine.debugInterrupted)
    }

    @MainActor func testInterruptionEnded_missingOptionKey_defaultsToNoResume() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        // Post .ended with no option key — edge case from older OS versions
        let userInfo: [AnyHashable: Any] = [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue
            // Deliberately omitting AVAudioSessionInterruptionOptionKey
        ]
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: userInfo
        )
        drainMain()
        XCTAssertFalse(engine.debugInterruptionShouldResume,
                       "Missing option key must default to shouldResume=false")
    }

    // MARK: - Route Change

    @MainActor func testRouteChange_oldDeviceUnavailable_stopsPlayback() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        postRouteChange(reason: .oldDeviceUnavailable)
        XCTAssertFalse(engine.isPlaying, "oldDeviceUnavailable must stop playback")
    }

    @MainActor func testRouteChange_oldDeviceUnavailable_isIdempotent() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        postRouteChange(reason: .oldDeviceUnavailable)
        postRouteChange(reason: .oldDeviceUnavailable)
        XCTAssertFalse(engine.isPlaying)
    }

    @MainActor func testRouteChange_newDeviceAvailable_doesNotCrash() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        postRouteChange(reason: .newDeviceAvailable)
        XCTAssertFalse(engine.isPlaying) // no file; no shouldResume intent
    }

    @MainActor func testRouteChange_categoryChange_doesNotCrash() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        postRouteChange(reason: .categoryChange)
        XCTAssertFalse(engine.isPlaying)
    }

    @MainActor func testRouteChange_wakeFromSleep_doesNotCrash() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        postRouteChange(reason: .wakeFromSleep)
        XCTAssertFalse(engine.isPlaying)
    }

    @MainActor func testRouteChange_malformedUserInfo_isHarmless() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        // Missing reason key — guard in handleRouteChange must absorb this silently
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: nil,
            userInfo: [:]
        )
        drainMain()
        XCTAssertFalse(engine.isPlaying)
    }

    // MARK: - Lifecycle

    @MainActor func testSuspendForLifecycle_stopsPlayback() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        engine.suspendForLifecycle()
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(engine.debugAppIsForeground)
    }

    @MainActor func testSuspendForLifecycle_isIdempotent() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        engine.suspendForLifecycle()
        engine.suspendForLifecycle()
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(engine.debugAppIsForeground)
    }

    @MainActor func testResumeAfterLifecycle_setsAppIsForeground() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        engine.suspendForLifecycle()
        engine.resumeAfterLifecycle()
        XCTAssertTrue(engine.debugAppIsForeground)
    }

    @MainActor func testSuspendThenResume_doesNotCrash() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        engine.suspendForLifecycle()
        engine.resumeAfterLifecycle()
        XCTAssertFalse(engine.isPlaying) // no file loaded
    }

    @MainActor func testCancelPendingLifecycleWork_isIdempotent() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        engine.suspendForLifecycle()
        engine.cancelPendingLifecycleWork()
        engine.cancelPendingLifecycleWork()
        XCTAssertFalse(engine.isPlaying)
    }

    // MARK: - pendingSafeEnginePause debounce
    //
    // These tests use a strong local reference (not [weak self]) to prevent tearDown
    // from nil-ing `engine` before the async closure asserts, which would cause
    // vacuous passes via nil-coalescing.

    @MainActor func testPendingSafeEnginePause_firesAfterDelay() async throws {
        let localEngine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        localEngine.suspendForLifecycle()

        let exp = expectation(description: "AVAudioEngine pauses after 0.2s debounce")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            XCTAssertFalse(localEngine.debugIsEngineRunning,
                           "AVAudioEngine must be paused after pendingSafeEnginePause fires")
            exp.fulfill()
        }
        await fulfillment(of: [exp], timeout: 1.0)
    }

    @MainActor func testPendingSafeEnginePause_cancelledByResume() async throws {
        let localEngine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        localEngine.suspendForLifecycle()
        // Immediately resume — DispatchWorkItem must be cancelled before it fires
        localEngine.resumeAfterLifecycle()

        let exp = expectation(description: "AVAudioEngine stays running when pause was cancelled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Note: isRunning reflects whether the engine is started, not whether audio is playing.
            // After resume with no file, startIfNeeded() starts the engine so isRunning == true.
            XCTAssertTrue(localEngine.debugIsEngineRunning,
                          "AVAudioEngine must not be paused when resume cancelled the pending pause work item")
            exp.fulfill()
        }
        await fulfillment(of: [exp], timeout: 1.5)
    }

    // MARK: - setAdaptivePlayback clamping

    @MainActor func testSetAdaptivePlayback_clampsBelowMinSpeed_doesNotCrash() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        // min valid speed is 0.5; values below must be clamped, not crash
        engine.setAdaptivePlayback(speed: 0.1, horizontalBias: 0)
    }

    @MainActor func testSetAdaptivePlayback_clampsAboveMaxSpeed_doesNotCrash() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        // max valid speed is 2.0; values above must be clamped, not crash
        engine.setAdaptivePlayback(speed: 9.9, horizontalBias: 0)
    }

    @MainActor func testSetAdaptivePlayback_clampsBias_doesNotCrash() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        // pan range is -1.0...1.0
        engine.setAdaptivePlayback(speed: 1.0, horizontalBias: -5.0)
        engine.setAdaptivePlayback(speed: 1.0, horizontalBias: 5.0)
    }

    // MARK: - Interleaved / overlap scenarios

    @MainActor func testInterruptionDuringBackground_stateIsConsistent() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        engine.suspendForLifecycle()
        postInterruption(type: .began)
        XCTAssertTrue(engine.debugInterrupted)
        XCTAssertFalse(engine.debugAppIsForeground)
        postInterruption(type: .ended, shouldResume: true)
        engine.resumeAfterLifecycle()
        XCTAssertFalse(engine.debugInterrupted)
        XCTAssertTrue(engine.debugAppIsForeground)
    }

    @MainActor func testRouteChangeDuringInterruption_doesNotCorruptState() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        postInterruption(type: .began)
        postRouteChange(reason: .oldDeviceUnavailable)
        XCTAssertTrue(engine.debugInterrupted, "interrupted must remain set after route change during interruption")
        XCTAssertFalse(engine.isPlaying)
        postInterruption(type: .ended, shouldResume: true)
        XCTAssertFalse(engine.debugInterrupted)
        XCTAssertTrue(engine.debugInterruptionShouldResume)
    }

    @MainActor func testRapidSuspendResumeCycle_completesWithinTimeout() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        // Wrap in expectation with explicit timeout so a deadlock surfaces as a fast failure
        // rather than hanging the CI job indefinitely.
        let exp = expectation(description: "20 rapid suspend/resume cycles complete without deadlock")
        DispatchQueue.main.async {
            for _ in 0..<20 {
                engine.suspendForLifecycle()
                engine.resumeAfterLifecycle()
            }
            XCTAssertTrue(engine.debugAppIsForeground)
            XCTAssertFalse(engine.isPlaying)
            exp.fulfill()
        }
        await fulfillment(of: [exp], timeout: 2.0)
    }

    // MARK: - deinit: observer removal and retain cycle

    @MainActor func testDeinit_removesObserversAndDoesNotCrash() async {
        // autoreleasepool forces immediate ARC release — without it the test runner's own
        // pool may keep localEngine alive past XCTAssertNil, giving a false failure.
        weak var weakRef: AudioEngine?
        autoreleasepool {
            let localEngine = AudioEngine()
            weakRef = localEngine
            // localEngine goes out of scope and is released here
        }
        XCTAssertNil(weakRef,
                     "AudioEngine must deallocate — retain cycle in observer closure suspected if this fails")
        // Post notifications after deinit — must not crash (observers must have been removed)
        postInterruption(type: .began)
        postRouteChange(reason: .oldDeviceUnavailable)
        // Reaching here = no EXC_BAD_ACCESS from dangling observer
    }

    // MARK: - AE-1: rate must not move pitch (driven offline through the same unit type)

    /// Ruling AE-1 (2026-09-06): the child's stroke velocity drives the
    /// playback rate; the spatial arm's pitch encodes vertical position.
    /// The engine drives BOTH through one `AVAudioUnitTimePitch`
    /// (pitch-preserving time-stretch + an independent cents shift). This
    /// test DRIVES that unit offline: a 440 Hz triangle rendered at rate
    /// 0.5, 1.0 and 2.0 must stay at 440 Hz, and ±1200 cents must give
    /// 880 / 220 Hz — while the same graph with an `AVAudioUnitVarispeed`
    /// (what "playback-rate pitching" would be) is driven to the failure:
    /// rate 2.0 → 880 Hz. Hardware suite: the simulator skips the engine.
    @MainActor func testTimePitchRate_doesNotMovePitch_varispeedDoes() throws {
        func dominantHz(_ node: AVAudioUnit, configure: (AVAudioUnit) -> Void) throws -> Double {
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
            engine.attach(player); engine.attach(node)
            engine.connect(player, to: node, format: format)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            configure(node)
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            // 2 s of 440 Hz triangle, looped like the carrier.
            let frames = AVAudioFrameCount(88_200)
            let src = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            src.frameLength = frames
            let p = src.floatChannelData![0]
            for i in 0..<Int(frames) {
                let phase = (Double(i) * 440.0 / 44_100).truncatingRemainder(dividingBy: 1)
                p[i] = Float(4 * abs(phase - 0.5) - 1) * 0.5
            }
            try engine.start()
            player.scheduleBuffer(src, at: nil, options: .loops)
            player.play()
            let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                       frameCapacity: engine.manualRenderingMaximumFrameCount)!
            var samples: [Float] = []
            // Skip the unit's warm-up, then keep 1.5 s.
            var rendered = 0
            while rendered < 44_100 * 3 {
                let status = try engine.renderOffline(4096, to: out)
                guard status == .success else { break }
                let q = out.floatChannelData![0]
                if rendered >= 44_100 { samples.append(contentsOf: UnsafeBufferPointer(start: q, count: Int(out.frameLength))) }
                rendered += Int(out.frameLength)
            }
            engine.stop()
            XCTAssertGreaterThan(samples.count, 44_100, "offline render produced too little audio")
            // Fundamental by positive-going zero crossings.
            var crossings = 0
            for i in 1..<samples.count where samples[i - 1] < 0 && samples[i] >= 0 { crossings += 1 }
            return Double(crossings) / (Double(samples.count) / 44_100)
        }
        // Time-pitch: rate does not move pitch.
        for rate: Float in [0.5, 1.0, 2.0] {
            let hz = try dominantHz(AVAudioUnitTimePitch()) { ($0 as! AVAudioUnitTimePitch).rate = rate }
            XCTAssertEqual(hz, 440, accuracy: 15, "AVAudioUnitTimePitch at rate \(rate) moved the pitch to \(hz) Hz")
        }
        // Time-pitch: cents move pitch, independently of rate.
        let up = try dominantHz(AVAudioUnitTimePitch()) { let t = $0 as! AVAudioUnitTimePitch; t.rate = 2.0; t.pitch = 1200 }
        XCTAssertEqual(up, 880, accuracy: 30, "+1200 cents at rate 2.0 should be 880 Hz, got \(up)")
        let down = try dominantHz(AVAudioUnitTimePitch()) { let t = $0 as! AVAudioUnitTimePitch; t.rate = 0.5; t.pitch = -1200 }
        XCTAssertEqual(down, 220, accuracy: 15, "−1200 cents at rate 0.5 should be 220 Hz, got \(down)")
        // The failure the ruling describes, driven: varispeed at rate 2.0 doubles the pitch.
        let vari = try dominantHz(AVAudioUnitVarispeed()) { ($0 as! AVAudioUnitVarispeed).rate = 2.0 }
        XCTAssertEqual(vari, 880, accuracy: 30, "varispeed at rate 2.0 is the confound: expected 880 Hz, got \(vari)")
    }

    // MARK: - Helpers

    /// Post an AVAudioSession interruption notification with forged userInfo.
    /// object: nil matches AudioEngine's observer registration which uses object: nil (any sender).
    @MainActor private func postInterruption(type: AVAudioSession.InterruptionType,
                                  shouldResume: Bool = false) {
        var userInfo: [AnyHashable: Any] = [
            AVAudioSessionInterruptionTypeKey: type.rawValue
        ]
        if type == .ended {
            let options: AVAudioSession.InterruptionOptions = shouldResume ? [.shouldResume] : []
            userInfo[AVAudioSessionInterruptionOptionKey] = options.rawValue
        }
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: userInfo
        )
        drainMain()
    }

    /// Post an AVAudioSession route change notification with forged userInfo.
    @MainActor private func postRouteChange(reason: AVAudioSession.RouteChangeReason) {
        let userInfo: [AnyHashable: Any] = [
            AVAudioSessionRouteChangeReasonKey: reason.rawValue
        ]
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: nil,
            userInfo: userInfo
        )
        drainMain()
    }

    /// Drain the main RunLoop long enough for .main-queue observers to fire synchronously.
    /// Observers in AudioEngine are registered on .main queue; XCTest runs test methods on the
    /// main thread, so RunLoop.main.run(until:) is the correct and sufficient drain mechanism.
    @MainActor private func drainMain() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
}
