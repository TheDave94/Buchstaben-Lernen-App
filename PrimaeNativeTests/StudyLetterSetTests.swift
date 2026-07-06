// Pins the 5-letter pilot stimulus set: `studyMode` restricts
// `visibleLetterNames` to A, F, I, L, M — UPPERCASE only — regardless of
// `showAllLetters`, while non-study sessions keep the full alphabet.
// (Letter-set decision 2026-07-06; case decision: uppercase.)

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

    @Test("studyMode ON → exactly the 5 uppercase study letters")
    func studyMode_pinsFiveUppercase() {
        let vm = makeVM(studyMode: true)
        #expect(Set(vm.visibleLetterNames) == ["A", "F", "I", "L", "M"])
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
        #expect(Set(vm.visibleLetterNames) == ["A", "F", "I", "L", "M"])
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
