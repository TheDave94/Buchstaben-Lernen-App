// Third-pass audit (2026-09-04/05): regression pins for the class one/two
// defects found in the Tracing surface and the participant handling.
// Each test names the defect it would have caught.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

fileprivate final class ThirdPassRecordingStore: ParentDashboardStoring {
    var snapshot: DashboardSnapshot { DashboardSnapshot() }
    private(set) var sessionCalls: [(letter: String, duration: TimeInterval)] = []
    private(set) var phaseCalls: [(letter: String, phase: String, completed: Bool, score: Double,
                                   trainedSubset: String?, phaseDurationSeconds: Double?,
                                   spatialDeviation: Double?, rawTraceID: UUID?, studyMode: Bool?, probe: String?)] = []
    func recordSession(letter: String, accuracy: Double,
                       durationSeconds: TimeInterval,
                       wallClockSeconds: TimeInterval?,
                       date: Date, condition: ThesisCondition,
                       inputDevice: String?) {
        sessionCalls.append((letter, durationSeconds))
    }
    func recordPhaseSession(letter: String, phase: String, completed: Bool, score: Double, schedulerPriority: Double, condition: ThesisCondition, audioCondition: PilotAudioCondition, assessment: WritingAssessment?, recognition: RecognitionSample?, inputDevice: String?, rawTraceID: UUID?, trainedSubset: String?, phaseDurationSeconds: Double?, frechetDistance: Double?, checkpointCoverage: Double?, spatialDeviation: Double?, strokeCount: Int?, strokeOrder: String?, reversedStrokeCount: Int?, studyMode: Bool?, probe: String?) {
        phaseCalls.append((letter, phase, completed, score, trainedSubset, phaseDurationSeconds,
                           spatialDeviation, rawTraceID, studyMode, probe))
    }
    func reset() {}
}

@Suite(.serialized) @MainActor struct AuditThirdPassTests {

    private let canvas = CGSize(width: 400, height: 400)

    private func studyVM(store: ThirdPassRecordingStore? = nil) -> TracingViewModel {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        if let store { deps.dashboardStore = store }
        return TracingViewModel(deps)
    }

    private func inkStroke(_ vm: TracingViewModel, from x0: CGFloat, y: CGFloat, count: Int, t: inout CFTimeInterval) {
        vm.beginTouch(at: CGPoint(x: x0, y: y), t: t)
        var p = CGPoint(x: x0, y: y)
        for _ in 0..<count { t += 0.01; p.x += 10; vm.updateTouch(at: p, t: t, canvasSize: canvas) }
    }

    // MARK: - Observe phase (T1 / T2)

    @Test("the FIRST letter of a session leaves observe after two animation cycles without a tap")
    func firstLetterObserveAutoAdvances() {
        let vm = studyVM()
        vm.canvasSize = canvas
        #expect(vm.learningPhase == .observe, "precondition: a study session starts in observe")
        #expect(vm.animation.onCycleComplete != nil,
                "load(letter:) must install the auto-advance — it used to leave it nil on the first letter, and studyMode makes the tap inert")
        vm.animation.onCycleComplete?()
        #expect(vm.learningPhase == .observe, "one cycle is not enough")
        vm.animation.onCycleComplete?()
        #expect(vm.learningPhase != .observe, "two cycles must end observe; got \(vm.learningPhase)")
    }

    @Test("guided-phase animation loops do not pre-count toward the next letter's observe exit")
    func observeCycleCountResetsPerLetter() {
        let vm = studyVM()
        vm.canvasSize = canvas
        vm.phaseController.resume(at: .guided)
        // The same animator runs during guided; its cycles used to
        // accumulate, so the NEXT observe exited after one cycle.
        for _ in 0..<3 { vm.animation.onCycleComplete?() }
        vm.loadLetter(name: vm.currentLetterName)
        #expect(vm.learningPhase == .observe, "precondition: reload starts in observe")
        vm.animation.onCycleComplete?()
        #expect(vm.learningPhase == .observe, "the first cycle of a fresh observe must not exit it")
        vm.animation.onCycleComplete?()
        #expect(vm.learningPhase != .observe)
    }

    // MARK: - FreeWrite recording (T9 / T3)

    @Test("the pen-down sample is the first point of every freeWrite stroke")
    func penDownSampleIsRecorded() {
        let vm = studyVM()
        vm.canvasSize = canvas
        vm.phaseController.resume(at: .freeWrite)
        var t: CFTimeInterval = 1000
        vm.beginTouch(at: CGPoint(x: 50, y: 200), t: t)
        #expect(vm.freeWritePoints.count == 1, "pen-down must be recorded before any movement")
        #expect(vm.freeWritePoints.first == CGPoint(x: 50, y: 200))
        #expect(vm.freeWriteTimestamps.first == t)
        for _ in 0..<5 { t += 0.01; vm.updateTouch(at: CGPoint(x: 50 + CGFloat(vm.freeWritePoints.count) * 10, y: 200), t: t, canvasSize: canvas) }
        vm.endTouch()
        #expect(vm.freeWritePoints.count == 6)
        // Second stroke: its boundary sits exactly at the first stroke's length.
        t += 0.5
        vm.beginTouch(at: CGPoint(x: 50, y: 300), t: t)
        #expect(vm.freeWriteStrokeStartIndices == [6], "got \(vm.freeWriteStrokeStartIndices)")
        #expect(vm.freeWritePoints.count == 7)
        vm.endTouch()
    }

    @Test("an out-of-bounds excursion in freeWrite ends the stroke, keeps what was drawn, and gives no retry cue")
    func freeWriteExcursionSplitsStroke() {
        let vm = studyVM()
        vm.canvasSize = canvas
        vm.phaseController.resume(at: .freeWrite)
        var t: CFTimeInterval = 1000
        inkStroke(vm, from: 50, y: 200, count: 5, t: &t)
        let before = vm.freeWritePoints.count
        #expect(before == 6)
        t += 0.01; vm.updateTouch(at: CGPoint(x: -20, y: 200), t: t, canvasSize: canvas)   // leaves the canvas
        #expect(vm.freeWritePoints.count == before, "nothing is recorded outside the canvas, and nothing is erased")
        #expect(vm.toastMessage == nil, "free production gives no retry cue")
        t += 0.01; vm.updateTouch(at: CGPoint(x: 30, y: 210), t: t, canvasSize: canvas)    // re-enters
        t += 0.01; vm.updateTouch(at: CGPoint(x: 45, y: 215), t: t, canvasSize: canvas)
        #expect(vm.freeWriteStrokeStartIndices == [before],
                "the re-entry must start a new stroke, not fuse with the aborted one: \(vm.freeWriteStrokeStartIndices)")
        #expect(vm.freeWritePoints.count == before + 2)
        vm.endTouch()
    }

    // MARK: - Backgrounding with the finger down (T10)

    @Test("backgrounding mid-stroke records the finished production instead of leaving it to a task that may never run")
    func backgroundWithFingerDownRecordsTheTrial() async {
        let store = ThirdPassRecordingStore()
        let vm = studyVM(store: store)
        vm.canvasSize = canvas
        vm.phaseController.resume(at: .freeWrite)
        var t: CFTimeInterval = 1000
        inkStroke(vm, from: 50, y: 200, count: 15, t: &t)   // finger still down
        await vm.appDidEnterBackground()
        let fw = store.phaseCalls.first { $0.phase == LearningPhase.freeWrite.rawName }
        #expect(fw != nil, "the production must be recorded before the app is suspended")
        #expect(fw?.completed == true)
        #expect(fw?.spatialDeviation != nil, "and scored")
    }

    // MARK: - Participant identity (V1 / V2)

    @Test("after a participant reset the VM refuses to trace until relaunch")
    func resetBlocksTracingUntilRelaunch() {
        let vm = studyVM()
        vm.canvasSize = canvas
        vm.phaseController.resume(at: .guided)
        #expect(vm.sessionBlockReason == nil, "precondition: the fixture can trace")
        let prevID = ParticipantStore.participantId
        defer { UserDefaults.standard.set(prevID.uuidString, forKey: "de.flamingistan.primae.participantId") }
        _ = vm.resetForNewParticipant()
        #expect(vm.sessionBlockReason != nil, "the arms in memory are the previous child's")
        var t: CFTimeInterval = 1000
        inkStroke(vm, from: 0, y: 200, count: 10, t: &t)
        #expect(vm.progress == 0, "no trace may be accepted under the old arms; got \(vm.progress)")
    }

    @Test("restoring the id this device already carries keeps the original enrolment instant")
    func restoreSameParticipantKeepsEnrolledAt() {
        let prevID = ParticipantStore.participantId
        let prevEnrolled = ParticipantStore.isEnrolled
        let prevStamp = UserDefaults.standard.object(forKey: "de.flamingistan.primae.thesisEnrolledAt")
        defer {
            UserDefaults.standard.set(prevID.uuidString, forKey: "de.flamingistan.primae.participantId")
            ParticipantStore.isEnrolled = prevEnrolled
            UserDefaults.standard.set(prevStamp, forKey: "de.flamingistan.primae.thesisEnrolledAt")
        }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: "de.flamingistan.primae.participantId")
        let original = Date(timeIntervalSince1970: 1_700_000_000)
        UserDefaults.standard.set(original, forKey: "de.flamingistan.primae.thesisEnrolledAt")
        _ = ParticipantStore.restoreParticipant(uuidString: id.uuidString)
        #expect(ParticipantStore.enrolledAt == original,
                "same child, same device: existing rows must stay inside the export window")
        // A DIFFERENT id re-stamps, so another child's rows stay out.
        _ = ParticipantStore.restoreParticipant(uuidString: UUID().uuidString)
        #expect((ParticipantStore.enrolledAt ?? .distantPast) > original)
    }

    // MARK: - Export filename (V3)

    @Test("two exports on one day for two participants do not collide")
    func exportFilenamesAreUniquePerParticipant() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let prevID = ParticipantStore.participantId
        defer { UserDefaults.standard.set(prevID.uuidString, forKey: "de.flamingistan.primae.participantId") }
        let a = try ParentDashboardExporter.exportFileURL(from: DashboardSnapshot(), format: .csv, tempDirectory: tmp)
        UserDefaults.standard.set(UUID().uuidString, forKey: "de.flamingistan.primae.participantId")
        let b = try ParentDashboardExporter.exportFileURL(from: DashboardSnapshot(), format: .csv, tempDirectory: tmp)
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        #expect(a.lastPathComponent != b.lastPathComponent, "\(a.lastPathComponent) vs \(b.lastPathComponent)")
        #expect(a.lastPathComponent.contains(String(prevID.uuidString.prefix(8))))
    }

    // MARK: - Ink width against the renderer's formula (V8)

    @Test("live ink width follows the renderer's pressure formula")
    func inkWidthFormula() {
        #expect(InkStyle.width(forPressure: nil) == 14, "finger")
        #expect(InkStyle.width(forPressure: 0) == 8, "pencil, no pressure")
        #expect(InkStyle.width(forPressure: 1) == 22, "pencil, full pressure")
    }

    // MARK: - Retrieval prompt cannot fire in a study session (C1-3, 2026-09-05)

    @Test("the spaced-retrieval prompt is unreachable in a study session even when the parent toggle is on")
    func retrievalPromptUnreachableUnderStudy() {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        deps.enableRetrievalPrompts = true
        let vm = TracingViewModel(deps)
        vm.canvasSize = canvas
        #expect(vm.enableRetrievalPrompts, "precondition: the toggle is on")
        vm.loadRecommendedLetter()   // the only enqueue site sits behind the studyMode early return
        var sawPrompt = false
        if case .retrievalPrompt = vm.overlayQueue.currentOverlay { sawPrompt = true }
        #expect(!sawPrompt && vm.overlayQueue.pendingCount == 0,
                "no retrieval prompt may be queued in a study session; current=\(String(describing: vm.overlayQueue.currentOverlay)) pending=\(vm.overlayQueue.pendingCount)")
    }

    // MARK: - Spatial arm precondition (C1-6, 2026-09-05)

    @Test("the spatial carrier resolves in the bundle and the spatial arm passes the session precondition")
    func spatialCarrierIsASessionPrecondition() {
        #expect(SpatialSonification.carrierToneURL() != nil,
                "the carrier must resolve by the engine's own lookups: \(SpatialSonification.carrierToneFile)")
        var deps = TracingDependencies.stub
        deps.studyMode = true
        deps.audioCondition = .spatial
        let vm = TracingViewModel(deps)
        #expect(vm.studyPreconditionFailure == nil, "\(String(describing: vm.studyPreconditionFailure))")
    }

}
