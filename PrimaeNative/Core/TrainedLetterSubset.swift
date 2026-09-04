// TrainedLetterSubset.swift
// PrimaeNative
//
// Third assignment axis for the pilot: which 3 of the 5 study letters
// (A F I L M) a participant TRAINS. The post-test (H6) covers all 5
// regardless — the untrained 2 are the within-child baseline, so the
// subset filters only the practice pool (`visibleLetterNames` under
// `studyMode`), never the post-test.
//
// Mirrors the `ThesisCondition` / `PilotAudioCondition` machinery:
// deterministic UUID-byte assignment (its own decorrelated byte),
// researcher override in `ParticipantStore`, captured as `let` at VM
// init, stamped on every `PhaseSessionRecord`, exported per row.

import Foundation

/// One of the C(5,3) = 10 possible trained 3-subsets of the study set.
/// `rawValue` is the canonical sorted concatenation (e.g. "AFI") —
/// the CSV export keys on it, so it must stay stable.
struct TrainedLetterSubset: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    let rawValue: String

    /// The 5-letter pilot stimulus set, sorted. THE single owner of
    /// this list: `TracingViewModel.studyBaseLetters` and
    /// `LetterPickerBar.demoLetters` both read it from here, and
    /// `allSubsets` below derives the ten assignment buckets from it.
    static let studyLetters = ["A", "F", "I", "L", "M"]

    /// All 10 subsets in deterministic lexicographic order — index i of
    /// this array is what the UUID-modulo assignment selects, so the
    /// order is load-bearing for reproducibility. Do not reorder.
    static let allSubsets: [TrainedLetterSubset] = {
        var result: [TrainedLetterSubset] = []
        let l = studyLetters
        for i in 0..<l.count {
            for j in (i + 1)..<l.count {
                for k in (j + 1)..<l.count {
                    result.append(TrainedLetterSubset(validated: l[i] + l[j] + l[k]))
                }
            }
        }
        return result
    }()

    /// Internal non-validating init for the canonical enumeration.
    private init(validated: String) { self.rawValue = validated }

    /// Failable public init — accepts only one of the 10 canonical
    /// subsets (letters sorted, all from the study set). A stored
    /// override or record carrying anything else decodes to nil and
    /// falls back to derivation, same shape as the arm enums.
    init?(rawValue: String) {
        guard Self.allSubsets.contains(where: { $0.rawValue == rawValue }) else { return nil }
        self.rawValue = rawValue
    }

    /// The trained letters as base-letter keys (uppercase), for
    /// filtering against `LetterAsset.baseLetter`.
    var letters: Set<String> { Set(rawValue.map(String.init)) }

    /// The 2 study letters this participant does NOT train — the
    /// within-child post-test baseline.
    var untrainedLetters: Set<String> { Set(Self.studyLetters).subtracting(letters) }

    /// Proctor-facing label, e.g. "A · F · I".
    var displayName: String { rawValue.map(String.init).joined(separator: " · ") }

    /// Deterministically assign a participant to a trained subset from
    /// the stable UUID. Keys on byte 9 — decorrelated from byte 0
    /// (`ThesisCondition`) and byte 15 (`PilotAudioCondition`) so the
    /// three axes stay independent.
    ///
    /// NOT byte 8 (2026-09-04): `ParticipantStore.participantId` is a
    /// Foundation `UUID()`, i.e. RFC 4122 version 4, whose byte 6 carries
    /// the version nibble and whose byte 8 carries the two VARIANT bits
    /// (`10xxxxxx`) — byte 8 only ever takes the 64 values 128…191, so
    /// `byte % 10` gave subsets 0, 1, 8, 9 seven of those 64 values and
    /// the other six subsets six each (~10.9 % vs ~9.4 %; measured over
    /// 200 000 v4 UUIDs). The earlier claim of a "~4‰ residual bias from
    /// 256 % 10" assumed a uniform byte. Byte 9 is fully random; the
    /// residual is the genuine 256 % 10 (subsets 0–5 get 26/256, 6–9 get
    /// 25/256). The researcher override exists for exact small-cohort
    /// counterbalancing regardless.
    static func assign(participantId: UUID) -> TrainedLetterSubset {
        let byte = participantId.uuid.9
        return allSubsets[Int(byte) % allSubsets.count]
    }

    /// The trained subset for this install. Researcher override wins;
    /// enrolled installs derive from the participant UUID; non-enrolled
    /// installs get the first canonical subset ("AFI") — inert, since
    /// the subset only takes effect under `studyMode`.
    static var defaultForInstall: TrainedLetterSubset {
        if let manual = ParticipantStore.trainedSubsetOverride {
            return manual
        }
        return ParticipantStore.isEnrolled
            ? .assign(participantId: ParticipantStore.participantId)
            : allSubsets[0]
    }
}
