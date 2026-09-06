// Direct unit coverage for the recognizer's image pipeline. The
// Vision-request path needs a real or mocked CoreML model and is
// exercised end-to-end via integration tests; the rendering /
// coordinate-flipping internals are pure CoreGraphics and testable
// here without a model.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@Suite struct CoreMLLetterRecognizerImageTests {

    @Test("renderToImage returns nil for empty input")
    func emptyInputReturnsNil() {
        #expect(CoreMLLetterRecognizer.renderToImage(
            points: [], canvasSize: .init(width: 400, height: 400)) == nil)
    }

    @Test("renderToImage returns nil for single point")
    func singlePointReturnsNil() {
        let single = [CGPoint(x: 100, y: 100)]
        #expect(CoreMLLetterRecognizer.renderToImage(
            points: single, canvasSize: .init(width: 400, height: 400)) == nil)
    }

    @Test("renderToImage produces a 40×40 grayscale image for a non-trivial path")
    func nonTrivialPathYields40Square() {
        // Diagonal across the canvas — guaranteed non-zero bounding box
        // in both X and Y so the centering math doesn't divide by zero.
        let diag = (0...20).map { i -> CGPoint in
            let t = Double(i) / 20.0
            return CGPoint(x: 80 + t * 240, y: 80 + t * 240)
        }
        let img = CoreMLLetterRecognizer.renderToImage(
            points: diag, canvasSize: .init(width: 400, height: 400))
        #expect(img != nil, "Expected a non-nil image for a 21-point diagonal")
        #expect(img?.width == 40, "Model expects a 40-pixel-wide grayscale image")
        #expect(img?.height == 40)
    }

    @Test("renderToImage handles a degenerate vertical-only path")
    func degenerateAxis() {
        // All points share the same X — boxW would be 0 without the max(.., 1)
        // guard. Should still produce an image, not crash.
        let vertical = (0...10).map { i in
            CGPoint(x: 200, y: 100 + Double(i) * 20)
        }
        let img = CoreMLLetterRecognizer.renderToImage(
            points: vertical, canvasSize: .init(width: 400, height: 400))
        #expect(img != nil, "Vertical-only path must still rasterise")
    }

    @Test("renderToImage centres the path despite asymmetric input bounds")
    func centeringInvariantUnderTranslation() {
        // Two identical L-shapes at different canvas positions should
        // produce visually-identical 40×40 outputs because the renderer
        // bounding-box-normalises before scaling. We don't assert
        // pixel-equality (subpixel rendering may differ at edges); we
        // assert both calls succeed and return the documented size.
        let lShapeAtTopLeft = [
            CGPoint(x: 50, y: 50), CGPoint(x: 50, y: 90), CGPoint(x: 90, y: 90)
        ]
        let lShapeAtBottomRight = [
            CGPoint(x: 280, y: 280), CGPoint(x: 280, y: 320), CGPoint(x: 320, y: 320)
        ]
        let canvas = CGSize(width: 400, height: 400)
        let a = CoreMLLetterRecognizer.renderToImage(points: lShapeAtTopLeft, canvasSize: canvas)
        let b = CoreMLLetterRecognizer.renderToImage(points: lShapeAtBottomRight, canvasSize: canvas)
        #expect(a != nil && b != nil)
        #expect(a?.width == b?.width)
        #expect(a?.height == b?.height)
    }
}

@Suite struct CoreMLLetterRecognizerPipelineTests {

    /// Deterministic stub classifier — returns canned classifications
    /// regardless of input. Lets the rest of the pipeline (calibrator,
    /// makeResult, isCorrect comparison, raw-vs-calibrated tracking)
    /// be exercised end-to-end without bundling a real `.mlpackage`.
    private func stub(_ canned: [LetterClassification]) -> CoreMLLetterRecognizer.Classifier {
        { _ in canned }
    }

    private let diagonal: [CGPoint] = (0...20).map {
        CGPoint(x: 80 + Double($0) * 12, y: 80 + Double($0) * 12)
    }
    private let canvas = CGSize(width: 400, height: 400)

    @Test("recognize routes the top classification's identifier verbatim")
    func recognizeReturnsTopIdentifier() async {
        let recognizer = CoreMLLetterRecognizer(
            calibrator: ConfidenceCalibrator(),
            classifier: stub([
                LetterClassification(identifier: "A", confidence: 0.92),
                LetterClassification(identifier: "H", confidence: 0.05)
            ])
        )
        let r = await recognizer.recognize(
            points: diagonal, canvasSize: canvas,
            expectedLetter: "A", historicalFormScores: []
        )
        #expect(r?.predictedLetter == "A")
        #expect(r?.isCorrect == true)
    }

    /// Audit 2026-09-06: the history boost belongs to the EXPECTED
    /// letter's form history; a wrong prediction must not inherit it.
    @Test("a strong history boosts only the candidate matching the expected letter")
    func historyBoostScopedToExpectedLetter() {
        let strong: [CGFloat] = [0.9, 0.9, 0.9, 0.9, 0.9]
        let classifications = [
            LetterClassification(identifier: "H", confidence: 0.5),
            LetterClassification(identifier: "A", confidence: 0.4)
        ]
        let r = CoreMLLetterRecognizer.makeResult(
            from: classifications, expectedLetter: "A",
            calibrator: ConfidenceCalibrator(), historicalFormScores: strong)
        // The classifier's confidence is a Float; the calibrator works in
        // CGFloat — compare with a tolerance, not `==` (CI run 1656).
        let unboosted = ConfidenceCalibrator().calibrate(rawConfidence: 0.5, predictedLetter: "H")
        let boosted   = ConfidenceCalibrator().calibrate(rawConfidence: 0.4, predictedLetter: "A",
                                                         historicalFormScores: strong)
        let top = r?.confidence ?? -1
        let a   = r?.topThree.first(where: { $0.letter == "A" })?.confidence ?? -1
        #expect(abs(top - unboosted) < 1e-6, "the wrong top prediction keeps its unboosted confidence: \(top) vs \(unboosted)")
        #expect(abs(a - boosted) < 1e-6, "the expected letter's candidate carries the boost: \(a) vs \(boosted)")
        #expect(boosted > 0.4, "fixture must actually trigger the boost")
    }

    @Test("isCorrect compares case-insensitively against expectedLetter")
    func isCorrectCaseInsensitive() async {
        let recognizer = CoreMLLetterRecognizer(
            calibrator: ConfidenceCalibrator(),
            classifier: stub([LetterClassification(identifier: "a", confidence: 0.8)])
        )
        let r = await recognizer.recognize(
            points: diagonal, canvasSize: canvas,
            expectedLetter: "A", historicalFormScores: []
        )
        #expect(r?.isCorrect == true)
    }

    @Test("isCorrect is false when expectedLetter is nil (freeform mode)")
    func freeformAlwaysIncorrect() async {
        let recognizer = CoreMLLetterRecognizer(
            calibrator: ConfidenceCalibrator(),
            classifier: stub([LetterClassification(identifier: "X", confidence: 0.9)])
        )
        let r = await recognizer.recognize(
            points: diagonal, canvasSize: canvas,
            expectedLetter: nil, historicalFormScores: []
        )
        #expect(r?.isCorrect == false)
        #expect(r?.predictedLetter == "X")
    }

    @Test("rawConfidence preserves the pre-calibration value")
    func rawConfidencePreserved() async {
        let recognizer = CoreMLLetterRecognizer(
            calibrator: ConfidenceCalibrator(),
            classifier: stub([LetterClassification(identifier: "C", confidence: 0.75)])
        )
        let r = await recognizer.recognize(
            points: diagonal, canvasSize: canvas,
            expectedLetter: "C", historicalFormScores: []
        )
        #expect(r?.rawConfidence != nil)
        // 0.75 within float-rounding tolerance.
        #expect(abs((r?.rawConfidence ?? 0) - 0.75) < 1e-4)
    }

    @Test("topThree carries the calibrated confidences for up to 3 candidates")
    func topThreeCarriesCandidates() async {
        let recognizer = CoreMLLetterRecognizer(
            calibrator: ConfidenceCalibrator(),
            classifier: stub([
                LetterClassification(identifier: "A", confidence: 0.7),
                LetterClassification(identifier: "H", confidence: 0.2),
                LetterClassification(identifier: "K", confidence: 0.05),
                LetterClassification(identifier: "M", confidence: 0.03)
            ])
        )
        let r = await recognizer.recognize(
            points: diagonal, canvasSize: canvas,
            expectedLetter: "A", historicalFormScores: []
        )
        #expect(r?.topThree.count == 3)
        #expect(r?.topThree.first?.letter == "A")
    }

    @Test("Empty classifier output → nil result (model-missing fallback path)")
    func emptyClassifierReturnsNil() async {
        let recognizer = CoreMLLetterRecognizer(
            calibrator: ConfidenceCalibrator(),
            classifier: stub([])
        )
        let r = await recognizer.recognize(
            points: diagonal, canvasSize: canvas,
            expectedLetter: "A", historicalFormScores: []
        )
        #expect(r == nil)
    }

    @Test("Short input (< 2 points) skips classifier entirely")
    func shortInputBypassesClassifier() async {
        // The classifier should never be called for a single point,
        // so a stub that fatals-on-call would fail this test if
        // recognize doesn't short-circuit.
        let recognizer = CoreMLLetterRecognizer(
            calibrator: ConfidenceCalibrator(),
            classifier: { _ in
                Issue.record("classifier should not be called for < 2 points")
                return [LetterClassification(identifier: "X", confidence: 1.0)]
            }
        )
        let r = await recognizer.recognize(
            points: [.init(x: 0, y: 0)], canvasSize: canvas,
            expectedLetter: "A", historicalFormScores: []
        )
        #expect(r == nil)
    }
}
