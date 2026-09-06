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
// literal below from the seven `Letters/Regular/{I,A,F,L,M,t_l,i_l}/strokes.json`
// files (scored subset only). F, L and M were added 2026-09-06 so that
// ALL FIVE study letters (TrainedLetterSubset.studyLetters) are pinned —
// before that a re-bake of F, L or M between pilot builds passed CI. A value drift failing this test is the
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
        "F": ScoredGeometry(letter: "F", checkpointRadius: 0.1, strokes: [
            ScoredStroke(id: 1, checkpoints: [
                cp(0.19, 0.04), cp(0.187, 0.063), cp(0.184, 0.087), cp(0.182, 0.11), cp(0.179, 0.133), cp(0.176, 0.157),
                cp(0.173, 0.18), cp(0.17, 0.203), cp(0.167, 0.226), cp(0.165, 0.25), cp(0.162, 0.273), cp(0.159, 0.296),
                cp(0.156, 0.32), cp(0.153, 0.343), cp(0.15, 0.366), cp(0.147, 0.39), cp(0.145, 0.413), cp(0.142, 0.436),
                cp(0.139, 0.459), cp(0.136, 0.483), cp(0.133, 0.506), cp(0.13, 0.529), cp(0.127, 0.553), cp(0.124, 0.576),
                cp(0.121, 0.599), cp(0.119, 0.623), cp(0.116, 0.646), cp(0.113, 0.669), cp(0.11, 0.692), cp(0.107, 0.716),
                cp(0.104, 0.739), cp(0.101, 0.762), cp(0.098, 0.786), cp(0.096, 0.809), cp(0.093, 0.832), cp(0.09, 0.856),
                cp(0.087, 0.879), cp(0.084, 0.902), cp(0.081, 0.925), cp(0.078, 0.949),
            ]),
            ScoredStroke(id: 2, checkpoints: [
                cp(0.19, 0.041), cp(0.21, 0.041), cp(0.229, 0.041), cp(0.248, 0.041), cp(0.267, 0.041), cp(0.286, 0.041),
                cp(0.306, 0.041), cp(0.325, 0.041), cp(0.344, 0.041), cp(0.363, 0.041), cp(0.383, 0.041), cp(0.402, 0.041),
                cp(0.421, 0.041), cp(0.44, 0.041), cp(0.459, 0.041), cp(0.479, 0.041), cp(0.498, 0.041), cp(0.517, 0.041),
                cp(0.536, 0.04), cp(0.556, 0.04), cp(0.575, 0.04), cp(0.594, 0.04), cp(0.613, 0.04), cp(0.632, 0.039),
                cp(0.652, 0.039), cp(0.671, 0.039), cp(0.69, 0.039), cp(0.709, 0.039), cp(0.729, 0.039), cp(0.748, 0.039),
                cp(0.767, 0.039), cp(0.786, 0.039), cp(0.805, 0.039), cp(0.825, 0.039), cp(0.844, 0.039), cp(0.863, 0.04),
                cp(0.882, 0.04), cp(0.902, 0.04), cp(0.921, 0.04), cp(0.94, 0.04),
            ]),
            ScoredStroke(id: 3, checkpoints: [
                cp(0.15, 0.48), cp(0.166, 0.48), cp(0.182, 0.48), cp(0.198, 0.48), cp(0.215, 0.48), cp(0.231, 0.48),
                cp(0.247, 0.48), cp(0.263, 0.48), cp(0.279, 0.48), cp(0.295, 0.48), cp(0.312, 0.48), cp(0.328, 0.48),
                cp(0.344, 0.48), cp(0.36, 0.479), cp(0.376, 0.48), cp(0.392, 0.48), cp(0.408, 0.48), cp(0.425, 0.48),
                cp(0.441, 0.48), cp(0.457, 0.48), cp(0.473, 0.48), cp(0.489, 0.48), cp(0.505, 0.48), cp(0.522, 0.48),
                cp(0.538, 0.48), cp(0.554, 0.48), cp(0.57, 0.48), cp(0.586, 0.48), cp(0.602, 0.48), cp(0.618, 0.48),
                cp(0.635, 0.48), cp(0.651, 0.48), cp(0.667, 0.48), cp(0.683, 0.48), cp(0.699, 0.48), cp(0.715, 0.48),
                cp(0.732, 0.48), cp(0.748, 0.48), cp(0.764, 0.48), cp(0.78, 0.48),
            ]),
        ]),
        "L": ScoredGeometry(letter: "L", checkpointRadius: 0.1, strokes: [
            ScoredStroke(id: 1, checkpoints: [
                cp(0.2, 0.05), cp(0.197, 0.073), cp(0.193, 0.096), cp(0.19, 0.119), cp(0.187, 0.142), cp(0.184, 0.165),
                cp(0.18, 0.188), cp(0.177, 0.211), cp(0.174, 0.234), cp(0.17, 0.257), cp(0.167, 0.28), cp(0.164, 0.303),
                cp(0.161, 0.326), cp(0.158, 0.349), cp(0.155, 0.372), cp(0.152, 0.395), cp(0.149, 0.419), cp(0.146, 0.442),
                cp(0.144, 0.465), cp(0.141, 0.488), cp(0.138, 0.511), cp(0.136, 0.534), cp(0.133, 0.557), cp(0.13, 0.58),
                cp(0.128, 0.603), cp(0.125, 0.626), cp(0.122, 0.649), cp(0.12, 0.673), cp(0.117, 0.696), cp(0.115, 0.719),
                cp(0.112, 0.742), cp(0.11, 0.765), cp(0.107, 0.788), cp(0.105, 0.811), cp(0.102, 0.834), cp(0.1, 0.858),
                cp(0.097, 0.881), cp(0.095, 0.904), cp(0.092, 0.927), cp(0.09, 0.95),
            ]),
            ScoredStroke(id: 2, checkpoints: [
                cp(0.09, 0.95), cp(0.112, 0.95), cp(0.134, 0.95), cp(0.155, 0.95), cp(0.177, 0.95), cp(0.199, 0.95),
                cp(0.221, 0.95), cp(0.243, 0.95), cp(0.264, 0.95), cp(0.286, 0.95), cp(0.308, 0.95), cp(0.33, 0.95),
                cp(0.352, 0.95), cp(0.373, 0.95), cp(0.395, 0.95), cp(0.417, 0.95), cp(0.439, 0.95), cp(0.461, 0.95),
                cp(0.482, 0.95), cp(0.504, 0.95), cp(0.526, 0.95), cp(0.548, 0.95), cp(0.569, 0.95), cp(0.591, 0.95),
                cp(0.613, 0.95), cp(0.635, 0.95), cp(0.657, 0.95), cp(0.678, 0.95), cp(0.7, 0.95), cp(0.722, 0.95),
                cp(0.744, 0.95), cp(0.766, 0.95), cp(0.787, 0.95), cp(0.809, 0.95), cp(0.831, 0.95), cp(0.853, 0.95),
                cp(0.875, 0.95), cp(0.896, 0.95), cp(0.918, 0.95), cp(0.94, 0.95),
            ]),
        ]),
        "M": ScoredGeometry(letter: "M", checkpointRadius: 0.1, strokes: [
            ScoredStroke(id: 1, checkpoints: [
                cp(0.05, 0.957), cp(0.052, 0.938), cp(0.055, 0.92), cp(0.058, 0.901), cp(0.06, 0.883), cp(0.063, 0.864),
                cp(0.066, 0.845), cp(0.068, 0.827), cp(0.071, 0.808), cp(0.074, 0.79), cp(0.076, 0.771), cp(0.079, 0.753),
                cp(0.081, 0.734), cp(0.084, 0.715), cp(0.087, 0.697), cp(0.09, 0.678), cp(0.092, 0.66), cp(0.095, 0.641),
                cp(0.098, 0.623), cp(0.1, 0.604), cp(0.103, 0.585), cp(0.106, 0.567), cp(0.108, 0.548), cp(0.111, 0.53),
                cp(0.114, 0.511), cp(0.117, 0.492), cp(0.119, 0.474), cp(0.122, 0.455), cp(0.125, 0.437), cp(0.128, 0.418),
                cp(0.131, 0.4), cp(0.134, 0.381), cp(0.137, 0.363), cp(0.139, 0.344), cp(0.142, 0.325), cp(0.145, 0.307),
                cp(0.148, 0.288), cp(0.15, 0.27), cp(0.153, 0.251), cp(0.156, 0.233), cp(0.159, 0.214), cp(0.162, 0.196),
                cp(0.165, 0.177), cp(0.168, 0.159), cp(0.171, 0.14), cp(0.175, 0.122), cp(0.179, 0.103), cp(0.183, 0.085),
                cp(0.188, 0.067), cp(0.193, 0.049), cp(0.206, 0.05), cp(0.214, 0.067), cp(0.221, 0.085), cp(0.228, 0.102),
                cp(0.234, 0.12), cp(0.241, 0.137), cp(0.247, 0.155), cp(0.253, 0.173), cp(0.259, 0.19), cp(0.265, 0.208),
                cp(0.271, 0.226), cp(0.276, 0.244), cp(0.282, 0.262), cp(0.288, 0.28), cp(0.293, 0.298), cp(0.299, 0.316),
                cp(0.305, 0.334), cp(0.31, 0.352), cp(0.316, 0.369), cp(0.321, 0.387), cp(0.327, 0.405), cp(0.333, 0.423),
                cp(0.338, 0.441), cp(0.344, 0.459), cp(0.35, 0.477), cp(0.355, 0.495), cp(0.361, 0.513), cp(0.367, 0.531),
                cp(0.372, 0.548), cp(0.378, 0.566), cp(0.383, 0.584), cp(0.389, 0.602), cp(0.394, 0.62), cp(0.4, 0.638),
                cp(0.405, 0.656), cp(0.411, 0.674), cp(0.416, 0.692), cp(0.422, 0.71), cp(0.428, 0.728), cp(0.433, 0.746),
                cp(0.438, 0.764), cp(0.444, 0.782), cp(0.449, 0.8), cp(0.455, 0.818), cp(0.46, 0.836), cp(0.466, 0.853),
                cp(0.472, 0.871), cp(0.477, 0.889), cp(0.484, 0.907), cp(0.498, 0.906), cp(0.506, 0.889), cp(0.514, 0.872),
                cp(0.522, 0.855), cp(0.531, 0.838), cp(0.539, 0.821), cp(0.548, 0.805), cp(0.556, 0.788), cp(0.564, 0.771),
                cp(0.572, 0.754), cp(0.579, 0.736), cp(0.587, 0.719), cp(0.595, 0.702), cp(0.602, 0.685), cp(0.61, 0.668),
                cp(0.618, 0.651), cp(0.625, 0.634), cp(0.633, 0.617), cp(0.641, 0.599), cp(0.648, 0.582), cp(0.656, 0.565),
                cp(0.664, 0.548), cp(0.672, 0.531), cp(0.679, 0.514), cp(0.687, 0.497), cp(0.695, 0.48), cp(0.703, 0.463),
                cp(0.711, 0.446), cp(0.719, 0.429), cp(0.727, 0.412), cp(0.735, 0.395), cp(0.743, 0.378), cp(0.751, 0.361),
                cp(0.759, 0.344), cp(0.766, 0.327), cp(0.774, 0.309), cp(0.781, 0.292), cp(0.788, 0.275), cp(0.796, 0.258),
                cp(0.803, 0.24), cp(0.811, 0.223), cp(0.818, 0.206), cp(0.826, 0.189), cp(0.833, 0.172), cp(0.841, 0.154),
                cp(0.849, 0.137), cp(0.857, 0.12), cp(0.865, 0.104), cp(0.874, 0.087), cp(0.884, 0.071), cp(0.894, 0.055),
                cp(0.905, 0.04), cp(0.916, 0.051), cp(0.919, 0.069), cp(0.921, 0.088), cp(0.922, 0.107), cp(0.924, 0.125),
                cp(0.925, 0.144), cp(0.926, 0.163), cp(0.927, 0.182), cp(0.928, 0.2), cp(0.928, 0.219), cp(0.929, 0.238),
                cp(0.929, 0.257), cp(0.93, 0.276), cp(0.93, 0.294), cp(0.93, 0.313), cp(0.931, 0.332), cp(0.931, 0.351),
                cp(0.932, 0.369), cp(0.932, 0.388), cp(0.933, 0.407), cp(0.933, 0.426), cp(0.934, 0.444), cp(0.934, 0.463),
                cp(0.935, 0.482), cp(0.936, 0.501), cp(0.936, 0.519), cp(0.937, 0.538), cp(0.937, 0.557), cp(0.938, 0.576),
                cp(0.938, 0.595), cp(0.939, 0.613), cp(0.939, 0.632), cp(0.94, 0.651), cp(0.94, 0.67), cp(0.941, 0.688),
                cp(0.942, 0.707), cp(0.942, 0.726), cp(0.943, 0.745), cp(0.943, 0.763), cp(0.944, 0.782), cp(0.945, 0.801),
                cp(0.945, 0.82), cp(0.946, 0.838), cp(0.946, 0.857), cp(0.947, 0.876), cp(0.948, 0.895), cp(0.948, 0.914),
                cp(0.949, 0.932), cp(0.949, 0.951),
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
