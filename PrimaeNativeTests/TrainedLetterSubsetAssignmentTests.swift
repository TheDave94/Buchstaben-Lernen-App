// Verifies the trained 3-of-5 letter-subset assignment mirrors the two
// arm axes' guarantees — canonical 10-subset enumeration, stable
// deterministic assignment on its own UUID byte (9), decorrelated from
// byte 0 (ThesisCondition) and byte 15 (PilotAudioCondition), NOT on a
// byte RFC 4122 fixes (6 = version, 8 = variant), researcher-override
// wins — and pins the legacy-decode default for
// `PhaseSessionRecord.trainedSubset`.
//
// Parallel to PilotAudioConditionAssignmentTests.

import Foundation
import Testing
@testable import PrimaeNative

@Suite struct TrainedLetterSubsetAssignmentTests {

    @Test("Exactly 10 canonical subsets, unique, 3 letters each, all from the study set")
    func canonical_enumeration() {
        let all = TrainedLetterSubset.allSubsets
        #expect(all.count == 10)
        #expect(Set(all.map(\.rawValue)).count == 10)
        let study = Set(TrainedLetterSubset.studyLetters)
        for subset in all {
            #expect(subset.letters.count == 3)
            #expect(subset.letters.isSubset(of: study))
            #expect(subset.untrainedLetters.count == 2)
            // rawValue is the sorted concatenation — canonical form.
            #expect(subset.rawValue == subset.rawValue.sorted().map(String.init).joined())
        }
        // Order is load-bearing (UUID modulo indexes it) — pin the ends.
        #expect(all.first?.rawValue == "AFI")
        #expect(all.last?.rawValue == "ILM")
    }

    @Test("rawValue init accepts only the 10 canonical subsets")
    func rawValue_validation() {
        #expect(TrainedLetterSubset(rawValue: "AFI") != nil)
        #expect(TrainedLetterSubset(rawValue: "ILM") != nil)
        #expect(TrainedLetterSubset(rawValue: "FIA") == nil)   // unsorted
        #expect(TrainedLetterSubset(rawValue: "ABC") == nil)   // outside study set
        #expect(TrainedLetterSubset(rawValue: "AFIL") == nil)  // wrong size
        #expect(TrainedLetterSubset(rawValue: "") == nil)
    }

    @Test("Same UUID always maps to the same subset")
    func stable_assignment() {
        let uuid = UUID()
        let first  = TrainedLetterSubset.assign(participantId: uuid)
        let second = TrainedLetterSubset.assign(participantId: uuid)
        #expect(first == second)
    }

    @Test("Assignment spans all 10 subsets across many random UUIDs")
    func covers_all_subsets() {
        var seen = Set<TrainedLetterSubset>()
        for _ in 0..<2000 {
            seen.insert(TrainedLetterSubset.assign(participantId: UUID()))
            if seen.count == 10 { break }
        }
        #expect(seen.count == 10)
    }

    /// Premise every assignment axis rests on: `ParticipantStore.participantId`
    /// is a Foundation `UUID()`, i.e. RFC 4122 version 4 — byte 6 carries
    /// the version nibble (`0100xxxx`) and byte 8 the variant bits
    /// (`10xxxxxx`). Neither byte is uniform, so neither may drive an
    /// assignment. Asserted here so the premise is measured, not assumed.
    @Test("Premise: Foundation UUID() is RFC 4122 v4 — bytes 6 and 8 carry fixed bits")
    func foundation_uuid_is_v4() {
        for _ in 0..<2_000 {
            let u = UUID().uuid
            #expect(u.6 >> 4 == 0x4, "version nibble must be 4")
            #expect(u.8 >> 6 == 0b10, "variant bits must be 10")
        }
    }

    @Test("Exhaustive over the assignment byte: every subset gets 25 or 26 of the 256 values")
    func exhaustive_assignment_byte() {
        var counts: [TrainedLetterSubset: Int] = [:]
        for v in UInt8(0)...UInt8(255) {
            let id = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, v, 0, 0, 0, 0, 0, 0))
            counts[TrainedLetterSubset.assign(participantId: id), default: 0] += 1
        }
        for subset in TrainedLetterSubset.allSubsets {
            let c = counts[subset] ?? 0
            #expect((25...26).contains(c), "subset \(subset.rawValue) got \(c) of 256 byte values")
        }
    }

    @Test("Bytes RFC 4122 fixes (6 = version, 8 = variant) do not move the subset")
    func fixed_format_bytes_do_not_drive_assignment() {
        // Assignment keyed on byte 8 (the previous implementation) read
        // only the 64 values 128…191 and gave four subsets ~10.9 % and
        // six ~9.4 %. Varying each fixed byte over its full range must
        // leave the subset untouched.
        var base: uuid_t = (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15)
        let reference = TrainedLetterSubset.assign(participantId: UUID(uuid: base))
        for v in UInt8(0)...UInt8(255) {
            base.6 = v
            #expect(TrainedLetterSubset.assign(participantId: UUID(uuid: base)) == reference,
                    "byte 6 (version) moved the subset at \(v)")
            base.6 = 6
            base.8 = v
            #expect(TrainedLetterSubset.assign(participantId: UUID(uuid: base)) == reference,
                    "byte 8 (variant) moved the subset at \(v)")
            base.8 = 8
        }
    }

    @Test("Distribution over real UUIDs is uniform to within the 256 % 10 residual")
    func roughly_uniform_distribution() {
        // n = 100 000 v4 UUIDs: expected 10 000 per subset (26/256 →
        // 10 156, 25/256 → 9 766), sd ≈ 95. Band ±700 ≈ 5 sd above the
        // residual, so a false failure is ~1e-6 per subset — and it is
        // tight enough to catch the defect the old ±150-on-5 000 band
        // (7 sd) passed over: byte-8 keying put ~10.9 % (10 938 here) on
        // four subsets.
        var counts: [TrainedLetterSubset: Int] = [:]
        let n = 100_000
        for _ in 0..<n {
            counts[TrainedLetterSubset.assign(participantId: UUID()), default: 0] += 1
        }
        for subset in TrainedLetterSubset.allSubsets {
            let c = counts[subset] ?? 0
            #expect(c > 9_300 && c < 10_700,
                    "Subset \(subset.rawValue) got \(c); expected ~10 000 ± 700")
        }
    }

    @Test("Known-byte UUIDs map deterministically off byte 9")
    func deterministic_by_byte_nine() {
        // byte9 = 0 → allSubsets[0] "AFI"; 9 → allSubsets[9] "ILM".
        let byteNineZero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0,
                                       0, 0, 0, 0, 0, 0, 0, 0))
        #expect(TrainedLetterSubset.assign(participantId: byteNineZero).rawValue == "AFI")
        let byteNineNine = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0,
                                       0, 9, 0, 0, 0, 0, 0, 0))
        #expect(TrainedLetterSubset.assign(participantId: byteNineNine).rawValue == "ILM")
        // And byte 8 alone (the old key) must NOT select — a UUID with
        // byte 8 = 9 and byte 9 = 0 stays on "AFI".
        let byteEightNine = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0,
                                        9, 0, 0, 0, 0, 0, 0, 0))
        #expect(TrainedLetterSubset.assign(participantId: byteEightNine).rawValue == "AFI")
    }

    /// Changing only byte 0 (ThesisCondition's byte) or byte 15
    /// (PilotAudioCondition's byte) must not move the trained subset.
    @Test("Subset is independent of both arm-assignment bytes")
    func decorrelated_from_arm_axes() {
        let a = UUID(uuid: (0,   1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 0))
        let b = UUID(uuid: (255, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 0))
        let c = UUID(uuid: (0,   1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 255))
        #expect(TrainedLetterSubset.assign(participantId: a)
                == TrainedLetterSubset.assign(participantId: b),
                "Subset must not depend on byte 0")
        #expect(TrainedLetterSubset.assign(participantId: a)
                == TrainedLetterSubset.assign(participantId: c),
                "Subset must not depend on byte 15")
    }

    // MARK: - Enrolment gating + researcher override

    @Test("defaultForInstall is the first canonical subset when not enrolled")
    func default_unenrolled_is_first() {
        let previousEnrolled = ParticipantStore.isEnrolled
        let previousOverride = ParticipantStore.trainedSubsetOverride
        defer {
            ParticipantStore.isEnrolled = previousEnrolled
            ParticipantStore.trainedSubsetOverride = previousOverride
        }
        ParticipantStore.trainedSubsetOverride = nil
        ParticipantStore.isEnrolled = false
        #expect(TrainedLetterSubset.defaultForInstall.rawValue == "AFI")
    }

    @Test("defaultForInstall uses assign(participantId:) when enrolled")
    func enrolled_uses_assign() {
        let previousEnrolled = ParticipantStore.isEnrolled
        let previousOverride = ParticipantStore.trainedSubsetOverride
        defer {
            ParticipantStore.isEnrolled = previousEnrolled
            ParticipantStore.trainedSubsetOverride = previousOverride
        }
        ParticipantStore.trainedSubsetOverride = nil
        ParticipantStore.isEnrolled = true
        let expected = TrainedLetterSubset.assign(participantId: ParticipantStore.participantId)
        #expect(TrainedLetterSubset.defaultForInstall == expected)
    }

    @Test("trainedSubsetOverride wins over modulo assignment and round-trips")
    func override_wins() {
        let previousEnrolled = ParticipantStore.isEnrolled
        let previousOverride = ParticipantStore.trainedSubsetOverride
        defer {
            ParticipantStore.isEnrolled = previousEnrolled
            ParticipantStore.trainedSubsetOverride = previousOverride
        }
        ParticipantStore.isEnrolled = true
        for subset in TrainedLetterSubset.allSubsets {
            ParticipantStore.trainedSubsetOverride = subset
            #expect(ParticipantStore.trainedSubsetOverride == subset)   // persisted round-trip
            #expect(TrainedLetterSubset.defaultForInstall == subset)    // override wins
        }
        ParticipantStore.trainedSubsetOverride = nil
        #expect(ParticipantStore.trainedSubsetOverride == nil)
    }

    @Test("Setting the subset override does not touch either arm override")
    func override_axes_are_separate() {
        let prevSubset = ParticipantStore.trainedSubsetOverride
        let prevAudio  = ParticipantStore.audioConditionOverride
        let prevPed    = ParticipantStore.conditionOverride
        defer {
            ParticipantStore.trainedSubsetOverride = prevSubset
            ParticipantStore.audioConditionOverride = prevAudio
            ParticipantStore.conditionOverride = prevPed
        }
        ParticipantStore.conditionOverride = nil
        ParticipantStore.audioConditionOverride = nil
        ParticipantStore.trainedSubsetOverride = TrainedLetterSubset(rawValue: "FIM")
        #expect(ParticipantStore.conditionOverride == nil)
        #expect(ParticipantStore.audioConditionOverride == nil)
    }

    // MARK: - Record stamping / decode compatibility

    @Test("Legacy PhaseSessionRecord JSON without trainedSubset decodes to nil")
    func legacy_record_defaults_to_nil() throws {
        let legacyJSON = """
        {
          "letter": "L", "phase": "guided", "completed": true,
          "score": 0.5, "schedulerPriority": 0.0, "condition": "threePhase"
        }
        """.data(using: .utf8)!
        let legacy = try JSONDecoder().decode(PhaseSessionRecord.self, from: legacyJSON)
        #expect(legacy.trainedSubset == nil)
        #expect(legacy.phaseDurationSeconds == nil)
    }

    @Test("trainedSubset + phaseDurationSeconds survive an encode → decode round-trip")
    func record_roundtrips_new_fields() throws {
        let record = PhaseSessionRecord(
            letter: "A", phase: "freeWrite", completed: true,
            score: 0.8, schedulerPriority: 0.1,
            condition: .control, audioCondition: .spatial,
            recordedAt: Date(timeIntervalSince1970: 1_780_000_000),
            trainedSubset: "AIM",
            phaseDurationSeconds: 12.345
        )
        let data = try JSONEncoder().encode(record)
        let back = try JSONDecoder().decode(PhaseSessionRecord.self, from: data)
        #expect(back.trainedSubset == "AIM")
        #expect(back.phaseDurationSeconds == 12.345)
        #expect(back == record)
    }
}
