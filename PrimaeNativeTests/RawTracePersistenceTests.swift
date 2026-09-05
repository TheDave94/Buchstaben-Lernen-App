// Proves #12 raw-trace capture/persistence/export:
//  - captureFreeWriteTrace writes a trace and links it by id (trace-first)
//  - the trace is lossless: points + canvasSize reconstruct the path
//  - empty buffer captures nothing
//  - RawTrace round-trips through Codable
//  - the new-participant reset wipes the trace store
//  - the JSON export carries traces; the CSV export does NOT
//  - the pre-wipe (new-participant) export path carries vm.rawTraces
//
// Capture is exercised by populating the freeWrite recorder directly and
// calling captureFreeWriteTrace (the same snapshot recordSessionCompletion
// takes), avoiding the recognizer-gated full-phase pipeline.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@Suite(.serialized) @MainActor struct RawTracePersistenceTests {

    private func vmWith(_ store: StubRawTraceStore) -> TracingViewModel {
        TracingViewModel(.stub.with(rawTraceStore: store))
    }

    // MARK: - Capture mechanics

    @Test("captureFreeWriteTrace writes a trace and returns its linking id")
    func captureWritesAndLinks() {
        let store = StubRawTraceStore()
        let vm = vmWith(store)
        vm.freeWriteRecorder.startSession()
        let canvas = vm.canvasSize
        vm.freeWriteRecorder.record(point: CGPoint(x: 10, y: 20), timestamp: 1.0, force: 0.5, canvasSize: canvas)
        vm.freeWriteRecorder.record(point: CGPoint(x: 30, y: 40), timestamp: 1.1, force: 0.6, canvasSize: canvas)
        vm.freeWriteRecorder.beginStroke()
        vm.freeWriteRecorder.record(point: CGPoint(x: 50, y: 60), timestamp: 1.2, force: 0.7, canvasSize: canvas)

        let id = vm.captureFreeWriteTrace()
        #expect(id != nil)
        #expect(store.traces.count == 1)
        let t = store.traces[0]
        #expect(t.id == id, "the returned id must link to the stored trace")
        #expect(t.points == [CGPoint(x: 10, y: 20), CGPoint(x: 30, y: 40), CGPoint(x: 50, y: 60)])
        #expect(t.timestamps == [1.0, 1.1, 1.2])
        #expect(t.forces == [0.5, 0.6, 0.7])
        #expect(t.strokeStartIndices == [2], "stroke break recorded")
        #expect(t.canvasSize == vm.canvasSize)
    }

    @Test("points + canvasSize losslessly reconstruct the normalised path")
    func pointsReconstructPath() {
        let store = StubRawTraceStore()
        let vm = vmWith(store)
        vm.freeWriteRecorder.startSession()
        let canvas = vm.canvasSize
        for (i, p) in [CGPoint(x: 100, y: 200), CGPoint(x: 300, y: 400)].enumerated() {
            vm.freeWriteRecorder.record(point: p, timestamp: Double(i), force: 0, canvasSize: canvas)
        }
        _ = vm.captureFreeWriteTrace()
        let t = store.traces[0]
        // path[i] == points[i] / canvasSize — the stored fields recover the
        // normalised path the recorder would have produced.
        let reconstructed = t.points.map {
            CGPoint(x: $0.x / t.canvasSize.width, y: $0.y / t.canvasSize.height)
        }
        #expect(reconstructed == vm.freeWriteRecorder.path)
    }

    @Test("empty freeWrite buffer captures nothing")
    func emptyBufferCapturesNothing() {
        let store = StubRawTraceStore()
        let vm = vmWith(store)
        // No startSession / no points.
        let id = vm.captureFreeWriteTrace()
        #expect(id == nil)
        #expect(store.traces.isEmpty)
    }

    // MARK: - Codable round-trip

    @Test("RawTrace round-trips through Codable")
    func codableRoundTrip() throws {
        let trace = RawTrace(
            id: UUID(), letter: "A", recordedAt: Date(timeIntervalSince1970: 1_770_000_000),
            points: [CGPoint(x: 1.5, y: 2.5), CGPoint(x: 3.5, y: 4.5)],
            timestamps: [0.0, 0.25], forces: [0.0, 0.9],
            strokeStartIndices: [1], canvasSize: CGSize(width: 800, height: 600),
            referenceStrokes: LetterStrokes(letter: "A", checkpointRadius: 0.05, strokes: [
                StrokeDefinition(id: 1, checkpoints: [Checkpoint(x: 0.1, y: 0.2), Checkpoint(x: 0.9, y: 0.2)])
            ]))
        let data = try JSONEncoder().encode(trace)
        let back = try JSONDecoder().decode(RawTrace.self, from: data)
        #expect(back == trace)
        #expect(back.referenceStrokes?.strokes.first?.checkpoints.count == 2)
    }

    @Test("a trace written before referenceStrokes existed still decodes")
    func legacyTraceWithoutReferenceDecodes() throws {
        let legacyJSON = """
        {"id":"00000000-0000-0000-0000-000000000001","letter":"A",
         "recordedAt":1770000000,"points":[[1.5,2.5]],"timestamps":[0],
         "forces":[0],"strokeStartIndices":[],"canvasSize":[800,600]}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let back = try decoder.decode(RawTrace.self, from: legacyJSON)
        #expect(back.referenceStrokes == nil)
        #expect(back.points.count == 1)
    }

    // MARK: - Reset wipes the store

    @Test("resetForNewParticipant wipes the raw-trace store")
    func resetWipesTraceStore() {
        // resetForNewParticipant mutates global ParticipantStore identity;
        // restore the keys with public setters so other suites are clean.
        let enrolled = ParticipantStore.isEnrolled
        let pedOverride = ParticipantStore.conditionOverride
        let audioOverride = ParticipantStore.audioConditionOverride
        defer {
            ParticipantStore.isEnrolled = enrolled
            ParticipantStore.conditionOverride = pedOverride
            ParticipantStore.audioConditionOverride = audioOverride
        }
        let store = StubRawTraceStore()
        let vm = vmWith(store)
        vm.freeWriteRecorder.startSession()
        vm.freeWriteRecorder.record(point: .init(x: 1, y: 1), timestamp: 0, force: 0, canvasSize: vm.canvasSize)
        _ = vm.captureFreeWriteTrace()
        #expect(!store.traces.isEmpty)
        vm.resetForNewParticipant()
        #expect(store.traces.isEmpty, "reset must wipe traces")
        #expect(store.resetCount == 1)
    }

    // MARK: - JSON-backed store persistence

    @Test("JSONRawTraceStore appends, caps, persists, and resets")
    func jsonStoreRoundTrips() async {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = JSONRawTraceStore(fileURL: tmp)
        func trace(_ letter: String) -> RawTrace {
            RawTrace(id: UUID(), letter: letter, recordedAt: Date(),
                     points: [CGPoint(x: 5, y: 5)], timestamps: [0], forces: [0],
                     strokeStartIndices: [], canvasSize: CGSize(width: 100, height: 100))
        }
        store.append(trace("B"))
        #expect(store.traces.count == 1)
        // Persists: a fresh instance over the same file decodes it
        // (the test used to claim this and never did it — audit 2026-09-04).
        await store.flush()
        let reopened = JSONRawTraceStore(fileURL: tmp)
        #expect(reopened.traces.count == 1 && reopened.traces.first?.letter == "B",
                "the persisted trace must come back from disk; got \(reopened.traces.count)")
        // Caps at 500, dropping the OLDEST.
        for i in 0..<520 { store.append(trace("C\(i)")) }
        #expect(store.traces.count == 500, "cap is 500, got \(store.traces.count)")
        #expect(store.traces.first?.letter == "C20", "the oldest traces are the ones dropped")
        // Resets.
        store.reset()
        #expect(store.traces.isEmpty)
    }

    // MARK: - Durability across the app lifecycle

    /// The trace and the `PhaseSessionRecord` that links to it are written
    /// by two different stores, and for a while only the record's store was
    /// named in the VM's background drain. That let the archive keep a
    /// `rawTraceID` pointing at a trace that never reached disk — the exact
    /// inverse of the invariant `captureFreeWriteTrace`'s trace-first
    /// ordering exists to guarantee. It hit the LAST trial of a session,
    /// because that is when the proctor closes the app.
    ///
    /// Asserted on the drain call rather than on the file: the detached
    /// write usually wins the race unaided, so a disk round-trip would pass
    /// with or without the drain and guard nothing. What has to be pinned
    /// is that the VM names this store at all.
    @Test("backgrounding drains the raw-trace store")
    func backgroundingDrainsTheTraceStore() async {
        let store = StubRawTraceStore()
        let vm = vmWith(store)
        #expect(store.flushCount == 0)

        await vm.appDidEnterBackground()

        #expect(store.flushCount == 1,
                "the raw-trace store must be drained alongside the store that holds the linking record")
    }

    // MARK: - Export: JSON carries traces, CSV does not

    @Test("JSON export includes rawTraces; CSV excludes rawTraceID")
    func exportRoutesTracesToJSONOnly() throws {
        let traceID = UUID()
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords.append(PhaseSessionRecord(
            letter: "A", phase: "freeWrite", completed: true, score: 0.8,
            schedulerPriority: 0, recordedAt: Date(timeIntervalSince1970: 1_770_000_000),
            rawTraceID: traceID))
        snap.phaseSessionRecords.append(PhaseSessionRecord(
            letter: "A", phase: "guided", completed: true, score: 0.5,
            schedulerPriority: 0, recordedAt: Date(timeIntervalSince1970: 1_770_000_000)))
        let trace = RawTrace(id: traceID, letter: "A", recordedAt: Date(),
                             points: [CGPoint(x: 1, y: 2)], timestamps: [0], forces: [0],
                             strokeStartIndices: [], canvasSize: CGSize(width: 10, height: 10))

        let json = String(data: try ParentDashboardExporter.jsonData(
            from: snap, progress: [:], rawTraces: [trace]), encoding: .utf8)!
        #expect(json.contains("rawTraces"), "JSON must carry the traces array")
        #expect(json.contains(traceID.uuidString), "JSON must link the trace id")

        let csv = String(data: ParentDashboardExporter.csvData(
            from: snap, progress: [:], enrolledAt: nil), encoding: .utf8)!
        #expect(!csv.contains(traceID.uuidString),
                "CSV must NOT reference the rawTraceID — it stays derived-only")
        #expect(!csv.contains("rawTraceID"),
                "CSV header must not gain a rawTraceID column")
    }

    @Test("exportFileURL JSON (the pre-wipe archive shape) embeds traces")
    func preWipeArchiveEmbedsTraces() throws {
        let traceID = UUID()
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords.append(PhaseSessionRecord(
            letter: "C", phase: "freeWrite", completed: true, score: 0.9,
            schedulerPriority: 0, recordedAt: Date(), rawTraceID: traceID))
        let trace = RawTrace(id: traceID, letter: "C", recordedAt: Date(),
                             points: [CGPoint(x: 3, y: 4)], timestamps: [0], forces: [0],
                             strokeStartIndices: [], canvasSize: CGSize(width: 50, height: 50))
        let url = try ParentDashboardExporter.exportFileURL(
            from: snap, format: .json, progress: [:], rawTraces: [trace])
        defer { try? FileManager.default.removeItem(at: url) }
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains(traceID.uuidString),
                "the pre-wipe JSON archive must carry traces so rawTraceIDs don't dangle")
    }
}
