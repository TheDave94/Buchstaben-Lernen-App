// AudioEngine+SpatialPitch.swift
// PrimaeNative
//
// Spatial-arm pitch drive, kept OUT of AudioEngine.swift on purpose:
// that file is stable-and-fragile (LESSONS.md — init/deinit/observer
// pattern, shared audio session) and must not grow surface area. The
// engine already exposes `pitchCents` (a proxy onto the existing
// AVAudioUnitTimePitch node, wired since the debug audio panel); this
// extension only forwards to it. No session, node-graph, or lifecycle
// code is touched.

extension AudioEngine {
    /// `PilotAudioCondition.spatial` per-tick pitch drive. Cents are
    /// relative to the carrier's authored frequency (440 Hz — see
    /// `SpatialSonification`); the mapping layer emits ±1200. The clamp
    /// here is the AVAudioUnitTimePitch hardware bound, a backstop only.
    func setSpatialPitch(cents: Float) {
        guard cents.isFinite else { return }
        pitchCents = max(-2400, min(2400, cents))
    }
}
