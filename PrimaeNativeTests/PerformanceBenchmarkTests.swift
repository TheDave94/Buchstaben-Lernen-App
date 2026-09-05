// NOTE: Intentionally uses XCTest — Swift Testing has no measure()/XCTMetric equivalent. Do not migrate.
//
// XCTest measure-block benchmarks for StrokeTracker hit-testing and
// LetterRepository load time. CI baselines established on first run.

import XCTest
import CoreGraphics
@testable import PrimaeNative

final class PerformanceBenchmarkTests: XCTestCase {


    // MARK: - StrokeTracker hit-test performance

    /// 1000 update() calls on a 5-stroke, 10-checkpoint-per-stroke letter.
    @MainActor func testStrokeTrackerHitTest_performance() async {
        let definition = LetterStrokes(
            letter: "PERF",
            checkpointRadius: 0.05,
            strokes: (0..<5).map { strokeIdx in
                StrokeDefinition(
                    id: strokeIdx + 1,
                    checkpoints: (0..<10).map { cpIdx in
                        Checkpoint(
                            x: CGFloat(cpIdx) / 10.0,
                            y: CGFloat(strokeIdx) / 5.0
                        )
                    }
                )
            }
        )

        let tracker = StrokeTracker()
        tracker.load(definition)
        let canvas = CGSize(width: 400, height: 400)

        // Pre-generate 1000 random(ish) points using seeded values
        var points: [CGPoint] = []
        var x: CGFloat = 0.1
        for _ in 0..<1000 {
            x = (x * 137.0 + 0.01).truncatingRemainder(dividingBy: 1.0)
            let y = (x * 1.618).truncatingRemainder(dividingBy: 1.0)
            points.append(CGPoint(x: x * canvas.width, y: y * canvas.height))
        }

        measure {
            tracker.load(definition)   // reset for each iteration
            for pt in points {
                // StrokeTracker.update(normalizedPoint:) expects coordinates in 0…1.
                // Normalize from canvas-space (0…400) by dividing by canvas dimensions.
                let normalized = CGPoint(x: pt.x / canvas.width, y: pt.y / canvas.height)
                tracker.update(normalizedPoint: normalized)
            }
        }
    }

    /// Rapid reset+load cycle — 500 iterations.
    @MainActor func testStrokeTrackerResetLoad_performance() async {
        let definition = LetterStrokes(
            letter: "RESET",
            checkpointRadius: 0.06,
            strokes: [
                .init(id: 1, checkpoints: [.init(x: 0.3, y: 0.8), .init(x: 0.5, y: 0.2), .init(x: 0.7, y: 0.8)]),
                .init(id: 2, checkpoints: [.init(x: 0.38, y: 0.55), .init(x: 0.62, y: 0.55)])
            ]
        )

        let tracker = StrokeTracker()
        measure {
            for _ in 0..<500 {
                tracker.load(definition)
                tracker.reset()
            }
        }
    }

    // MARK: - LetterRepository load performance

    /// loadLetters() on empty provider (fallback path) should be <1ms.
    @MainActor func testLetterRepository_emptyProvider_loadPerformance() async {
        let repo = LetterRepository(resources: EmptyProvider(), cache: NullLetterCache())
        measure {
            _ = repo.loadLetters()
        }
    }

    /// loadLetters() is called many times (e.g., view refreshes) — must be fast.
    @MainActor func testLetterRepository_repeatedLoad_performance() async {
        let repo = LetterRepository(resources: EmptyProvider(), cache: NullLetterCache())
        measure {
            for _ in 0..<100 {
                _ = repo.loadLetters()
            }
        }
    }

    // MARK: - PlaybackStateMachine performance

    /// 10,000 rapid transition() calls — must complete in <50ms.
    @MainActor func testPlaybackStateMachine_rapidTransitions_performance() async {
        measure {
            var machine = PlaybackStateMachine()
            machine.appIsForeground = true
            machine.resumeIntent = true
            for i in 0..<10_000 {
                _ = machine.transition(to: i.isMultiple(of: 2) ? .active : .idle)
            }
        }
    }
}

// MARK: - EmptyProvider

private struct EmptyProvider: LetterResourceProviding {
    var bundle: Bundle = .main
    var searchBundles: [Bundle] { [bundle] }
    func allResourceURLs() -> [URL] { [] }
    func resourceURL(for relativePath: String) -> URL? { nil }
}
