// StoreFileQuarantine.swift
// PrimaeNative
//
// Two helpers the three JSON stores (ProgressStore, ParentDashboardStore,
// RawTraceStore) share so that a file which EXISTS but does not decode is
// neither silently dropped nor destroyed (2026-09-04 audit):
//
//   1. `quarantine(_:)` moves the undecodable file aside before the next
//      atomic save replaces it — the study's phase records and raw traces
//      live in these files, and "starting empty" used to be
//      indistinguishable from a fresh install.
//   2. `LossyArray` decodes an array element by element, dropping (and
//      counting) only the elements that fail. One malformed row no longer
//      costs every row written before it.

import Foundation

enum StoreFileQuarantine {
    /// Copies `url` to `<stem>.undecodable-<unix-seconds>.<ext>` beside it,
    /// leaving the original in place — for a file that decoded well enough
    /// to keep running from, but lost a block worth inspecting.
    @discardableResult
    static func preserveCopy(_ url: URL) -> URL? {
        let stamp = Int(Date().timeIntervalSince1970)
        let ext = url.pathExtension
        var dest = url.deletingPathExtension()
            .appendingPathExtension("undecodable-\(stamp)")
        if !ext.isEmpty { dest = dest.appendingPathExtension(ext) }
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            storePersistenceLogger.error(
                "Partly undecodable store file copied to \(dest.path, privacy: .public) for inspection; the live file keeps running.")
            return dest
        } catch {
            storePersistenceLogger.error(
                "Partly undecodable store file at \(url.path, privacy: .public) could NOT be copied aside (\(error.localizedDescription, privacy: .public)).")
            return nil
        }
    }

    /// Moves `url` to `<stem>.undecodable-<unix-seconds>.<ext>` beside it.
    /// Returns the destination, or nil (already logged) if the move failed.
    @discardableResult
    static func quarantine(_ url: URL) -> URL? {
        let stamp = Int(Date().timeIntervalSince1970)
        let ext = url.pathExtension
        var dest = url.deletingPathExtension()
            .appendingPathExtension("undecodable-\(stamp)")
        if !ext.isEmpty { dest = dest.appendingPathExtension(ext) }
        do {
            try FileManager.default.moveItem(at: url, to: dest)
            storePersistenceLogger.error(
                "Undecodable store file moved aside to \(dest.path, privacy: .public) — nothing was overwritten; copy it off the device and inspect it.")
            return dest
        } catch {
            storePersistenceLogger.error(
                "Undecodable store file at \(url.path, privacy: .public) could NOT be moved aside (\(error.localizedDescription, privacy: .public)); the next save WILL overwrite it.")
            return nil
        }
    }
}

/// Array decoding that survives individual bad elements. `droppedCount`
/// is reported by the caller so the loss is visible in the log.
struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]
    let droppedCount: Int

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var out: [Element] = []
        var dropped = 0
        while !container.isAtEnd {
            let before = container.currentIndex
            if let element = try? container.decode(Element.self) {
                out.append(element)
            } else {
                dropped += 1
                // Consume the bad element so the loop advances.
                _ = try? container.decode(Skip.self)
            }
            // A container that cannot advance would spin forever — stop
            // and keep what was decoded so far.
            if container.currentIndex == before {
                // Everything after this element is lost too — say so.
                if let total = container.count {
                    dropped += max(0, total - container.currentIndex - 1)
                }
                break
            }
        }
        elements = out
        droppedCount = dropped
    }

    /// Decodes any JSON value without inspecting it.
    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {
            _ = try decoder.singleValueContainer()
        }
    }
}
