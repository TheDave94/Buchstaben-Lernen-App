import AVFoundation
import Foundation
import OSLog
import Synchronization

@MainActor
public final class AudioEngine: AudioControlling, CustomStringConvertible {

    // MARK: - Observer store (Mutex-protected for nonisolated deinit access)

    private typealias ObserverTasks = (interruption: Task<Void, Never>, routeChange: Task<Void, Never>)
    // nonisolated(unsafe) is load-bearing: nonisolated deinit needs actor-isolation escape. Xcode warning is a false positive — Mutex<> being Sendable is unrelated.
    private nonisolated(unsafe) static let observerStore = Mutex<[ObjectIdentifier: ObserverTasks]>([:])

    // MARK: - Private state

    private let engine     = AVAudioEngine()
    private let player     = AVAudioPlayerNode()
    private let timePitch  = AVAudioUnitTimePitch()
    private var currentFile: AVAudioFile?

    private var shouldResumePlayback          = false
    private var appIsForeground               = true
    private var interrupted                   = false
    private var interruptionShouldResume      = true
    private var interruptionResumeGateRequired = false
    private var pendingLifecyclePauseTask: Task<Void, Error>?

    private let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "PrimaeNative",
        category: "AudioEngine"
    )

    private(set) var isPlaying = false
    /// Non-nil when init failed to bring the audio stack up — VM toasts this
    /// at startup so a parent notices something is wrong instead of seeing
    /// the child poke a silent device. Stays nil after a healthy init.
    private(set) var initializationError: String? = nil

    // MARK: - Tunable parameters (live-adjustable from the debug audio panel)

    /// Linear fade-out duration applied by `stop()` before the player is
    /// halted and the audio session deactivated. 0 reverts to the legacy
    /// abrupt-stop behaviour. Default ~120 ms keeps the cut from sounding
    /// like a chop without delaying the perceived stop noticeably.
    public var fadeOutSeconds: TimeInterval = 0.12

    /// Lower clamp for the time-stretch playback rate set by
    /// `setAdaptivePlayback(speed:_:)`. Slower than this and the audio
    /// becomes unintelligible muddy artefacts.
    public var minPlaybackRate: Float = 0.5

    /// Upper clamp for the time-stretch playback rate. Faster than this and
    /// the audio sounds like a chipmunk regardless of the AVAudioUnitTimePitch
    /// formant preservation.
    public var maxPlaybackRate: Float = 2.0

    /// Pitch shift applied to the time-stretched audio, in cents
    /// (AVAudioUnitTimePitch.pitch). Default 0 = unshifted.
    public var pitchCents: Float {
        get { timePitch.pitch }
        set { timePitch.pitch = newValue }
    }

    /// In-flight fade-out task. Cancelled (and player.volume restored) by
    /// any subsequent `play()` so a quick re-tap during a fade plays at
    /// full volume instead of resuming mid-ramp.
    private var fadeOutTask: Task<Void, Never>?

    /// Per-file loudness gain for `currentFile` (ruling AE-2, 2026-09-06;
    /// computed by AudioEngine+Loudness at load). "Full volume" for the
    /// player is THIS value, not 1.0, so every file plays at one RMS.
    private(set) var loudnessGain: Float = 1.0

    // MARK: - Debug accessors

    #if DEBUG
    var debugInterrupted:                  Bool { interrupted }
    var debugInterruptionShouldResume:     Bool { interruptionShouldResume }
    var debugIsEngineRunning:              Bool { engine.isRunning }
    var debugShouldResumePlayback:         Bool { shouldResumePlayback }
    var debugAppIsForeground:              Bool { appIsForeground }
    var debugInterruptionResumeGateRequired: Bool { interruptionResumeGateRequired }
    #endif

    // MARK: - Init / deinit

    public init() {
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player,    to: timePitch,              format: engine.mainMixerNode.outputFormat(forBus: 0))
        engine.connect(timePitch, to: engine.mainMixerNode,   format: engine.mainMixerNode.outputFormat(forBus: 0))
        player.prepare(withFrameCount: 1024)
        timePitch.rate = 1.0; timePitch.pitch = 0.0

        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback, mode: .default, options: [.interruptSpokenAudioAndMixWithOthers]
            )
            try? AVAudioSession.sharedInstance().setActive(true)
            if !engine.isRunning {
                do { try engine.start() } catch {
                    player.stop()
                    isPlaying             = false
                    shouldResumePlayback  = false
                    initializationError   = "Ton konnte nicht gestartet werden"
                    log.error("Initial engine start failed: \(error.localizedDescription)")
                }
            }
        } catch {
            isPlaying            = false
            shouldResumePlayback = false
            initializationError  = "Audio nicht verfügbar"
            log.error("AVAudioSession config failed: \(error.localizedDescription)")
        }

        let key = ObjectIdentifier(self)

        // Tasks inherit @MainActor isolation from init context.
        // [weak self] is still correct — these tasks are long-lived observers.
        let interruptionTask = Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(
                named: AVAudioSession.interruptionNotification, object: nil
            ) {
                guard notification.name == AVAudioSession.interruptionNotification else { continue }
                guard let self else { break }
                let typeValue    = (notification.userInfo?[AVAudioSessionInterruptionTypeKey]    as? NSNumber)?.uintValue
                let optionsValue = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
                if let typeValue,
                   let type = AVAudioSession.InterruptionType(rawValue: typeValue) {
                    if type == .began {
                        self.isPlaying = false
                        self.handleInterruptionBegan()
                    } else if type == .ended, self.shouldResumePlayback, self.currentFile != nil {
                        if self.canResumePlayback() { self.attemptResumePlayback() }
                    }
                }
                self.handleInterruptionValues(type: typeValue, options: optionsValue)
            }
        }

        let routeChangeTask = Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(
                named: AVAudioSession.routeChangeNotification, object: nil
            ) {
                guard let self else { return }
                let reasonValue = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
                self.handleRouteChangeValue(reason: reasonValue)
            }
        }

        Self.observerStore.withLock {
            $0[key] = (interruption: interruptionTask, routeChange: routeChangeTask)
        }
    }

    nonisolated deinit { AudioEngine.removeObservers(for: self) }

    // MARK: - AudioControlling

    func loadAudioFile(named fileName: String, autoplay: Bool = false) {
        guard let url = resourceURL(for: fileName) else {
            log.warning("Missing audio file: \(fileName)")
            return
        }
        do {
            player.stop()
            currentFile = try AVAudioFile(forReading: url)
            loudnessGain = Self.loudnessGain(forFileAt: url)
            player.volume = loudnessGain
            prepareCurrentTrack()
            guard engine.isRunning else { startIfNeeded(); return }
            shouldResumePlayback = autoplay
            if autoplay { attemptResumePlayback() } else { isPlaying = false }
        } catch {
            player.stop()
            currentFile          = nil
            isPlaying            = false
            shouldResumePlayback = false
            log.error("Failed to load audio file \(fileName): \(error.localizedDescription)")
        }
    }

    func setAdaptivePlayback(speed: Float, horizontalBias: Float) {
        guard speed.isFinite && horizontalBias.isFinite else { return }
        let clampedSpeed = max(minPlaybackRate, min(maxPlaybackRate, speed))
        if timePitch.rate != clampedSpeed { timePitch.rate = clampedSpeed }
        player.pan = max(-1.0, min(1.0, horizontalBias))
    }

    func play() {
        guard currentFile != nil else { return }
        // Cancel any in-flight fade-out and restore full volume so a quick
        // re-tap while the previous stop is fading doesn't play at a half
        // volume snapshot mid-ramp.
        fadeOutTask?.cancel()
        fadeOutTask = nil
        player.volume = loudnessGain
        shouldResumePlayback           = true
        interruptionResumeGateRequired = false
        interruptionShouldResume       = true
        // An explicit play() is the user's intent and outranks a stale
        // interruption flag: iOS does not guarantee an `.ended`
        // notification for every `.began` (an interruption that started
        // while the app was suspended arrives as `.began` on resume with
        // no `.ended`), and `interrupted` was otherwise cleared only by
        // `.ended` — leaving every later play() refused for the rest of
        // the session, both sound arms silent, nothing in the export
        // (audit 2026-09-06, R5).
        interrupted                    = false
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            log.error("Failed to activate audio session: \(error.localizedDescription)")
        }
        if !engine.isRunning { startIfNeeded() }
        attemptResumePlayback()
    }

    func stop() {
        // Cancel any prior fade-out so back-to-back stop()s don't pile up
        // ramp tasks competing on player.volume.
        fadeOutTask?.cancel()
        fadeOutTask = nil

        let needsFade = fadeOutSeconds > 0 && isPlaying && engine.isRunning && player.isPlaying
        let startVolume = player.volume

        guard needsFade else {
            finishStop(restoreVolume: startVolume)
            return
        }

        // Linear fade ramp on player.volume → 0, then complete the existing
        // stop sequence. ~60 Hz step rate is smooth without saturating the
        // main actor; minimum 4 steps so very-short fades still ramp.
        let duration = fadeOutSeconds
        fadeOutTask = Task { [weak self] in
            guard let self else { return }
            let steps = max(4, Int(duration * 60))
            let interval = duration / Double(steps)
            for i in 1...steps {
                if Task.isCancelled { return }
                let progress = Float(i) / Float(steps)
                self.player.volume = startVolume * (1 - progress)
                try? await Task.sleep(for: .seconds(interval))
            }
            if Task.isCancelled { return }
            self.finishStop(restoreVolume: startVolume)
        }
    }

    /// Synchronous tail of `stop()` — runs after the optional fade ramp
    /// completes (or immediately when no fade is needed). Restores
    /// `player.volume` so the next `play()` doesn't start at the faded value.
    ///
    /// Intentionally does NOT call `setActive(false)` on the shared
    /// AVAudioSession. `stop()` fires every time the user lifts a
    /// finger from the canvas (and on phase / letter transitions);
    /// deactivating the shared session at that frequency cut every
    /// in-flight `AVSpeechSynthesizer` utterance short, because the
    /// synth shares this session by default. The session stays
    /// active for AudioEngine's lifetime — `suspendForLifecycle` and
    /// the deinit observer-cleanup handle the genuinely-needed
    /// teardown points (background, interruption, dealloc).
    private func finishStop(restoreVolume: Float) {
        shouldResumePlayback           = false
        isPlaying                      = false
        interruptionResumeGateRequired = false
        cancelPendingLifecycleWork()
        player.reset()
        player.stop()
        player.volume = restoreVolume
        currentFile = nil
    }

    func restart() {
        shouldResumePlayback           = true
        interruptionResumeGateRequired = false
        interruptionShouldResume       = true
        if let file = currentFile { player.stop(); player.scheduleFile(file, at: nil, completionHandler: nil) }
        attemptResumePlayback()
    }

    func suspendForLifecycle() {
        appIsForeground      = false
        cancelPendingLifecycleWork()
        shouldResumePlayback = isPlaying || player.isPlaying
        player.pause()
        isPlaying = false
        pendingSafeEnginePause()
    }

    func resumeAfterLifecycle() {
        guard currentFile != nil else { shouldResumePlayback = false; return }
        appIsForeground = true
        cancelPendingLifecycleWork()
        startIfNeeded()
        if let file = currentFile, !player.isPlaying {
            player.scheduleFile(file, at: nil, completionHandler: nil)
        }
        if engine.isRunning && currentFile != nil && canResumePlayback() && appIsForeground {
            player.play()
            isPlaying = true
        }
    }

    func cancelPendingLifecycleWork() {
        pendingLifecyclePauseTask?.cancel()
        pendingLifecyclePauseTask = nil
    }

    public nonisolated var description: String { "<AudioEngine>" }
}

// MARK: - Private helpers

private extension AudioEngine {

    nonisolated static func removeObservers(for object: AnyObject) {
        let key   = ObjectIdentifier(object)
        let tasks = observerStore.withLock { $0.removeValue(forKey: key) }
        tasks?.interruption.cancel()
        tasks?.routeChange.cancel()
    }

    func resourceURL(for fileName: String) -> URL? {
        let ns    = fileName as NSString
        let name  = (ns.lastPathComponent as NSString).deletingPathExtension
        let ext   = ns.pathExtension
        let dir   = ns.deletingLastPathComponent as String
        for bundle in [Bundle.main, Bundle.module] {
            // FileManager path construction — reliable for nested SPM bundle paths
            if let root = bundle.resourceURL {
                let candidate = root.appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
            // Bundle API with subdirectory
            if !dir.isEmpty,
               let url = bundle.url(forResource: name,
                                    withExtension: ext.isEmpty ? nil : ext,
                                    subdirectory: dir) { return url }
            // Flat fallback
            if let url = bundle.url(forResource: name,
                                    withExtension: ext.isEmpty ? nil : ext) { return url }
        }
        return nil
    }

    func startIfNeeded() {
        guard !engine.isRunning else { return }
        let session  = AVAudioSession.sharedInstance()
        let category = session.category
        let canStart = category == .playback || category == .playAndRecord || category == .multiRoute
        guard canStart || AVAudioApplication.shared.recordPermission == .granted else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        do {
            try engine.start()
        } catch {
            player.stop()
            isPlaying            = false
            shouldResumePlayback = false
            log.error("Engine failed to start: \(error.localizedDescription)")
        }
    }

    func canResumePlayback() -> Bool {
        appIsForeground && !interrupted && shouldResumePlayback
            && (!interruptionResumeGateRequired || interruptionShouldResume)
    }

    func attemptResumePlayback() {
        guard engine.isRunning else { startIfNeeded(); return }
        guard currentFile != nil else { return }
        prepareCurrentTrack()
        guard canResumePlayback() else {
            player.pause()
            isPlaying = false
            pendingSafeEnginePause()
            return
        }
        if !player.isPlaying { player.play() }
        isPlaying = true
    }

    func prepareCurrentTrack() {
        guard let currentFile else { return }
        player.stop()
        scheduleLooping(file: currentFile)
        isPlaying = false
    }

    private func scheduleLooping(file: AVAudioFile) {
        player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.shouldResumePlayback, let f = self.currentFile else { return }
                f.framePosition = 0
                self.scheduleLooping(file: f)
            }
        }
    }

    func pendingSafeEnginePause() {
        cancelPendingLifecycleWork()
        pendingLifecyclePauseTask = Task { [weak self] in
            try await Task.sleep(for: .seconds(0.2))
            guard let self, !Task.isCancelled, !self.isPlaying else { return }
            self.engine.pause()
        }
    }

    func stopAndReset() {
        player.stop()
        engine.stop()
        currentFile                    = nil
        shouldResumePlayback           = false
        appIsForeground                = true
        interrupted                    = false
        interruptionShouldResume       = true
        interruptionResumeGateRequired = false
        cancelPendingLifecycleWork()
        isPlaying = false
    }

    func handleInterruptionBegan() {
        let savedResumeIntent = isPlaying
        player.pause()
        isPlaying = false
        stop()
        // Restore resume intent — stop() clears shouldResumePlayback,
        // but we need it preserved so playback resumes after interruption ends.
        shouldResumePlayback = savedResumeIntent
    }

    func handleInterruptionValues(type typeValue: UInt?, options optionsValue: UInt?) {
        guard let typeValue else { return }
        // handleInterruptionValues is always called from the @MainActor observer Task.
        // The Thread.isMainThread guard is removed — we are always on MainActor here.
        switch AVAudioSession.InterruptionType(rawValue: typeValue) {
        case .began?:
            interrupted                    = true
            interruptionResumeGateRequired = true
            interruptionShouldResume       = false
            player.pause()
            isPlaying = false
            pendingSafeEnginePause()

        case .ended?:
            interrupted = false
            if let optionsValue {
                interruptionShouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    .contains(.shouldResume)
            } else {
                interruptionShouldResume = false
            }
            if interruptionShouldResume { attemptResumePlayback() }

        case nil:
            return
        @unknown default:
            break
        }
    }

    func handleRouteChangeValue(reason reasonValue: UInt?) {
        guard let reasonValue,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        switch reason {
        case .oldDeviceUnavailable:
            stop()
        case .newDeviceAvailable, .categoryChange, .override,
             .routeConfigurationChange, .wakeFromSleep, .noSuitableRouteForCategory:
            // Only resume if we were actually playing — otherwise attemptResumePlayback
            // falls into its !canResumePlayback() branch and schedules
            // pendingSafeEnginePause(), which pauses the engine 0.2s later.
            // That killed all audio when the user connected AirPods while idle.
            if appIsForeground && !interrupted && shouldResumePlayback { attemptResumePlayback() }
        default:
            break
        }
    }
}
