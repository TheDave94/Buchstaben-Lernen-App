// StudyModeGuardTests.swift
// PrimaeNativeTests
//
// The CalibrationStore study-mode guard's own proof. Verifies the
// single resolution chokepoint `TracingViewModel.resolvedStrokes(for:)`
// directly — no font, no glyph-rect mapping, no on-device render layer:
//
//   studyMode == true  -> returns the bundle (letter.strokes), bypassing
//                         any on-device CalibrationStore override. This
//                         is the thesis-truth-condition: every device
//                         traces the identical frozen stimulus.
//   studyMode == false -> the saved user calibration wins (current,
//                         pre-guard behavior preserved).
//
// The override is materialised through the real mechanism — a
// CalibrationStore.persist to Application Support — mirroring
// CalibrationStoreTests, and cleaned up after. Pairs with
// StrokeGeometryGoldenTests, which pins the `letter.strokes` target this
// guard makes the scored path return.

import Foundation
import CoreGraphics
import Testing
@testable import PrimaeNative

@MainActor
struct StudyModeGuardTests {

    /// Absolute URL for a persisted calibration, matching the store's
    /// on-disk layout so the test cleans up after itself.
    private func fontSpecificURL(letter: String, schriftArt: SchriftArt) -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PrimaeNative/CalibratedStrokes/\(schriftArt.rawValue)/\(letter).json")
    }

    /// A distinct "bundle" asset: TWO strokes, so it can't be confused
    /// with the ONE-stroke override persisted below.
    private func makeBundleAsset(name: String) -> LetterAsset {
        let strokes = LetterStrokes(letter: name, checkpointRadius: 0.1, strokes: [
            StrokeDefinition(id: 1, checkpoints: [Checkpoint(x: 0.2, y: 0.1),
                                                  Checkpoint(x: 0.2, y: 0.9)]),
            StrokeDefinition(id: 2, checkpoints: [Checkpoint(x: 0.1, y: 0.5),
                                                  Checkpoint(x: 0.9, y: 0.5)]),
        ])
        return LetterAsset(id: name, name: name, audioFiles: [], strokes: strokes)
    }

    @Test("studyMode bypasses the override; off-mode preserves override-wins")
    func resolvedStrokes_respectsStudyMode() throws {
        // Unique letter name so no other test (or stale cache) collides.
        let letter = "Z_\(UUID().uuidString.prefix(6))"

        let vm = makeTestVM()
        let art = vm.schriftArt   // persist under whatever the VM actually uses

        // Materialise a ONE-stroke (3-checkpoint) override on disk for
        // this letter under the VM's active SchriftArt.
        let store = CalibrationStore()
        store.persist([[CGPoint(x: 0.0, y: 0.0),
                        CGPoint(x: 0.5, y: 0.5),
                        CGPoint(x: 1.0, y: 1.0)]],
                      for: letter, schriftArt: art)
        defer {
            if let url = fontSpecificURL(letter: letter, schriftArt: art) {
                try? FileManager.default.removeItem(at: url)
            }
            vm.studyMode = false   // restore the persisted flag key
        }

        let asset = makeBundleAsset(name: letter)   // 2 strokes (the bundle)

        // Guard OFF: the on-device override (1 stroke) wins — the
        // pre-guard behavior the shadow produced.
        vm.studyMode = false
        let offResolved = vm.resolvedStrokes(for: asset)
        #expect(offResolved.strokes.count == 1,
                "studyMode==false must let the on-device calibration override win")

        // Guard ON: the override is bypassed; the bundle (2 strokes) is
        // returned verbatim — the identical frozen stimulus.
        vm.studyMode = true
        let onResolved = vm.resolvedStrokes(for: asset)
        #expect(onResolved.strokes.count == 2,
                "studyMode==true must bypass the override and return the bundle")
        #expect(onResolved == asset.strokes,
                "studyMode==true must return exactly the bundle strokes")
    }
}
