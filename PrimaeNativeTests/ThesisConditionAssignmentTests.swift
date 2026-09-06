// Verifies the A/B cohort assignment is stable (same UUID → same arm)
// and that assignment covers all three arms across participants.

import Foundation
import Testing
@testable import PrimaeNative

@Suite struct ThesisConditionAssignmentTests {

    @Test("Same UUID always maps to the same condition")
    func stable_assignment() {
        let uuid = UUID()
        let first  = ThesisCondition.assign(participantId: uuid)
        let second = ThesisCondition.assign(participantId: uuid)
        let third  = ThesisCondition.assign(participantId: uuid)
        #expect(first == second)
        #expect(second == third)
    }

    @Test("Assignment spans all three arms across many random UUIDs")
    func covers_all_arms() {
        var seen = Set<ThesisCondition>()
        for _ in 0..<300 {
            seen.insert(ThesisCondition.assign(participantId: UUID()))
            if seen.count == 3 { break }
        }
        #expect(seen.count == 3)
    }

    @Test("Distribution across arms is uniform to within the 256 % 3 residual")
    func roughly_uniform_distribution() {
        // Same band and reasoning as PilotAudioConditionAssignmentTests:
        // n = 100 000, expected 33 203–33 594 (86/85/85 residual), band
        // 32 583–34 250 ≥ 4.1 sd on both sides (2026-09-06).
        var counts: [ThesisCondition: Int] = [:]
        let n = 100_000
        for _ in 0..<n {
            counts[ThesisCondition.assign(participantId: UUID()), default: 0] += 1
        }
        for arm in ThesisCondition.allCases {
            let c = counts[arm] ?? 0
            #expect(c > 32_583 && c < 34_250,
                    "Arm \(arm) got \(c) assignments; expected 33 203–33 594, band 32 583–34 250")
        }
    }

    @Test("Known-byte UUIDs map deterministically off byte 0")
    func deterministic_by_first_byte() {
        // Byte 0 = 0 → threePhase, 1 → guidedOnly, 2 → control. Pinned
        // to the actual mapping — the previous form of this test compared
        // assign(x) with assign(x), which cannot fail, so the two sibling
        // suites' "independent of byte 0" tests rested on nothing.
        func id(byte0: UInt8) -> UUID {
            UUID(uuid: (byte0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        }
        #expect(ThesisCondition.assign(participantId: id(byte0: 0)) == .threePhase)
        #expect(ThesisCondition.assign(participantId: id(byte0: 1)) == .guidedOnly)
        #expect(ThesisCondition.assign(participantId: id(byte0: 2)) == .control)
        #expect(ThesisCondition.assign(participantId: id(byte0: 3)) == .threePhase)
    }

    /// Mirror of the sibling suites' decorrelation tests: changing only
    /// byte 9 (TrainedLetterSubset) or byte 15 (PilotAudioCondition) must
    /// not move the pedagogical arm.
    @Test("Pedagogical arm is independent of the subset and audio-arm bytes")
    func decorrelated_from_other_axes() {
        let a = UUID(uuid: (7, 1, 2, 3, 4, 5, 6, 7, 8, 0,   10, 11, 12, 13, 14, 0))
        let b = UUID(uuid: (7, 1, 2, 3, 4, 5, 6, 7, 8, 255, 10, 11, 12, 13, 14, 0))
        let c = UUID(uuid: (7, 1, 2, 3, 4, 5, 6, 7, 8, 0,   10, 11, 12, 13, 14, 255))
        #expect(ThesisCondition.assign(participantId: a) == ThesisCondition.assign(participantId: b),
                "must not depend on byte 9")
        #expect(ThesisCondition.assign(participantId: a) == ThesisCondition.assign(participantId: c),
                "must not depend on byte 15")
    }

    // MARK: - Enrollment gating

    /// The A/B random assignment must not apply to non-enrolled installs —
    /// otherwise 2 out of 3 casual users would silently have Anschauen and
    /// Richtung lernen skipped on every letter. These tests exercise
    /// `ThesisCondition.defaultForInstall` directly (no `TracingDependencies`
    /// instantiation) so they don't drag AudioEngine / JSONProgressStore into
    /// the headless CI test bundle.

    @Test("defaultForInstall is threePhase when not enrolled")
    func default_unenrolled_is_threePhase() {
        let previous = ParticipantStore.isEnrolled
        defer { ParticipantStore.isEnrolled = previous }
        ParticipantStore.isEnrolled = false
        #expect(ThesisCondition.defaultForInstall == .threePhase)
    }

    @Test("defaultForInstall uses ThesisCondition.assign when enrolled")
    func enrolled_uses_assign() {
        let previous = ParticipantStore.isEnrolled
        defer { ParticipantStore.isEnrolled = previous }
        ParticipantStore.isEnrolled = true
        let expected = ThesisCondition.assign(participantId: ParticipantStore.participantId)
        #expect(ThesisCondition.defaultForInstall == expected)
    }
}
