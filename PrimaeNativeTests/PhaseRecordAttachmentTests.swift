// Coordinator-level coverage for which measurement fields land on which
// phase row.
//
// Audit finding 19: `PhaseTransitionCoordinator.recordSessionCompletion`
// discards the `LearningPhase` type into `[String: Double]` and then
// re-derives it with eight `phase == "freeWrite"` string comparisons to
// decide which of six fields to attach. Nothing tested that decision.
// `MeasurementLayerTests` builds a `PhaseSessionRecord` directly and
// tests the *exporter*; every other `recordPhaseSession` reference in
// the suite is a direct store call or a no-op stub. So a coordinator
// that attached `frechetDistance` to the guided row — or dropped it
// from the freeWrite row — shipped green.
//
// This suite drives the real path from the VM's public entry:
//   advanceLearningPhase() → advance() → assess → runRecognizerForFreeWrite
//     → completePostFreeWriteRecognition → celebrateFreeWrite
//     → recordSessionCompletion → recordPhaseSession × phases
// and captures every argument of every `recordPhaseSession` call.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

// MARK: - Capturing store

/// Captures the full argument list of every `recordPhaseSession` call.
/// `StubDashboardStore` discards them and `StudyCleanConfigTests`'
/// recorder keeps only four — neither can see field attachment.
@MainActor
private final class CapturingDashboardStore: ParentDashboardStoring {
    struct Call {
        let letter: String
        let phase: String
        let completed: Bool
        let score: Double
        let condition: ThesisCondition
        let audioCondition: PilotAudioCondition
        let trainedSubset: String?
        // The six freeWrite-only measurement fields.
        let assessment: WritingAssessment?
        let recognition: RecognitionSample?
        let rawTraceID: UUID?
        let phaseDurationSeconds: Double?
        let frechetDistance: Double?
        let checkpointCoverage: Double?

        /// How many of the six are populated. 6 on freeWrite, 0 elsewhere.
        var measurementFieldCount: Int {
            [assessment != nil, recognition != nil, rawTraceID != nil,
             phaseDurationSeconds != nil, frechetDistance != nil,
             checkpointCoverage != nil].filter { $0 }.count
        }

        /// Names of the populated fields — makes a failure say *which*
        /// field moved, not merely that a count was wrong.
        var populatedFields: Set<String> {
            var out: Set<String> = []
            if assessment != nil { out.insert("assessment") }
            if recognition != nil { out.insert("recognition") }
            if rawTraceID != nil { out.insert("rawTraceID") }
            if phaseDurationSeconds != nil { out.insert("phaseDurationSeconds") }
            if frechetDistance != nil { out.insert("frechetDistance") }
            if checkpointCoverage != nil { out.insert("checkpointCoverage") }
            return out
        }
    }

    private(set) var calls: [Call] = []
    var snapshot: DashboardSnapshot { DashboardSnapshot() }

    func recordSession(letter: String, accuracy: Double,
                       durationSeconds: TimeInterval,
                       wallClockSeconds: TimeInterval?,
                       date: Date, condition: ThesisCondition,
                       inputDevice: String?) {}

    func recordPhaseSession(letter: String, phase: String, completed: Bool,
                            score: Double, schedulerPriority: Double,
                            condition: ThesisCondition,
                            audioCondition: PilotAudioCondition,
                            assessment: WritingAssessment?,
                            recognition: RecognitionSample?,
                            inputDevice: String?,
                            rawTraceID: UUID?,
                            trainedSubset: String?,
                            phaseDurationSeconds: Double?,
                            frechetDistance: Double?,
                            checkpointCoverage: Double?) {
        calls.append(Call(letter: letter, phase: phase, completed: completed,
                          score: score, condition: condition,
                          audioCondition: audioCondition,
                          trainedSubset: trainedSubset,
                          assessment: assessment, recognition: recognition,
                          rawTraceID: rawTraceID,
                          phaseDurationSeconds: phaseDurationSeconds,
                          frechetDistance: frechetDistance,
                          checkpointCoverage: checkpointCoverage))
    }

    func reset() {}
}

// MARK: - Suite

@Suite @MainActor struct PhaseRecordAttachmentTests {

    /// A completed four-phase session, captured at the store seam.
    private struct Session {
        let calls: [CapturingDashboardStore.Call]
        let traces: [RawTrace]
    }

    /// Drives one full letter session to completion and returns every
    /// `recordPhaseSession` call it produced.
    ///
    /// `.threePhase` is required: the shared `.stub` fixture pins
    /// `.guidedOnly`, whose controller starts at `.guided` and completes
    /// without ever entering freeWrite — the phase under test.
    private func runSession() async throws -> Session {
        let store = CapturingDashboardStore()
        let traceStore = StubRawTraceStore()
        var deps = TracingDependencies.stub
        deps.thesisCondition = .threePhase
        deps.dashboardStore = store
        deps.rawTraceStore = traceStore
        // Predicted letter must match the fixture letter: the stub
        // asserts (DEBUG) that `isCorrect` agrees with predicted-vs-expected.
        // isCorrect + high confidence also routes to celebrate, not retry.
        deps.letterRecognizer = StubLetterRecognizer.alwaysReturn(
            predicted: "A", confidence: 0.9, isCorrect: true)

        let vm = TracingViewModel(deps)
        vm.canvasSize = CGSize(width: 400, height: 400)

        // Fixture precondition, asserted rather than assumed: without a
        // stroke definition `advance()` takes its bail-out branch, calls
        // `clearAll()`, and wipes the very buffer these fields come from.
        // A silent fixture failure would then look like a logic failure.
        try #require(vm.strokeTracker.definition != nil,
                     "fixture letter has no stroke definition — the freeWrite branch would bail out and clear the recorder")

        // Walk observe → direct → guided, leaving currentPhase == .freeWrite
        // with three scores banked, so the completion emits four rows.
        vm.phaseController.advance(score: 1.0)   // observe
        vm.phaseController.advance(score: 1.0)   // direct
        vm.phaseController.advance(score: 0.8)   // guided
        #expect(vm.phaseController.currentPhase == .freeWrite)

        // A traced horizontal stroke along the fixture's reference
        // (y = 0.50 normalised → y = 200 on a 400×400 canvas). Real
        // samples are needed: they are what make rawTraceID,
        // phaseDurationSeconds and frechetDistance non-nil.
        vm.freeWriteRecorder.startSession(now: 100.0)
        for i in 0...18 {
            vm.freeWriteRecorder.record(
                point: CGPoint(x: 20 + Double(i) * 20, y: 200),
                timestamp: 100.0 + Double(i) * 0.1,
                force: 0.5,
                canvasSize: vm.canvasSize)
        }

        // Public entry. From here the coordinator runs unaided.
        vm.advanceLearningPhase()

        // The recogniser hop is a Task; wait on the observable outcome
        // rather than a fixed sleep. Bounded so a hang fails the test
        // instead of stalling the suite.
        for _ in 0..<100 where store.calls.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        try #require(!store.calls.isEmpty,
                     "no recordPhaseSession call within 500 ms — the completion pipeline never ran")

        return Session(calls: store.calls, traces: traceStore.traces)
    }

    private func row(_ phase: LearningPhase,
                     in calls: [CapturingDashboardStore.Call]) throws
        -> CapturingDashboardStore.Call {
        try #require(calls.first(where: { $0.phase == phase.rawName }),
                     "no row emitted for phase '\(phase.rawName)' — got \(calls.map(\.phase).sorted())")
    }

    // MARK: - 1. One row per scored phase

    @Test("a completed four-phase session emits exactly one row per phase")
    func emitsOneRowPerScoredPhase() async throws {
        let s = try await runSession()

        #expect(s.calls.count == 4,
                "expected 4 phase rows, got \(s.calls.count): \(s.calls.map(\.phase))")

        // Keys must be LearningPhase.rawName values, not ad-hoc strings.
        let phases = Set(s.calls.map(\.phase))
        #expect(phases == Set(LearningPhase.allCases.map(\.rawName)),
                "phase keys drifted from LearningPhase.rawName: \(phases.sorted())")

        for call in s.calls {
            #expect(call.letter == "A")
            #expect(call.completed, "\(call.phase) row should be marked completed")
            #expect((0...1).contains(call.score), "\(call.phase) score out of domain")
        }
    }

    // MARK: - 2. freeWrite carries all six

    @Test("the freeWrite row carries all six measurement fields")
    func freeWriteRowCarriesAllSixMeasurementFields() async throws {
        let s = try await runSession()
        let fw = try row(.freeWrite, in: s.calls)

        // Named individually so a failure identifies the field that
        // detached, not just that the total is wrong.
        #expect(fw.assessment != nil, "assessment missing from freeWrite row")
        #expect(fw.recognition != nil, "recognition missing from freeWrite row")
        #expect(fw.rawTraceID != nil, "rawTraceID missing from freeWrite row")
        #expect(fw.phaseDurationSeconds != nil, "phaseDurationSeconds missing from freeWrite row")
        #expect(fw.frechetDistance != nil, "frechetDistance missing — the PRIMARY outcome")
        #expect(fw.checkpointCoverage != nil, "checkpointCoverage missing — the SECONDARY outcome")

        #expect(fw.measurementFieldCount == 6,
                "freeWrite row carries \(fw.measurementFieldCount)/6: \(fw.populatedFields.sorted())")

        // Well-formed, not merely present.
        let span = try #require(fw.phaseDurationSeconds)
        #expect(span > 0, "measured span must be positive, got \(span)")
        #expect(abs(span - 1.8) < 0.001, "19 samples at 0.1 s → 1.8 s, got \(span)")

        let frechet = try #require(fw.frechetDistance)
        #expect(frechet.isFinite, "frechetDistance must be finite, got \(frechet)")
        #expect(frechet >= 0, "frechetDistance is a distance, got \(frechet)")

        let coverage = try #require(fw.checkpointCoverage)
        #expect((0...1).contains(coverage), "coverage out of domain: \(coverage)")

        let rec = try #require(fw.recognition)
        #expect(rec.predictedLetter == "A")
        #expect(rec.isCorrect)
    }

    // MARK: - 3. Every other phase carries none

    @Test("observe, direct and guided rows carry no measurement fields")
    func nonFreeWriteRowsCarryNoMeasurementFields() async throws {
        let s = try await runSession()

        for phase in [LearningPhase.observe, .direct, .guided] {
            let call = try row(phase, in: s.calls)
            #expect(call.measurementFieldCount == 0,
                    "\(phase.rawName) row must carry no measurement fields, but carries: \(call.populatedFields.sorted())")

            // Spelled out so a single migrated field names itself. A 0.0
            // here would read as a perfect overlay / a blank page.
            #expect(call.assessment == nil, "\(phase.rawName) picked up assessment")
            #expect(call.recognition == nil, "\(phase.rawName) picked up recognition")
            #expect(call.rawTraceID == nil, "\(phase.rawName) picked up rawTraceID")
            #expect(call.phaseDurationSeconds == nil, "\(phase.rawName) picked up phaseDurationSeconds")
            #expect(call.frechetDistance == nil, "\(phase.rawName) picked up frechetDistance")
            #expect(call.checkpointCoverage == nil, "\(phase.rawName) picked up checkpointCoverage")
        }

        // Exactly one row in the session owns the measurement fields.
        let carriers = s.calls.filter { $0.measurementFieldCount > 0 }
        #expect(carriers.count == 1,
                "exactly one row may carry measurements, got \(carriers.map(\.phase))")
        #expect(carriers.first?.phase == LearningPhase.freeWrite.rawName)
    }

    // MARK: - 4. The trace is written before the linking record

    @Test("the raw trace is persisted and the freeWrite row links to it")
    func rawTraceIsPersistedAndLinked() async throws {
        let s = try await runSession()
        let fw = try row(.freeWrite, in: s.calls)

        #expect(s.traces.count == 1, "expected one captured trace, got \(s.traces.count)")
        let trace = try #require(s.traces.first)
        let linked = try #require(fw.rawTraceID)

        // A record pointing at a missing trace is the failure the
        // write-order comment in captureFreeWriteTrace exists to prevent.
        #expect(trace.id == linked,
                "freeWrite row links \(linked) but the stored trace is \(trace.id)")
        #expect(trace.letter == "A")
        #expect(trace.points.count == 19, "expected 19 samples, got \(trace.points.count)")
        #expect(trace.timestamps.count == trace.points.count,
                "timestamps and points must stay parallel")
        #expect(trace.forces.count == trace.points.count,
                "forces and points must stay parallel")
    }

    // MARK: - 5. Assignment axes stamped on every row

    @Test("every row carries all three assignment axes, not just the freeWrite one")
    func everyRowCarriesTheAssignmentAxes() async throws {
        let s = try await runSession()

        // Per-arm export stratification reads these off each row, so a
        // row missing an axis silently drops out of its arm's aggregate.
        for call in s.calls {
            #expect(call.condition == .threePhase,
                    "\(call.phase) row lost the thesis arm")
            #expect(call.audioCondition == .phoneme,
                    "\(call.phase) row lost the audio arm")
            #expect(call.trainedSubset == TrainedLetterSubset.allSubsets[0].rawValue,
                    "\(call.phase) row lost the trained subset, got \(call.trainedSubset ?? "nil")")
        }
    }
}
