// Contention coverage for `CoreMLLetterRecognizer`'s shared model cache.
//
// Audit finding 20's precondition. Every existing recognizer test
// injects a stub classifier (`CoreMLLetterRecognizerTests` says so in
// its own header), so `loadModelIfNeeded` — the lock, the two shared
// statics, and the lazy VNCoreMLModel load behind them — was exercised
// by ZERO tests. Swapping the lock primitive under code nothing runs is
// not a refactor, it is a guess.
//
// `isModelAvailable()` is the only reachable entry to that path: it
// calls `Self.loadModelIfNeeded()` inside a detached Task. The private
// statics stay private — this asserts observable behaviour rather than
// reaching for a test-only seam into a concurrency primitive.
//
// WHAT THIS CAN AND CANNOT SEE.
//   - Deadlock: caught, via the harness time limit. Every call takes the
//     lock, warm or cold, so contention is real regardless of ordering.
//   - Torn read of the two statics: caught, as disagreement between
//     concurrent probes.
//   - Double LOAD on a cold cache: NOT caught. The cache is process-wide
//     and another suite may have warmed it first, and the statics are
//     private so a test cannot reset them. A double load costs ~50 ms
//     and a discarded handle; it is not a correctness fault, which is
//     why it is not worth widening access to chase.
//
// The probes ALSO assert that the answer is `true` (2026-09-04). They
// used to assert agreement only, and agreement holds just as well when
// nothing loads — CI run 1633's iPad (A16) leg proved it: the suite
// timed out at 60 s in the first process, then PASSED in 0.001 s on
// xcodebuild's automatic retry, an outcome only possible if the retry's
// probes agreed on "not available". A bundle-claiming suite that passes
// when the bundle does not resolve asserts nothing; the availability
// assertion turns that vacuous pass into the failure it is.
//
// TIMING, MEASURED from the same run (job logs, 2026-09-04): the first
// `isModelAvailable()` in a fresh simulator process took ~32 s on the
// iPad Pro (M5) leg and > 60 s on the iPad (A16) leg, and because
// `loadModelIfNeeded` holds a blocking lock while loading, every probe
// parked on it occupied a cooperative-pool thread — unrelated tests in
// the same process reported "passed after 59.6 seconds". Hence three
// probes, not eight, and a limit above the measured floor: the limit
// still turns a real deadlock into a named failure; it no longer turns
// a slow simulator into one.
//
// HISTORICAL NOTE, because this suite's name promised more than its
// first run delivered: when written, the model did not resolve at all,
// so the probes agreed on `nil`. That is a weaker statement than
// agreeing on one shared instance, and the double-load race the suite
// was written for cannot occur when nothing loads.

import Testing
import Foundation
@testable import PrimaeNative

@Suite struct RecognizerModelCacheTests {

    /// Three concurrent probes: enough for a torn read to show as
    /// disagreement, few enough that parking on the blocking load lock
    /// cannot exhaust the cooperative pool on a four-core runner.
    private static let probeCount = 3

    /// The time limit is the point of this test, not decoration. A lock
    /// defect here does not assert — it deadlocks, and a deadlocked
    /// `xcodebuild test` never returns. The trait converts a wedged run
    /// into a reported failure with a name attached. Three minutes: the
    /// measured first-load floor on the hosted A16 simulator is > 60 s.
    @Test(.timeLimit(.minutes(3)))
    func concurrentProbesAgreeAndTerminate() async {
        // The injected classifier keeps Vision out of the assertion path;
        // `isModelAvailable()` still drives the real static cache.
        let recognizer = CoreMLLetterRecognizer(classifier: { _ in [] })

        let answers: [Bool] = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<Self.probeCount {
                group.addTask { await recognizer.isModelAvailable() }
            }
            var collected: [Bool] = []
            for await answer in group { collected.append(answer) }
            return collected
        }

        #expect(answers.count == Self.probeCount,
                "expected \(Self.probeCount) probes to return, got \(answers.count)")
        #expect(Set(answers).count == 1,
                "concurrent probes disagreed (\(answers)) — a torn read of the shared model cache")
        #expect(answers.allSatisfy { $0 },
                "the bundled model did not resolve (\(answers)) — agreement on 'unavailable' is not a cache test")
    }

    /// Repeated probes must agree with each other and with the concurrent
    /// run: once `didAttemptLoad` is set the cache short-circuits, and a
    /// cache that re-decided per call would show up here as drift.
    @Test(.timeLimit(.minutes(3)))
    func repeatedProbesAreStable() async {
        let recognizer = CoreMLLetterRecognizer(classifier: { _ in [] })
        let first = await recognizer.isModelAvailable()
        #expect(first, "the bundled model must resolve for stability to mean anything")
        for probe in 1...4 {
            let again = await recognizer.isModelAvailable()
            #expect(again == first,
                    "probe \(probe) returned \(again) after an initial \(first) — the cache is not stable")
        }
    }

    /// A second instance shares the STATIC cache, so it must agree with
    /// the first. This is the property that makes the cache worth having
    /// and the one a mis-scoped lock would break.
    @Test(.timeLimit(.minutes(3)))
    func separateInstancesShareOneCache() async {
        let a = CoreMLLetterRecognizer(classifier: { _ in [] })
        let b = CoreMLLetterRecognizer(classifier: { _ in [] })
        let answerA = await a.isModelAvailable()
        let answerB = await b.isModelAvailable()
        #expect(answerA == answerB,
                "two instances disagreed (\(answerA) vs \(answerB)) — the cache is not shared")
        #expect(answerA, "the bundled model must resolve — see the file header")
    }
}
