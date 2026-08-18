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
// The probes deliberately do not assert WHETHER the model loads. Bundle
// resolution differs in the test host, so either answer is legitimate —
// what must hold is that every concurrent caller gets the SAME answer.

import Testing
import Foundation
@testable import PrimaeNative

@Suite struct RecognizerModelCacheTests {

    /// Eight concurrent probes, not eighty: a blocking-lock defect
    /// occupies a cooperative-pool thread per probe, and starving the
    /// pool would stop the harness's own timeout task from running.
    private static let probeCount = 8

    /// The time limit is the point of this test, not decoration. A lock
    /// defect here does not assert — it deadlocks, and a deadlocked
    /// `xcodebuild test` never returns. The trait converts a wedged run
    /// into a reported failure with a name attached.
    @Test(.timeLimit(.minutes(1)))
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
    }

    /// Repeated probes must agree with each other and with the concurrent
    /// run: once `didAttemptLoad` is set the cache short-circuits, and a
    /// cache that re-decided per call would show up here as drift.
    @Test(.timeLimit(.minutes(1)))
    func repeatedProbesAreStable() async {
        let recognizer = CoreMLLetterRecognizer(classifier: { _ in [] })
        let first = await recognizer.isModelAvailable()
        for probe in 1...4 {
            let again = await recognizer.isModelAvailable()
            #expect(again == first,
                    "probe \(probe) returned \(again) after an initial \(first) — the cache is not stable")
        }
    }

    /// A second instance shares the STATIC cache, so it must agree with
    /// the first. This is the property that makes the cache worth having
    /// and the one a mis-scoped lock would break.
    @Test(.timeLimit(.minutes(1)))
    func separateInstancesShareOneCache() async {
        let a = CoreMLLetterRecognizer(classifier: { _ in [] })
        let b = CoreMLLetterRecognizer(classifier: { _ in [] })
        let answerA = await a.isModelAvailable()
        let answerB = await b.isModelAvailable()
        #expect(answerA == answerB,
                "two instances disagreed (\(answerA) vs \(answerB)) — the cache is not shared")
    }
}
