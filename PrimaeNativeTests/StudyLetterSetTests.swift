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
}
