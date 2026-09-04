// Pins the study's measurement layer — the four things an analysis of
// the pilot has to be able to do without re-running a single child:
//
//  1. Re-derive ANY later measure offline  → raw traces persist + export
//     (mechanics covered in RawTracePersistenceTests; the tie between a
//     trace and the duration derived from it is pinned here).
//  2. Measure accuracy on a scale that doesn't hit ceiling
//     → raw discrete-Fréchet distance is the PRIMARY outcome,
//       checkpoint coverage the SECONDARY one.
//  3. Measure time end-inclusively
//     → the span runs first sample → last sample, never to the final
//       stroke's START (which would erase the whole trial for a
//       single-stroke letter).
//  4. Attribute every measured row to a letter
//     → per-letter analysis is mandatory; M is a structural outlier
//       (single stroke, ~200 checkpoints) so pooling across letters is
//       never valid.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

// MARK: - Fixtures

/// Horizontal line at y = 0.5 spanning x = 0.1…0.9, as one stroke.
/// `checkpointRadius` is deliberately generous so a sloppy-but-ordered
/// trace can still reach every checkpoint — that's the coverage-ceiling
/// case the Fréchet measure exists to see past.
private func lineReference(checkpointRadius: CGFloat = 0.2) -> LetterStrokes {
    LetterStrokes(
        letter: "I",
        checkpointRadius: checkpointRadius,
        strokes: [StrokeDefinition(id: 1, checkpoints: (0...8).map {
            Checkpoint(x: 0.1 + 0.1 * CGFloat($0), y: 0.5)
        })]
    )
}

@Suite @MainActor struct MeasurementLayerTests {

    // MARK: - 2a. spatialDeviation is captured, not just displayed

    @Test("no assessment yet → no spatial deviation to record")
    func spatialDeviationNilBeforeAssessment() {
        let r = FreeWritePhaseRecorder()
        #expect(r.lastSpatialDeviation == nil)
        r.startSession(now: 0)
        #expect(r.lastSpatialDeviation == nil,
                "a fresh session has measured nothing")
    }

    @Test("single-cell assess records the raw spatial deviation")
    func singleCellAssessRecordsSpatialDeviation() throws {
        let ref = lineReference()
        let r = FreeWritePhaseRecorder()
        r.startSession(now: 0)
        let canvas = CGSize(width: 100, height: 100)
        // Trace the line, but 0.1 (normalised) below it.
        for i in 0...8 {
            r.record(point: CGPoint(x: 10 + 10 * Double(i), y: 60),
                     timestamp: Double(i) * 0.05, force: 0, canvasSize: canvas)
        }
        _ = r.assess(reference: ref, canvasSize: canvas, now: 1.0)

        let recorded = try #require(r.lastSpatialDeviation)
        let normalised = r.points.map { CGPoint(x: $0.x / 100, y: $0.y / 100) }
        let expected = try #require(StrokeProcessScorer.analyze(
            points: normalised, strokeStartIndices: r.strokeStartIndices, reference: ref
        )).spatialDeviation
        #expect(abs(recorded - expected) < 1e-9,
                "the recorded value must be the scorer's raw distance, untransformed")
        #expect(recorded > 0, "an offset trace is not a perfect overlay")
    }

    @Test("degenerate trace records no distance instead of a sentinel")
    func degenerateTraceRecordsNoDistance() {
        let ref = lineReference()
        let r = FreeWritePhaseRecorder()
        r.startSession(now: 0)
        let canvas = CGSize(width: 100, height: 100)
        r.record(point: CGPoint(x: 10, y: 50), timestamp: 0, force: 0, canvasSize: canvas)
        _ = r.assess(reference: ref, canvasSize: canvas, now: 1.0)
        // A single point can't form a stroke comparable to the
        // reference — StrokeProcessScorer.analyze reports nil, which
        // must never reach the export as a defaulted number.
        #expect(r.lastSpatialDeviation == nil)
    }

    @Test("clearAll drops the distance so it can't bleed to the next letter")
    func clearAllDropsDistance() {
        let ref = lineReference()
        let r = FreeWritePhaseRecorder()
        r.startSession(now: 0)
        let canvas = CGSize(width: 100, height: 100)
        for i in 0...8 {
            r.record(point: CGPoint(x: 10 + 10 * Double(i), y: 60),
                     timestamp: Double(i) * 0.05, force: 0, canvasSize: canvas)
        }
        _ = r.assess(reference: ref, canvasSize: canvas, now: 1.0)
        #expect(r.lastSpatialDeviation != nil)
        r.clearAll()
        #expect(r.lastSpatialDeviation == nil)
    }

    // MARK: - 2b. Why spatialDeviation is primary: coverage saturates, it doesn't

    @Test("two traces both saturate checkpoint coverage at 1.0 but differ in spatialDeviation")
    func coverageSaturatesWhereSpatialDeviationDiscriminates() throws {
        let ref = lineReference(checkpointRadius: 0.2)

        // Tidy trace: straight along the reference.
        let tidy = (0...40).map { CGPoint(x: 0.1 + 0.02 * CGFloat($0), y: 0.5) }
        // Sloppy trace: same left-to-right ordering, but it zigzags in y.
        // Every checkpoint is still reached within the radius, so the
        // tracker still calls this a complete letter.
        let sloppy = (0...40).map { i -> CGPoint in
            let x = 0.1 + 0.02 * CGFloat(i)
            return CGPoint(x: x, y: 0.5 + (i % 2 == 0 ? 0.10 : -0.10))
        }

        func coverage(_ path: [CGPoint]) -> CGFloat {
            let tracker = StrokeTracker()
            tracker.load(ref)
            for p in path { tracker.update(normalizedPoint: p) }
            return tracker.overallProgress
        }

        #expect(coverage(tidy) == 1.0)
        #expect(coverage(sloppy) == 1.0,
                "the sloppy trace still reaches every checkpoint — coverage is at ceiling")

        let dTidy = try #require(StrokeProcessScorer.analyze(
            points: tidy, strokeStartIndices: [], reference: ref)).spatialDeviation
        let dSloppy = try #require(StrokeProcessScorer.analyze(
            points: sloppy, strokeStartIndices: [], reference: ref)).spatialDeviation
        #expect(dSloppy > dTidy,
                "spatialDeviation must still separate two traces that coverage calls identical")
    }

    @Test("spatialDeviation keeps ranking traces after formAccuracy has clamped to 0")
    func spatialDeviationDiscriminatesBelowTheFormAccuracyFloor() throws {
        let ref = lineReference(checkpointRadius: 0.05)
        // Both traces sit far outside checkpointRadius * 3 (= 0.15), so
        // the clamped formAccuracy reads 0 for each and loses the
        // difference. The raw distance does not.
        let bad   = (0...20).map { CGPoint(x: 0.1 + 0.04 * CGFloat($0), y: 0.85) }
        let worse = (0...20).map { CGPoint(x: 0.1 + 0.04 * CGFloat($0), y: 0.99) }

        let aBad = FreeWriteScorer.score(tracedPoints: bad, reference: ref)
        let aWorse = FreeWriteScorer.score(tracedPoints: worse, reference: ref)
        #expect(aBad.formAccuracy == 0)
        #expect(aWorse.formAccuracy == 0)

        let dBad = try #require(StrokeProcessScorer.analyze(
            points: bad, strokeStartIndices: [], reference: ref)).spatialDeviation
        let dWorse = try #require(StrokeProcessScorer.analyze(
            points: worse, strokeStartIndices: [], reference: ref)).spatialDeviation
        #expect(dWorse > dBad,
                "the raw distance is the only one of the two that still ranks these")
    }

    // MARK: - 2c. Both measures reach the record and the CSV

    @Test("freeWrite row stores Fréchet distance + checkpoint coverage + spatial deviation")
    func storeRecordsAllThreeAccuracyMeasures() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = JSONParentDashboardStore(fileURL: tmp)
        store.recordPhaseSession(
            letter: "M", phase: "freeWrite", completed: true, score: 0.72,
            schedulerPriority: 0.4, condition: .threePhase, audioCondition: .phoneme,
            assessment: nil, recognition: nil, inputDevice: "finger",
            rawTraceID: nil, trainedSubset: "AIM", phaseDurationSeconds: 6.25,
            frechetDistance: 0.083412, checkpointCoverage: 1.0,
            spatialDeviation: 0.067321)

        let rec = try #require(store.snapshot.phaseSessionRecords.last)
        #expect(rec.frechetDistance == 0.083412)
        #expect(rec.checkpointCoverage == 1.0)
        #expect(rec.spatialDeviation == 0.067321)
    }

    @Test("per-phase CSV gains frechetDistance + checkpointCoverage + spatialDeviation columns")
    func csvCarriesAllThreeAccuracyMeasures() {
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords.append(PhaseSessionRecord(
            letter: "I", phase: "freeWrite", completed: true, score: 0.6,
            schedulerPriority: 0, recordedAt: Date(timeIntervalSince1970: 1_770_000_000),
            phaseDurationSeconds: 4.5, frechetDistance: 0.123456,
            checkpointCoverage: 0.875, spatialDeviation: 0.098765))
        let csv = String(data: ParentDashboardExporter.csvData(
            from: snap, progress: [:], enrolledAt: nil), encoding: .utf8)!

        #expect(csv.contains("phaseDurationSeconds,frechetDistance,checkpointCoverage,spatialDeviation"),
                "the three measures append after the existing trailing column, newest last")
        #expect(csv.contains("0.123456"), "Fréchet exports at 6 dp — 0–1 letter space")
        #expect(csv.contains("0.8750"))
        #expect(csv.contains("0.098765"), "spatial deviation exports at 6 dp — same letter space")
    }

    @Test("store records stroke count/order/direction")
    func storeRecordsStrokeProcessMeasures() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = JSONParentDashboardStore(fileURL: tmp)
        store.recordPhaseSession(
            letter: "M", phase: "freeWrite", completed: true, score: 0.72,
            schedulerPriority: 0.4, condition: .threePhase, audioCondition: .phoneme,
            assessment: nil, recognition: nil, inputDevice: "finger",
            rawTraceID: nil, trainedSubset: "AIM", phaseDurationSeconds: 6.25,
            frechetDistance: 0.083412, checkpointCoverage: 1.0,
            spatialDeviation: 0.067321, strokeCount: 2, strokeOrder: "0,1",
            reversedStrokeCount: 1)

        let rec = try #require(store.snapshot.phaseSessionRecords.last)
        #expect(rec.strokeCount == 2)
        #expect(rec.strokeOrder == "0,1")
        #expect(rec.reversedStrokeCount == 1)
    }

    @Test("per-phase CSV gains strokeCount + strokeOrder + reversedStrokeCount columns")
    func csvCarriesStrokeProcessMeasures() {
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords.append(PhaseSessionRecord(
            letter: "I", phase: "freeWrite", completed: true, score: 0.6,
            schedulerPriority: 0, recordedAt: Date(timeIntervalSince1970: 1_770_000_000),
            phaseDurationSeconds: 4.5, strokeCount: 3, strokeOrder: "1,0,2",
            reversedStrokeCount: 2))
        let csv = String(data: ParentDashboardExporter.csvData(
            from: snap, progress: [:], enrolledAt: nil), encoding: .utf8)!

        #expect(csv.contains("spatialDeviation,strokeCount,strokeOrder,reversedStrokeCount"),
                "the three process measures append after spatialDeviation, newest last")
        #expect(csv.contains("1,0,2"), "the raw matched-order correspondence exports verbatim")
    }

    @Test("non-freeWrite and legacy rows leave all measurement columns empty")
    func nonFreeWriteRowsLeaveMeasuresEmpty() throws {
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords.append(PhaseSessionRecord(
            letter: "I", phase: "guided", completed: true, score: 0.9,
            schedulerPriority: 0, recordedAt: Date(timeIntervalSince1970: 1_770_000_000)))
        let csv = String(data: ParentDashboardExporter.csvData(
            from: snap, progress: [:], enrolledAt: nil), encoding: .utf8)!
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)
        let header = try #require(lines.first { $0.hasPrefix("letter,phase,completed") })
        let row = try #require(lines.first { $0.hasPrefix("I,guided") })
        let names = header.components(separatedBy: ",")
        let fields = row.components(separatedBy: ",")
        #expect(fields.count == names.count, "row and header must stay aligned")
        let frechetIdx = try #require(names.firstIndex(of: "frechetDistance"))
        let coverageIdx = try #require(names.firstIndex(of: "checkpointCoverage"))
        let deviationIdx = try #require(names.firstIndex(of: "spatialDeviation"))
        let strokeCountIdx = try #require(names.firstIndex(of: "strokeCount"))
        let strokeOrderIdx = try #require(names.firstIndex(of: "strokeOrder"))
        let reversedIdx = try #require(names.firstIndex(of: "reversedStrokeCount"))
        // Empty, never a defaulted 0 — a 0 distance reads as a perfect
        // overlay and a 0 coverage as a blank page.
        #expect(fields[frechetIdx].isEmpty)
        #expect(fields[coverageIdx].isEmpty)
        #expect(fields[deviationIdx].isEmpty)
        #expect(fields[strokeCountIdx].isEmpty)
        #expect(fields[strokeOrderIdx].isEmpty)
        #expect(fields[reversedIdx].isEmpty)
    }

    @Test("legacy JSON without the new keys decodes to nil, not 0")
    func legacyRecordDecodesMeasuresAsNil() throws {
        // A 0 here would read as "perfect overlay" / "no coverage" and
        // silently pollute the pilot's primary outcome.
        let legacy = """
        {"letter":"A","phase":"freeWrite","completed":true,"score":0.5,
         "schedulerPriority":0.1,"condition":"threePhase"}
        """.data(using: .utf8)!
        let rec = try JSONDecoder().decode(PhaseSessionRecord.self, from: legacy)
        #expect(rec.frechetDistance == nil)
        #expect(rec.checkpointCoverage == nil)
        #expect(rec.strokeCount == nil)
        #expect(rec.strokeOrder == nil)
        #expect(rec.reversedStrokeCount == nil)
        #expect(rec.spatialDeviation == nil)
    }

    // MARK: - 3. End-inclusive freeWrite time

    @Test("measured span runs first sample → last sample, past the final stroke's start")
    func spanIsEndInclusiveAcrossStrokes() throws {
        let r = FreeWritePhaseRecorder()
        r.startSession(now: 0)
        let canvas = CGSize(width: 100, height: 100)
        // Stroke 1: t = 0.0 … 0.4
        for i in 0...4 {
            r.record(point: CGPoint(x: 10 + Double(i), y: 10),
                     timestamp: Double(i) * 0.1, force: 0, canvasSize: canvas)
        }
        // Stroke 2 begins at t = 1.0 and runs a further 0.4 s.
        r.beginStroke()
        for i in 0...4 {
            r.record(point: CGPoint(x: 50 + Double(i), y: 10),
                     timestamp: 1.0 + Double(i) * 0.1, force: 0, canvasSize: canvas)
        }

        let span = try #require(r.measuredSpanSeconds)
        #expect(abs(span - 1.4) < 1e-9, "0.0 → 1.4 is the full span")

        // The regression this guards: a span ending at the final
        // stroke's START would read 1.0 and silently drop that stroke.
        let finalStrokeStart = try #require(r.strokeStartIndices.last)
        let startBasedSpan = r.timestamps[finalStrokeStart] - r.timestamps[0]
        #expect(span > startBasedSpan)
    }

    @Test("single-stroke letter keeps its whole duration")
    func singleStrokeSpanIsNotZero() throws {
        // I and M are single-stroke as baked. A stroke-start-based span
        // would be first-start minus first-start = 0 for these — the
        // entire trial erased.
        let r = FreeWritePhaseRecorder()
        r.startSession(now: 0)
        let canvas = CGSize(width: 100, height: 100)
        for i in 0...20 {
            r.record(point: CGPoint(x: 10, y: 10 + Double(i)),
                     timestamp: Double(i) * 0.15, force: 0, canvasSize: canvas)
        }
        #expect(r.strokeStartIndices.isEmpty, "one stroke: no post-lift starts recorded")
        let span = try #require(r.measuredSpanSeconds)
        #expect(abs(span - 3.0) < 1e-9)
    }

    @Test("fewer than two distinct samples yields no span")
    func spanNilWithoutTwoEndpoints() {
        let r = FreeWritePhaseRecorder()
        r.startSession(now: 0)
        #expect(r.measuredSpanSeconds == nil, "empty buffer")
        let canvas = CGSize(width: 100, height: 100)
        r.record(point: CGPoint(x: 1, y: 1), timestamp: 5.0, force: 0, canvasSize: canvas)
        #expect(r.measuredSpanSeconds == nil, "one sample is a point, not a span")
        r.record(point: CGPoint(x: 2, y: 2), timestamp: 5.0, force: 0, canvasSize: canvas)
        #expect(r.measuredSpanSeconds == nil, "two samples at one instant is still a point")
    }

    // MARK: - 1 ↔ 3. The exported trace reproduces the exported duration

    @Test("the persisted raw trace re-derives the recorded span offline")
    func rawTraceReDerivesTheSpan() throws {
        let store = StubRawTraceStore()
        let vm = TracingViewModel(.stub.with(rawTraceStore: store))
        vm.freeWriteRecorder.startSession(now: 0)
        let canvas = vm.canvasSize
        for i in 0...9 {
            vm.freeWriteRecorder.record(point: CGPoint(x: 10 + Double(i), y: 20),
                                        timestamp: Double(i) * 0.2, force: 0,
                                        canvasSize: canvas)
        }
        let span = try #require(vm.freeWriteRecorder.measuredSpanSeconds)
        _ = vm.captureFreeWriteTrace()

        let trace = try #require(store.traces.last)
        let firstStamp = try #require(trace.timestamps.first)
        let lastStamp = try #require(trace.timestamps.last)
        let reDerived = lastStamp - firstStamp
        #expect(abs(reDerived - span) < 1e-9,
                "the archived trace must reproduce the exported duration — that's what makes any later measure re-derivable")
    }

    // MARK: - 4. Letter identity on every measured row

    @Test("the freeWrite row carries letter, duration, and both measures together")
    func freeWriteRowIsSelfContainedPerLetter() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = JSONParentDashboardStore(fileURL: tmp)
        store.recordPhaseSession(
            letter: "M", phase: "freeWrite", completed: true, score: 0.5,
            schedulerPriority: 0, condition: .threePhase, audioCondition: .phoneme,
            assessment: nil, recognition: nil, inputDevice: "finger",
            rawTraceID: nil, trainedSubset: "AIM", phaseDurationSeconds: 9.75,
            frechetDistance: 0.21, checkpointCoverage: 0.6)

        let rec = try #require(store.snapshot.phaseSessionRecords.last)
        // Per-letter analysis is mandatory — M is a structural outlier
        // (single stroke, ~200 checkpoints), so a row that couldn't name
        // its letter would have to be pooled, which is invalid.
        #expect(rec.letter == "M")
        #expect(rec.phase == "freeWrite")
        #expect(rec.phaseDurationSeconds == 9.75)
        #expect(rec.frechetDistance == 0.21)
        #expect(rec.checkpointCoverage == 0.6)
    }

    @Test("the duration row carries the letter it practised")
    func durationRowCarriesLetter() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = JSONParentDashboardStore(fileURL: tmp)
        store.recordSession(letter: "I", accuracy: 0.9, durationSeconds: 12.0,
                            wallClockSeconds: 14.0, date: Date(),
                            condition: .threePhase, inputDevice: "finger")
        let rec = try #require(store.snapshot.sessionDurations.last)
        #expect(rec.letter == "I")
    }
}
