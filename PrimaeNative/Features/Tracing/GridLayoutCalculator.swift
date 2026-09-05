import CoreGraphics

/// Pure layout function: given a canvas size and an `InputPreset`, return
/// per-cell frames. Extracted from `SequenceGridController` so the math is
/// unit-testable in isolation and can't accidentally touch cell state.
///
/// Migration-neutral contract: with `InputPreset.finger` (cellCount=1,
/// spacing=12, inset=0), the single returned frame equals the whole canvas.
/// The existing single-letter renderer sees no coordinate change when
/// routed through the grid engine.
///
/// **Caching.** `TracingCanvasView`'s body re-evaluates this on every
/// SwiftUI redraw triggered by the VM (≈100 Hz during a Pencil stroke
/// thanks to `pencilPressure`). The function itself is cheap, but the
/// returned `[CGRect]` allocates a fresh array on every call. A 2-entry
/// memo keyed on `(canvasSize, preset)` avoids that churn — finger and
/// pencil presets are the only two flavours in use, and the canvas
/// size only changes on rotation, so the cache hits 99 % of the time.
@MainActor
enum GridLayoutCalculator {

    private struct CacheKey: Hashable {
        let width: CGFloat    // exact — an Int key returned stale frames for sub-point resizes (class two, 2026-09-05)
        let height: CGFloat
        let cellCount: Int
        let cellSpacing: CGFloat
        let horizontalInset: CGFloat
    }

    /// Bounded by the number of distinct presets actively in use; the
    /// app currently only flips between finger / pencil, so 4 slots is
    /// generous. Cap exists so a future preset-rotation experiment
    /// can't grow the cache without bound.
    private static let cacheLimit = 4
    private static var cache: [CacheKey: [CGRect]] = [:]

    static func cellFrames(canvasSize: CGSize, preset: InputPreset) -> [CGRect] {
        let key = CacheKey(
            width: canvasSize.width,
            height: canvasSize.height,
            cellCount: preset.cellCount,
            cellSpacing: preset.cellSpacing,
            horizontalInset: preset.horizontalInset
        )
        if let cached = cache[key] { return cached }
        let frames = compute(canvasSize: canvasSize, preset: preset)
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = frames
        return frames
    }

    private static func compute(canvasSize: CGSize, preset: InputPreset) -> [CGRect] {
        let n = max(1, preset.cellCount)
        let spacing = preset.cellSpacing
        let inset = preset.horizontalInset
        let available = canvasSize.width - 2 * inset - CGFloat(n - 1) * spacing
        let cellWidth = max(0, available / CGFloat(n))
        return (0..<n).map { i in
            CGRect(
                x: inset + CGFloat(i) * (cellWidth + spacing),
                y: 0,
                width: cellWidth,
                height: canvasSize.height
            )
        }
    }
}
