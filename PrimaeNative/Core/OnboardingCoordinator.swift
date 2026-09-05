import Foundation

// MARK: - Onboarding steps

enum OnboardingStep: String, Codable, CaseIterable, Equatable {
    case welcome
    case traceDemo        // phase 1 — observe (Anschauen) animated stroke demo
    case directDemo       // phase 2 — direct (Richtung lernen) numbered-dot tap demo
    case guidedDemo       // phase 3 — guided (Nachspuren) finger-trace demo
    case freeWriteDemo    // phase 4 — freeWrite (Selbst schreiben) intro
    case rewardIntro      // streak/reward explanation
    case complete
}

// MARK: - Onboarding length variants

/// Onboarding length variants for A/B comparison. The chosen variant
/// is recorded on `OnboardingState.variantUsed` so post-hoc CSV
/// analysis can correlate engagement with onboarding length. `full`
/// is the 7-step flow; `short` collapses to welcome → guided demo → done.
enum OnboardingVariant: String, Codable, CaseIterable, Equatable {
    case full
    case short

    /// German display label for the SettingsView picker.
    var displayName: String {
        switch self {
        case .full:  return "Lang (7 Schritte)"
        case .short: return "Kurz (3 Schritte)"
        }
    }

    /// Step list to iterate through. `complete` is the terminator.
    var steps: [OnboardingStep] {
        switch self {
        case .full:
            return OnboardingStep.allCases
        case .short:
            return [.welcome, .guidedDemo, .complete]
        }
    }
}

// MARK: - Coordinator state machine

struct OnboardingCoordinator: Equatable {

    private(set) var currentStep: OnboardingStep
    private(set) var completedSteps: Set<OnboardingStep>
    let steps: [OnboardingStep]

    init(steps: [OnboardingStep] = OnboardingStep.allCases) {
        self.steps = steps
        self.currentStep = steps.first ?? .welcome
        self.completedSteps = []
    }

    var isComplete: Bool { currentStep == .complete }
    var canGoBack: Bool {
        guard let idx = steps.firstIndex(of: currentStep) else { return false }
        return idx > 0
    }
    var progress: Double {
        guard steps.count > 1 else { return 1.0 }
        let idx = steps.firstIndex(of: currentStep) ?? 0
        return Double(idx) / Double(steps.count - 1)
    }

    /// Advance to next step. Returns true if advanced, false if already complete.
    @discardableResult
    mutating func advance() -> Bool {
        guard let idx = steps.firstIndex(of: currentStep),
              idx + 1 < steps.count else { return false }
        completedSteps.insert(currentStep)
        currentStep = steps[idx + 1]
        return true
    }

    /// Go back to previous step.
    @discardableResult
    mutating func back() -> Bool {
        guard let idx = steps.firstIndex(of: currentStep), idx > 0 else { return false }
        currentStep = steps[idx - 1]
        return true
    }

    /// Skip directly to complete.
    mutating func skip() {
        steps.forEach { completedSteps.insert($0) }
        completedSteps.remove(.complete)
        currentStep = .complete
    }

    /// Jump to a specific step (e.g. resume from persisted state).
    mutating func resume(at step: OnboardingStep) {
        guard steps.contains(step) else { return }
        currentStep = step
    }
}

// MARK: - First-launch detection store

protocol OnboardingStoring {
    var hasCompletedOnboarding: Bool { get }
    var savedStep: OnboardingStep? { get }
    /// Which `OnboardingVariant` ran for this install. Set on first
    /// complete and never overwritten so post-hoc CSV analysis can
    /// correlate the original variant with later engagement metrics.
    var variantUsed: OnboardingVariant? { get }
    func markComplete(variant: OnboardingVariant)
    func saveProgress(step: OnboardingStep)
    func reset()
    /// Re-persist the install's original A/B variant after a `reset()`
    /// wiped it (a parent re-run must not change the recorded assignment).
    func recordVariant(_ variant: OnboardingVariant)
    /// Await any pending background disk write so an app-suspension
    /// flush can guarantee the onboarding step is durable before the
    /// process suspends.
    func flush() async
}

extension OnboardingStoring {
    func flush() async {}
    func markComplete() { markComplete(variant: .full) }
    var variantUsed: OnboardingVariant? { nil }
    func recordVariant(_ variant: OnboardingVariant) {}
}

private struct OnboardingState: Codable {
    var completed: Bool = false
    var savedStepRaw: String? = nil
    /// nil on state files written before the variant field existed.
    var variantUsedRaw: String? = nil
}

final class JSONOnboardingStore: OnboardingStoring {

    private let fileURL: URL
    private var state: OnboardingState
    /// Serialised chain of background disk writes. Lets `persist()` return
    /// immediately (no MainActor hitch on every onboarding step change) while
    /// guaranteeing write order. `flush()` awaits any in-flight write.
    private var pendingSave: Task<Void, Never>?

    init(fileURL: URL? = nil) {
        if let url = fileURL {
            self.fileURL = url
        } else {
            // See ProgressStore.init for the `??` fallback rationale.
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            let dir = support.appendingPathComponent("PrimaeNative", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("onboarding.json")
        }
        self.state = Self.load(from: self.fileURL) ?? OnboardingState()
    }

    var hasCompletedOnboarding: Bool { state.completed }
    var savedStep: OnboardingStep? {
        guard let raw = state.savedStepRaw else { return nil }
        return OnboardingStep(rawValue: raw)
    }
    var variantUsed: OnboardingVariant? {
        guard let raw = state.variantUsedRaw else { return nil }
        return OnboardingVariant(rawValue: raw)
    }

    func markComplete(variant: OnboardingVariant) {
        state.completed = true
        state.savedStepRaw = nil
        // Record only on the FIRST complete — a parent re-run must
        // not overwrite the original A/B assignment.
        if state.variantUsedRaw == nil {
            state.variantUsedRaw = variant.rawValue
        }
        persist()
    }

    func saveProgress(step: OnboardingStep) {
        state.savedStepRaw = step.rawValue
        persist()
    }

    func reset() {
        state = OnboardingState()
        persist()
    }

    func recordVariant(_ variant: OnboardingVariant) {
        state.variantUsedRaw = variant.rawValue
        persist()
    }

    private func persist() {
        // Encode on main, write off main.
        guard let data = try? JSONEncoder().encode(state) else {
            storePersistenceLogger.warning("OnboardingCoordinator encode failed — onboarding state not persisted.")
            return
        }
        let url = fileURL
        // Coalesce-and-await: each call cancels its predecessor and
        // awaits it before writing, so order is preserved on disk.
        let previous = pendingSave
        previous?.cancel()
        pendingSave = Task.detached(priority: .utility) {
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                storePersistenceLogger.warning(
                    "OnboardingCoordinator disk write failed at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func flush() async {
        await pendingSave?.value
    }

    private static func load(from url: URL) -> OnboardingState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(OnboardingState.self, from: data)
    }
}
