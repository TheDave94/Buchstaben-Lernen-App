// AnimationGuideController.swift
// PrimaeNative
//
// Drives the "blue dot follows the stroke path" animation used during
// the observe phase and the onboarding trace demo.

import CoreGraphics
import Foundation

@MainActor
@Observable
final class AnimationGuideController {

    /// Current normalized (0–1) point of the animated guide dot.
    /// `nil` when no animation is running. Views render at screen scale
    /// using `PrimaeLetterRenderer.normalizedGlyphRect`.
    private(set) var guidePoint: CGPoint? = nil

    /// Fires after each full demonstration loop. Observe phase uses this
    /// to auto-advance after N cycles for non-reading children.
    var onCycleComplete: (@MainActor () -> Void)? = nil

    private var task: Task<Void, Never>?
    /// The strokes the running or pending animation was armed with —
    /// nil when idle. Read by `TracingViewModel.canvasSize.didSet` to
    /// re-arm an observe demonstration that was armed before the canvas
    /// had laid out (audit 2026-09-06), and by tests.
    private(set) var armedStrokes: LetterStrokes? = nil
    /// Deferred-start task for `startAfterDelay(_:strokes:)`. Tracked
    /// separately so `stop()` can cancel either phase cleanly.
    private var startTask: Task<Void, Never>?
    private let sleeper: Sleeper

    init(sleeper: @escaping Sleeper = realSleeper) {
        self.sleeper = sleeper
    }

    /// Begin the looping animation immediately for the supplied strokes.
    /// Replaces any in-flight animation.
    func start(strokes: LetterStrokes) {
        stop()
        let guide = LetterAnimationGuide.build(from: strokes)
        guard !guide.steps.isEmpty else { return }
        armedStrokes = strokes

        task = Task { [weak self, sleeper] in
            // Pre-attentive start cue: park the dot at the first step
            // for ~1 s on the first iteration so the child sees WHERE
            // the trace starts before motion begins (Mayer 2009).
            let firstHoldRequested = !Task.isCancelled
            var heldFirst = false
            // 60 Hz interpolation within a stroke; teleport across
            // stroke boundaries so cross-stroke moves read as pen lifts
            // rather than diagonal slides.
            let frameInterval: TimeInterval = 1.0 / 60.0
            while !Task.isCancelled {
                guard let self else { return }
                if !heldFirst, firstHoldRequested, let firstStep = guide.steps.first {
                    self.guidePoint = firstStep.point
                    try? await sleeper(.seconds(1.0))
                    heldFirst = true
                    if Task.isCancelled { break }
                }
                var previousStep: AnimationStep? = nil
                for step in guide.steps {
                    guard !Task.isCancelled else { break }
                    let duration = guide.duration(for: step)
                    if let prev = previousStep, prev.strokeIndex == step.strokeIndex {
                        let frames = max(1, Int((duration / frameInterval).rounded()))
                        let dx = step.point.x - prev.point.x
                        let dy = step.point.y - prev.point.y
                        for f in 1...frames {
                            if Task.isCancelled { break }
                            let t = CGFloat(f) / CGFloat(frames)
                            self.guidePoint = CGPoint(x: prev.point.x + dx * t,
                                                      y: prev.point.y + dy * t)
                            try? await sleeper(.seconds(frameInterval))
                        }
                    } else {
                        // First step of the cycle or a new stroke —
                        // teleport and dwell for the segment duration.
                        self.guidePoint = step.point
                        try? await sleeper(.seconds(duration))
                    }
                    previousStep = step
                }
                if !Task.isCancelled {
                    self.guidePoint = nil
                    try? await sleeper(.seconds(0.5))
                    if !Task.isCancelled { self.onCycleComplete?() }
                }
            }
            self?.guidePoint = nil
        }
    }

    /// Begin the animation after a delay so the dot doesn't race
    /// ahead of the letter ghost fade-in on a fresh letter load.
    func startAfterDelay(_ seconds: TimeInterval, strokes: LetterStrokes) {
        startTask?.cancel()
        armedStrokes = strokes
        startTask = Task { [weak self, sleeper] in
            try? await sleeper(.seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.start(strokes: strokes)
        }
    }

    /// Stop any running animation. Safe to call repeatedly.
    func stop() {
        startTask?.cancel()
        startTask = nil
        task?.cancel()
        task = nil
        guidePoint = nil
        armedStrokes = nil
    }
}
