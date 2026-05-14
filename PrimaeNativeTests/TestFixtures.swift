import Foundation
import CoreGraphics
import UserNotifications
@testable import PrimaeNative

// MARK: - Shared no-op stubs for unit tests

final class StubAudio: AudioControlling {
    var initializationError: String? { nil }
    func loadAudioFile(named: String, autoplay: Bool) {}
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) {}
    func play() {}
    func stop() {}
    func restart() {}
    func suspendForLifecycle() {}
    func resumeAfterLifecycle() {}
    func cancelPendingLifecycleWork() {}
}

final class StubHaptics: HapticEngineProviding {
    func prepare() {}
    func fire(_ event: HapticEvent) {}
}

// MARK: - No-op resource provider (avoids FileManager bundle scan hang in CI)
final class StubResourceProvider: LetterResourceProviding {
    var bundle: Bundle = .main
    var searchBundles: [Bundle] { [bundle] }

    /// Temporary directory containing a test letter whose stroke checkpoints
    /// align with the standard test drag helpers (from (0.25,0.5) → (0.5,0.5)
    /// in normalised coordinates on a 400×400 canvas).
    private static let testLetterDir: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StubLetterResources", isDirectory: true)
        let letterDir = dir.appendingPathComponent("Letters/Regular/A", isDirectory: true)
        try? FileManager.default.createDirectory(at: letterDir, withIntermediateDirectories: true)

        // Single horizontal stroke matching the test drag path
        let strokes: [String: Any] = [
            "letter": "A",
            "checkpointRadius": 0.5,
            "strokes": [
                [
                    "id": 1,
                    "checkpoints": [["x": 0.00, "y": 0.50], ["x": 0.02, "y": 0.50], ["x": 0.04, "y": 0.50], ["x": 0.06, "y": 0.50], ["x": 0.08, "y": 0.50], ["x": 0.10, "y": 0.50], ["x": 0.12, "y": 0.50], ["x": 0.14, "y": 0.50], ["x": 0.16, "y": 0.50], ["x": 0.18, "y": 0.50], ["x": 0.20, "y": 0.50], ["x": 0.22, "y": 0.50], ["x": 0.24, "y": 0.50], ["x": 0.26, "y": 0.50], ["x": 0.28, "y": 0.50], ["x": 0.30, "y": 0.50], ["x": 0.32, "y": 0.50], ["x": 0.34, "y": 0.50], ["x": 0.36, "y": 0.50], ["x": 0.38, "y": 0.50], ["x": 0.40, "y": 0.50], ["x": 0.42, "y": 0.50], ["x": 0.44, "y": 0.50], ["x": 0.46, "y": 0.50], ["x": 0.48, "y": 0.50], ["x": 0.50, "y": 0.50], ["x": 0.52, "y": 0.50], ["x": 0.54, "y": 0.50], ["x": 0.56, "y": 0.50], ["x": 0.58, "y": 0.50], ["x": 0.60, "y": 0.50], ["x": 0.62, "y": 0.50], ["x": 0.64, "y": 0.50], ["x": 0.66, "y": 0.50], ["x": 0.68, "y": 0.50], ["x": 0.70, "y": 0.50], ["x": 0.72, "y": 0.50], ["x": 0.74, "y": 0.50], ["x": 0.76, "y": 0.50], ["x": 0.78, "y": 0.50], ["x": 0.80, "y": 0.50], ["x": 0.82, "y": 0.50], ["x": 0.84, "y": 0.50], ["x": 0.86, "y": 0.50], ["x": 0.88, "y": 0.50], ["x": 0.90, "y": 0.50], ["x": 0.92, "y": 0.50], ["x": 0.94, "y": 0.50], ["x": 0.96, "y": 0.50], ["x": 0.98, "y": 0.50]]
                ]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: strokes, options: .prettyPrinted)
        try? data.write(to: letterDir.appendingPathComponent("strokes.json"))

        // Dummy audio file (zero bytes — StubAudio ignores it)
        try? Data().write(to: letterDir.appendingPathComponent("A.mp3"))

        return dir
    }()

    func allResourceURLs() -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: Self.testLetterDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    func resourceURL(for relativePath: String) -> URL? {
        let url = Self.testLetterDir.appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

// MARK: - No-op progress store (avoids FileManager.applicationSupportDirectory hang in CI)
final class StubProgressStore: ProgressStoring {
    func progress(for letter: String) -> LetterProgress { LetterProgress() }
    func recordCompletion(for letter: String, accuracy: Double,
                          phaseScores: [String: Double]?, speed: Double?,
                          recognitionResult: RecognitionResult?) {}
    // Explicitly opt in to no-op behaviour for the optional protocol
    // methods. The protocol's extension defaults are `fatalError` so a
    // forgotten stub override fails loudly in tests instead of silently
    // dropping thesis data.
    func recordPaperTransferScore(for letter: String, score: Double) {}
    func recordVariantUsed(for letter: String, variantID: String?) {}
    func recordFreeformCompletion(letter: String, result: RecognitionResult) {}
    func recordRecognitionSample(letter: String, result: RecognitionResult) {}
    func resetAll() {}
    var allProgress: [String: LetterProgress] { [:] }
    var totalCompletions: Int { 0 }
}

// MARK: - No-op streak store
final class StubStreakStore: StreakStoring {
    var currentStreak: Int { 0 }
    var longestStreak: Int { 0 }
    var totalCompletions: Int { 0 }
    var completedLetters: Set<String> { [] }
    @discardableResult
    func recordSession(date: Date, lettersCompleted: [String], accuracy: Double) -> [RewardEvent] { [] }
    func reset() {}
}

// MARK: - No-op dashboard store
final class StubDashboardStore: ParentDashboardStoring {
    var snapshot: DashboardSnapshot { DashboardSnapshot() }
    func recordSession(letter: String, accuracy: Double,
                       durationSeconds: TimeInterval,
                       wallClockSeconds: TimeInterval?,
                       date: Date, condition: ThesisCondition,
                       inputDevice: String?) {}
    func recordPhaseSession(letter: String, phase: String, completed: Bool, score: Double, schedulerPriority: Double, condition: ThesisCondition, assessment: WritingAssessment?, recognition: RecognitionSample?, inputDevice: String?) {}
    func reset() {}
}

// MARK: - No-op onboarding store
final class StubOnboardingStore: OnboardingStoring {
    var hasCompletedOnboarding: Bool { false }
    var savedStep: OnboardingStep? { nil }
    var variantUsed: OnboardingVariant? { nil }
    func markComplete(variant: OnboardingVariant) {}
    func saveProgress(step: OnboardingStep) {}
    func reset() {}
}

// MARK: - No-op notification center (avoids UNUserNotificationCenter.current() in CI)
final class StubNotificationCenter: UserNotificationCenterProtocol {
    func requestAuthorization(options: UNAuthorizationOptions,
                               completionHandler: @escaping @Sendable (Bool, Error?) -> Void) {
        completionHandler(false, nil)
    }
    func add(_ request: UNNotificationRequest,
             withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?) {}
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {}
    func removeAllPendingNotificationRequests() {}
}

// MARK: - Null letter cache (throws on load — forces fresh parse, prevents cross-test pollution)
struct NullLetterCache: LetterCacheStoring {
    func save(_ letters: [LetterAsset]) throws(LetterRepositoryError) {}
    func load() throws(LetterRepositoryError) -> [LetterAsset] {
        throw LetterRepositoryError.cacheReadFailed(path: "")
    }
    func clear() {}
}

// MARK: - Shared VM factory
@MainActor
func makeTestVM(
    audio: AudioControlling? = nil,
    haptics: HapticEngineProviding? = nil
) -> TracingViewModel {
    var deps = TracingDependencies.stub
    if let audio    { deps = deps.with(audio: audio) }
    if let haptics  { deps = deps.with(haptics: haptics) }
    return TracingViewModel(deps)
}

// MARK: - TracingDependencies test builder
extension TracingDependencies {
    /// Fully-stubbed configuration safe for headless CI.
    /// No FileManager, no AVAudioEngine, no UNUserNotificationCenter.
    @MainActor
    static var stub: TracingDependencies {
        let progressStore = StubProgressStore()
        let streakStore   = StubStreakStore()
        return TracingDependencies(
            audio:                StubAudio(),
            progressStore:        progressStore,
            haptics:              StubHaptics(),
            repo:                 LetterRepository(resources: StubResourceProvider(),
                                                   cache: NullLetterCache()),
            streakStore:          streakStore,
            dashboardStore:       StubDashboardStore(),
            onboardingStore:      StubOnboardingStore(),
            notificationScheduler: LocalNotificationScheduler(center: StubNotificationCenter()),
            thesisCondition:      .guidedOnly,
            letterRecognizer:     StubLetterRecognizer(),
            speech:               NullSpeechSynthesizer(),
            // Real AVAudioPlayer.play() in PromptPlayer adds enough
            // simulator overhead per call to push the rapid-tap test
            // past its 100 ms wall-clock playIntent debounce.
            makePromptPlayer:     { _ in NullPromptPlayer() }
        )
    }

    func with(audio: AudioControlling) -> TracingDependencies {
        var copy = self; copy.audio = audio; return copy
    }
    func with(progressStore: ProgressStoring) -> TracingDependencies {
        var copy = self; copy.progressStore = progressStore; return copy
    }
    func with(haptics: HapticEngineProviding) -> TracingDependencies {
        var copy = self; copy.haptics = haptics; return copy
    }
    func with(repo: LetterRepository) -> TracingDependencies {
        var copy = self; copy.repo = repo; return copy
    }
    func with(streakStore: StreakStoring) -> TracingDependencies {
        var copy = self; copy.streakStore = streakStore; return copy
    }
    func with(dashboardStore: ParentDashboardStoring) -> TracingDependencies {
        var copy = self; copy.dashboardStore = dashboardStore; return copy
    }
    func with(onboardingStore: OnboardingStoring) -> TracingDependencies {
        var copy = self; copy.onboardingStore = onboardingStore; return copy
    }
    func with(thesisCondition: ThesisCondition) -> TracingDependencies {
        var copy = self; copy.thesisCondition = thesisCondition; return copy
    }
}
