import Testing
import Foundation
@testable import PrimaeNative

private func makeStore(calendar: Calendar = utcCalendar()) -> JSONStreakStore {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("StreakTest-\(UUID().uuidString).json")
    return JSONStreakStore(fileURL: url, calendar: calendar)
}

private func utcCalendar() -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal
}

private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var c = DateComponents(); c.year = year; c.month = month; c.day = day
    c.hour = 10; c.minute = 0; c.second = 0
    return utcCalendar().date(from: c)!
}

@Suite @MainActor struct StreakStoreTests {

    @Test func initialState_allZero() {
        let store = makeStore()
        #expect(store.currentStreak == 0)
        #expect(store.longestStreak == 0)
        #expect(store.totalCompletions == 0)
        #expect(store.completedLetters.isEmpty)
    }

    @Test func firstSession_startsStreakAt1() {
        let store = makeStore()
        store.recordSession(date: date(2025, 1, 1), lettersCompleted: ["A"], accuracy: 0.9)
        #expect(store.currentStreak == 1)
    }

    @Test func consecutiveDays_incrementsStreak() {
        let store = makeStore()
        store.recordSession(date: date(2025, 1, 1), lettersCompleted: ["A"], accuracy: 0.9)
        store.recordSession(date: date(2025, 1, 2), lettersCompleted: ["B"], accuracy: 0.9)
        store.recordSession(date: date(2025, 1, 3), lettersCompleted: ["C"], accuracy: 0.9)
        #expect(store.currentStreak == 3)
    }

    @Test func gap_resetsStreak() {
        let store = makeStore()
        store.recordSession(date: date(2025, 1, 1), lettersCompleted: ["A"], accuracy: 0.9)
        store.recordSession(date: date(2025, 1, 2), lettersCompleted: ["B"], accuracy: 0.9)
        store.recordSession(date: date(2025, 1, 4), lettersCompleted: ["C"], accuracy: 0.9)
        #expect(store.currentStreak == 1)
    }

    @Test func sameDayTwice_doesNotDoubleIncrementStreak() {
        let store = makeStore()
        store.recordSession(date: date(2025, 3, 5), lettersCompleted: ["A"], accuracy: 0.8)
        store.recordSession(date: date(2025, 3, 5), lettersCompleted: ["B"], accuracy: 0.8)
        #expect(store.currentStreak == 1)
    }

    @Test func longestStreak_trackedCorrectly() {
        let store = makeStore()
        for d in 1...5 { store.recordSession(date: date(2025, 1, d), lettersCompleted: ["A"], accuracy: 0.9) }
        store.recordSession(date: date(2025, 1, 10), lettersCompleted: ["B"], accuracy: 0.9)
        store.recordSession(date: date(2025, 1, 11), lettersCompleted: ["C"], accuracy: 0.9)
        #expect(store.longestStreak == 5)
        #expect(store.currentStreak == 2)
    }

    @Test func monthBoundary_consecutive() {
        let store = makeStore()
        store.recordSession(date: date(2025, 1, 31), lettersCompleted: ["A"], accuracy: 0.9)
        store.recordSession(date: date(2025, 2, 1), lettersCompleted: ["B"], accuracy: 0.9)
        #expect(store.currentStreak == 2)
    }

    @Test func yearBoundary_consecutive() {
        let store = makeStore()
        store.recordSession(date: date(2024, 12, 31), lettersCompleted: ["A"], accuracy: 0.9)
        store.recordSession(date: date(2025, 1, 1), lettersCompleted: ["B"], accuracy: 0.9)
        #expect(store.currentStreak == 2)
    }

    @Test func totalCompletions_accumulates() {
        let store = makeStore()
        store.recordSession(date: date(2025, 1, 1), lettersCompleted: ["A", "B"], accuracy: 0.9)
        store.recordSession(date: date(2025, 1, 2), lettersCompleted: ["C"], accuracy: 0.9)
        #expect(store.totalCompletions == 3)
    }

    @Test func firstLetter_reward_firedOnce() {
        let store = makeStore()
        let r1 = store.recordSession(date: date(2025, 1, 1), lettersCompleted: ["A"], accuracy: 0.5)
        let r2 = store.recordSession(date: date(2025, 1, 2), lettersCompleted: ["B"], accuracy: 0.5)
        #expect(r1.contains(.firstLetter))
        #expect(!r2.contains(.firstLetter))
    }

    @Test func perfectAccuracy_reward() {
        let store = makeStore()
        let r = store.recordSession(date: date(2025, 1, 1), lettersCompleted: ["A"], accuracy: 1.0)
        #expect(r.contains(.perfectAccuracy))
    }

    @Test func perfectAccuracy_notFiredBelow1() {
        let store = makeStore()
        let r = store.recordSession(date: date(2025, 1, 1), lettersCompleted: ["A"], accuracy: 0.99)
        #expect(!r.contains(.perfectAccuracy))
    }

    @Test func streakDay3_reward() {
        let store = makeStore()
        store.recordSession(date: date(2025, 1, 1), lettersCompleted: ["A"], accuracy: 0.9)
        store.recordSession(date: date(2025, 1, 2), lettersCompleted: ["B"], accuracy: 0.9)
        let r = store.recordSession(date: date(2025, 1, 3), lettersCompleted: ["C"], accuracy: 0.9)
        #expect(r.contains(.streakDay3))
    }

    @Test func streakWeek_reward() {
        let store = makeStore()
        var lastRewards: [RewardEvent] = []
        for d in 1...7 {
            lastRewards = store.recordSession(date: date(2025, 1, d), lettersCompleted: ["A"], accuracy: 0.9)
        }
        #expect(lastRewards.contains(.streakWeek))
    }

    @Test func centuryClub_reward() {
        let store = makeStore()
        for d in 1...33 {
            store.recordSession(date: date(2025, 1, d <= 31 ? d : 31),
                lettersCompleted: ["A", "B", "C"], accuracy: 0.9)
        }
        let r = store.recordSession(date: date(2025, 2, 1), lettersCompleted: ["A"], accuracy: 0.9)
        #expect(store.totalCompletions >= 100)
        #expect(r.contains(.centuryClub), "100 completions must award centuryClub; got \(r)")
    }

    @Test func rewards_notDuplicated() {
        let store = makeStore()
        store.recordSession(date: date(2025, 1, 1), lettersCompleted: ["A"], accuracy: 1.0)
        let r2 = store.recordSession(date: date(2025, 1, 2), lettersCompleted: ["B"], accuracy: 1.0)
        #expect(!r2.contains(.firstLetter))
    }

    @Test func reset_clearsAll() {
        let store = makeStore()
        store.recordSession(date: date(2025, 1, 1), lettersCompleted: ["A", "B"], accuracy: 0.9)
        store.reset()
        #expect(store.currentStreak == 0)
        #expect(store.totalCompletions == 0)
        #expect(store.completedLetters.isEmpty)
    }

    @Test func persistence_roundtrip() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StreakPersist-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let firstStore = JSONStreakStore(fileURL: url, calendar: utcCalendar())
        firstStore.recordSession(date: date(2025, 1, 1), lettersCompleted: ["A", "B"], accuracy: 0.9)
        firstStore.recordSession(date: date(2025, 1, 2), lettersCompleted: ["C"], accuracy: 0.9)
        await firstStore.flush()

        let store2 = JSONStreakStore(fileURL: url, calendar: utcCalendar())
        #expect(store2.currentStreak == 2)
        #expect(store2.totalCompletions == 3)
        #expect(store2.completedLetters.contains("A"))
    }

    @Test func emptySession_noSideEffects() {
        let store = makeStore()
        let r = store.recordSession(date: date(2025, 1, 1), lettersCompleted: [], accuracy: 0.9)
        #expect(r.isEmpty)
        #expect(store.currentStreak == 0)
        #expect(store.totalCompletions == 0)
    }

    // MARK: - Unreadable file (audit 2026-09-04)

    @Test func unreadableFile_isQuarantinedNotOverwritten() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StreakTest-corrupt-\(UUID().uuidString).json")
        try Data("{not json".utf8).write(to: url)
        let store = JSONStreakStore(fileURL: url, calendar: utcCalendar())
        #expect(store.currentStreak == 0, "an unreadable file starts EMPTY, not crashed")
        let dir = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(stem) && $0.contains(".undecodable-") }
        #expect(siblings.count == 1, "the corrupt file must be moved aside, not silently replaced: \(siblings)")
    }

    // MARK: - dailyGoalMet (class two, 2026-09-05)

    @Test func dailyGoalMet_isAwardedWhenTheGoalIsReached() {
        let store = makeStore()
        let none = store.recordSession(date: date(2025, 3, 1), lettersCompleted: ["A"], accuracy: 0.9,
                                       dailyGoalReached: false)
        #expect(!none.contains(.dailyGoalMet), "not yet: \(none)")
        let hit = store.recordSession(date: date(2025, 3, 1), lettersCompleted: ["B"], accuracy: 0.9,
                                      dailyGoalReached: true)
        #expect(hit.contains(.dailyGoalMet), "the goal was reached and the reward never existed before: \(hit)")
        #expect(store.earnedRewards.contains(.dailyGoalMet))
    }

}
