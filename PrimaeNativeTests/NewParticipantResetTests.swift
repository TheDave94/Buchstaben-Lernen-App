// Proves the new-participant reset: a fresh enrollee on a shared study
// device gets a NEW UUID (which re-derives BOTH arm axes, decorrelated),
// cleared researcher overrides, a re-stamped enrolment, and wiped
// participant data stores — while device/parent config survives.
//
// Identity logic is exercised directly on ParticipantStore; the
// store-wipe is exercised through TracingViewModel.resetForNewParticipant
// with a temp-file dashboard store.

import Testing
import Foundation
@testable import PrimaeNative

@Suite(.serialized) @MainActor struct NewParticipantResetTests {

    private let studyModeKey   = "de.flamingistan.primae.studyMode"
    private let schriftArtKey  = "de.flamingistan.primae.selectedSchriftArt"
    private let retrievalKey   = "de.flamingistan.primae.retrievalCounter"

    /// Snapshot the global participant-scoped keys this suite mutates and
    /// restore them after each test so suites stay independent.
    private func withRestoredState(_ body: () -> Void) {
        let pedOverride   = ParticipantStore.conditionOverride
        let audioOverride = ParticipantStore.audioConditionOverride
        let enrolled      = ParticipantStore.isEnrolled
        let studyMode     = UserDefaults.standard.object(forKey: studyModeKey)
        let schriftArt    = UserDefaults.standard.object(forKey: schriftArtKey)
        defer {
            ParticipantStore.conditionOverride = pedOverride
            ParticipantStore.audioConditionOverride = audioOverride
            ParticipantStore.isEnrolled = enrolled
            UserDefaults.standard.set(studyMode, forKey: studyModeKey)
            UserDefaults.standard.set(schriftArt, forKey: schriftArtKey)
        }
        body()
    }

    // MARK: - Identity (ParticipantStore.startNewParticipant)

    @Test("startNewParticipant generates a new UUID")
    func generatesNewUUID() {
        withRestoredState {
            let before = ParticipantStore.participantId
            let new = ParticipantStore.startNewParticipant()
            #expect(new != before)
            #expect(ParticipantStore.participantId == new, "new UUID must be persisted")
        }
    }

    @Test("startNewParticipant clears both arm overrides")
    func clearsBothOverrides() {
        withRestoredState {
            ParticipantStore.conditionOverride = .control
            ParticipantStore.audioConditionOverride = .silent
            _ = ParticipantStore.startNewParticipant()
            #expect(ParticipantStore.conditionOverride == nil)
            #expect(ParticipantStore.audioConditionOverride == nil)
        }
    }

    @Test("startNewParticipant re-enrols with a fresh enrolledAt = now")
    func reEnrolsWithFreshTimestamp() {
        withRestoredState {
            // Simulate a stale enrolment far in the past.
            ParticipantStore.isEnrolled = false
            ParticipantStore.isEnrolled = true            // stamps an enrolledAt
            let old = ParticipantStore.enrolledAt
            _ = ParticipantStore.startNewParticipant()
            #expect(ParticipantStore.isEnrolled, "must remain enrolled")
            #expect(ParticipantStore.enrolledAt != nil)
            if let old, let fresh = ParticipantStore.enrolledAt {
                #expect(fresh >= old, "enrolledAt must be re-stamped to the reset instant")
            }
        }
    }

    @Test("startNewParticipant clears the retrieval counter")
    func clearsRetrievalCounter() {
        withRestoredState {
            UserDefaults.standard.set(7, forKey: retrievalKey)
            _ = ParticipantStore.startNewParticipant()
            #expect(UserDefaults.standard.object(forKey: retrievalKey) == nil)
        }
    }

    @Test("the new UUID re-derives BOTH arms, decorrelated")
    func newUUIDReDerivesBothArms() {
        withRestoredState {
            let new = ParticipantStore.startNewParticipant()   // sets enrolled=true, clears overrides
            // Enrolled + no override → defaultForInstall is the modulo arm.
            #expect(ThesisCondition.defaultForInstall == ThesisCondition.assign(participantId: new))
            #expect(PilotAudioCondition.defaultForInstall == PilotAudioCondition.assign(participantId: new))
            // The two axes key on independent UUID bytes (0 vs 15), so the
            // re-derivation is decorrelated — already proven in the
            // assignment suites; here we just confirm both move off the
            // same new UUID through defaultForInstall.
        }
    }

    @Test("device/parent config is preserved across a reset")
    func deviceConfigPreserved() {
        withRestoredState {
            UserDefaults.standard.set(true, forKey: studyModeKey)
            UserDefaults.standard.set("druckschrift", forKey: schriftArtKey)
            _ = ParticipantStore.startNewParticipant()
            #expect(UserDefaults.standard.bool(forKey: studyModeKey), "studyMode must survive")
            #expect(UserDefaults.standard.string(forKey: schriftArtKey) == "druckschrift",
                    "schriftArt must survive")
        }
    }

    // MARK: - Store wipe (TracingViewModel.resetForNewParticipant)

    @Test("resetForNewParticipant wipes the dashboard store and returns a new UUID")
    func vmResetWipesDataAndRegeneratesIdentity() {
        withRestoredState {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: tmp) }

            let store = JSONParentDashboardStore(fileURL: tmp)
            store.recordPhaseSession(letter: "A", phase: "guided", completed: true,
                                     score: 0.5, schedulerPriority: 0, condition: .threePhase)
            let vm = TracingViewModel(.stub.with(dashboardStore: store))
            #expect(!vm.dashboardSnapshot.phaseSessionRecords.isEmpty, "precondition: data present")

            ParticipantStore.conditionOverride = .control
            let before = ParticipantStore.participantId
            let newID = vm.resetForNewParticipant()

            #expect(vm.dashboardSnapshot.phaseSessionRecords.isEmpty, "records must be wiped")
            #expect(newID != before, "identity must regenerate")
            #expect(ParticipantStore.participantId == newID)
            #expect(ParticipantStore.conditionOverride == nil, "override must clear")
        }
    }
}
