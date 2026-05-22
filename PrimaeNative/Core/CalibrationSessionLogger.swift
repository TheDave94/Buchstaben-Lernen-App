// CalibrationSessionLogger.swift
// PrimaeNative
//
// Captures pre/post polyline pairs at every successful
// CalibrationStore.persist() so future calibration sessions
// become training data for correction-pattern analysis.
//
// Established by Sub-D of the correction-corpus investigation:
// historical SKELETT/ANKER edits are irretrievably lost beyond
// the final polylines in git. This module ensures every future
// session is captured.
//
// Write failures never block the persist() call — they log to
// OSLog and return.

import Foundation
import CoreGraphics
import OSLog

private nonisolated(unsafe) let sessionLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "PrimaeNative",
    category: "CalibrationSessionLogger")

@MainActor
public enum CalibrationSessionLogger {

    /// Tool that produced the save. Mirrors `StrokeCalibrationOverlay`'s
    /// `TopMode` plus an explicit "OTHER" fallback for any future save
    /// path that doesn't carry a tool mode.
    public enum Tool: String {
        case skelett = "SKELETT"
        case anker = "ANKER"
        case other = "OTHER"
    }

    /// Create the session-log root directory + a one-time README so the
    /// app appears in the Files app and Finder USB share even before any
    /// calibration save lands. Without this, iPadOS hides apps with empty
    /// shared-document directories from the file pickers, and David
    /// wouldn't see Primae listed under "Auf meinem iPad" → Primae
    /// until after his first save.
    ///
    /// Idempotent. Errors are logged and swallowed.
    public static func bootstrap() {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        let root = documents.appendingPathComponent(
            "PrimaeNative/CalibrationSessions")
        do {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true)
        } catch {
            sessionLogger.warning("bootstrap mkdir failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let readme = root.appendingPathComponent("README.txt")
        guard !FileManager.default.fileExists(atPath: readme.path) else { return }
        let text = """
        Primae calibration session logs
        ================================

        Every time you save a SKELETT or ANKER edit in the calibrator,
        a JSON file lands here as `<letter>/<timestamp>.json` capturing
        the polyline before and after your edit plus a few metadata
        fields. These pairs are the training-data corpus for future
        correction-pattern analysis.

        Safe to delete this entire folder; the app re-creates it on
        next launch. Safe to leave it growing; each save is small
        (~5-30 KB).
        """
        try? text.data(using: .utf8)?.write(to: readme, options: .atomic)
    }

    /// Write a pre/post pair to
    /// `Documents/PrimaeNative/CalibrationSessions/<letter>/<timestamp>.json`.
    /// No-op if `pre == post` (no-edit auto-save). Errors are logged
    /// and swallowed.
    public static func log(pre: [[CGPoint]],
                    post: [[CGPoint]],
                    letter: String,
                    schriftArt: SchriftArt,
                    editCount: Int,
                    tool: Tool) {
        // Pointwise equality after the 4-decimal rounding the JSON
        // encoder applies — keeps the no-op detection consistent with
        // what would have been written to disk.
        let preRounded = pre.map { rounded($0) }
        let postRounded = post.map { rounded($0) }
        guard preRounded != postRounded else { return }

        guard let dir = sessionDir(letter: letter) else {
            sessionLogger.warning("session dir unavailable; skipping")
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
        } catch {
            sessionLogger.warning("mkdir failed at \(dir.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        let record = Record(letter: letter,
                            schriftArt: schriftArt.rawValue,
                            timestamp_iso: timestampString(),
                            pre_polyline: preRounded.map(toCodable),
                            post_polyline: postRounded.map(toCodable),
                            edit_count_in_session: editCount,
                            tool: tool.rawValue)
        let url = dir.appendingPathComponent("\(timestampFilename()).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(record)
            try data.write(to: url, options: .atomic)
        } catch {
            sessionLogger.warning("write failed at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Private

    private struct Record: Encodable {
        let letter: String
        let schriftArt: String
        let timestamp_iso: String
        let pre_polyline: [[CodablePoint]]
        let post_polyline: [[CodablePoint]]
        let edit_count_in_session: Int
        let tool: String
    }

    private struct CodablePoint: Encodable {
        let x: Double
        let y: Double
    }

    private static func rounded(_ stroke: [CGPoint]) -> [CGPoint] {
        stroke.map { CGPoint(x: (($0.x * 10000).rounded() / 10000),
                              y: (($0.y * 10000).rounded() / 10000)) }
    }

    private static func toCodable(_ stroke: [CGPoint]) -> [CodablePoint] {
        stroke.map { CodablePoint(x: Double($0.x), y: Double($0.y)) }
    }

    private static func sessionDir(letter: String) -> URL? {
        // Documents/ (not Application Support/) so the
        // `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`
        // Info.plist keys expose this folder to Files-app and Finder
        // USB — David needs to extract the captures after each
        // calibration session.
        FileManager.default.urls(for: .documentDirectory,
                                  in: .userDomainMask).first?
            .appendingPathComponent("PrimaeNative/CalibrationSessions/\(letter)")
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// ISO-8601 with `Z` suffix for the payload.
    private static func timestampString() -> String {
        isoFormatter.string(from: Date())
    }

    /// Same instant as `timestampString()`, but with colons replaced
    /// by hyphens for filesystem safety.
    private static func timestampFilename() -> String {
        timestampString().replacingOccurrences(of: ":", with: "-")
    }
}
