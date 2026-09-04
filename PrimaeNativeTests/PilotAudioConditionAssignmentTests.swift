// Verifies the pilot AUDIO-arm assignment mirrors the pedagogical
// `ThesisCondition` guarantees — stable (same UUID → same arm), spans
// all three arms, roughly uniform, researcher-override wins — and is
// DECORRELATED from the pedagogical axis (keys on a different UUID byte).
// Also pins the legacy-decode default for `PhaseSessionRecord`.
//
// Parallel to ThesisConditionAssignmentTests, which is left intact.

import Foundation
import Testing
@testable import PrimaeNative

@Suite struct PilotAudioConditionAssignmentTests {

    @Test("Same UUID always maps to the same audio arm")
    func stable_assignment() {
        let uuid = UUID()
        let first  = PilotAudioCondition.assign(participantId: uuid)
        let second = PilotAudioCondition.assign(participantId: uuid)
        let third  = PilotAudioCondition.assign(participantId: uuid)
        #expect(first == second)
        #expect(second == third)
    }

    @Test("Assignment spans all three audio arms across many random UUIDs")
    func covers_all_arms() {
        var seen = Set<PilotAudioCondition>()
        for _ in 0..<300 {
            seen.insert(PilotAudioCondition.assign(participantId: UUID()))
            if seen.count == 3 { break }
        }
        #expect(seen.count == 3)
    }

    @Test("Distribution across audio arms is uniform to within the 256 % 3 residual")
    func roughly_uniform_distribution() {
        // n = 100 000 v4 UUIDs: expected 33 333 per arm (86/256 → 33 594,
        // 85/256 → 33 203), sd ≈ 149. Band ±750 ≈ 4 sd above the residual.
        // Tight enough to catch keying on an RFC 4122 fixed byte (64
        // values % 3 → 34.4 % = 34 375 here), which the old ±200-on-3 000
        // band (7.7 sd) could not see.
        var counts: [PilotAudioCondition: Int] = [:]
        let n = 100_000
        for _ in 0..<n {
            counts[PilotAudioCondition.assign(participantId: UUID()), default: 0] += 1
        }
        for arm in PilotAudioCondition.allCases {
            let c = counts[arm] ?? 0
            #expect(c > 32_583 && c < 34_083,
                    "Arm \(arm) got \(c) assignments; expected ~33 333 ± 750")
        }
    }

    @Test("Exhaustive over byte 15: arms get 86 / 85 / 85 of the 256 values")
    func exhaustive_assignment_byte() {
        var counts: [PilotAudioCondition: Int] = [:]
        for v in UInt8(0)...UInt8(255) {
            let id = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, v))
            counts[PilotAudioCondition.assign(participantId: id), default: 0] += 1
        }
        #expect(counts[.phoneme] == 86)
        #expect(counts[.spatial] == 85)
        #expect(counts[.silent] == 85)
    }

    @Test("Bytes RFC 4122 fixes (6 = version, 8 = variant) do not move the audio arm")
    func fixed_format_bytes_do_not_drive_assignment() {
        var base: uuid_t = (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15)
        let reference = PilotAudioCondition.assign(participantId: UUID(uuid: base))
        for v in UInt8(0)...UInt8(255) {
            base.6 = v
            #expect(PilotAudioCondition.assign(participantId: UUID(uuid: base)) == reference,
                    "byte 6 (version) moved the arm at \(v)")
            base.6 = 6
            base.8 = v
            #expect(PilotAudioCondition.assign(participantId: UUID(uuid: base)) == reference,
                    "byte 8 (variant) moved the arm at \(v)")
            base.8 = 8
        }
    }

    @Test("Known-byte UUIDs map deterministically off the LAST byte")
    func deterministic_by_last_byte() {
        // Audio assignment keys on uuid.15 (the last byte), not uuid.0.
        // A UUID with last byte 0 → phoneme; 1 → spatial; 2 → silent.
        let lastByteZero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0,
                                       0, 0, 0, 0, 0, 0, 0, 0))
        #expect(PilotAudioCondition.assign(participantId: lastByteZero) == .phoneme)
        let lastByteOne = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0,
                                      0, 0, 0, 0, 0, 0, 0, 1))
        #expect(PilotAudioCondition.assign(participantId: lastByteOne) == .spatial)
        let lastByteTwo = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0,
                                      0, 0, 0, 0, 0, 0, 0, 2))
        #expect(PilotAudioCondition.assign(participantId: lastByteTwo) == .silent)
    }

    /// The decorrelation guarantee: changing only the FIRST byte (which
    /// drives `ThesisCondition`) must not move the audio arm. If the audio
    /// axis ever shared byte 0 with the pedagogical axis, this fails.
    @Test("Audio arm is independent of the byte ThesisCondition keys on")
    func decorrelated_from_pedagogical_axis() {
        // Two UUIDs that differ ONLY in byte 0 → same audio arm.
        let a = UUID(uuid: (0,   1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 42))
        let b = UUID(uuid: (255, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 42))
        #expect(PilotAudioCondition.assign(participantId: a)
                == PilotAudioCondition.assign(participantId: b),
                "Audio arm must not depend on byte 0 (ThesisCondition's byte)")
    }

    // MARK: - Enrollment gating

    @Test("defaultForInstall is phoneme when not enrolled")
    func default_unenrolled_is_phoneme() {
        let previousEnrolled = ParticipantStore.isEnrolled
        let previousOverride = ParticipantStore.audioConditionOverride
        defer {
            ParticipantStore.isEnrolled = previousEnrolled
            ParticipantStore.audioConditionOverride = previousOverride
        }
        ParticipantStore.audioConditionOverride = nil
        ParticipantStore.isEnrolled = false
        #expect(PilotAudioCondition.defaultForInstall == .phoneme)
    }

    @Test("defaultForInstall uses PilotAudioCondition.assign when enrolled")
    func enrolled_uses_assign() {
        let previousEnrolled = ParticipantStore.isEnrolled
        let previousOverride = ParticipantStore.audioConditionOverride
        defer {
            ParticipantStore.isEnrolled = previousEnrolled
            ParticipantStore.audioConditionOverride = previousOverride
        }
        ParticipantStore.audioConditionOverride = nil
        ParticipantStore.isEnrolled = true
        let expected = PilotAudioCondition.assign(participantId: ParticipantStore.participantId)
        #expect(PilotAudioCondition.defaultForInstall == expected)
    }

    // MARK: - Researcher override

    @Test("audioConditionOverride wins over modulo assignment and round-trips")
    func override_wins() {
        let previousEnrolled = ParticipantStore.isEnrolled
        let previousOverride = ParticipantStore.audioConditionOverride
        defer {
            ParticipantStore.isEnrolled = previousEnrolled
            ParticipantStore.audioConditionOverride = previousOverride
        }
        ParticipantStore.isEnrolled = true
        // Force each arm explicitly; override must beat the byte-derived arm.
        for arm in PilotAudioCondition.allCases {
            ParticipantStore.audioConditionOverride = arm
            #expect(ParticipantStore.audioConditionOverride == arm)   // persisted round-trip
            #expect(PilotAudioCondition.defaultForInstall == arm)     // override wins
        }
        // Clearing the override falls back to derivation.
        ParticipantStore.audioConditionOverride = nil
        #expect(ParticipantStore.audioConditionOverride == nil)
    }

    @Test("Setting the audio override does NOT touch the pedagogical override")
    func override_axes_are_separate() {
        let prevAudio = ParticipantStore.audioConditionOverride
        let prevPed   = ParticipantStore.conditionOverride
        defer {
            ParticipantStore.audioConditionOverride = prevAudio
            ParticipantStore.conditionOverride = prevPed
        }
        ParticipantStore.conditionOverride = nil
        ParticipantStore.audioConditionOverride = .silent
        #expect(ParticipantStore.conditionOverride == nil,
                "Audio override must be stored under its own key")
    }

    // MARK: - Participant restore (delayed retention test, 2026-09-04)

    @Test("restoreParticipant re-installs an existing id, enrols, and clears every override")
    func restoreParticipant_roundTrip() {
        let prevID = ParticipantStore.participantId
        let prevEnrolled = ParticipantStore.isEnrolled
        let prevAudio = ParticipantStore.audioConditionOverride
        let prevPed = ParticipantStore.conditionOverride
        let prevSubset = ParticipantStore.trainedSubsetOverride
        defer {
            UserDefaults.standard.set(prevID.uuidString, forKey: "de.flamingistan.primae.participantId")
            ParticipantStore.isEnrolled = prevEnrolled
            ParticipantStore.audioConditionOverride = prevAudio
            ParticipantStore.conditionOverride = prevPed
            ParticipantStore.trainedSubsetOverride = prevSubset
        }
        ParticipantStore.audioConditionOverride = .spatial
        let original = UUID()
        let restored = ParticipantStore.restoreParticipant(uuidString: " \(original.uuidString.lowercased()) ")
        #expect(restored == original, "whitespace and case must not matter — the id is typed from a printout")
        #expect(ParticipantStore.participantId == original)
        #expect(ParticipantStore.isEnrolled)
        #expect(ParticipantStore.audioConditionOverride == nil, "an override from the first session is on its rows, not on the device")
        // The arms re-derive from the restored id, exactly as at first enrolment.
        #expect(PilotAudioCondition.defaultForInstall == PilotAudioCondition.assign(participantId: original))
        #expect(TrainedLetterSubset.defaultForInstall == TrainedLetterSubset.assign(participantId: original))
    }

    @Test("restoreParticipant refuses a malformed id and changes nothing")
    func restoreParticipant_malformed() {
        let prevID = ParticipantStore.participantId
        let prevEnrolled = ParticipantStore.isEnrolled
        defer {
            UserDefaults.standard.set(prevID.uuidString, forKey: "de.flamingistan.primae.participantId")
            ParticipantStore.isEnrolled = prevEnrolled
        }
        #expect(ParticipantStore.restoreParticipant(uuidString: "not-a-uuid") == nil)
        #expect(ParticipantStore.participantId == prevID)
    }

    // MARK: - Backward-compatible decode

    @Test("Legacy PhaseSessionRecord JSON without audioCondition decodes to .phoneme")
    func legacy_record_defaults_to_phoneme() throws {
        // Wire format predating the audio axis: no `audioCondition` key.
        let legacyJSON = """
        {
          "letter": "L", "phase": "guided", "completed": true,
          "score": 0.5, "schedulerPriority": 0.0, "condition": "threePhase"
        }
        """.data(using: .utf8)!
        let legacy = try JSONDecoder().decode(PhaseSessionRecord.self, from: legacyJSON)
        #expect(legacy.audioCondition == .phoneme)
        #expect(legacy.condition == .threePhase)   // existing default still holds
    }

    @Test("audioCondition survives an encode → decode round-trip")
    func record_roundtrips_audio_arm() throws {
        for arm in PilotAudioCondition.allCases {
            let record = PhaseSessionRecord(
                letter: "A", phase: "freeWrite", completed: true,
                score: 0.8, schedulerPriority: 0.1,
                condition: .control, audioCondition: arm,
                recordedAt: Date(timeIntervalSince1970: 1_770_000_000)
            )
            let data = try JSONEncoder().encode(record)
            let back = try JSONDecoder().decode(PhaseSessionRecord.self, from: data)
            #expect(back.audioCondition == arm)
            #expect(back == record)   // full Equatable round-trip
        }
    }
}
