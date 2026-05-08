import Foundation

/// All injectable dependencies for TracingViewModel. Use `.live` in
/// production, or construct a custom instance in tests. Per-VM
/// controllers are exposed as factories so each instance gets a fresh
/// state without sharing across tests.
@MainActor
struct TracingDependencies {
    var audio: AudioControlling
    var progressStore: ProgressStoring
    var haptics: HapticEngineProviding
    /// Difficulty adaptation policy. `nil` lets the VM pick a default
    /// per `thesisCondition`: `.control` gets a `FixedAdaptationPolicy`
    /// so the difficulty manipulation can't confound the phase IV;
    /// other arms get `MovingAverageAdaptationPolicy`.
    var adaptationPolicy: (any AdaptationPolicy)?
    var repo: LetterRepository
    var streakStore: StreakStoring
    var dashboardStore: ParentDashboardStoring
    var onboardingStore: OnboardingStoring
    var notificationScheduler: LocalNotificationScheduler
    var thesisCondition: ThesisCondition
    var schriftArt: SchriftArt
    var letterOrdering: LetterOrderingStrategy
    var enablePaperTransfer: Bool
    /// Whether freeform writing is exposed in the picker bar.
    var enableFreeformMode: Bool
    /// Play the phoneme instead of the letter name; falls back to
    /// name audio for letters without phoneme recordings.
    var enablePhonemeMode: Bool
    /// Opt-in spaced-retrieval prompts before every Nth letter.
    var enableRetrievalPrompts: Bool
    /// Reverse direct-phase tap order (Spooner 2014).
    var enableBackwardChaining: Bool
    /// CoreML letter recognizer; tests inject a stub.
    var letterRecognizer: LetterRecognizerProtocol
    /// German speech synthesiser; tests inject `NullSpeechSynthesizer`.
    var speech: SpeechSynthesizing

    /// Factory for the per-VM playback controller. Receives audio + the
    /// isPlaying callback the VM closes over with `[weak self]`.
    var makePlaybackController: (AudioControlling, @escaping (Bool) -> Void) -> PlaybackController

    /// Factory for the per-VM PromptPlayer. Tests inject
    /// `NullPromptPlayer` since AVAudioPlayer setup on the simulator
    /// can push rapid-tap tests past the wall-clock debounce.
    var makePromptPlayer: (SpeechSynthesizing) -> any PromptPlaying

    /// Factory for the per-VM message presenter; tests inject an
    /// instant sleep so auto-clear fires deterministically.
    var makeMessagePresenter: () -> TransientMessagePresenter

    /// Factory for the per-VM animation guide controller — keeps
    /// in-flight animation tasks scoped per test.
    var makeAnimationGuide: () -> AnimationGuideController

    /// Factory for the per-VM calibration store; tests can back it
    /// with an in-memory or fake URL.
    var makeCalibrationStore: () -> CalibrationStore

    /// Factory for the per-VM letter scheduler (Ebbinghaus-style).
    /// Tests inject custom weights or fixed-letter stubs.
    var makeLetterScheduler: () -> LetterScheduler

    init(
        audio: AudioControlling = AudioEngine(),
        progressStore: ProgressStoring = JSONProgressStore(),
        haptics: HapticEngineProviding = CoreHapticsEngine(),
        adaptationPolicy: (any AdaptationPolicy)? = nil,
        repo: LetterRepository = LetterRepository(),
        streakStore: StreakStoring = JSONStreakStore(),
        dashboardStore: ParentDashboardStoring = JSONParentDashboardStore(),
        onboardingStore: OnboardingStoring = JSONOnboardingStore(),
        notificationScheduler: LocalNotificationScheduler = LocalNotificationScheduler(),
        // Default to the full four-phase flow unless the install opted
        // into the thesis A/B study; gate lives on ThesisCondition for
        // testability.
        thesisCondition: ThesisCondition = .defaultForInstall,
        schriftArt: SchriftArt = {
            if let raw = UserDefaults.standard.string(forKey: "de.flamingistan.primae.selectedSchriftArt")
                ?? UserDefaults.standard.string(forKey: "selectedSchriftArt") {
                if let art = SchriftArt(rawValue: raw) { return art }
                // Migration: `.schulschrift1995` → `.schreibschrift`
                // when Pesendorfer OTF was replaced by Playwrite AT.
                if raw == "schulschrift1995" { return .schreibschrift }
            }
            return .druckschrift
        }(),
        letterOrdering: LetterOrderingStrategy = {
            if let raw = UserDefaults.standard.string(forKey: "de.flamingistan.primae.letterOrdering"),
               let strategy = LetterOrderingStrategy(rawValue: raw) {
                return strategy
            }
            return .motorSimilarity
        }(),
        enablePaperTransfer: Bool = UserDefaults.standard.bool(
            forKey: "de.flamingistan.primae.enablePaperTransfer"
        ),
        enableFreeformMode: Bool = {
            // Default-on when the key has never been set; once parents
            // toggle it the stored Bool becomes authoritative.
            let key = "de.flamingistan.primae.enableFreeformMode"
            if UserDefaults.standard.object(forKey: key) == nil { return true }
            return UserDefaults.standard.bool(forKey: key)
        }(),
        enablePhonemeMode: Bool = UserDefaults.standard.bool(
            forKey: "de.flamingistan.primae.enablePhonemeMode"
        ),
        enableRetrievalPrompts: Bool = UserDefaults.standard.bool(
            forKey: "de.flamingistan.primae.enableRetrievalPrompts"
        ),
        enableBackwardChaining: Bool = UserDefaults.standard.bool(
            forKey: "de.flamingistan.primae.enableBackwardChaining"
        ),
        letterRecognizer: LetterRecognizerProtocol = CoreMLLetterRecognizer(),
        speech: SpeechSynthesizing = AVSpeechSpeechSynthesizer(),
        makePlaybackController: @escaping (AudioControlling, @escaping (Bool) -> Void) -> PlaybackController = {
            PlaybackController(audio: $0, onIsPlayingChanged: $1)
        },
        makePromptPlayer: @escaping (SpeechSynthesizing) -> any PromptPlaying = {
            PromptPlayer(fallbackSpeech: $0)
        },
        makeMessagePresenter: @escaping () -> TransientMessagePresenter = { TransientMessagePresenter() },
        makeAnimationGuide:   @escaping () -> AnimationGuideController   = { AnimationGuideController() },
        makeCalibrationStore: @escaping () -> CalibrationStore           = { CalibrationStore() },
        makeLetterScheduler:  (() -> LetterScheduler)?                   = nil
    ) {
        self.audio = audio
        self.progressStore = progressStore
        self.haptics = haptics
        self.adaptationPolicy = adaptationPolicy
        self.repo = repo
        self.streakStore = streakStore
        self.dashboardStore = dashboardStore
        self.onboardingStore = onboardingStore
        self.notificationScheduler = notificationScheduler
        self.thesisCondition = thesisCondition
        self.schriftArt = schriftArt
        self.letterOrdering = letterOrdering
        self.enablePaperTransfer = enablePaperTransfer
        self.enableFreeformMode = enableFreeformMode
        self.enablePhonemeMode = enablePhonemeMode
        self.enableRetrievalPrompts = enableRetrievalPrompts
        self.enableBackwardChaining = enableBackwardChaining
        self.letterRecognizer = letterRecognizer
        self.speech = speech
        self.makePlaybackController = makePlaybackController
        self.makePromptPlayer       = makePromptPlayer
        self.makeMessagePresenter   = makeMessagePresenter
        self.makeAnimationGuide     = makeAnimationGuide
        self.makeCalibrationStore   = makeCalibrationStore
        // `.control` gets fixed-order scheduling so it can't confound
        // the phase-progression IV; other conditions get the full
        // Ebbinghaus-weighted scheduler.
        if let factory = makeLetterScheduler {
            self.makeLetterScheduler = factory
        } else {
            let condition = thesisCondition
            self.makeLetterScheduler = {
                condition == .control
                    ? LetterScheduler.fixedOrder()
                    : LetterScheduler()
            }
        }
    }

    /// Production configuration. Reads UserDefaults / ParticipantStore
    /// once on first access (app launch). Post-launch settings changes
    /// write directly to the running VM, not back through `live` —
    /// don't re-read it mid-session expecting fresh defaults.
    static let live = TracingDependencies()
}
