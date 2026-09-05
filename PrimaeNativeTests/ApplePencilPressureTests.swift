import Testing
import CoreGraphics
@testable import PrimaeNative

@Suite @MainActor struct ApplePencilPressureTests {

    let vm: TracingViewModel
    init() { vm = makeTestVM() }

    @Test func p1_pencilPressureDefaultsToNil() {
        #expect(vm.pencilPressure == nil)
    }

    @Test func p2_pencilAzimuthDefaultsToZero() {
        #expect(abs(vm.pencilAzimuth - 0) < 0.001)
    }

    @Test func p3_endTouchResetsPressureToNil() {
        vm.pencilPressure = 0.8
        vm.pencilAzimuth = 1.0
        vm.endTouch()
        #expect(vm.pencilPressure == nil)
    }

    @Test func p4_endTouchResetsAzimuthToZero() {
        vm.pencilAzimuth = 1.5
        vm.endTouch()
        #expect(abs(vm.pencilAzimuth - 0) < 0.001)
    }

    // p5–p9 (ink width at 0 / full pressure / finger, azimuth bias at 0 / π)
    // were removed on 2026-09-04: they asserted arithmetic written in the
    // test file (`4 + pressure * 10`, `cos(a) * 0.5`) that the renderer and
    // the touch dispatcher do not use (`InkStyle.width`: 8 + 14·p, finger 14;
    // azimuth bias: cos(a) · 0.2), so they could not fail. The ink-width
    // formula is pinned in AuditThirdPassTests.inkWidthFormula.

    @Test func p10_pencilPressureIsSettable() {
        vm.pencilPressure = 0.65
        #expect(abs((vm.pencilPressure.map(Double.init) ?? 0) - 0.65) < 0.001)
    }
}
