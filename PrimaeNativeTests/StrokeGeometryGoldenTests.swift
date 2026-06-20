// StrokeGeometryGoldenTests.swift
// PrimaeNativeTests
//
// Characterization / golden test: pins the BUNDLE scored stroke
// geometry against a frozen inline baseline. Safety net for the
// upcoming CalibrationStore study-mode guard and any later geometry
// change (re-bake, font swap, parser edit).
//
// SEAM (see recon / docs/ROADMAP.md Known issues — CalibrationStore
// override-shadow). Letters load through the
// production `LetterRepository` + `BundleLetterResourceProvider`, which
// decodes `strokes.json` straight into `LetterStrokes` and NEVER
// consults `CalibrationStore`. So `LetterAsset.strokes` here is the
// pure `?? letter.strokes` fallback target — exactly the geometry the
// scored path (`TracingViewModel.reloadStrokeCheckpoints`, the resolve
// at ~:1554) lands on once on-device overrides are bypassed. No disk
// overrides, no font, no MainActor entanglement -> deterministic.
//
// PINS the scored subset only: `letter`, `checkpointRadius`, and each
// stroke's `id` + checkpoint `(x, y)`. Deliberately EXCLUDES
// `skeleton` / `skeletonAdj` / `bridgeEdges` (calibrator point-clouds,
// not scored geometry; `LetterStrokes: Equatable` includes them, so we
// compare a projection, not whole-struct `==`). The font-derived
// bbox->cell mapping (`reloadStrokeCheckpoints` ~:1590-1606) is also
// out of scope here: it gets its own on-device golden after the
// CalibrationStore guard and the new font land.
//
// REGENERATING after an APPROVED bake change: update the `baseline`
// literal below from the four `Letters/Regular/{I,A,t_l,i_l}/strokes.json`
// files (scored subset only). A value drift failing this test is the
// consciously-approve contract working as intended — do not "fix" it by
// loosening the assertion.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@MainActor
struct StrokeGeometryGoldenTests {

    // MARK: Projected scored-geometry model (skeleton fields excluded)

    private struct ScoredStroke: Equatable {
        let id: Int
        let checkpoints: [Checkpoint]
    }
    private struct ScoredGeometry: Equatable {
        let letter: String
        let checkpointRadius: CGFloat
        let strokes: [ScoredStroke]
    }

    private static func project(_ s: LetterStrokes) -> ScoredGeometry {
        ScoredGeometry(
            letter: s.letter,
            checkpointRadius: s.checkpointRadius,
            strokes: s.strokes.map { ScoredStroke(id: $0.id, checkpoints: $0.checkpoints) }
        )
    }

    /// Compact checkpoint constructor for the baseline literal.
    private static func cp(_ x: CGFloat, _ y: CGFloat) -> Checkpoint { Checkpoint(x: x, y: y) }

    // MARK: Frozen baseline — generated from current bundle geometry.

    private static let baseline: [String: ScoredGeometry] = [
        "I": ScoredGeometry(letter: "I", checkpointRadius: 0.1, strokes: [
            ScoredStroke(id: 1, checkpoints: [
                cp(0.71, 0.04), cp(0.699, 0.063), cp(0.688, 0.086), cp(0.677, 0.11), cp(0.665, 0.133), cp(0.654, 0.156),
                cp(0.643, 0.179), cp(0.632, 0.202), cp(0.621, 0.226), cp(0.61, 0.249), cp(0.599, 0.272), cp(0.588, 0.295),
                cp(0.577, 0.319), cp(0.566, 0.342), cp(0.555, 0.365), cp(0.544, 0.389), cp(0.533, 0.412), cp(0.522, 0.435),
                cp(0.511, 0.458), cp(0.5, 0.482), cp(0.489, 0.505), cp(0.478, 0.528), cp(0.467, 0.552), cp(0.457, 0.575),
                cp(0.446, 0.599), cp(0.436, 0.622), cp(0.426, 0.646), cp(0.416, 0.67), cp(0.407, 0.694), cp(0.398, 0.718),
                cp(0.389, 0.742), cp(0.38, 0.766), cp(0.371, 0.79), cp(0.362, 0.815), cp(0.354, 0.839), cp(0.345, 0.863),
                cp(0.336, 0.887), cp(0.328, 0.912), cp(0.319, 0.936), cp(0.31, 0.96),
            ]),
        ]),
        "A": ScoredGeometry(letter: "A", checkpointRadius: 0.1, strokes: [
            ScoredStroke(id: 1, checkpoints: [
                cp(0.058, 0.959), cp(0.071, 0.935), cp(0.085, 0.911), cp(0.098, 0.887), cp(0.111, 0.864), cp(0.125, 0.84),
                cp(0.138, 0.816), cp(0.152, 0.792), cp(0.165, 0.768), cp(0.178, 0.744), cp(0.192, 0.721), cp(0.205, 0.697),
                cp(0.219, 0.673), cp(0.232, 0.649), cp(0.245, 0.625), cp(0.259, 0.602), cp(0.272, 0.578), cp(0.286, 0.554),
                cp(0.3, 0.53), cp(0.313, 0.506), cp(0.327, 0.483), cp(0.34, 0.459), cp(0.354, 0.435), cp(0.367, 0.412),
                cp(0.381, 0.388), cp(0.394, 0.364), cp(0.408, 0.34), cp(0.421, 0.316), cp(0.435, 0.293), cp(0.448, 0.269),
                cp(0.462, 0.245), cp(0.475, 0.221), cp(0.489, 0.198), cp(0.502, 0.174), cp(0.516, 0.15), cp(0.529, 0.126),
                cp(0.543, 0.102), cp(0.556, 0.079), cp(0.57, 0.055), cp(0.583, 0.031),
            ]),
            ScoredStroke(id: 2, checkpoints: [
                cp(0.936, 0.953), cp(0.927, 0.93), cp(0.918, 0.906), cp(0.909, 0.883), cp(0.9, 0.859), cp(0.891, 0.836),
                cp(0.882, 0.813), cp(0.873, 0.789), cp(0.864, 0.766), cp(0.855, 0.742), cp(0.846, 0.719), cp(0.837, 0.695),
                cp(0.828, 0.672), cp(0.819, 0.649), cp(0.81, 0.625), cp(0.801, 0.602), cp(0.792, 0.578), cp(0.783, 0.555),
                cp(0.774, 0.531), cp(0.766, 0.508), cp(0.757, 0.485), cp(0.748, 0.461), cp(0.739, 0.438), cp(0.73, 0.414),
                cp(0.721, 0.391), cp(0.712, 0.367), cp(0.703, 0.344), cp(0.694, 0.32), cp(0.685, 0.297), cp(0.676, 0.274),
                cp(0.667, 0.25), cp(0.659, 0.227), cp(0.65, 0.203), cp(0.641, 0.18), cp(0.632, 0.156), cp(0.623, 0.133),
                cp(0.614, 0.109), cp(0.605, 0.086), cp(0.596, 0.063), cp(0.587, 0.039),
            ]),
            ScoredStroke(id: 3, checkpoints: [
                cp(0.286, 0.588), cp(0.299, 0.588), cp(0.312, 0.588), cp(0.325, 0.588), cp(0.338, 0.588), cp(0.351, 0.588),
                cp(0.365, 0.588), cp(0.378, 0.588), cp(0.391, 0.588), cp(0.404, 0.589), cp(0.417, 0.589), cp(0.43, 0.589),
                cp(0.443, 0.589), cp(0.457, 0.589), cp(0.47, 0.589), cp(0.483, 0.589), cp(0.496, 0.59), cp(0.509, 0.59),
                cp(0.522, 0.59), cp(0.535, 0.59), cp(0.549, 0.59), cp(0.562, 0.59), cp(0.575, 0.59), cp(0.588, 0.591),
                cp(0.601, 0.591), cp(0.614, 0.591), cp(0.627, 0.591), cp(0.641, 0.59), cp(0.654, 0.59), cp(0.667, 0.59),
                cp(0.68, 0.59), cp(0.693, 0.59), cp(0.706, 0.59), cp(0.719, 0.589), cp(0.733, 0.589), cp(0.746, 0.589),
                cp(0.759, 0.588), cp(0.772, 0.588), cp(0.785, 0.588), cp(0.798, 0.588),
            ]),
        ]),
        "t": ScoredGeometry(letter: "t", checkpointRadius: 0.1, strokes: [
            ScoredStroke(id: 1, checkpoints: [
                cp(0.42, 0.06), cp(0.415, 0.096), cp(0.41, 0.132), cp(0.405, 0.168), cp(0.399, 0.204), cp(0.392, 0.24),
                cp(0.386, 0.276), cp(0.38, 0.312), cp(0.373, 0.348), cp(0.367, 0.384), cp(0.36, 0.42), cp(0.354, 0.456),
                cp(0.347, 0.492), cp(0.341, 0.528), cp(0.336, 0.564), cp(0.33, 0.6), cp(0.325, 0.636), cp(0.321, 0.673),
                cp(0.318, 0.709), cp(0.315, 0.745), cp(0.315, 0.782), cp(0.318, 0.818), cp(0.326, 0.854), cp(0.345, 0.885),
                cp(0.374, 0.907), cp(0.407, 0.923), cp(0.441, 0.936), cp(0.477, 0.943), cp(0.513, 0.948), cp(0.549, 0.95),
                cp(0.586, 0.95), cp(0.622, 0.947), cp(0.658, 0.942), cp(0.694, 0.936), cp(0.73, 0.928), cp(0.765, 0.918),
                cp(0.8, 0.908), cp(0.835, 0.896), cp(0.869, 0.884), cp(0.904, 0.872),
            ]),
            ScoredStroke(id: 2, checkpoints: [
                cp(0.102, 0.303), cp(0.123, 0.303), cp(0.139, 0.303), cp(0.16, 0.303), cp(0.182, 0.303), cp(0.198, 0.303),
                cp(0.219, 0.303), cp(0.241, 0.303), cp(0.257, 0.303), cp(0.278, 0.303), cp(0.3, 0.303), cp(0.316, 0.303),
                cp(0.337, 0.303), cp(0.358, 0.303), cp(0.374, 0.303), cp(0.396, 0.303), cp(0.417, 0.303), cp(0.433, 0.303),
                cp(0.455, 0.303), cp(0.476, 0.303), cp(0.492, 0.303), cp(0.513, 0.303), cp(0.535, 0.303), cp(0.551, 0.303),
                cp(0.572, 0.303), cp(0.594, 0.303), cp(0.61, 0.303), cp(0.631, 0.303), cp(0.652, 0.303), cp(0.668, 0.303),
                cp(0.69, 0.303), cp(0.711, 0.303), cp(0.727, 0.303), cp(0.749, 0.303), cp(0.77, 0.303), cp(0.786, 0.303),
                cp(0.808, 0.303), cp(0.829, 0.303), cp(0.845, 0.303), cp(0.866, 0.303),
            ]),
        ]),
        "i": ScoredGeometry(letter: "i", checkpointRadius: 0.1, strokes: [
            ScoredStroke(id: 1, checkpoints: [
                cp(0.49, 0.33), cp(0.484, 0.346), cp(0.478, 0.362), cp(0.472, 0.378), cp(0.466, 0.394), cp(0.46, 0.41),
                cp(0.453, 0.425), cp(0.447, 0.441), cp(0.441, 0.457), cp(0.435, 0.473), cp(0.429, 0.489), cp(0.423, 0.505),
                cp(0.418, 0.521), cp(0.412, 0.537), cp(0.406, 0.553), cp(0.401, 0.569), cp(0.395, 0.586), cp(0.39, 0.602),
                cp(0.385, 0.618), cp(0.38, 0.634), cp(0.374, 0.65), cp(0.369, 0.667), cp(0.364, 0.683), cp(0.359, 0.699),
                cp(0.354, 0.715), cp(0.349, 0.732), cp(0.344, 0.748), cp(0.339, 0.764), cp(0.334, 0.781), cp(0.329, 0.797),
                cp(0.324, 0.813), cp(0.319, 0.829), cp(0.314, 0.846), cp(0.309, 0.862), cp(0.304, 0.878), cp(0.3, 0.895),
                cp(0.295, 0.911), cp(0.29, 0.927), cp(0.285, 0.944), cp(0.28, 0.96),
            ]),
            ScoredStroke(id: 2, checkpoints: [
                cp(0.59, 0.074),
            ]),
        ]),
    ]

    // MARK: Test

    @Test("Bundle scored stroke geometry matches the frozen baseline")
    func bundleGeometryMatchesBaseline() throws {
        let repo = LetterRepository(resources: BundleLetterResourceProvider(),
                                    cache: NullLetterCache())
        let letters = repo.loadLetters()

        // Loud-fail guard: a bundle miss falls back to the single
        // hardcoded sample letter (LetterRepository.fallbackSampleLetter).
        // Require the real corpus so the test can't pass against the stub.
        #expect(letters.count > 20,
                "Expected the full bundled corpus; got \(letters.count). Bundle likely unresolved in the test host — without this guard the test would assert against fallbackSampleLetter().")

        for (name, expected) in Self.baseline {
            let asset = try #require(letters.first(where: { $0.name == name }),
                                     "Letter \(name) missing from the bundle")
            #expect(Self.project(asset.strokes) == expected,
                    "Scored stroke geometry for \(name) drifted from the frozen baseline")
        }
    }
}
