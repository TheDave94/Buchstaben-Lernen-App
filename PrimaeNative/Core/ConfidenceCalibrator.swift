// ConfidenceCalibrator.swift
// PrimaeNative
//
// Post-processing shim between raw CoreML softmax probabilities and the
// confidence values the UI feeds into its 0.4 / 0.7 feedback thresholds.
// Applies a confusable-pair penalty and a history-based boost.

import CoreGraphics
import Foundation

/// Adjusts raw GermanLetterRecognizer confidences to reduce false
/// positives on visually-similar letter pairs and reward demonstrated
/// historical accuracy.
///
/// `nonisolated` so `CoreMLLetterRecognizer` can construct it off-main
/// despite the package-level `defaultIsolation(MainActor.self)`.
nonisolated struct ConfidenceCalibrator: Sendable {

    // MARK: - Public knobs

    /// Penalty applied when the prediction is in a confusable pair.
    /// 0.15 = require an extra 15% raw confidence before flagging
    /// "confident". Empirically tuned to push C vs O confusions below
    /// the 0.7 "correct" badge threshold.
    var confusablePenalty: CGFloat

    /// Multiplicative boost applied when the child has a strong history
    /// of writing the expected letter (mean form score ≥
    /// `historyStrongThreshold`). Capped at 1.0.
    var historyBoost: CGFloat

    /// Mean historical form-accuracy required before the history boost
    /// applies. Set high (0.80) so a child who barely practised the
    /// letter doesn't get a free uplift.
    var historyStrongThreshold: CGFloat

    /// Minimum number of history samples required before the history
    /// boost is considered.
    var minimumHistorySamples: Int

    /// Letter pairs the model regularly mixes up. Both cases stay in
    /// the set because the model's output classes are case-specific.
    var confusableLetters: Set<String>

    // MARK: - Init

    init(
        confusablePenalty: CGFloat = 0.15,
        historyBoost: CGFloat = 0.10,
        historyStrongThreshold: CGFloat = 0.80,
        minimumHistorySamples: Int = 5,
        confusableLetters: Set<String> = Self.defaultConfusables
    ) {
        self.confusablePenalty      = confusablePenalty
        self.historyBoost           = historyBoost
        self.historyStrongThreshold = historyStrongThreshold
        self.minimumHistorySamples  = minimumHistorySamples
        self.confusableLetters      = confusableLetters
    }

    /// Default confusable set, including the vertical-stroke trio
    /// I / i / l (the most common German-handwriting confusion at
    /// age 5–6 — all reduce to a single vertical in a child's hand).
    static let defaultConfusables: Set<String> = [
        "C", "c", "O", "o", "S", "s", "V", "v", "W", "w",
        "X", "x", "Z", "z", "P", "p", "U", "u", "K", "k",
        "I", "i", "l"
    ]

    // MARK: - Calibration

    /// Calibrate a raw model confidence. Pass an empty
    /// `historicalFormScores` to skip the boost branch.
    func calibrate(
        rawConfidence: CGFloat,
        predictedLetter: String,
        historicalFormScores: [CGFloat] = []
    ) -> CGFloat {
        var confidence = max(0, min(1, rawConfidence))

        if confusableLetters.contains(predictedLetter) {
            confidence = max(0, confidence - confusablePenalty)
        }

        if historicalFormScores.count >= minimumHistorySamples {
            let mean = historicalFormScores.reduce(0, +) / CGFloat(historicalFormScores.count)
            if mean >= historyStrongThreshold {
                confidence = min(1, confidence * (1 + historyBoost))
            }
        }

        return confidence
    }
}
