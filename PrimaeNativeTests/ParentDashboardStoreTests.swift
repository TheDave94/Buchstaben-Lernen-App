import Testing
import Foundation
@testable import PrimaeNative

private func utcCal() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var c = DateComponents(); c.year = year; c.month = month; c.day = day; c.hour = 10
    return utcCal().date(from: c)!
}

private func makeStore() -> JSONParentDashboardStore {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("Dashboard-\(UUID().uuidString).json")
    return JSONParentDashboardStore(fileURL: url, calendar: utcCal())
}

@Suite @MainActor struct LetterAccuracyStatTests {
    @Test func averageAccuracy_empty() {
        #expect(LetterAccuracyStat(letter: "A", accuracySamples: []).averageAccuracy == 0)
    }
    @Test func averageAccuracy_singleSample() {
        #expect(abs(LetterAccuracyStat(letter: "A", accuracySamples: [0.8]).averageAccuracy - 0.8) < 1e-9)
    }
    @Test func averageAccuracy_multipleSamples() {
        #expect(abs(LetterAccuracyStat(letter: "A", accuracySamples: [0.6, 0.8, 1.0]).averageAccuracy - 0.8) < 1e-9)
    }
    @Test func trend_empty_isZero() {
        #expect(LetterAccuracyStat(letter: "A", accuracySamples: []).trend == 0)
    }
    @Test func trend_singleSample_isZero() {
        #expect(LetterAccuracyStat(letter: "A", accuracySamples: [0.5]).trend == 0)
    }
    @Test func trend_improvingSequence_positive() {
        #expect(LetterAccuracyStat(letter: "A", accuracySamples: [0.3, 0.5, 0.7, 0.9]).trend > 0)
    }
    @Test func trend_decliningSequence_negative() {
        #expect(LetterAccuracyStat(letter: "A", accuracySamples: [0.9, 0.7, 0.5, 0.3]).trend < 0)
    }
    @Test func trend_usesLast10Samples() {
        let stat = LetterAccuracyStat(letter: "A", accuracySamples: Array(repeating: 0.0, count: 5) + Array(repeating: 1.0, count: 10))
        #expect(abs(stat.trend) < 1e-9)
    }
}

@Suite struct DashboardSnapshotTests {
    @Test func topLetters_empty() {
        #expect(DashboardSnapshot().topLetters.isEmpty)
    }
    @Test func topLetters_limitsToFive() {
        var snap = DashboardSnapshot()
        for (i, letter) in "ABCDEFGH".map(String.init).enumerated() {
            snap.letterStats[letter] = LetterAccuracyStat(letter: letter, accuracySamples: [Double(i) / 10.0])
        }
        #expect(snap.topLetters.count == 5)
    }
    @Test func topLetters_sortedByAccuracyDescending() {
        var snap = DashboardSnapshot()
        snap.letterStats["A"] = LetterAccuracyStat(letter: "A", accuracySamples: [0.9])
        snap.letterStats["B"] = LetterAccuracyStat(letter: "B", accuracySamples: [0.5])
        snap.letterStats["C"] = LetterAccuracyStat(letter: "C", accuracySamples: [0.7])
        #expect(snap.topLetters.first?.letter == "A")
    }
    @Test func lettersBelow_filtersCorrectly() {
        var snap = DashboardSnapshot()
        snap.letterStats["A"] = LetterAccuracyStat(letter: "A", accuracySamples: [0.9])
        snap.letterStats["B"] = LetterAccuracyStat(letter: "B", accuracySamples: [0.4])
        snap.letterStats["C"] = LetterAccuracyStat(letter: "C", accuracySamples: [0.55])
        #expect(snap.lettersBelow(accuracy: 0.6).map(\.letter) == ["B", "C"])
    }
    @Test func totalPracticeTime_sumsRecentDays() {
        var snap = DashboardSnapshot()
        snap.sessionDurations = [
            SessionDurationRecord(dateString: "2025-03-04", durationSeconds: 300),
            SessionDurationRecord(dateString: "2025-03-08", durationSeconds: 600),
            SessionDurationRecord(dateString: "2025-03-10", durationSeconds: 900),
            SessionDurationRecord(dateString: "2025-02-01", durationSeconds: 9999),
        ]
        let total = snap.totalPracticeTime(recentDays: 7, referenceDate: date(2025, 3, 10), calendar: utcCal())
        #expect(abs(total - 1800) < 1e-6)
    }

    // MARK: - phaseScores(for:)

    @Test func phaseScores_emptyForUntracedLetter() {
        let snap = DashboardSnapshot()
        #expect(snap.phaseScores(for: "A").isEmpty)
    }

    @Test func phaseScores_meanAcrossSessionsByPhase() {
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords = [
            PhaseSessionRecord(letter: "A", phase: "observe",   completed: true, score: 0.90, schedulerPriority: 0.5),
            PhaseSessionRecord(letter: "A", phase: "observe",   completed: true, score: 0.80, schedulerPriority: 0.5),
            PhaseSessionRecord(letter: "A", phase: "guided",    completed: true, score: 0.70, schedulerPriority: 0.5),
            PhaseSessionRecord(letter: "A", phase: "freeWrite", completed: true, score: 0.60, schedulerPriority: 0.5),
        ]
        let scores = snap.phaseScores(for: "A")
        #expect(abs((scores["observe"]   ?? -1) - 0.85) < 1e-9)
        #expect(abs((scores["guided"]    ?? -1) - 0.70) < 1e-9)
        #expect(abs((scores["freeWrite"] ?? -1) - 0.60) < 1e-9)
    }

    @Test func phaseScores_excludesIncompleteSessions() {
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords = [
            PhaseSessionRecord(letter: "B", phase: "observe", completed: true,  score: 1.00, schedulerPriority: 0.5),
            PhaseSessionRecord(letter: "B", phase: "observe", completed: false, score: 0.00, schedulerPriority: 0.5),
        ]
        // Only the completed sample contributes — incomplete sessions are
        // pedagogically meaningless for accuracy reporting.
        #expect(abs((snap.phaseScores(for: "B")["observe"] ?? -1) - 1.0) < 1e-9)
    }

    @Test func phaseScores_caseInsensitive() {
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords = [
            PhaseSessionRecord(letter: "A", phase: "guided", completed: true, score: 0.5, schedulerPriority: 0.5),
        ]
        #expect(snap.phaseScores(for: "a") == snap.phaseScores(for: "A"))
    }

    // MARK: - dailyPracticeMinutes(days:)

    @Test func dailyPracticeMinutes_returnsExactWindowLength() {
        let snap = DashboardSnapshot()
        let series = snap.dailyPracticeMinutes(days: 30,
                                                referenceDate: date(2025, 3, 10),
                                                calendar: utcCal())
        #expect(series.count == 30)
    }

    @Test func dailyPracticeMinutes_fillsMissingDaysWithZero() {
        var snap = DashboardSnapshot()
        snap.sessionDurations = [
            SessionDurationRecord(dateString: "2025-03-10", durationSeconds: 600),  // 10 min
        ]
        let series = snap.dailyPracticeMinutes(days: 7,
                                                referenceDate: date(2025, 3, 10),
                                                calendar: utcCal())
        // The most recent entry is the reference date; older days fill with 0.
        #expect(series.count == 7)
        #expect(abs((series.last?.minutes ?? -1) - 10.0) < 1e-9, "today should be 10 min")
        #expect(series.dropLast().allSatisfy { $0.minutes == 0 },
                "all earlier days should be filled with 0 minutes")
    }

    @Test func dailyPracticeMinutes_sumsMultipleSessionsPerDay() {
        var snap = DashboardSnapshot()
        snap.sessionDurations = [
            SessionDurationRecord(dateString: "2025-03-10", durationSeconds: 300),
            SessionDurationRecord(dateString: "2025-03-10", durationSeconds: 600),
        ]
        let series = snap.dailyPracticeMinutes(days: 1,
                                                referenceDate: date(2025, 3, 10),
                                                calendar: utcCal())
        #expect(abs((series.first?.minutes ?? -1) - 15.0) < 1e-9, "two sessions on the same day must sum")
    }

    @Test func dailyPracticeMinutes_isOldestFirst() {
        var snap = DashboardSnapshot()
        snap.sessionDurations = [
            SessionDurationRecord(dateString: "2025-03-09", durationSeconds: 60),
            SessionDurationRecord(dateString: "2025-03-10", durationSeconds: 120),
        ]
        let series = snap.dailyPracticeMinutes(days: 2,
                                                referenceDate: date(2025, 3, 10),
                                                calendar: utcCal())
        #expect(series.count == 2)
        #expect(abs(series[0].minutes - 1.0) < 1e-9, "oldest first: index 0 is the older day")
        #expect(abs(series[1].minutes - 2.0) < 1e-9)
    }

    // D11#2 regression: the proxy pairs *consecutive* records per letter
    // to compute a score delta. Before the fix, "consecutive" meant
    // array (insertion) order, not `recordedAt` order — feeding the same
    // records in a different insertion order silently repaired/garbled
    // the pairing. The proxy must now be insertion-order independent.
    @Test func schedulerEffectivenessProxy_isInsertionOrderIndependent() {
        let letterARecords = [
            PhaseSessionRecord(letter: "A", phase: "freeWrite", completed: true,
                                score: 0.2, schedulerPriority: 0.1,
                                recordedAt: date(2025, 3, 1)),
            PhaseSessionRecord(letter: "A", phase: "freeWrite", completed: true,
                                score: 0.5, schedulerPriority: 0.5,
                                recordedAt: date(2025, 3, 2)),
            PhaseSessionRecord(letter: "A", phase: "freeWrite", completed: true,
                                score: 0.9, schedulerPriority: 0.9,
                                recordedAt: date(2025, 3, 3)),
        ]
        var chronological = DashboardSnapshot()
        chronological.phaseSessionRecords = letterARecords
        var reverseInserted = DashboardSnapshot()
        reverseInserted.phaseSessionRecords = letterARecords.reversed()

        let proxyChrono   = chronological.schedulerEffectivenessProxy
        let proxyReversed = reverseInserted.schedulerEffectivenessProxy
        #expect(abs(proxyChrono - proxyReversed) < 1e-9,
                "proxy must be keyed on recordedAt, not insertion order")
    }
}

@Suite struct JSONParentDashboardStoreTests {
    @Test func initialState_empty() {
        let store = makeStore()
        #expect(store.snapshot.letterStats.isEmpty)
        #expect(store.snapshot.sessionDurations.isEmpty)
    }
    @Test func recordSession_updatesLetterStats() {
        let store = makeStore()
        store.recordSession(letter: "A", accuracy: 0.8, durationSeconds: 60, date: date(2025, 1, 1), condition: .threePhase)
        #expect(store.snapshot.letterStats["A"]?.accuracySamples == [0.8])
    }
    @Test func recordSession_accumulates() {
        let store = makeStore()
        store.recordSession(letter: "A", accuracy: 0.6, durationSeconds: 30, date: date(2025, 1, 1), condition: .threePhase)
        store.recordSession(letter: "A", accuracy: 0.9, durationSeconds: 40, date: date(2025, 1, 2), condition: .threePhase)
        #expect(store.snapshot.letterStats["A"]?.accuracySamples.count == 2)
    }
    @Test func recordSession_normalizesLetterToUppercase() {
        let store = makeStore()
        store.recordSession(letter: "a", accuracy: 0.7, durationSeconds: 20, date: date(2025, 1, 1), condition: .threePhase)
        #expect(store.snapshot.letterStats["A"] != nil)
        #expect(store.snapshot.letterStats["a"] == nil)
    }
    @Test func recordSession_zeroDuration_notRecorded() {
        let store = makeStore()
        store.recordSession(letter: "B", accuracy: 0.5, durationSeconds: 0, date: date(2025, 1, 1), condition: .threePhase)
        #expect(store.snapshot.sessionDurations.isEmpty)
    }
    @Test func reset_clearsAll() {
        let store = makeStore()
        store.recordSession(letter: "A", accuracy: 0.9, durationSeconds: 120, date: date(2025, 1, 1), condition: .threePhase)
        store.reset()
        #expect(store.snapshot.letterStats.isEmpty)
        #expect(store.snapshot.sessionDurations.isEmpty)
    }
    @Test func persistence_roundtrip() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DashPersist-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let firstStore = JSONParentDashboardStore(fileURL: url, calendar: utcCal())
        firstStore.recordSession(letter: "Z", accuracy: 0.75, durationSeconds: 90, date: date(2025, 6, 1), condition: .threePhase)
        await firstStore.flush()

        let store2 = JSONParentDashboardStore(fileURL: url, calendar: utcCal())
        #expect(store2.snapshot.letterStats["Z"]?.accuracySamples == [0.75])
        #expect(store2.snapshot.sessionDurations.count == 1)
    }
    @Test func multipleLetters_independent() {
        let store = makeStore()
        store.recordSession(letter: "A", accuracy: 1.0, durationSeconds: 10, date: date(2025, 1, 1), condition: .threePhase)
        store.recordSession(letter: "B", accuracy: 0.5, durationSeconds: 10, date: date(2025, 1, 1), condition: .threePhase)
        #expect(abs((store.snapshot.letterStats["A"]?.averageAccuracy ?? 0) - 1.0) < 1e-9)
        #expect(abs((store.snapshot.letterStats["B"]?.averageAccuracy ?? 0) - 0.5) < 1e-9)
    }

    /// Rapid-fire batching contract: when several `recordSession` /
    /// `recordPhaseSession` calls fire synchronously in one runloop tick,
    /// the cancel-and-replace chain in `persist()` must coalesce them
    /// into a single durable write that reflects the final accumulated
    /// state. Cancelling earlier writes must not drop data — the
    /// value-type `DashboardSnapshot` snapshot in each task already
    /// captures the accumulated state at enqueue time.
    @Test func rapidFireWrites_finalStateIsDurable() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DashRapid-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = JSONParentDashboardStore(fileURL: url, calendar: utcCal())
        // Four synchronous writes — exercises the cancel-and-replace chain.
        store.recordSession(letter: "A", accuracy: 0.5, durationSeconds: 10, date: date(2025, 1, 1), condition: .threePhase)
        store.recordSession(letter: "B", accuracy: 0.6, durationSeconds: 10, date: date(2025, 1, 1), condition: .threePhase)
        store.recordSession(letter: "C", accuracy: 0.7, durationSeconds: 10, date: date(2025, 1, 1), condition: .threePhase)
        store.recordSession(letter: "D", accuracy: 0.8, durationSeconds: 10, date: date(2025, 1, 1), condition: .threePhase)
        await store.flush()

        let reloaded = JSONParentDashboardStore(fileURL: url, calendar: utcCal())
        #expect(reloaded.snapshot.letterStats["A"]?.accuracySamples == [0.5])
        #expect(reloaded.snapshot.letterStats["B"]?.accuracySamples == [0.6])
        #expect(reloaded.snapshot.letterStats["C"]?.accuracySamples == [0.7])
        #expect(reloaded.snapshot.letterStats["D"]?.accuracySamples == [0.8])
        #expect(reloaded.snapshot.sessionDurations.count == 4)
    }
}

// MARK: - averageWritingDimensions denominators (audit 2026-09-04)

@Suite @MainActor struct WritingDimensionAverageTests {
    private func record(_ json: String) throws -> PhaseSessionRecord {
        try JSONDecoder().decode(PhaseSessionRecord.self, from: Data(json.utf8))
    }

    /// The decoder sets the four dimensions independently, so a row can
    /// carry `formAccuracy` without `tempoConsistency`. That row used to
    /// add 0 to tempo's numerator and 1 to the shared denominator.
    @Test("each dimension averages over its own present values")
    func perDimensionDenominators() throws {
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords = [
            try record("""
            {"letter":"A","phase":"freeWrite","completed":true,"score":0.5,"schedulerPriority":0,
             "condition":"threePhase","formAccuracy":0.6,"tempoConsistency":0.8,"pressureControl":0.4,"rhythmScore":0.2}
            """),
            try record("""
            {"letter":"A","phase":"freeWrite","completed":true,"score":0.5,"schedulerPriority":0,
             "condition":"threePhase","formAccuracy":0.4}
            """),
        ]
        let dims = try #require(snap.averageWritingDimensions)
        #expect(abs(dims.form - 0.5) < 1e-9)
        #expect(abs(dims.tempo - 0.8) < 1e-9, "tempo has ONE value; got \(dims.tempo)")
        #expect(abs(dims.pressure - 0.4) < 1e-9)
        #expect(abs(dims.rhythm - 0.2) < 1e-9)
    }
}

