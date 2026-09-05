// CalibrationStore.swift
// PrimaeNative
//
// Owns the per-letter user-calibrated stroke JSON files in
// Application Support. Decoded results are cached in memory so the
// ghost / dot-render path doesn't hit disk on every frame.

import Foundation
import CoreGraphics

/// Reads and writes user-calibrated stroke definitions for a letter
/// under a specific `SchriftArt`. Files live at
/// `~/Application Support/PrimaeNative/CalibratedStrokes/<schriftArt>/<letter>.json`
/// and take priority over the bundle `strokes.json`. Reads fall back to
/// the pre-per-font path `CalibratedStrokes/<letter>.json` so legacy
/// calibrations still apply; the next save promotes them.
@MainActor
final class CalibrationStore {

    /// Decoded strokes keyed by `schriftArt.rawValue + "/" + letter`,
    /// including negative (nil) results so the ghost-render path doesn't
    /// re-hit disk for letters the user has never calibrated.
    private var cache: [String: LetterStrokes?] = [:]

    /// Returns the user-calibrated strokes for `letter` in `schriftArt`,
    /// or nil if none exist. Falls back to the pre-per-font path so
    /// calibrations saved before the schema split still apply.
    func strokes(for letter: String, schriftArt: SchriftArt) -> LetterStrokes? {
        let key = cacheKey(letter: letter, schriftArt: schriftArt)
        if let cached = cache[key] { return cached }

        if let url = fontSpecificURL(letter: letter, schriftArt: schriftArt),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(LetterStrokes.self, from: data) {
            cache[key] = decoded
            return decoded
        }

        if let url = legacyURL(letter: letter),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(LetterStrokes.self, from: data) {
            cache[key] = decoded
            return decoded
        }

        // Memoize the negative result. updateValue is required because
        // `dict[k] = nil` removes the key on Optional-valued dictionaries.
        cache.updateValue(nil, forKey: key)
        return nil
    }

    /// Writes glyph-relative stroke checkpoints for `letter` in
    /// `schriftArt` to disk and invalidates the in-memory cache.
    func persist(_ strokes: [[CGPoint]], for letter: String, schriftArt: SchriftArt,
                 checkpointRadius: CGFloat = 0.10) {
        let defs = strokes.enumerated().compactMap { (i, pts) -> StrokeDefinition? in
            guard !pts.isEmpty else { return nil }
            return StrokeDefinition(id: i + 1, checkpoints: pts.map {
                // Round to 3 decimals so files don't churn on imperceptible drift.
                Checkpoint(x: (($0.x * 1000).rounded() / 1000),
                           y: (($0.y * 1000).rounded() / 1000))
            })
        }
        // The caller passes the letter's authored radius (0.10 Druckschrift,
        // 0.05 Schreibschrift); a hard-coded 0.10 doubled Schreibschrift's
        // tolerance in every override (class two, 2026-09-05).
        let ls = LetterStrokes(letter: letter, checkpointRadius: checkpointRadius, strokes: defs)
        guard let url = fontSpecificURL(letter: letter, schriftArt: schriftArt) else { return }
        guard let data = try? JSONEncoder().encode(ls) else {
            storePersistenceLogger.warning(
                "CalibrationStore encode failed for '\(letter, privacy: .public)' — calibration not persisted.")
            return
        }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            storePersistenceLogger.warning(
                "CalibrationStore disk write failed at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        cache.removeValue(forKey: cacheKey(letter: letter, schriftArt: schriftArt))
    }

    private func cacheKey(letter: String, schriftArt: SchriftArt) -> String {
        "\(schriftArt.rawValue)/\(letter)"
    }

    private func fontSpecificURL(letter: String, schriftArt: SchriftArt) -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PrimaeNative/CalibratedStrokes/\(schriftArt.rawValue)/\(letter).json")
    }

    private func legacyURL(letter: String) -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PrimaeNative/CalibratedStrokes/\(letter).json")
    }

    /// Wipes every per-letter calibration file for `schriftArt` from
    /// disk and clears the in-memory cache so the next read falls
    /// through to the bundled `strokes.json`. Used after shipping a
    /// new bundle to discard stale on-device overrides.
    func clearAll(for schriftArt: SchriftArt) {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        let dir = support.appendingPathComponent(
            "PrimaeNative/CalibratedStrokes/\(schriftArt.rawValue)")
        try? FileManager.default.removeItem(at: dir)
        cache = cache.filter { !$0.key.hasPrefix("\(schriftArt.rawValue)/") }
    }

    /// Returns every persisted per-letter calibration for `schriftArt`,
    /// keyed by the letter character. Used by the "Alle JSON" export
    /// button in the calibrator so a calibration session can be shipped
    /// as one bundle instead of letter-by-letter copy/paste.
    func loadAll(for schriftArt: SchriftArt) -> [String: LetterStrokes] {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return [:]
        }
        let dir = support.appendingPathComponent(
            "PrimaeNative/CalibratedStrokes/\(schriftArt.rawValue)")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else {
            return [:]
        }
        var out: [String: LetterStrokes] = [:]
        let decoder = JSONDecoder()
        for url in entries where url.pathExtension == "json" {
            let letter = url.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? decoder.decode(LetterStrokes.self, from: data)
            else { continue }
            out[letter] = decoded
        }
        return out
    }
}
