// Verifies the trained 3-of-5 letter-subset assignment mirrors the two
// arm axes' guarantees — canonical 10-subset enumeration, stable
// deterministic assignment on its own UUID byte (8), decorrelated from
// byte 0 (ThesisCondition) and byte 15 (PilotAudioCondition),
// researcher-override wins — and pins the legacy-decode default for
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

    @Test("Distribution across subsets is roughly uniform (counterbalance)")
    func roughly_uniform_distribution() {
        var counts: [TrainedLetterSubset: Int] = [:]
        let n = 5000
        for _ in 0..<n {
            counts[TrainedLetterSubset.assign(participantId: UUID()), default: 0] += 1
        }
        // Uniform is 1/10 each = ~500. Allow ±150 for 5000 samples
        // (the 256 % 10 residual bias is ~4‰, far below this band).
        for subset in TrainedLetterSubset.allSubsets {
            let c = counts[subset] ?? 0
            #expect(c > 350 && c < 650,
                    "Subset \(subset.rawValue) got \(c); expected ~500 ± 150")
        }
    }

    @Test("Known-byte UUIDs map deterministically off byte 8")
    func deterministic_by_byte_eight() {
        // byte8 = 0 → allSubsets[0] "AFI"; 9 → allSubsets[9] "ILM".
        let byteEightZero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0,
                                        0, 0, 0, 0, 0, 0, 0, 0))
        #expect(TrainedLetterSubset.assign(participantId: byteEightZero).rawValue == "AFI")
        let byteEightNine = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0,
                                        9, 0, 0, 0, 0, 0, 0, 0))
        #expect(TrainedLetterSubset.assign(participantId: byteEightNine).rawValue == "ILM")
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
