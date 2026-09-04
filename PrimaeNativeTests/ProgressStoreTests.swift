import Testing
import Foundation
@testable import PrimaeNative

@Suite @MainActor struct ProgressStoreTests {

    let tempURL: URL
    let store: JSONProgressStore

    init() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProgressStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempURL = dir.appendingPathComponent("progress.json")
        store = JSONProgressStore(fileURL: tempURL)
    }

    @Test func initialState_isEmpty() {
        #expect(store.totalCompletions == 0)
        #expect(store.allProgress.isEmpty)
    }
    @Test func initialProgress_forUnknownLetter_returnsDefault() {
        let p = store.progress(for: "Z")
        #expect(p.completionCount == 0)
        #expect(p.bestAccuracy == 0.0)
        #expect(p.lastCompletedAt == nil)
    }
    @Test func recordCompletion_incrementsCount() {
        store.recordCompletion(for: "A", accuracy: 0.9)
        #expect(store.progress(for: "A").completionCount == 1)
    }
    @Test func recordCompletion_multipleTimes_incrementsCount() {
        store.recordCompletion(for: "B", accuracy: 0.5)
        store.recordCompletion(for: "B", accuracy: 0.7)
        store.recordCompletion(for: "B", accuracy: 0.6)
        #expect(store.progress(for: "B").completionCount == 3)
    }
    @Test func recordCompletion_tracksBestAccuracy() {
        store.recordCompletion(for: "C", accuracy: 0.5)
        store.recordCompletion(for: "C", accuracy: 0.9)
        store.recordCompletion(for: "C", accuracy: 0.7)
        #expect(abs(store.progress(for: "C").bestAccuracy - 0.9) < 1e-9)
    }
    @Test func recordCompletion_setsLastCompletedAt() {
        let before = Date()
        store.recordCompletion(for: "D", accuracy: 1.0)
        let after = Date()
        let ts = store.progress(for: "D").lastCompletedAt
        #expect(ts != nil)
        #expect(ts! >= before)
        #expect(ts! <= after)
    }
    @Test func recordCompletion_isCaseInsensitive() {
        store.recordCompletion(for: "a", accuracy: 0.8)
        store.recordCompletion(for: "A", accuracy: 0.6)
        #expect(store.progress(for: "A").completionCount == 2)
        #expect(store.progress(for: "a").completionCount == 2)
    }
    @Test func recordCompletion_clampsAccuracyToUnit() {
        store.recordCompletion(for: "E", accuracy: 2.5)
        #expect(store.progress(for: "E").bestAccuracy <= 1.0)
        store.recordCompletion(for: "F", accuracy: -0.5)
        #expect(store.progress(for: "F").bestAccuracy >= 0.0) // unwired-guard-ok: the input was -0.5, so this bound fails without the clamp
    }
    @Test func totalCompletions_sumsAcrossAllLetters() {
        store.recordCompletion(for: "A", accuracy: 1.0)
        store.recordCompletion(for: "A", accuracy: 1.0)
        store.recordCompletion(for: "B", accuracy: 0.8)
        #expect(store.totalCompletions == 3)
    }
    @Test func persistence_survivesReinit() async {
        store.recordCompletion(for: "G", accuracy: 0.75)
        store.recordCompletion(for: "G", accuracy: 0.95)
        await store.flush()
        let reloaded = JSONProgressStore(fileURL: tempURL)
        #expect(reloaded.progress(for: "G").completionCount == 2)
        #expect(abs(reloaded.progress(for: "G").bestAccuracy - 0.95) < 1e-9)
    }
    @Test func persistence_totalCompletionsSurvivesReinit() async {
        store.recordCompletion(for: "H", accuracy: 1.0)
        store.recordCompletion(for: "I", accuracy: 0.9)
        await store.flush()
        #expect(JSONProgressStore(fileURL: tempURL).totalCompletions == 2)
    }
    @Test func resetAll_clearsEverything() {
        store.recordCompletion(for: "J", accuracy: 1.0)
        store.recordCompletion(for: "K", accuracy: 0.8)
        store.resetAll()
        #expect(store.totalCompletions == 0)
        #expect(store.allProgress.isEmpty)
    }
    @Test func resetAll_persistsOnDisk() async {
        store.recordCompletion(for: "L", accuracy: 1.0)
        store.resetAll()
        await store.flush()
        #expect(JSONProgressStore(fileURL: tempURL).totalCompletions == 0)
    }
    @Test func recordCompletion_withPhaseScores_persistsAndLoads() async {
        let scores: [String: Double] = ["observe": 1.0, "guided": 0.85, "freeWrite": 0.72]
        store.recordCompletion(for: "Q", accuracy: 0.85, phaseScores: scores)
        await store.flush()
        let reloaded = JSONProgressStore(fileURL: tempURL)
        let p = reloaded.progress(for: "Q")
        #expect(p.phaseScores != nil)
        #expect(abs((p.phaseScores?["observe"] ?? 0) - 1.0) < 1e-9)
        #expect(abs((p.phaseScores?["guided"] ?? 0) - 0.85) < 1e-9)
        #expect(abs((p.phaseScores?["freeWrite"] ?? 0) - 0.72) < 1e-9)
    }
    @Test func recordCompletion_withoutPhaseScores_leavesPhaseScoresNil() {
        store.recordCompletion(for: "R", accuracy: 0.9)
        #expect(store.progress(for: "R").phaseScores == nil)
    }
    @Test func allProgress_containsAllRecordedLetters() {
        store.recordCompletion(for: "O", accuracy: 0.9)
        store.recordCompletion(for: "P", accuracy: 0.5)
        let all = store.allProgress
        #expect(all.keys.contains("O"))
        #expect(all.keys.contains("P"))
        #expect(!all.keys.contains("Q"))
    }

    // MARK: - speedTrend cap

    @Test func speedTrend_capsAtFiftyEntries() {
        // The thesis export needs the full automatisation trajectory; the
        // scheduler's `automatizationBonus` only reads halves so longer
        // histories don't distort the bonus.
        let speeds: [Double] = (0..<60).map { Double($0) * 0.1 + 0.1 }
        for s in speeds {
            store.recordCompletion(for: "S", accuracy: 0.9,
                                   phaseScores: nil, speed: s)
        }
        let trend = store.progress(for: "S").speedTrend ?? []
        #expect(trend.count == 50, "speedTrend exceeded the documented 50-entry cap")
        // Oldest 10 entries should have been dropped — cap keeps the most
        // recent 50 so the trend reflects the latest sessions.
        #expect(trend.first == speeds[10])
        #expect(trend.last  == speeds.last)
    }

    @Test func speedTrend_isNilUntilFirstSpeedRecorded() {
        store.recordCompletion(for: "T", accuracy: 0.9)
        #expect(store.progress(for: "T").speedTrend == nil)
        store.recordCompletion(for: "T", accuracy: 0.9,
                               phaseScores: nil, speed: 1.5)
        #expect(store.progress(for: "T").speedTrend == [1.5])
    }

    // MARK: - paperTransfer + variant round-trip

    /// Round-trip persistence for `recordPaperTransferScore` — a
    /// regression that nil'd the field would otherwise ship without
    /// breaking any test.
    @Test func recordPaperTransferScore_persistsAndReloads() async {
        store.recordPaperTransferScore(for: "P", score: 0.5)
        #expect(store.progress(for: "P").paperTransferScore == 0.5)
        await store.flush()
        let reloaded = JSONProgressStore(fileURL: tempURL)
        #expect(reloaded.progress(for: "P").paperTransferScore == 0.5)
    }

    /// Round-trip for `recordVariantUsed` so a regression that loses
    /// the variant ID after an app restart can't sneak through. nil
    /// resets the field — also exercised so the "child reverted to
    /// standard form" path stays correct.
    @Test func recordVariantUsed_persistsAndReloads() async {
        store.recordVariantUsed(for: "G", variantID: "open-loop")
        #expect(store.progress(for: "G").lastVariantUsed == "open-loop")
        await store.flush()
        let reloaded = JSONProgressStore(fileURL: tempURL)
        #expect(reloaded.progress(for: "G").lastVariantUsed == "open-loop")
        // Setting back to nil clears the field on the next flush.
        reloaded.recordVariantUsed(for: "G", variantID: nil)
        await reloaded.flush()
        let again = JSONProgressStore(fileURL: tempURL)
        #expect(again.progress(for: "G").lastVariantUsed == nil)
    }

    // MARK: - Recognition samples

    @Test func recordCompletion_storesFullRecognitionSample() {
        let result = RecognitionResult(
            predictedLetter: "O",
            confidence: 0.62,
            topThree: [.init(letter: "O", confidence: 0.62)],
            isCorrect: false  // child was supposed to write A
        )
        store.recordCompletion(for: "A", accuracy: 0.8,
                               phaseScores: nil, speed: nil,
                               recognitionResult: result)
        let p = store.progress(for: "A")
        let sample = p.recognitionSamples?.last
        #expect(sample?.predictedLetter == "O")
        #expect(abs((sample?.confidence ?? 0) - 0.62) < 1e-6)
        #expect(sample?.isCorrect == false)
        // Legacy field stays populated for backward compatibility.
        #expect(p.recognitionAccuracy?.last.map { abs($0 - 0.62) < 1e-6 } == true)
    }

    // MARK: - formAccuracy history (2026-09-04 fix)
    //
    // The calibrator's practised-letter boost ("historicalFormScores")
    // is documented to need geometric form accuracy — how well the
    // child has historically FORMED the letter, not how confident the
    // recognizer has been. Before this fix, no channel carrying real
    // form-accuracy history existed at all, and the read site silently
    // substituted `recognitionAccuracy` (confidence). These tests pin
    // the two channels as genuinely separate.

    @Test("recordCompletion with formAccuracy populates formAccuracyHistory, independent of recognitionResult confidence")
    func recordCompletion_populatesFormAccuracyHistory_separateFromConfidence() {
        let result = RecognitionResult(
            predictedLetter: "A", confidence: 0.30,
            topThree: [.init(letter: "A", confidence: 0.30)], isCorrect: true)
        store.recordCompletion(for: "A", accuracy: 0.8, phaseScores: nil, speed: nil,
                               recognitionResult: result, formAccuracy: 0.95)
        let p = store.progress(for: "A")
        #expect(p.formAccuracyHistory == [0.95],
                "a well-formed letter (0.95) with a LOW recognizer confidence (0.30) must still record the true form accuracy")
        #expect(p.recognitionAccuracy?.last.map { abs($0 - 0.30) < 1e-6 } == true,
                "recognitionAccuracy must independently keep the recognizer's own confidence")
    }

    @Test("formAccuracy nil (no freeWrite phase this session) leaves formAccuracyHistory untouched")
    func recordCompletion_nilFormAccuracy_doesNotAppend() {
        store.recordCompletion(for: "B", accuracy: 0.8, phaseScores: nil, speed: nil,
                               recognitionResult: nil, formAccuracy: nil)
        #expect(store.progress(for: "B").formAccuracyHistory == nil)
    }

    @Test("formAccuracyHistory caps at the same rolling window as recognitionAccuracy")
    func formAccuracyHistory_capsAtTen() {
        for i in 0..<12 {
            let fa = 0.5 + (Double(i) * 0.04)
            store.recordCompletion(for: "C", accuracy: 0.8, phaseScores: nil, speed: nil,
                                   recognitionResult: nil, formAccuracy: fa)
        }
        let history = store.progress(for: "C").formAccuracyHistory
        #expect(history?.count == 10)
        #expect(abs((history?.first ?? 0) - (0.5 + 2 * 0.04)) < 1e-9,
                "oldest 2 of 12 entries should have been dropped")
    }

    @Test("formAccuracy is clamped to 0...1, same discipline as bestAccuracy")
    func formAccuracyHistory_clampsToUnit() throws {
        store.recordCompletion(for: "D", accuracy: 0.8, phaseScores: nil, speed: nil,
                               recognitionResult: nil, formAccuracy: 1.4)
        store.recordCompletion(for: "D", accuracy: 0.8, phaseScores: nil, speed: nil,
                               recognitionResult: nil, formAccuracy: -0.2)
        let history = try #require(store.progress(for: "D").formAccuracyHistory)
        #expect(history == [1.0, 0.0])
    }

    @Test func recordFreeformCompletion_storesFullRecognitionSample() {
        let result = RecognitionResult(
            predictedLetter: "M",
            confidence: 0.91,
            topThree: [.init(letter: "M", confidence: 0.91)],
            isCorrect: false  // freeform has no expectation
        )
        store.recordFreeformCompletion(letter: "M", result: result)
        let p = store.progress(for: "M")
        #expect(p.recognitionSamples?.count == 1)
        #expect(p.recognitionSamples?.first?.predictedLetter == "M")
        #expect(p.freeformCompletionCount == 1)
    }

    @Test func recordRecognitionSample_capsAtTen() {
        for i in 0..<12 {
            let conf = 0.4 + (Double(i) * 0.05)
            let result = RecognitionResult(
                predictedLetter: "A",
                confidence: CGFloat(conf),
                topThree: [.init(letter: "A", confidence: CGFloat(conf))],
                isCorrect: true
            )
            store.recordRecognitionSample(letter: "A", result: result)
        }
        let p = store.progress(for: "A")
        #expect(p.recognitionSamples?.count == 10)
        #expect(p.recognitionAccuracy?.count == 10)
        // Oldest two readings dropped: the first kept reading should be
        // the third one (index 2 → confidence 0.5).
        #expect(abs((p.recognitionSamples?.first?.confidence ?? 0) - 0.5) < 1e-6)
    }
}
