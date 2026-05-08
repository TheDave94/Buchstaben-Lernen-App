import Foundation
import CoreGraphics

// MARK: - Animation speed

enum AnimationSpeed: Double, CaseIterable, Equatable {
    case slow   = 0.4
    case normal = 1.0
    case fast   = 2.0

    var multiplier: Double { rawValue }
}

// MARK: - Animation step

struct AnimationStep: Equatable {
    let strokeIndex: Int
    let checkpointIndex: Int
    let point: CGPoint
    /// Duration in seconds to reach this checkpoint from the previous one.
    let segmentDuration: TimeInterval
}

// MARK: - Playback state

enum AnimationPlaybackState: Equatable {
    case idle
    case playing(stepIndex: Int)
    case paused(stepIndex: Int)
    case complete
    case skipped
}

// MARK: - Guide engine

struct LetterAnimationGuide {

    let steps: [AnimationStep]
    private(set) var playbackState: AnimationPlaybackState = .idle
    private(set) var speed: AnimationSpeed = .normal
    private(set) var currentStepIndex: Int = 0

    /// Total animation duration at current speed.
    var totalDuration: TimeInterval {
        steps.reduce(0) { $0 + $1.segmentDuration } / speed.multiplier
    }

    /// Duration for a specific step adjusted for speed.
    func duration(for step: AnimationStep) -> TimeInterval {
        step.segmentDuration / speed.multiplier
    }

    /// Whether there's a next step available.
    var hasNextStep: Bool { currentStepIndex < steps.count - 1 }
    var hasPreviousStep: Bool { currentStepIndex > 0 }

    /// Current animation step or nil if none.
    var currentStep: AnimationStep? {
        steps.indices.contains(currentStepIndex) ? steps[currentStepIndex] : nil
    }

    /// Progress 0–1 through the full animation.
    var progress: Double {
        guard !steps.isEmpty else { return 0 }
        return Double(currentStepIndex) / Double(steps.count)
    }

    // MARK: - Mutating methods

    mutating func start() {
        currentStepIndex = 0
        playbackState = .playing(stepIndex: 0)
    }

    mutating func pause() {
        if case .playing(let idx) = playbackState {
            playbackState = .paused(stepIndex: idx)
        }
    }

    mutating func resume() {
        if case .paused(let idx) = playbackState {
            playbackState = .playing(stepIndex: idx)
        }
    }

    mutating func skip() {
        playbackState = .skipped
        currentStepIndex = steps.count
    }

    /// Advance to the next step. Returns false if already at the last step.
    @discardableResult
    mutating func advanceStep() -> Bool {
        guard hasNextStep else {
            playbackState = .complete
            return false
        }
        currentStepIndex += 1
        if case .playing = playbackState {
            playbackState = .playing(stepIndex: currentStepIndex)
        }
        return true
    }

    mutating func setSpeed(_ newSpeed: AnimationSpeed) {
        speed = newSpeed
    }

    mutating func reset() {
        currentStepIndex = 0
        playbackState = .idle
        speed = .normal
    }

    // MARK: - Factory

    /// Build steps from a letter's stroke definition. Per-segment
    /// duration scales with Euclidean distance between consecutive
    /// checkpoints so the dot moves at constant linear speed regardless
    /// of how densely a stroke is sampled.
    /// `unitsPerSecond` is in cell-relative units (1.0 ≈ one cell width).
    static func build(from strokes: LetterStrokes,
                      unitsPerSecond: TimeInterval = 0.9) -> LetterAnimationGuide {
        var allSteps: [AnimationStep] = []
        for (strokeIdx, stroke) in strokes.strokes.enumerated() {
            var prev: CGPoint? = nil
            for (cpIdx, checkpoint) in stroke.checkpoints.enumerated() {
                let pt = CGPoint(x: checkpoint.x, y: checkpoint.y)
                let dt: TimeInterval
                if let p = prev {
                    let dx = pt.x - p.x
                    let dy = pt.y - p.y
                    let dist = (dx * dx + dy * dy).squareRoot()
                    dt = max(1.0 / 240.0, Double(dist) / unitsPerSecond)
                } else {
                    dt = 1.0 / 60.0
                }
                allSteps.append(AnimationStep(
                    strokeIndex: strokeIdx,
                    checkpointIndex: cpIdx,
                    point: pt,
                    segmentDuration: dt
                ))
                prev = pt
            }
        }
        return LetterAnimationGuide(steps: allSteps)
    }
}
