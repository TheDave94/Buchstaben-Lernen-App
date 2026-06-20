// PilotAudioCondition.swift
// PrimaeNative
//
// Audio-arm infrastructure for the three-arm pilot study.
//
// Orthogonal to `ThesisCondition` (the pedagogical-flow axis): this enum
// is the AUDIO axis. Per pilot decision D1 the pedagogical flow is held
// constant and only the audio varies across arms (phoneme /
// arbitrary-sound / silent). It is modelled as a SEPARATE axis so a
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

    /// Engagement-matched, coupling-matched non-phonemic control sound.
    /// Named by its ROLE, not its content: what the sound actually is
    /// remains open (pilot decision D2). Whatever it becomes, it runs the
    /// identical coupling path as `phoneme` so the only difference is
    /// phonemic content (the §2.6 matching discipline).
    case arbitrarySound

    /// No audio at all — the silent control arm.
    case silent

    /// German display label for the parent dashboard and thesis reports.
    /// Display-only: the CSV/TSV/JSON export keys on `rawValue`, never on
    /// this string, so wording can change without touching the data.
    var displayName: String {
        switch self {
        case .phoneme:        return "Phonem"
        case .arbitrarySound: return "Kontrollklang"
        case .silent:         return "Ohne Ton"
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
        case 1:  return .arbitrarySound
        default: return .silent
        }
    }
}
