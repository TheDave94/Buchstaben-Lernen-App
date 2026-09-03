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
}
