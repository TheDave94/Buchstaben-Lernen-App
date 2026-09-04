// SilentAudio.swift
// PrimaeNative
//
// The silent study arm's audio engine: a conformer that does nothing.
//
// Supervisor ruling C3-2 (2026-09-04): the study arm is AUTHORITATIVE.
// Until now `.silent` was implemented by `activeAudioFiles` returning
// `[]` plus study mode nulling speech and prompts — two conditions in
// two places, and the second only held when study mode was on. A silent-
// arm child in an enrolled, non-study session could hear TTS prompts,
// chimes and praise, and the export could not tell that session from a
// study one. Substituting this engine at the injection seam means no
// audio path can fire for the silent arm whatever any other parameter
// says: the playback controller, the coupling, the demonstration, the
// replay entries and every load all talk to an object that cannot make
// sound.

import Foundation

final class SilentAudio: AudioControlling {
    var initializationError: String? { nil }
    func loadAudioFile(named fileName: String, autoplay: Bool) {}
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) {}
    func setSpatialPitch(cents: Float) {}
    func play() {}
    func stop() {}
    func restart() {}
    func suspendForLifecycle() {}
    func resumeAfterLifecycle() {}
    func cancelPendingLifecycleWork() {}
}
