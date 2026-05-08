// LetterRecognizer.swift
// PrimaeNative
//
// CoreML-backed letter recognition service. Takes a freehand path of
// CGPoints and asks `GermanLetterRecognizer.mlpackage` to classify the
// result as one of 53 classes (A–Z, a–z, ß). Used by the freeWrite phase
// feedback and the freeform writing mode.

import CoreGraphics
import CoreML
import Foundation
import OSLog
import Vision

// MARK: - Classifier intermediate type

/// Framework-agnostic projection of a Vision
/// `VNClassificationObservation`. Keeps the recognizer pipeline free
/// of Vision deps and lets tests inject a deterministic classifier.
struct LetterClassification: Equatable, Sendable {
    let identifier: String
    let confidence: Float
}

// MARK: - Result type

/// Outcome of a single recognition call.
struct RecognitionResult: Equatable, Sendable {
    /// Top-1 label returned by the model.
    let predictedLetter: String
    /// Calibrated confidence (0–1) for the top label.
    let confidence: CGFloat
    /// Pre-calibration softmax confidence so the thesis can report
    /// the calibrator's effect. Optional so stubbed results stay
    /// unaffected.
    let rawConfidence: CGFloat?
    /// Top-3 labels with calibrated confidences, descending.
    let topThree: [TopCandidate]
    /// True when `predictedLetter` matches `expectedLetter`
    /// case-insensitively. Always `false` in freeform mode.
    let isCorrect: Bool

    /// Nonisolated so the `Task.detached` recognizer path can build
    /// results without bouncing through MainActor.
    nonisolated init(predictedLetter: String, confidence: CGFloat,
                     rawConfidence: CGFloat? = nil,
                     topThree: [TopCandidate], isCorrect: Bool) {
        self.predictedLetter = predictedLetter
        self.confidence = confidence
        self.rawConfidence = rawConfidence
        self.topThree = topThree
        self.isCorrect = isCorrect
    }

    struct TopCandidate: Equatable, Sendable {
        let letter: String
        let confidence: CGFloat
    }
}

// MARK: - Protocol

/// Async recognition seam. Swap `StubLetterRecognizer` in tests.
protocol LetterRecognizerProtocol: Sendable {
    /// Recognise the rasterised stroke. `strokeStartIndices` marks
    /// fresh-stroke indices into `points`; the rasterizer breaks the
    /// polyline there so multi-stroke letters aren't drawn with
    /// phantom diagonals between lifts (F → P misclassification).
    /// `historicalFormScores` feeds the calibrator's confidence boost
    /// for letters the child has practised reliably.
    func recognize(points: [CGPoint],
                   strokeStartIndices: [Int],
                   canvasSize: CGSize,
                   expectedLetter: String?,
                   historicalFormScores: [CGFloat]) async -> RecognitionResult?
    /// Whether the backing model is loaded and ready. `false` means
    /// every `recognize` call returns `nil`; the UI uses this to
    /// distinguish "model missing" from "model said no".
    func isModelAvailable() async -> Bool
}

extension LetterRecognizerProtocol {
    /// Convenience overload omitting stroke breaks and
    /// `historicalFormScores` (single-stroke letters, freeform mode).
    func recognize(points: [CGPoint],
                   canvasSize: CGSize,
                   expectedLetter: String?,
                   historicalFormScores: [CGFloat] = []) async -> RecognitionResult? {
        await recognize(points: points,
                        strokeStartIndices: [],
                        canvasSize: canvasSize,
                        expectedLetter: expectedLetter,
                        historicalFormScores: historicalFormScores)
    }
}

// MARK: - CoreML-backed recognizer

private nonisolated(unsafe) let recognizerLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "PrimaeNative",
    category: "LetterRecognizer"
)

/// Production recognizer backed by `GermanLetterRecognizer.mlpackage`.
/// Model loads lazily on first `recognize(…)`; missing/load-failed
/// model logs a warning and subsequent calls return `nil` so the app
/// falls back to Fréchet-only scoring.
///
/// Declared `nonisolated` so the hot path can run inside a detached
/// Task on the cooperative pool, away from the package-level
/// `defaultIsolation(MainActor.self)`.
nonisolated final class CoreMLLetterRecognizer: LetterRecognizerProtocol, @unchecked Sendable {

    // MARK: Static model cache

    /// `nonisolated(unsafe)` because Vision model handles are
    /// expensive to load (~50 ms) and safe to share across threads
    /// after construction. Guarded by `loadLock` on first touch.
    private nonisolated(unsafe) static var sharedModel: VNCoreMLModel?
    private nonisolated(unsafe) static var didAttemptLoad = false
    private static let loadLock = NSLock()

    private let calibrator: ConfidenceCalibrator
    /// Classification is the only Vision-touching step — taking it as
    /// an injectable closure lets tests stub it without bundling a
    /// `.mlpackage`, so renderToImage + makeResult become testable.
    typealias Classifier = @Sendable (CGImage) -> [LetterClassification]
    private let classify: Classifier

    // MARK: Init

    init(calibrator: ConfidenceCalibrator = ConfidenceCalibrator(),
         classifier: Classifier? = nil) {
        self.calibrator = calibrator
        self.classify = classifier ?? Self.defaultClassifier
    }

    /// Production classifier: lazy-load the bundled `.mlpackage`,
    /// run a `VNCoreMLRequest`, project observations onto the
    /// framework-agnostic `LetterClassification`. Returns `[]` when
    /// the model can't be loaded.
    /// Spelled with the full closure type because Swift's stored-
    /// property-initializer rules flag a covariant-Self reference
    /// on the `Classifier` typealias here.
    private static let defaultClassifier: @Sendable (CGImage) -> [LetterClassification] = { image in
        guard let model = CoreMLLetterRecognizer.loadModelIfNeeded() else { return [] }
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .centerCrop
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
            let observations = request.results as? [VNClassificationObservation] ?? []
            return observations.map {
                LetterClassification(identifier: $0.identifier, confidence: $0.confidence)
            }
        } catch {
            recognizerLogger.warning("Vision request failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: LetterRecognizerProtocol

    /// First access compiles the `.mlpackage` and warms the
    /// VNCoreMLModel — disk + GPU blocking. Run on a detached Task
    /// so the probe never executes on MainActor.
    func isModelAvailable() async -> Bool {
        await Task.detached(priority: .userInitiated) {
            Self.loadModelIfNeeded() != nil
        }.value
    }

    func recognize(points: [CGPoint],
                   strokeStartIndices: [Int],
                   canvasSize: CGSize,
                   expectedLetter: String?,
                   historicalFormScores: [CGFloat]) async -> RecognitionResult? {
        guard points.count >= 2, canvasSize.width > 0, canvasSize.height > 0 else {
            return nil
        }
        let expected = expectedLetter
        let calibratorCopy = calibrator
        let history = historicalFormScores
        let classifier = classify
        let breaks = strokeStartIndices
        // Hot path (model load, 40×40 rasterization, Vision perform)
        // is CPU-heavy and must run off MainActor. A detached Task
        // doesn't inherit caller isolation, so every sync call inside
        // stays off-main.
        return await Task.detached(priority: .userInitiated) {
            guard let image = Self.renderToImage(points: points,
                                                  strokeStartIndices: breaks,
                                                  canvasSize: canvasSize) else {
                return nil
            }
            let classifications = classifier(image)
            guard !classifications.isEmpty else { return nil }
            return Self.makeResult(
                from: classifications,
                expectedLetter: expected,
                calibrator: calibratorCopy,
                historicalFormScores: history
            )
        }.value
    }

    // MARK: - Model loading

    private static func loadModelIfNeeded() -> VNCoreMLModel? {
        loadLock.lock()
        defer { loadLock.unlock() }
        if didAttemptLoad { return sharedModel }
        didAttemptLoad = true
        sharedModel = loadModel()
        return sharedModel
    }

    private static func loadModel() -> VNCoreMLModel? {
        let candidates: [Bundle] = {
            var bundles: [Bundle] = [.main]
            let name = "PrimaeNative_PrimaeNative"
            if let b = Bundle(identifier: name) { bundles.append(b) }
            bundles.append(contentsOf: Bundle.allBundles.filter {
                $0.bundlePath.hasSuffix(name + ".bundle")
            })
            bundles.append(contentsOf: Bundle.allFrameworks.filter {
                $0.bundlePath.hasSuffix(name + ".bundle")
            })
            return bundles
        }()

        let modelURL: URL? = {
            // SwiftPM `.copy("Resources")` preserves tree structure,
            // Xcode flattens to bundle root — probe all layouts.
            let subdirs: [String?] = [nil, "Resources/ML", "ML", "Resources"]
            for bundle in candidates {
                for sub in subdirs {
                    if let u = bundle.url(
                        forResource: "GermanLetterRecognizer",
                        withExtension: "mlmodelc",
                        subdirectory: sub
                    ) {
                        return u
                    }
                }
                for sub in subdirs {
                    if let u = bundle.url(
                        forResource: "GermanLetterRecognizer",
                        withExtension: "mlpackage",
                        subdirectory: sub
                    ) {
                        do {
                            return try MLModel.compileModel(at: u)
                        } catch {
                            recognizerLogger.warning("Failed to compile mlpackage at \(u.path): \(error.localizedDescription)")
                            continue
                        }
                    }
                }
            }
            return nil
        }()

        guard let url = modelURL else {
            recognizerLogger.warning("GermanLetterRecognizer model not found in any bundle — letter recognition disabled")
            return nil
        }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            let core = try MLModel(contentsOf: url, configuration: config)
            return try VNCoreMLModel(for: core)
        } catch {
            recognizerLogger.warning("Could not initialize VNCoreMLModel: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Result post-processing

    static func makeResult(
        from classifications: [LetterClassification],
        expectedLetter: String?,
        calibrator: ConfidenceCalibrator,
        historicalFormScores: [CGFloat]
    ) -> RecognitionResult? {
        guard let top = classifications.first else { return nil }
        let rawTopLetter = top.identifier
        let calibratedTopConfidence = calibrator.calibrate(
            rawConfidence: CGFloat(top.confidence),
            predictedLetter: rawTopLetter,
            historicalFormScores: historicalFormScores
        )
        let topThree: [RecognitionResult.TopCandidate] = classifications
            .prefix(3)
            .map { obs in
                let conf = calibrator.calibrate(
                    rawConfidence: CGFloat(obs.confidence),
                    predictedLetter: obs.identifier,
                    historicalFormScores: historicalFormScores
                )
                return .init(letter: obs.identifier, confidence: conf)
            }

        let isCorrect: Bool
        if let expected = expectedLetter {
            isCorrect = rawTopLetter.caseInsensitiveCompare(expected) == .orderedSame
        } else {
            isCorrect = false
        }

        return RecognitionResult(
            predictedLetter: rawTopLetter,
            confidence: calibratedTopConfidence,
            rawConfidence: CGFloat(top.confidence),
            topThree: topThree,
            isCorrect: isCorrect
        )
    }

    // MARK: - Image rendering

    /// Rasterize the child's stroke into a 40×40 grayscale CGImage
    /// matching the training distribution (black bg, white strokes,
    /// centred with small padding, line width 2.5).
    static func renderToImage(points: [CGPoint],
                               strokeStartIndices: [Int] = [],
                               canvasSize: CGSize) -> CGImage? {
        guard points.count >= 2 else { return nil }
        let targetSize = CGSize(width: 40, height: 40)

        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        let boxW = max(maxX - minX, 1)
        let boxH = max(maxY - minY, 1)

        // 10% padding on each side → scale to fit 80% of 40×40 = 32 px
        let padding: CGFloat = 4
        let drawSize = targetSize.width - 2 * padding
        let scale = min(drawSize / boxW, drawSize / boxH)
        let offsetX = (targetSize.width  - boxW * scale) / 2
        let offsetY = (targetSize.height - boxH * scale) / 2

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: Int(targetSize.width),
            height: Int(targetSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        // Black background (0 in grayscale).
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(origin: .zero, size: targetSize))

        // Flip Y so top-left-origin points draw upright into the
        // bottom-left-origin CGContext; otherwise the letter renders
        // upside down and the model sees mirror glyphs.
        context.translateBy(x: 0, y: targetSize.height)
        context.scaleBy(x: 1, y: -1)

        context.setStrokeColor(gray: 1, alpha: 1)
        context.setLineWidth(2.5)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // Break the polyline at every stroke-start index so multi-
        // stroke letters render as N disjoint polylines, not one
        // zig-zag with phantom diagonals across the lifts.
        let breaks = ([0] + strokeStartIndices.filter { $0 > 0 && $0 < points.count })
            .sorted()
        let path = CGMutablePath()
        for (b, breakIdx) in breaks.enumerated() {
            let endIdx = (b + 1 < breaks.count) ? breaks[b + 1] : points.count
            guard breakIdx < endIdx else { continue }
            let first = points[breakIdx]
            path.move(to: CGPoint(
                x: offsetX + (first.x - minX) * scale,
                y: offsetY + (first.y - minY) * scale
            ))
            for i in (breakIdx + 1)..<endIdx {
                let p = points[i]
                path.addLine(to: CGPoint(
                    x: offsetX + (p.x - minX) * scale,
                    y: offsetY + (p.y - minY) * scale
                ))
            }
        }
        context.addPath(path)
        context.strokePath()

        return context.makeImage()
    }
}

// MARK: - Test stub

/// In-memory recognizer for tests and previews. Returns its
/// pre-configured result regardless of input, or `nil` to simulate
/// a missing model.
struct StubLetterRecognizer: LetterRecognizerProtocol {
    let result: RecognitionResult?

    init(result: RecognitionResult? = nil) {
        self.result = result
    }

    /// Convenience: build a recognizer that always reports the given
    /// letter as correct with the given confidence.
    static func alwaysReturn(
        predicted: String,
        confidence: CGFloat,
        isCorrect: Bool = true
    ) -> StubLetterRecognizer {
        StubLetterRecognizer(result: RecognitionResult(
            predictedLetter: predicted,
            confidence: confidence,
            topThree: [.init(letter: predicted, confidence: confidence)],
            isCorrect: isCorrect
        ))
    }

    func recognize(points: [CGPoint],
                   strokeStartIndices: [Int],
                   canvasSize: CGSize,
                   expectedLetter: String?,
                   historicalFormScores: [CGFloat]) async -> RecognitionResult? {
        // Inputs ignored — the stub returns its pre-configured result.
        _ = historicalFormScores
        _ = strokeStartIndices
        // Truthfulness check (DEBUG only): asserting on an inconsistent
        // stub setup keeps tests honest. Stripped from production so
        // the stub stays zero-cost.
        #if DEBUG
        if let result, let expected = expectedLetter {
            let actuallyCorrect =
                result.predictedLetter.caseInsensitiveCompare(expected) == .orderedSame
            assert(
                result.isCorrect == actuallyCorrect,
                "StubLetterRecognizer: result.isCorrect (\(result.isCorrect)) " +
                "contradicts predicted='\(result.predictedLetter)' vs " +
                "expected='\(expected)'. Either fix the stub setup or use " +
                "alwaysReturn(predicted:confidence:isCorrect:) honestly."
            )
        }
        #endif
        return result
    }

    func isModelAvailable() async -> Bool { result != nil }
}
