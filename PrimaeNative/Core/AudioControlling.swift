import Foundation

@MainActor
protocol AudioControlling: AnyObject {
    func loadAudioFile(named fileName: String, autoplay: Bool)
    func setAdaptivePlayback(speed: Float, horizontalBias: Float)
    /// Spatial-arm pitch drive (pen Y → carrier pitch, in cents relative
    /// to the carrier's authored frequency). Called on the per-tick
    /// coupling path ONLY for `PilotAudioCondition.spatial`; the phoneme
    /// and silent arms never invoke it, so their pitch stays at the
    /// engine default (0 cents). Default implementation is a no-op —
    /// only pitch-capable engines opt in (see AudioEngine+SpatialPitch).
    func setSpatialPitch(cents: Float)
    func play()
    func stop()
    func restart()
    func suspendForLifecycle()
    func resumeAfterLifecycle()
    func cancelPendingLifecycleWork()
    /// Non-nil when audio failed to initialise; the VM surfaces this as
    /// a startup toast so silent failure is visible. No protocol default
    /// is provided so conformers must spell out their state explicitly.
    var initializationError: String? { get }
}

extension AudioControlling {
    /// No-op default so non-pitch conformers (test doubles, previews)
    /// satisfy the requirement without change. Declared as a protocol
    /// REQUIREMENT above (not extension-only) so conformers that do
    /// implement it — AudioEngine — are reached via dynamic dispatch.
    func setSpatialPitch(cents: Float) {}
}
