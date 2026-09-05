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
        // Positive control: the same stroke advances the tracker BEFORE the reset.
        var t: CFTimeInterval = 1000
        inkStroke(vm, from: 0, y: 200, count: 10, t: &t)
        vm.endTouch()
        #expect(vm.progress > 0, "precondition: this stroke hits the fixture's checkpoints; got \(vm.progress)")
        vm.loadLetter(name: vm.currentLetterName)
        vm.phaseController.resume(at: .guided)
        _ = vm.resetForNewParticipant()
        #expect(vm.sessionBlockReason != nil, "the arms in memory are the previous child's")
        t += 1
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

    // MARK: - Review 2026-09-05: linkage of the freeWrite row to its trace

    @Test("a scored production accepts no more ink while the recognizer runs")
    func scoredProductionRefusesInk() async {
        let store = ThirdPassRecordingStore()
        let traces = StubRawTraceStore()
        let vm = studyVM(store: store)
        vm.canvasSize = canvas
        vm.phaseController.resume(at: .freeWrite)
        var t: CFTimeInterval = 1000
        inkStroke(vm, from: 50, y: 200, count: 15, t: &t)
        vm.endTouch()
        let inkBefore = vm.freeWritePoints.count
        vm.advanceLearningPhase()   // what the quiet window calls: latches the measures, starts the recognizer
        #expect(vm.didCompleteCurrentLetter, "the production is closed the moment it is scored")
        t += 0.5
        inkStroke(vm, from: 50, y: 300, count: 5, t: &t)   // the child touches again during the await
        vm.endTouch()
        #expect(vm.freeWritePoints.count == inkBefore,
                "no ink may enter the buffer the later capture reads; got \(vm.freeWritePoints.count) vs \(inkBefore)")
        _ = traces
    }

    @Test("a pencil move or lift during a finger session is ignored, and vice versa")
    func touchSessionIsPinnedToItsDevice() {
        let vm = studyVM()
        vm.canvasSize = canvas
        vm.phaseController.resume(at: .freeWrite)
        var t: CFTimeInterval = 1000
        vm.fingerDidTouchDown()
        vm.beginTouch(at: CGPoint(x: 50, y: 200), t: t)
        t += 0.01; vm.updateTouch(at: CGPoint(x: 60, y: 200), t: t, canvasSize: canvas)
        let before = vm.freeWritePoints.count
        // A Pencil move arrives (the pencil overlay stamps pressure first).
        vm.pencilPressure = 0.6
        t += 0.01; vm.updateTouch(at: CGPoint(x: 300, y: 50), t: t, canvasSize: canvas)
        #expect(vm.freeWritePoints.count == before, "the pencil's point must not join the finger's stroke")
        #expect(vm.pencilPressure == nil, "the stray pencil stamp is cleared")
        // The Pencil lifts: the finger's session must survive it.
        vm.endTouch(fromPencil: true)
        t += 0.01; vm.updateTouch(at: CGPoint(x: 70, y: 200), t: t, canvasSize: canvas)
        #expect(vm.freeWritePoints.count == before + 1, "the finger is still drawing after the pencil lifted")
        vm.endTouch(fromPencil: false)
        #expect(vm.freeWriteStrokeStartIndices.isEmpty, "one stroke, no boundary from the ignored events")
    }

    @Test("a one-sample contact is not a finished production")
    func singleSampleContactDoesNotComplete() async {
        let store = ThirdPassRecordingStore()
        let vm = studyVM(store: store)
        vm.canvasSize = canvas
        vm.phaseController.resume(at: .freeWrite)
        vm.beginTouch(at: CGPoint(x: 50, y: 200), t: 1000)   // a palm: one sample, no movement
        vm.endTouch()
        #expect(vm.freeWritePoints.count == 1)
        try? await Task.sleep(for: .seconds(2.5))   // past the quiet window
        #expect(store.phaseCalls.isEmpty, "a palm contact must not produce a completed freeWrite row")
        // The unload/background path agrees.
        vm.loadLetter(name: vm.currentLetterName)
        #expect(!store.phaseCalls.contains { $0.phase == LearningPhase.freeWrite.rawName && $0.completed },
                "still not a completed production on unload")
    }

    @Test("a participant reset closes the outgoing trial: nothing of it is written under the new id")
    func resetClosesTheOutgoingTrial() {
        let store = ThirdPassRecordingStore()
        let vm = studyVM(store: store)
        vm.canvasSize = canvas
        vm.phaseController.resume(at: .freeWrite)
        var t: CFTimeInterval = 1000
        inkStroke(vm, from: 50, y: 200, count: 15, t: &t)
        vm.endTouch()   // ink on the canvas, quiet window pending
        let prevID = ParticipantStore.participantId
        defer { UserDefaults.standard.set(prevID.uuidString, forKey: "de.flamingistan.primae.participantId") }
        _ = vm.resetForNewParticipant()
        #expect(vm.freeWritePoints.isEmpty, "the outgoing child's ink is discarded")
        vm.loadLetter(name: vm.currentLetterName)   // what the next probe/letter would do
        #expect(store.phaseCalls.isEmpty, "no row may be written for the outgoing child after the reset: \(store.phaseCalls.count)")
    }

    @Test("a blocked session refuses cold probes too")
    func blockedSessionRefusesProbes() {
        let vm = studyVM()
        vm.canvasSize = canvas
        let prevID = ParticipantStore.participantId
        defer { UserDefaults.standard.set(prevID.uuidString, forKey: "de.flamingistan.primae.participantId") }
        _ = vm.resetForNewParticipant()
        let phaseBefore = vm.learningPhase
        vm.startColdProbe(letter: "A", kind: .pretest)
        #expect(vm.currentProbe == nil && vm.learningPhase == phaseBefore,
                "a probe must not start while the arms in memory are stale")
    }

    @Test("schedulerPriority belongs to the scheduler's pick, not to the next letter loaded by hand")
    func schedulerPriorityDoesNotLeak() {
        var deps = TracingDependencies.stub
        deps.studyMode = false
        let vm = TracingViewModel(deps)
        vm.canvasSize = canvas
        vm.lastScheduledLetterPriority = 0.7   // as loadRecommendedLetter would leave it
        vm.loadLetter(name: vm.currentLetterName)
        #expect(vm.lastScheduledLetterPriority == 0, "a hand-loaded letter carries no scheduler priority")
    }

    @Test("two stroke boundaries at one index collapse to one")
    func duplicateStrokeBoundaryIsDropped() {
        let r = FreeWritePhaseRecorder()
        r.startSession(now: 100)
        r.record(point: CGPoint(x: 1, y: 1), timestamp: 100, force: 0, canvasSize: canvas)
        r.beginStroke(); r.beginStroke()
        #expect(r.strokeStartIndices == [1], "got \(r.strokeStartIndices)")
    }

    // MARK: - Review 2026-09-05: duration rows

    @Test("duration rows carry the arm, the study flag and the probe, and are filtered on enrolment like the phase rows")
    func durationRowsAreStampedAndFiltered() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dur-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = JSONParentDashboardStore(fileURL: tmp)
        let enrolled = Date(timeIntervalSince1970: 1_770_000_000)
        store.recordSession(letter: "A", accuracy: 0.5, durationSeconds: 30, wallClockSeconds: 31,
                            date: enrolled.addingTimeInterval(-3600), condition: .threePhase, inputDevice: "finger",
                            audioCondition: .spatial, studyMode: true, probe: nil)          // before enrolment
        store.recordSession(letter: "A", accuracy: 0.5, durationSeconds: 40, wallClockSeconds: 41,
                            date: enrolled.addingTimeInterval(60), condition: .threePhase, inputDevice: "pencil",
                            audioCondition: .phoneme, studyMode: true, probe: "delayed")   // after
        let last = try #require(store.snapshot.sessionDurations.last)
        #expect(last.audioCondition == .phoneme && last.studyMode == true && last.probe == "delayed")
        let csv = String(data: ParentDashboardExporter.csvData(from: store.snapshot, progress: [:], enrolledAt: enrolled), encoding: .utf8)!
        let lines = csv.components(separatedBy: "\n")
        let header = try #require(lines.first { $0.hasPrefix("date,recordedAt,durationSeconds") })
        #expect(header.hasSuffix(",letter,audioCondition,studyMode,probe"), "\(header)")
        let rows = lines.filter { $0.hasPrefix("20") && $0.contains(",threePhase,") && $0.contains(",A,") }
        #expect(rows.count == 1, "the pre-enrolment duration must be filtered out: \(rows)")
        #expect(rows.first?.hasSuffix(",pencil,A,phoneme,true,delayed") == true, "\(String(describing: rows.first))")
    }

    // MARK: - Class two (2026-09-05): the model has no umlaut class

    @Test("a predicted base letter counts as correct for its umlaut, case-insensitively; a different letter does not")
    func recogniserMatchFoldsDiacritics() {
        #expect(LetterMatch.matches(predicted: "A", expected: "Ä"))
        #expect(LetterMatch.matches(predicted: "o", expected: "Ö"))
        #expect(LetterMatch.matches(predicted: "u", expected: "ü"))
        #expect(LetterMatch.matches(predicted: "a", expected: "A"))
        #expect(LetterMatch.matches(predicted: "ß", expected: "ß"))
        #expect(!LetterMatch.matches(predicted: "B", expected: "A"))
        #expect(!LetterMatch.matches(predicted: "s", expected: "ß"), "ß is its own class")
    }

    @Test("an unenrolled study device refuses to start a session")
    func unenrolledStudyDeviceRefuses() {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        deps.participantEnrolled = false
        let vm = TracingViewModel(deps)
        #expect(vm.studyPreconditionFailure?.contains("Neuer Teilnehmer") == true,
                "the arms are un-randomised defaults until enrolment: \(String(describing: vm.studyPreconditionFailure))")
        deps.participantEnrolled = true
        #expect(TracingViewModel(deps).studyPreconditionFailure == nil)
    }

}
