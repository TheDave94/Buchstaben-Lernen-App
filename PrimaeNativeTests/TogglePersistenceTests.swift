// Round-trip coverage for the six persisted parent/research toggles.
//
// Audit finding 15's precondition, and a gap in its own right: five of
// the six had ZERO references anywhere in the test tree, and the sixth
// (enablePhonemeMode) appeared only as an INPUT to arm-routing tests.
// Nothing asserted that any of them survives a relaunch.
//
// Each toggle is hand-wired across two files with no compiler-checked
// link between the halves:
//
//   WRITE  TracingViewModel's didSet -> UserDefaults.set(_, forKey: "…")
//   READ   TracingDependencies.init's DEFAULT ARGUMENT -> UserDefaults
//
// A typo on either side, or a didSet quietly dropped in a refactor,
// silently reverts a proctor's device configuration on the next launch
// and nothing fails. That is the same shape as the exporter gap: not a
// tidiness problem, a nothing-is-watching problem.
//
// WHY EACH TEST FLIPS THE TOGGLE AWAY FROM ITS UNSET DEFAULT.
// Setting a default-off toggle to `false` (or a default-on toggle to
// `true`) passes whether persistence works or not — the unset default
// supplies the same answer. Every test below therefore writes the value
// the unset default does NOT produce, so a broken write or a broken
// read is the only way to get the expected result.
//
// `.stub` supplies the heavy dependencies explicitly but deliberately
// OMITS these toggles, so their default arguments still evaluate
// against UserDefaults — which is what makes the read half reachable
// from a test at all.
//
// KEY STABILITY comes free: each test hardcodes the key it expects the
// didSet to write, so renaming the write side alone fails here. What no
// test can catch is BOTH sides renamed together — that compiles, passes,
// and silently reverts every already-configured proctor device on next
// launch. The keys are a storage schema; treat a rename as a migration.

import Testing
import Foundation
@testable import PrimaeNative

@Suite(.serialized) @MainActor struct TogglePersistenceTests {

    // MARK: - Isolation

    /// Clear the named keys, run the body, then restore whatever the
    /// device had. Without this a toggle flipped here would leak into
    /// every later suite that builds a VM.
    private func withCleanDefaults(_ keys: [String], _ body: () -> Void) {
        let saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer { for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) } }
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        body()
    }

    /// One round trip: flip the toggle away from its unset default, prove
    /// the write reached UserDefaults under the expected key, then prove a
    /// freshly-built dependency set and VM read it back.
    ///
    /// - Parameters:
    ///   - unsetDefault: what the toggle reads as when the key is absent.
    ///     The test writes `!unsetDefault`, so the assertions can only
    ///     pass if persistence genuinely ran.
    private func assertRoundTrip(
        name: String,
        key: String,
        unsetDefault: Bool,
        set: (TracingViewModel, Bool) -> Void,
        readFromDeps: (TracingDependencies) -> Bool,
        readFromVM: (TracingViewModel) -> Bool
    ) {
        withCleanDefaults([key]) {
            let target = !unsetDefault

            let vm = TracingViewModel(.stub)
            #expect(readFromVM(vm) == unsetDefault,
                    "\(name): precondition — with '\(key)' absent the toggle should read \(unsetDefault)")

            set(vm, target)

            // WRITE half.
            let stored = UserDefaults.standard.object(forKey: key) as? Bool
            #expect(stored == target,
                    "\(name): didSet did not persist \(target) under '\(key)' — stored \(String(describing: stored))")

            // READ half: the default argument in TracingDependencies.init.
            #expect(readFromDeps(.stub) == target,
                    "\(name): value is in UserDefaults but TracingDependencies did not read it back")

            // And the rebuilt VM must surface it — the path a relaunch takes.
            #expect(readFromVM(TracingViewModel(.stub)) == target,
                    "\(name): dependencies carried it but the rebuilt VM did not expose it")
        }
    }

    // MARK: - The five toggles .stub leaves to UserDefaults

    @Test("enablePaperTransfer survives a rebuild")
    func paperTransferRoundTrips() {
        assertRoundTrip(
            name: "enablePaperTransfer",
            key: "de.flamingistan.primae.enablePaperTransfer",
            unsetDefault: false,
            set: { $0.enablePaperTransfer = $1 },
            readFromDeps: \.enablePaperTransfer,
            readFromVM: \.enablePaperTransfer)
    }

    /// The only default-ON toggle, so this one is written to `false`.
    @Test("enableFreeformMode survives a rebuild (default-on, written off)")
    func freeformModeRoundTrips() {
        assertRoundTrip(
            name: "enableFreeformMode",
            key: "de.flamingistan.primae.enableFreeformMode",
            unsetDefault: true,
            set: { $0.enableFreeformMode = $1 },
            readFromDeps: \.enableFreeformMode,
            readFromVM: \.enableFreeformMode)
    }

    @Test("enablePhonemeMode survives a rebuild")
    func phonemeModeRoundTrips() {
        assertRoundTrip(
            name: "enablePhonemeMode",
            key: "de.flamingistan.primae.enablePhonemeMode",
            unsetDefault: false,
            set: { $0.enablePhonemeMode = $1 },
            readFromDeps: \.enablePhonemeMode,
            readFromVM: \.enablePhonemeMode)
    }

    @Test("enableRetrievalPrompts survives a rebuild")
    func retrievalPromptsRoundTrips() {
        assertRoundTrip(
            name: "enableRetrievalPrompts",
            key: "de.flamingistan.primae.enableRetrievalPrompts",
            unsetDefault: false,
            set: { $0.enableRetrievalPrompts = $1 },
            readFromDeps: \.enableRetrievalPrompts,
            readFromVM: \.enableRetrievalPrompts)
    }

    @Test("enableBackwardChaining survives a rebuild")
    func backwardChainingRoundTrips() {
        assertRoundTrip(
            name: "enableBackwardChaining",
            key: "de.flamingistan.primae.enableBackwardChaining",
            unsetDefault: false,
            set: { $0.enableBackwardChaining = $1 },
            readFromDeps: \.enableBackwardChaining,
            readFromVM: \.enableBackwardChaining)
    }

    // MARK: - studyMode, which .stub pins on purpose

    /// `.stub` hard-pins `studyMode: false` so that VM-building tests do
    /// not change behaviour depending on which binary compiled them (B2
    /// makes the unset default ON in a study build). That pin means the
    /// dependency default is NOT the read path here — `resolveStudyMode`
    /// is, and it is the same function `TracingDependencies` calls.
    @Test("studyMode survives a rebuild via StudyBuild.resolveStudyMode")
    func studyModeRoundTrips() {
        let key = StudyBuild.studyModeDefaultsKey
        withCleanDefaults([key]) {
            let unset = StudyBuild.studyModeDefault
            let target = !unset

            let vm = TracingViewModel(.stub.with(studyMode: unset))
            #expect(vm.studyMode == unset, "precondition: VM starts at the pinned value")

            vm.studyMode = target
            #expect(UserDefaults.standard.object(forKey: key) as? Bool == target,
                    "studyMode: didSet did not persist \(target) under '\(key)'")
            #expect(StudyBuild.resolveStudyMode() == target,
                    "studyMode: stored value must win over the build default")
        }
    }
}
