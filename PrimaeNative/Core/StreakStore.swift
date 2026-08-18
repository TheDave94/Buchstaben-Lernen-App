import Foundation

// MARK: - Reward events

enum RewardEvent: String, Codable, CaseIterable, Equatable {
    case firstLetter          // completed a letter for the very first time
    case dailyGoalMet         // completed the configured daily practice goal
    case streakDay3           // 3-day streak
    case streakWeek           // 7-day streak
    case streakMonth          // 30-day streak
    case allLettersComplete   // every letter in the alphabet traced at least once
    case perfectAccuracy      // completed a letter with 100% accuracy
    case centuryClub          // 100 total letter completions
}

// MARK: - Streak store protocol

@MainActor
protocol StreakStoring {
    var currentStreak: Int { get }
    var longestStreak: Int { get }
    var totalCompletions: Int { get }
    var completedLetters: Set<String> { get }
    /// Set of `RewardEvent` cases the child has unlocked across all
    /// sessions. Surfaced in the child-facing Fortschritte gallery as
    /// achievement badges; gray-rendered for unearned events.
    var earnedRewards: Set<RewardEvent> { get }
    /// Record a practice session. Returns any newly earned RewardEvents.
    @discardableResult
    func recordSession(date: Date, lettersCompleted: [String], accuracy: Double) -> [RewardEvent]
    func reset()
    /// Await any pending background write. See ProgressStoring.flush().
    func flush() async
}

extension StreakStoring {
    func flush() async {}
    /// Default empty set so older conformers that pre-date the badge UI
    /// still compile. Production stores override with the persisted set.
    var earnedRewards: Set<RewardEvent> { [] }
}

// MARK: - Persisted model

private struct StreakState: Codable, Equatable {
    var currentStreak: Int = 0
    var longestStreak: Int = 0
    var totalCompletions: Int = 0
    var completedLetters: Set<String> = []
    var earnedRewards: Set<String> = []
    /// Calendar day string "yyyy-MM-dd" of last practice session.
    var lastPracticeDayString: String = ""
    /// Calendar day string of current streak start.
    var streakStartDayString: String = ""
    var schemaVersion: Int? = streakSchemaVersion
}

/// Current on-disk schema for `StreakState`.
private let streakSchemaVersion = 1

// MARK: - JSON-persisted implementation

final class JSONStreakStore: StreakStoring {

    private let fileURL: URL
    private let calendar: Calendar
    private var state: StreakState
    private var pendingSave: Task<Void, Never>?

    init(fileURL: URL? = nil, calendar: Calendar = .current) {
        self.calendar = calendar
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
            self.fileURL = dir.appendingPathComponent("streak.json")
        }
        self.state = Self.load(from: self.fileURL) ?? StreakState()
    }

    var currentStreak: Int { state.currentStreak }
    var longestStreak: Int { state.longestStreak }
    var totalCompletions: Int { state.totalCompletions }
    var completedLetters: Set<String> { state.completedLetters }
    var earnedRewards: Set<RewardEvent> {
        Set(state.earnedRewards.compactMap { RewardEvent(rawValue: $0) })
    }

    @discardableResult
    func recordSession(date: Date, lettersCompleted: [String], accuracy: Double) -> [RewardEvent] {
        guard !lettersCompleted.isEmpty else { return [] }

        let dayString = dayKey(for: date)
        var newRewards: [RewardEvent] = []

        // Update streak
        let wasNewDay = dayString != state.lastPracticeDayString
        if wasNewDay {
            let isConsecutive = isConsecutiveDay(after: state.lastPracticeDayString, current: dayString)
            if isConsecutive {
                state.currentStreak += 1
            } else {
                state.currentStreak = 1
                state.streakStartDayString = dayString
            }
            state.longestStreak = max(state.longestStreak, state.currentStreak)
            state.lastPracticeDayString = dayString
        }

        // Route through `LetterProgress.canonicalKey` so `ß` stays
        // in lock-step with the progress and dashboard stores — the
        // `allLettersComplete` check below uses `"ß"` literally.
        let previousLetterCount = state.completedLetters.count
        state.totalCompletions += lettersCompleted.count
        lettersCompleted.forEach { letter in
            state.completedLetters.insert(LetterProgress.canonicalKey(letter))
        }

        // Check rewards
        let newLetterThisSession = previousLetterCount == 0 && !state.completedLetters.isEmpty
        newRewards += checkReward(.firstLetter, condition: newLetterThisSession)
        newRewards += checkReward(.perfectAccuracy, condition: accuracy >= 1.0)
        newRewards += checkReward(.streakDay3, condition: state.currentStreak >= 3)
        newRewards += checkReward(.streakWeek, condition: state.currentStreak >= 7)
        newRewards += checkReward(.streakMonth, condition: state.currentStreak >= 30)
        newRewards += checkReward(.centuryClub, condition: state.totalCompletions >= 100)
        // allLettersComplete: every supported uppercase letter.
        let allAlphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ".map { String($0) }
            + ["Ä", "Ö", "Ü", "ß"])
        newRewards += checkReward(.allLettersComplete, condition: allAlphabet.isSubset(of: state.completedLetters))

        persist()
        return newRewards
    }

    func reset() {
        state = StreakState()
        persist()
    }

    // MARK: - Private

    private func checkReward(_ reward: RewardEvent, condition: Bool) -> [RewardEvent] {
        guard condition, !state.earnedRewards.contains(reward.rawValue) else { return [] }
        state.earnedRewards.insert(reward.rawValue)
        return [reward]
    }

    private func dayKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      components.year ?? 0,
                      components.month ?? 0,
                      components.day ?? 0)
    }

    private func isConsecutiveDay(after previous: String, current: String) -> Bool {
        guard !previous.isEmpty else { return false }
        guard let prevDate = parseDay(previous), let currDate = parseDay(current) else { return false }
        let diff = calendar.dateComponents([.day], from: prevDate, to: currDate).day ?? 0
        return diff == 1
    }

    private func parseDay(_ string: String) -> Date? {
        let parts = string.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var comps = DateComponents()
        comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
        return calendar.date(from: comps)
    }

    private func persist() {
        // Encode on main, write off main — see ProgressStore.save().
        guard let data = try? JSONEncoder().encode(state) else {
            storePersistenceLogger.warning("StreakStore encode failed — streak state not persisted.")
            return
        }
        let url = fileURL
        // Coalesce + order: see ProgressStore.save() for rationale.
        let previous = pendingSave
        previous?.cancel()
        pendingSave = Task.detached(priority: .utility) {
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                storePersistenceLogger.warning(
                    "StreakStore disk write failed at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Await any pending background write. Required before reading the file
    /// from another store instance.
    func flush() async {
        await pendingSave?.value
    }

    private static func load(from url: URL) -> StreakState? {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(StreakState.self, from: data)
        else { return nil }
        // Refuse a future-schema file — see ProgressStore.load.
        if let v = decoded.schemaVersion, v > streakSchemaVersion {
            storePersistenceLogger.warning(
                "StreakStore at \(url.path, privacy: .public) is schema v\(v) but build expects v\(streakSchemaVersion); ignoring on-disk state.")
            return nil
        }
        return decoded
    }
}
