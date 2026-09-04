// Pins the 2026-09-04 fix: `TracingViewModel.isCalibrating` must be
// compile-time FALSE on a study build, not just runtime-false-by-
// default. `StrokeCalibrationOverlay` (the view this flag gates) is
// itself `#if !STUDY_BUILD`-gated out of the study binary, but
// `isCalibrating` used to be read UNCONDITIONALLY throughout
// TracingCanvasView.swift to suppress ghost lines / checkpoints /
// hit-testing — reachable via the "Striche kalibrieren" Settings
// toggle even on a study device, degrading the child-facing canvas
// with no calibration UI ever appearing to undo it (the overlay never
// renders there). Written per-branch, same idiom as StudyBuildTests,
// so a flag that silently stopped arriving fails the suite instead of
// agreeing with itself.

import Testing
@testable import PrimaeNative

@MainActor
@Suite struct IsCalibratingStudyBuildTests {

    @Test("isCalibrating ignores showDebug/showCalibration entirely on a study build")
    func isCalibrating_studyBuildGate() {
        let vm = TracingViewModel(.stub)
        vm.showDebug = true
        vm.showCalibration = true

        #if STUDY_BUILD
        #expect(!vm.isCalibrating,
                "a study build must never enter calibration mode, however the toggles are set")
        #else
        #expect(vm.isCalibrating,
                "a non-study build must still honour the debug + calibration toggles")
        #endif
    }
}
