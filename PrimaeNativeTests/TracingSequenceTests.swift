import Testing
import Foundation
@testable import PrimaeNative

@Suite @MainActor struct TracingSequenceTests {

    // MARK: - Migration-neutral guarantee: length-1 sequence == today's app

    @Test func singleLetter_producesLengthOneSequence() {
        let seq = TracingSequence.singleLetter("A")
        #expect(seq.items.count == 1)
        #expect(seq.items[0].letter == "A")
        #expect(seq.title == "A")
        #expect(seq.kind == .singleLetter("A"))
    }

    @Test func singleLetter_itemDefaultsMatchLegacy() {
        let item = TracingSequence.singleLetter("A").items[0]
        #expect(item.slotRole == .primary)
        #expect(item.scriptOverride == nil)
        #expect(item.variantID == nil)
    }

    // MARK: - Repetition mode

    @Test func repetition_expandsToCountCopies() {
        let seq = TracingSequence.repetition("A", count: 4)
        #expect(seq.items.count == 4)
        #expect(seq.items.allSatisfy { $0.letter == "A" })
        #expect(seq.title == "A×4")
    }

    @Test func repetition_clampsCountToAtLeastOne() {
        let seq = TracingSequence.repetition("A", count: 0)
        #expect(seq.items.count == 1)
        let negative = TracingSequence.repetition("A", count: -3)
        #expect(negative.items.count == 1)
    }

    // MARK: - Word mode

    @Test func word_splitsIntoPerCharacterItems() {
        let seq = TracingSequence.word("Affe")
        #expect(seq.items.map(\.letter) == ["A", "f", "f", "e"])
        #expect(seq.title == "Affe")
    }

    @Test func word_preservesCase() {
        let seq = TracingSequence.word("Oma")
        #expect(seq.items.map(\.letter) == ["O", "m", "a"])
    }

    @Test func word_splitsByGraphemeSoSharpSStaysOneItem() {
        let seq = TracingSequence.word("Straße")
        #expect(seq.items.map(\.letter) == ["S", "t", "r", "a", "ß", "e"])
    }

    // MARK: - Script override propagation

    @Test func scriptOverride_appliesToAllItems() {
        let seq = TracingSequence.word("Affe", scriptOverride: .schreibschrift)
        #expect(seq.items.allSatisfy { $0.scriptOverride == .schreibschrift })
    }

    @Test func scriptOverride_nilByDefault() {
        let seq = TracingSequence.singleLetter("A")
        #expect(seq.items[0].scriptOverride == nil)
    }

    // MARK: - Identity + equality

    @Test func twoSequencesWithSameKind_haveDifferentIDs() {
        let a = TracingSequence.singleLetter("A")
        let b = TracingSequence.singleLetter("A")
        #expect(a.id != b.id)
    }

    @Test func sequence_equalityIncludesIdentity() {
        // Equatable compares all properties INCLUDING id: two structurally
        // identical sequences are NOT equal, a copy is. (The previous form
        // asserted `a == a`, which cannot fail — 2026-09-04.)
        let a = TracingSequence.singleLetter("A")
        let b = TracingSequence.singleLetter("A")
        #expect(a != b, "different ids must make structurally identical sequences unequal")
        let copy = a
        #expect(a == copy)
    }

    // MARK: - Audio policy default

    @Test func audioPolicy_defaultsToPerCell() {
        let seq = TracingSequence.singleLetter("A")
        #expect(seq.audioPolicy == .perCell)
    }

    // MARK: - SequenceKind titles

    @Test func kindTitle_singleLetter() {
        #expect(SequenceKind.singleLetter("A").title == "A")
    }

    @Test func kindTitle_repetitionFormatsWithMultiplicationSign() {
        #expect(SequenceKind.repetition(letter: "A", count: 4).title == "A×4")
    }

    @Test func kindTitle_word() {
        #expect(SequenceKind.word("Affe").title == "Affe")
    }
}
