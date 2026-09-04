import Testing
import CoreGraphics
@testable import PrimaeNative

@Suite @MainActor struct InputPresetTests {

    // MARK: - Finger preset matches today's single-letter canvas

    @Test func fingerPreset_defaultsToSingleCell() {
        #expect(InputPreset.finger.cellCount == 1)
        #expect(InputPreset.finger.kind == .finger)
        #expect(InputPreset.finger.lineaturStyle == .none)
    }

    // MARK: - Pencil preset

    @Test func pencilPreset_defaultsToFourCells() {
        #expect(InputPreset.pencil.cellCount == 4)
        #expect(InputPreset.pencil.kind == .pencil)
        #expect(InputPreset.pencil.lineaturStyle == .fourLine)
    }

    // MARK: - Sequence-length resolution

    @Test func resolved_forLengthOne_returnsPresetUnchanged() {
        let r = InputPreset.finger.resolved(forSequenceLength: 1)
        #expect(r == InputPreset.finger)
    }

    @Test func resolved_expandsCellCountForLongerSequence() {
        let r = InputPreset.finger.resolved(forSequenceLength: 4)
        #expect(r.cellCount == 4)
        #expect(r.kind == .finger)
        #expect(r.cellSpacing == InputPreset.finger.cellSpacing)
        #expect(r.lineaturStyle == InputPreset.finger.lineaturStyle)
    }

    @Test func resolved_keepsPencilDefaultWhenSequenceShorter() {
        let r = InputPreset.pencil.resolved(forSequenceLength: 1)
        #expect(r.cellCount == 4)
    }

    @Test func resolved_expandsPencilForLongerWord() {
        let r = InputPreset.pencil.resolved(forSequenceLength: 6)
        #expect(r.cellCount == 6)
    }

    @Test func resolved_clampsZeroOrNegativeToOne() {
        let r = InputPreset.finger.resolved(forSequenceLength: 0)
        #expect(r.cellCount == 1)
        let n = InputPreset.finger.resolved(forSequenceLength: -4)
        #expect(n.cellCount == 1)
    }

    // MARK: - Equality

    @Test func fingerPreset_pinsItsValues() {
        // Pins the finger preset's actual geometry against a freshly
        // constructed value. (The previous form compared the static to
        // itself, which cannot fail — 2026-09-04.)
        let expected = InputPreset(kind: .finger, cellCount: 1, cellSpacing: 12,
                                   lineaturStyle: .none, horizontalInset: 0)
        #expect(InputPreset.finger == expected)
        #expect(InputPreset.finger.resolved(forSequenceLength: 1) == expected)
    }

    @Test func fingerAndPencil_areNotEqual() {
        #expect(InputPreset.finger != InputPreset.pencil)
    }
}
