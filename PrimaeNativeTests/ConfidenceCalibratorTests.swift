import Testing
import CoreGraphics
@testable import PrimaeNative

@Suite("ConfidenceCalibrator")
struct ConfidenceCalibratorTests {

    @Test("raw confidence passes through for non-confusable letters with no history")
    func pass_through_when_not_confusable() {
        let c = ConfidenceCalibrator()
        let out = c.calibrate(rawConfidence: 0.82, predictedLetter: "A")
        #expect(abs(out - 0.82) < 0.0001)
    }

    @Test("confusable letters lose 15 %")
    func confusable_penalty_applied() {
        let c = ConfidenceCalibrator()
        let raw: CGFloat = 0.80
        let out = c.calibrate(rawConfidence: raw, predictedLetter: "O")
        #expect(abs(out - (raw - 0.15)) < 0.0001)
    }

    @Test("confusable penalty clamps at zero")
    func confusable_penalty_clamps() {
        let c = ConfidenceCalibrator()
        let out = c.calibrate(rawConfidence: 0.05, predictedLetter: "S")
        #expect(out == 0.0)
    }

    @Test("lowercase confusables also penalized")
    func confusable_pair_covers_lowercase() {
        let c = ConfidenceCalibrator()
        let upper = c.calibrate(rawConfidence: 0.9, predictedLetter: "C")
        let lower = c.calibrate(rawConfidence: 0.9, predictedLetter: "c")
        #expect(upper == lower)
    }

    @Test("history boost applied when ≥5 strong samples")
    func history_boost_with_enough_history() {
        let c = ConfidenceCalibrator()
        let history: [CGFloat] = [0.85, 0.9, 0.82, 0.88, 0.9]
        let raw: CGFloat = 0.6
        let out = c.calibrate(
            rawConfidence: raw,
            predictedLetter: "A",
            historicalFormScores: history
        )
        // 0.6 * 1.10 = 0.66
        #expect(out > raw)
        #expect(abs(out - raw * 1.10) < 0.0001)
    }

    @Test("history boost skipped when fewer than 5 samples")
    func history_boost_skipped_with_few_samples() {
        let c = ConfidenceCalibrator()
        let history: [CGFloat] = [0.9, 0.9, 0.9]
        let raw: CGFloat = 0.6
        let out = c.calibrate(
            rawConfidence: raw,
            predictedLetter: "A",
            historicalFormScores: history
        )
        #expect(out == raw)
    }

    @Test("history boost skipped when mean below threshold")
    func history_boost_skipped_when_weak() {
        let c = ConfidenceCalibrator()
        let history: [CGFloat] = [0.4, 0.5, 0.45, 0.5, 0.55]
        let raw: CGFloat = 0.6
        let out = c.calibrate(
            rawConfidence: raw,
            predictedLetter: "A",
            historicalFormScores: history
        )
        #expect(out == raw)
    }

    @Test("history boost caps at 1.0")
    func history_boost_caps_at_one() {
        let c = ConfidenceCalibrator()
        let history: [CGFloat] = [0.95, 0.95, 0.95, 0.95, 0.95]
        let out = c.calibrate(
            rawConfidence: 0.95,
            predictedLetter: "A",
            historicalFormScores: history
        )
        #expect(out <= 1.0)
    }

    @Test("confusable penalty and history boost can combine")
    func penalty_and_boost_stack() {
        let c = ConfidenceCalibrator()
        let history: [CGFloat] = [0.85, 0.9, 0.82, 0.88, 0.9]
        // Raw 0.80 on 'O' — penalty drops to 0.65, history adds 10% → 0.715.
        let out = c.calibrate(
            rawConfidence: 0.80,
            predictedLetter: "O",
            historicalFormScores: history
        )
        #expect(abs(out - 0.715) < 0.0001)
    }
}
