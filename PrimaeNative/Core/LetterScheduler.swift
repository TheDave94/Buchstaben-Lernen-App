// LetterScheduler.swift
// PrimaeNative
//
// Lightweight spaced-repetition scheduler that prioritises letters by
// novelty, recency (Ebbinghaus 1885), accuracy deficit, and practice
// count. Uses data already in JSONProgressStore.
// References: Ebbinghaus 1885 forgetting curve; Cepeda et al. 2006
// spacing meta-analysis.

import Foundation

struct LetterScheduler {

    // MARK: - Scored letter

    /// A letter with its computed practice priority.
    struct ScoredLetter: Comparable, Equatable {
        let letter: String
        let priority: Double

        static func < (lhs: ScoredLetter, rhs: ScoredLetter) -> Bool {
            lhs.priority > rhs.priority  // Higher priority first
        }
    }

    // MARK: - Tuning weights

    /// How much recency urgency (Ebbinghaus-style forgetting) affects priority.
    var recencyWeight: Double = 0.40

    /// How much accuracy deficit affects priority.
    var accuracyWeight: Double = 0.35

    /// How much novelty (low completion count) affects priority.
    var noveltyWeight: Double = 0.25

    /// Baseline Ebbinghaus memory stability in days. Lower bound for
    /// `effectiveStabilityDays`, which expands per-letter as
    /// completions accrue (SuperMemo-style).
    var memoryStabilityDays: Double = 7.0

    /// Maximum stability the expanding interval can reach. Caps the
    /// flattening so a long-untouched letter still resurfaces.
    var maxStabilityDays: Double = 60.0

    /// Days assigned to letters never practised (treated as "very stale").
    var neverPracticedDays: Double = 30.0

    /// When true, `prioritized` ignores Ebbinghaus/accuracy/novelty
    /// scoring and ranks letters by `-completionCount` (round-robin).
    /// Used by the `.control` thesis arm so scheduling doesn't confound
    /// the phase-progression manipulation.
    var fixedOrder: Bool = false

    /// Builds a control scheduler walking letters round-robin by
    /// completion count.
    static func fixedOrder() -> LetterScheduler {
        var s = LetterScheduler()
        s.fixedOrder = true
        return s
    }

    // MARK: - API

    /// Returns all available letters ordered by practice priority
    /// (highest first). Ties preserve the order of `available` via
    /// Swift's stable sort — pre-sort alphabetically for deterministic
    /// tie-break.
    func prioritized(
        available: [String],
        progress: [String: LetterProgress],
        now: Date = Date()
    ) -> [ScoredLetter] {
        if fixedOrder {
            // priority = -completionCount so less-practised letters
            // bubble up; stable sort preserves caller order on ties.
            return available.map { letter in
                // Progress is keyed canonically (uppercase); `available`
                // carries display names ("a"). Look up by the store's key
                // (audit 2026-09-04, class two).
                let count = progress[LetterProgress.canonicalKey(letter)]?.completionCount ?? 0
                return ScoredLetter(letter: letter, priority: -Double(count))
            }.sorted()
        }
        return available.map { letter in
            score(letter: letter, progress: progress[LetterProgress.canonicalKey(letter)], now: now)
        }.sorted()
    }

    /// Returns the single best letter to practice next.
    func recommendNext(
        available: [String],
        progress: [String: LetterProgress],
        now: Date = Date()
    ) -> String? {
        prioritized(available: available, progress: progress, now: now).first?.letter
    }

    /// Returns the top `n` recommended letters.
    func recommendTopN(
        _ n: Int,
        available: [String],
        progress: [String: LetterProgress],
        now: Date = Date()
    ) -> [ScoredLetter] {
        Array(prioritized(available: available, progress: progress, now: now).prefix(n))
    }

    // MARK: - Scoring

    private func score(
        letter: String,
        progress: LetterProgress?,
        now: Date
    ) -> ScoredLetter {
        let p = progress ?? LetterProgress()

        // Recency: days since last practice.
        let daysSince: Double
        if let last = p.lastCompletedAt {
            daysSince = max(0, now.timeIntervalSince(last) / 86400)
        } else {
            daysSince = neverPracticedDays
        }

        // Accuracy deficit: lower accuracy → higher need for practice.
        let accuracyDeficit = 1.0 - p.bestAccuracy

        // Novelty: fewer completions → more practice needed.
        // Logarithmic decay 1/(1+count) so early completions reduce
        // priority quickly, then it levels off.
        let novelty = 1.0 / (1.0 + Double(p.completionCount))

        // Ebbinghaus recency urgency: 1 - e^(-t/S). Stability S expands
        // per letter as completions + accuracy accrue (SuperMemo SM-2
        // style), so well-practised letters take longer to feel "due".
        let stability = effectiveStabilityDays(for: p)
        let recencyUrgency = 1.0 - exp(-daysSince / stability)

        // Automatization adjustment: speeding up → lower priority so
        // the scheduler focuses on stagnant letters that need it more.
        let speedBonus = automatizationBonus(trend: p.speedTrend)

        // Weighted sum. Factors are in [0, 1], scaled to [0, 100] so
        // weights read as percentages.
        let priority = recencyUrgency  * 100 * recencyWeight
                     + accuracyDeficit * 100 * accuracyWeight
                     + novelty         * 100 * noveltyWeight
                     + speedBonus

        return ScoredLetter(letter: letter, priority: priority)
    }

    /// Per-letter Ebbinghaus stability in days. Grows from
    /// `memoryStabilityDays` toward `maxStabilityDays` as the child
    /// builds up `completionCount` and `bestAccuracy`. Logarithmic in
    /// completions: early rounds widen the interval quickly, later
    /// rounds nudge it only modestly.
    func effectiveStabilityDays(for p: LetterProgress) -> Double {
        guard p.completionCount > 0 else { return memoryStabilityDays }
        // Growth factor 1 + ln(1 + completionCount): after 1
        // completion → 1.69×; after 5 → 2.79×; after 20 → 4.04×.
        let practiceFactor = 1.0 + log(1.0 + Double(p.completionCount))
        // Accuracy factor in [0.5, 1.5]. Struggling letters
        // (bestAccuracy = 0) stay near baseline; clean letters stretch.
        let accuracyFactor = 0.5 + p.bestAccuracy
        let stretched = memoryStabilityDays * practiceFactor * accuracyFactor
        return min(maxStabilityDays, max(memoryStabilityDays, stretched))
    }

    /// Returns a priority adjustment based on writing-speed trend.
    /// Improving speed → negative bonus (deprioritize automatized letters).
    /// Stagnant/declining speed → zero or small positive boost.
    /// Range: approximately [-12, +5] points.
    private func automatizationBonus(trend: [Double]?) -> Double {
        guard let trend, trend.count >= 2 else { return 0 }
        let half = max(1, trend.count / 2)
        let oldAvg = trend.prefix(half).reduce(0.0, +) / Double(half)
        let newAvg = trend.suffix(trend.count - half).reduce(0.0, +) / Double(trend.count - half)
        guard oldAvg > 0 else { return 0 }
        let relativeGain = (newAvg - oldAvg) / oldAvg
        return -min(12.0, max(-5.0, relativeGain * 20.0))
    }
}

// MARK: - Static convenience

extension LetterScheduler {
    /// Default scheduler with standard weights.
    static let standard = LetterScheduler()
}
