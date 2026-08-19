// Regression guard for resource-bundle resolution.
//
// Nothing covered this, and the cost was measured rather than guessed:
// `recognition_predicted` was empty in 194 of 194 recognition-bearing
// records across 41 sessions and 7 bundle IDs, 2026-05-06 to 2026-08-16.
// Three exported columns have never carried a value, because the model
// was never found and `recognize(…)` returned nil every time.
//
// The failure was silent by construction: a missing model logs a warning
// and degrades to Fréchet-only scoring, which is the correct runtime
// behaviour and the reason nobody noticed for three months.
//
// These tests fail loudly instead.

import Testing
import Foundation
@testable import PrimaeNative

@Suite struct BundleResolutionTests {

    @Test("the module's resource bundle resolves to something other than .main")
    func resourceBundleResolves() {
        #expect(PrimaeBundle.resources != .main,
                "fell back to Bundle.main — the resource bundle was not located, and every bundled resource is now looked up in the wrong place")
    }

    /// Both shipped forms are DIRECTORIES, which is what
    /// `url(forResource:withExtension:)` failed to resolve. Asserting on
    /// the path probe pins the fix rather than the symptom.
    ///
    /// This probes `CoreMLLetterRecognizer.resolveModelURL()` — the SAME
    /// list the loader uses — rather than a path of its own. A test with
    /// its own hard-coded path stays green while the loader fails, which
    /// is precisely how 194 records came back empty under coverage.
    @Test("the CoreML model is present in the resource bundle")
    func modelIsPresent() throws {
        let found = try #require(
            CoreMLLetterRecognizer.resolveModelURL(),
            "GermanLetterRecognizer not found at any probed location — the resource stopped shipping, and recognition is silently disabled")
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: found.url.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue,
                "expected a directory-shaped .mlmodelc/.mlpackage — a file here means the resource rule changed and the probe order should follow")
    }

    /// `.process("MLResources")` exists to ship the COMPILED model.
    /// Under `.copy` the raw `.mlpackage` shipped instead and every cold
    /// load ran `MLModel.compileModel(at:)`, relying on runtime
    /// compilation of an uncompiled package — undocumented behaviour in
    /// the one feature already known to fail silently.
    ///
    /// If this goes red while `modelIsPresent` stays green, the model is
    /// shipping but SwiftPM did not compile it: the `.process` rule is
    /// not doing what it was added for.
    @Test("the shipped model is the compiled form, not a raw .mlpackage")
    func modelShipsCompiled() throws {
        let found = try #require(CoreMLLetterRecognizer.resolveModelURL())
        #expect(found.isCompiled,
                "shipped as \(found.url.lastPathComponent) — expected GermanLetterRecognizer.mlmodelc from the .process rule")
    }

    /// THE guard. `isModelAvailable()` returning false is exactly the
    /// state that produced 194 empty records.
    @Test("the recognizer reports its model available")
    func recognizerFindsItsModel() async {
        let recognizer = CoreMLLetterRecognizer(classifier: { _ in [] })
        #expect(await recognizer.isModelAvailable(),
                "the model did not load — recognition is disabled and recognitionPredicted/Confidence/Correct will export empty")
    }

    /// The letter loader resolved through the one surviving probe of
    /// three, which is an accident rather than a design. Pin it.
    @Test("the real bundle letter provider finds bundled letters")
    func letterProviderFindsLetters() {
        let provider = BundleLetterResourceProvider()
        let urls = provider.allResourceURLs()
        #expect(!urls.isEmpty, "no resources enumerated from the bundle at all")
        #expect(urls.contains { $0.lastPathComponent == "strokes.json" },
                "no strokes.json among \(urls.count) enumerated resources")
    }
}
