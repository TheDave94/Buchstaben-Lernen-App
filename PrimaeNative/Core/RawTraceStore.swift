// RawTraceStore.swift
// PrimaeNative
//
// Per-trial raw freeWrite traces — points + timestamps + forces + stroke
// breaks — captured at phase exit BEFORE the buffer clears on the next
// letter load. Re-analysis insurance against the unvalidated
// Schreibmotorik scorer (C1): any future metric can be recomputed from
// the raw trace, which is otherwise discarded forever.
//
// Deliberately a SEPARATE store from ParentDashboardStore: that snapshot
// is re-encoded on the main actor on every persist and is designed to
// stay <100 KB. Raw traces are large, cold, export-only data that must
// not bloat that hot path. Records link to their trace by
// `PhaseSessionRecord.rawTraceID`.

import CoreGraphics
import Foundation

/// One freeWrite trial's raw captured trace. The normalised `path` is
/// intentionally NOT stored — it's redundant (`points[i] / canvasSize`)
/// and reconstructable offline, so `points` + `canvasSize` is lossless
/// and smaller.
struct RawTrace: Codable, Equatable, Identifiable {
    let id: UUID
    let letter: String
    let recordedAt: Date
    /// Canvas-space sample points (one per touch sample).
    let points: [CGPoint]
    /// `CACurrentMediaTime()` per point.
    let timestamps: [CFTimeInterval]
    /// Digitiser force per point (0 for finger / no pencil data).
    let forces: [CGFloat]
    /// Indices into `points` where a fresh stroke begins after a lift.
    let strokeStartIndices: [Int]
    /// Canvas size at capture — lets `points` be re-normalised to 0–1
    /// offline, losslessly recovering the normalised path.
    let canvasSize: CGSize
    /// The reference the trial was scored against, exactly as the scorer
    /// saw it: the bundle's bbox-relative strokes mapped through the
    /// rendered glyph rect into the SAME canvas-normalised space
    /// `points / canvasSize` yields (2026-09-04). Without it a trace could
    /// only be re-scored by re-running the app's CoreText glyph layout for
    /// that canvas size — the offline re-analysis the thesis promises
    /// (Ch.3, Ch.6) was not possible from the export alone. Optional so
    /// traces written before this field decode unchanged.
    var referenceStrokes: LetterStrokes? = nil
}

@MainActor
protocol RawTraceStoring {
    /// All stored traces, oldest first.
    var traces: [RawTrace] { get }
    /// Append one trace. Call BEFORE writing the linking
    /// `PhaseSessionRecord` so a crash leaves at most an orphan trace,
    /// never a record pointing at a missing trace.
    func append(_ trace: RawTrace)
    func reset()
    /// Await any pending background write.
    func flush() async
}

extension RawTraceStoring {
    func flush() async {}
}

/// JSON-backed implementation. Mirrors `JSONParentDashboardStore`: encode
/// on main, write off main with cancel-and-replace coalescing.
final class JSONRawTraceStore: RawTraceStoring {

    private let fileURL: URL
    private(set) var traces: [RawTrace]
    private var pendingSave: Task<Void, Never>?

    /// Hard ceiling — bounds the file if a device is reused without a
    /// reset. One freeWrite trial per letter, so ~500 is many sessions of
    /// headroom; the new-participant reset clears it between children.
    private static let cap = 500

    init(fileURL: URL? = nil) {
        if let url = fileURL {
            self.fileURL = url
        } else {
            // See ProgressStore.init for the `??` fallback rationale.
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            let dir = support.appendingPathComponent("PrimaeNative", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("rawtraces.json")
        }
        self.traces = Self.load(from: self.fileURL) ?? []
    }

    func append(_ trace: RawTrace) {
        traces.append(trace)
        if traces.count > Self.cap {
            traces.removeFirst(traces.count - Self.cap)
        }
        persist()
    }

    func reset() {
        traces = []
        persist()
    }

    func flush() async { await pendingSave?.value }

    // MARK: Private

    private func persist() {
        // Encode on main, write off main. See ParentDashboardStore.persist
        // for the cancel-and-replace coalescing rationale.
        guard let data = try? JSONEncoder().encode(traces) else {
            storePersistenceLogger.warning("RawTraceStore encode failed — raw traces not persisted.")
            return
        }
        let url = fileURL
        let previous = pendingSave
        previous?.cancel()
        pendingSave = Task.detached(priority: .utility) {
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                storePersistenceLogger.warning(
                    "RawTraceStore disk write failed at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func load(from url: URL) -> [RawTrace]? {
        // No file yet is the ordinary first-launch case and stays quiet.
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            // Element-wise: one malformed trace must not cost the rest
            // (see LossyArray). A whole-file failure is quarantined.
            let lossy = try JSONDecoder().decode(LossyArray<RawTrace>.self, from: data)
            if lossy.droppedCount > 0 {
                storePersistenceLogger.error(
                    "RawTraceStore: dropped \(lossy.droppedCount) undecodable trace(s); \(lossy.elements.count) kept. Copy \(url.path, privacy: .public) off the device before it is rewritten.")
            }
            return lossy.elements
        } catch {
            // See ProgressStore.load: these are the re-analysis raw
            // traces, and an undecodable file used to vanish silently.
            storePersistenceLogger.error(
                "RawTraceStore at \(url.path, privacy: .public) exists but failed to decode (\(error.localizedDescription, privacy: .public)) — starting EMPTY.")
            StoreFileQuarantine.quarantine(url)
            return nil
        }
    }
}
