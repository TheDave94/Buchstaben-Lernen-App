// PilotAudioCondition.swift
// PrimaeNative
//
// Audio-arm infrastructure for the three-arm pilot study.
//
// Orthogonal to `ThesisCondition` (the pedagogical-flow axis): this enum
// is the AUDIO axis. Per pilot decision D1 the pedagogical flow is held
// constant and only the audio varies across arms (phoneme /
// spatial-sonification / silent). It is modelled as a SEPARATE axis so a
// future crossed (pedagogical × audio) design isn't precluded.
//
// H1 scope: assignment + persistence + export only. Per-arm playback
// routing — `activeAudioFiles(for:)` branching and the silent
// short-circuit — is H2 and is deliberately NOT wired here.

import Foundation
import os

/// Surfaces pilot-audio integrity issues (e.g. a phoneme-arm study
/// device degrading to name audio because a letter has no phoneme
/// recording). Logged at letter-load frequency — never on the per-tick
/// coupling path. `nonisolated(unsafe)` matches the module's other
/// shared loggers.
nonisolated(unsafe) let pilotAudioLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "PrimaeNative",
    category: "PilotAudio"
)

/// Audio condition for the three-arm pilot. The arms differ ONLY in what
/// sound plays during tracing; the pedagogical flow is identical across
/// arms (pilot decision D1).
///
/// Backward-compatible with historical dashboard JSON: records written
/// before this axis existed carry no `audioCondition` and decode to
/// `.phoneme` (see `PhaseSessionRecord.init(from:)`).
enum PilotAudioCondition: String, Codable, CaseIterable, Sendable {
    /// The letter's phoneme — the pilot's primary, linguistically
    /// meaningful sonification.
    case phoneme

    /// Spatial 2D sonification: a neutral looped carrier tone whose PITCH
    /// tracks the pen's vertical canvas position (top = 880 Hz, bottom =
    /// 220 Hz, linear-in-cents — see `SpatialSonification`) while stereo
    /// pan tracks the horizontal position, same as the phoneme arm.
    /// Headphone delivery. Supersedes the former `arbitrarySound`
    /// (engagement-matched control) arm — decision superseding D2; the
    /// arms are matched on pan and differ in pitch-drive + sound identity.
    case spatial

    /// No audio at all — the silent control arm.
    case silent

    /// German display label for the parent dashboard and thesis reports.
    /// Display-only: the CSV/TSV/JSON export keys on `rawValue`, never on
    /// this string, so wording can change without touching the data.
    var displayName: String {
        switch self {
        case .phoneme: return "Phonem"
        case .spatial: return "Raumklang"
        case .silent:  return "Ohne Ton"
        }
    }

    /// The default audio arm for this install. Non-enrolled installs get
    /// `.phoneme` (the app's historical always-meaningful-sound default);
    /// enrolled installs get the stable UUID-derived arm. A researcher-set
    /// override wins over modulo derivation. Mirrors
    /// `ThesisCondition.defaultForInstall`, reusing the same
    /// `ParticipantStore` enrolment gating.
    static var defaultForInstall: PilotAudioCondition {
        if let manual = ParticipantStore.audioConditionOverride {
            return manual
        }
        return ParticipantStore.isEnrolled
            ? .assign(participantId: ParticipantStore.participantId)
            : .phoneme
    }

    /// Deterministically assign a participant to an audio arm from a
    /// stable UUID. Same UUID → same arm, so assignment can't drift
    /// mid-study. Invoked only when `isEnrolled == true`.
    ///
    /// Uses the LAST UUID byte (`uuid.15`), NOT the first byte
    /// `ThesisCondition.assign` keys on. Sharing a byte would make the two
    /// axes perfectly correlated — every pedagogical `threePhase` install
    /// would be forced into `phoneme` — confounding any future crossed
    /// design. Pilot D1 holds the pedagogical flow constant today, so the
    /// correlation is moot now; decorrelating here keeps it from becoming
    /// a latent trap.
    static func assign(participantId: UUID) -> PilotAudioCondition {
        // v4 UUID bytes are uniformly distributed; byte 15 is independent
        // of byte 0.
        let byte = participantId.uuid.15
        switch Int(byte) % PilotAudioCondition.allCases.count {
        case 0:  return .phoneme
        case 1:  return .spatial
        default: return .silent
        }
    }
}
