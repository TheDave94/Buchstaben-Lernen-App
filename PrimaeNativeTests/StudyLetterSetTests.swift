// Pins the study letter pool: `studyMode` restricts
// `visibleLetterNames` to the participant's TRAINED 3 of the 5 study
// letters (A F I L M) — UPPERCASE only — regardless of
// `showAllLetters`, while non-study sessions keep the full alphabet.
// (5-letter set + uppercase decided 2026-07-06; 3-of-5 trained-subset
// design added the same day. The stub deps pin the subset to "AFI".)

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@Suite(.serialized) @MainActor struct StudyLetterSetTests {

    private func makeAsset(_ name: String,
                           base: String,
                           letterCase: LetterAsset.LetterCase) -> LetterAsset {
        LetterAsset(id: name, name: name, baseLetter: base, letterCase: letterCase,
                    audioFiles: [],
                    strokes: LetterStrokes(letter: name, checkpointRadius: 0.1, strokes: []))
    }

    /// A mixed pool: the 5 study letters in both cases, plus K and O
    /// (the former 7-letter demo set's extras) and Z as a control.
    private func makeVM(studyMode: Bool) -> TracingViewModel {
        var deps = TracingDependencies.stub
        deps.studyMode = studyMode
        // Pinned rather than left at .defaultForInstall, which reads
        // ParticipantStore's persisted UserDefaults state and is not
        // deterministic across a test run. .threePhase also matches the
        // real precondition every study device must run under — see
        // DECISIONS.md: guidedOnly/control omit freeWrite entirely, which
        // is what CI caught here (learningPhase stayed .guided instead of
        // .freeWrite because activePhases didn't contain it).
        deps.thesisCondition = .threePhase
        let vm = TracingViewModel(deps)
        vm.letters = [
            makeAsset("A", base: "A", letterCase: .upper),
            makeAsset("F", base: "F", letterCase: .upper),
            makeAsset("I", base: "I", letterCase: .upper),
            makeAsset("L", base: "L", letterCase: .upper),
            makeAsset("M", base: "M", letterCase: .upper),
            makeAsset("K", base: "K", letterCase: .upper),
            makeAsset("O", base: "O", letterCase: .upper),
            makeAsset("Z", base: "Z", letterCase: .upper),
            makeAsset("a", base: "A", letterCase: .lower),
            makeAsset("f", base: "F", letterCase: .lower),
            makeAsset("m", base: "M", letterCase: .lower)
        ]
        return vm
    }

    @Test("studyMode ON → exactly the trained 3 uppercase letters (stub subset AFI)")
    func studyMode_pinsTrainedThreeUppercase() {
        let vm = makeVM(studyMode: true)
        #expect(Set(vm.visibleLetterNames) == ["A", "F", "I"])
    }

    @Test("studyMode ON: pool follows the assigned trained subset")
    func studyMode_poolFollowsSubset() {
        for subset in TrainedLetterSubset.allSubsets {
            var deps = TracingDependencies.stub.with(trainedSubset: subset)
            deps.studyMode = true
            let vm = TracingViewModel(deps)
            vm.letters = TrainedLetterSubset.studyLetters.map {
                makeAsset($0, base: $0, letterCase: .upper)
            }
            #expect(Set(vm.visibleLetterNames) == subset.letters,
                    "subset \(subset.rawValue) must define the practice pool")
        }
    }

    @Test("studyMode ON excludes lowercase variants of study letters")
    func studyMode_excludesLowercase() {
        let vm = makeVM(studyMode: true)
        #expect(!vm.visibleLetterNames.contains("a"))
        #expect(!vm.visibleLetterNames.contains("f"))
        #expect(!vm.visibleLetterNames.contains("m"))
    }

    @Test("studyMode ON excludes the former demo extras (K, O)")
    func studyMode_excludesFormerDemoExtras() {
        let vm = makeVM(studyMode: true)
        #expect(!vm.visibleLetterNames.contains("K"))
        #expect(!vm.visibleLetterNames.contains("O"))
    }

    @Test("studyMode ON wins even if showAllLetters is true (the default)")
    func studyMode_overridesShowAll() {
        let vm = makeVM(studyMode: true)
        vm.showAllLetters = true
        #expect(Set(vm.visibleLetterNames) == ["A", "F", "I"])
    }

    @Test("studyMode OFF + showAllLetters → full pool, both cases (app unchanged outside study)")
    func normalMode_keepsFullAlphabet() {
        let vm = makeVM(studyMode: false)
        vm.showAllLetters = true
        #expect(Set(vm.visibleLetterNames)
                == ["A", "F", "I", "L", "M", "K", "O", "Z", "a", "f", "m"])
    }

    @Test("studyMode OFF + showAllLetters false → study base letters, both cases")
    func demoFilter_keepsBothCases() {
        let vm = makeVM(studyMode: false)
        vm.showAllLetters = false
        #expect(Set(vm.visibleLetterNames) == ["A", "F", "I", "L", "M", "a", "f", "m"])
    }

    // MARK: - H6 post-test reachability
    //
    // The trained 3 (visibleLetterNames) and the untrained 2 (reachable
    // ONLY through startPostTest) are complementary halves of the same
    // 5-letter set. Stub subset is AFI, so L and M are untrained.

    @Test("startPostTest loads an untrained letter directly into freeWrite")
    func startPostTest_untrainedLetter_jumpsToFreeWrite() {
        let vm = makeVM(studyMode: true)
        vm.startPostTest(letter: "L")
        #expect(vm.currentLetterName == "L")
        #expect(vm.learningPhase == .freeWrite,
                "observe/guided must be skipped entirely — reaching either would train the letter")
    }

    @Test("startPostTest refuses a TRAINED letter — state unchanged")
    func startPostTest_trainedLetter_isNoOp() {
        let vm = makeVM(studyMode: true)
        let letterBefore = vm.currentLetterName
        let phaseBefore = vm.learningPhase
        vm.startPostTest(letter: "A")  // A is trained in the stub subset (AFI)
        #expect(vm.currentLetterName == letterBefore,
                "a trained letter must not be reachable via the post-test entry point")
        #expect(vm.learningPhase == phaseBefore)
    }

    @Test("startPostTest is a no-op outside studyMode")
    func startPostTest_outsideStudyMode_isNoOp() {
        let vm = makeVM(studyMode: false)
        let letterBefore = vm.currentLetterName
        let phaseBefore = vm.learningPhase
        vm.startPostTest(letter: "L")
        #expect(vm.currentLetterName == letterBefore)
        #expect(vm.learningPhase == phaseBefore)
    }

    @Test("startPostTest override does not leak into the NEXT letter load")
    func startPostTest_overrideDoesNotLeak() {
        let vm = makeVM(studyMode: true)
        vm.startPostTest(letter: "L")
        #expect(vm.learningPhase == .freeWrite)
        // A normal load right after — e.g. the proctor picking a trained
        // letter again — must not inherit the one-shot freeWrite override.
        // Asserting != .freeWrite rather than pinning to .observe
        // specifically: makeAsset's fixture letters carry empty strokes,
        // which load(letter:)'s own (unrelated, pre-existing) "nothing to
        // demonstrate" skip auto-advances past observe/direct to .guided —
        // correct fixture behaviour, not a leak, and not what this test is
        // about.
        vm.loadLetter(name: "A")
        #expect(vm.learningPhase != .freeWrite,
                "the one-shot override must not leak into a later normal load")
    }

    // MARK: - Cold probes (2026-09-04): pretest / post-test / delayed

    @Test("pretest opens a TRAINED study letter cold in freeWrite and tags it")
    func pretest_trainedLetter_opensColdAndTagged() {
        let vm = makeVM(studyMode: true)
        vm.startColdProbe(letter: "A", kind: .pretest)   // A is trained (stub AFI)
        #expect(vm.currentLetterName == "A")
        #expect(vm.learningPhase == .freeWrite, "the pretest is a cold production on every study letter, trained included")
        #expect(vm.currentProbe == .pretest)
    }

    @Test("delayed probe opens any study letter cold; post-test still refuses a trained one")
    func delayed_anyLetter_postTest_untrainedOnly() {
        let vm = makeVM(studyMode: true)
        vm.startColdProbe(letter: "A", kind: .delayed)
        #expect(vm.learningPhase == .freeWrite && vm.currentProbe == .delayed)
        let before = vm.currentLetterName
        vm.startColdProbe(letter: "A", kind: .posttest)   // trained → refused
        #expect(vm.currentLetterName == before && vm.currentProbe == .delayed,
                "the post-test on a trained letter is its final training pass, not a cold entry")
        vm.startColdProbe(letter: "L", kind: .posttest)   // untrained → allowed
        #expect(vm.currentLetterName == "L" && vm.currentProbe == .posttest)
    }

    @Test("a probe refuses a letter outside the study set and is cleared by the next training load")
    func probe_scopeAndClearing() {
        let vm = makeVM(studyMode: true)
        let before = vm.currentLetterName
        vm.startColdProbe(letter: "Z", kind: .pretest)
        #expect(vm.currentLetterName == before && vm.currentProbe == nil, "Z is not a study letter")
        vm.startColdProbe(letter: "A", kind: .pretest)
        #expect(vm.currentProbe == .pretest)
        vm.loadLetter(name: "A")
        #expect(vm.currentProbe == nil, "a training load must not inherit the probe tag")
        #expect(vm.learningPhase != .freeWrite)
    }

    @Test("startPostTest reaches freeWrite even when the injected pedagogical condition omits it")
    func startPostTest_survivesGuidedOnlyDeps() {
        // Exactly the failure CI once caught here and the fixture then
        // papered over by pinning `.threePhase` in makeVM. An enrolled
        // install can draw `.guidedOnly` / `.control` from UUID byte 0;
        // the VM's own studyMode pin — not a test fixture — is what keeps
        // the post-test (and every training letter's freeWrite phase)
        // reachable (2026-09-04).
        var deps = TracingDependencies.stub   // carries .guidedOnly
        deps.studyMode = true
        let vm = TracingViewModel(deps)
        vm.letters = TrainedLetterSubset.studyLetters.map {
            makeAsset($0, base: $0, letterCase: .upper)
        }
        vm.startPostTest(letter: "L")
        #expect(vm.currentLetterName == "L")
        #expect(vm.learningPhase == .freeWrite,
                "with the stub's .guidedOnly, resume(at: .freeWrite) silently no-ops unless the VM pins the flow")
    }
}
