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

    @Test("Distribution across audio arms is roughly uniform")
    func roughly_uniform_distribution() {
        var counts: [PilotAudioCondition: Int] = [:]
        let n = 3000
        for _ in 0..<n {
            counts[PilotAudioCondition.assign(participantId: UUID()), default: 0] += 1
        }
        // Uniform is 1/3 each = ~1000. Allow +/- 200 for 3000 samples.
        for arm in PilotAudioCondition.allCases {
            let c = counts[arm] ?? 0
            #expect(c > 800 && c < 1200,
                    "Arm \(arm) got \(c) assignments; expected ~1000 ± 200")
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
