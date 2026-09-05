// SpatialSonification.swift
// PrimaeNative
//
// Constants + pure mapping for the pilot's spatial-2D-sonification arm
// (`PilotAudioCondition.spatial`): as the pen traces, vertical canvas
// position drives the carrier tone's PITCH and horizontal position
// drives stereo PAN (pan is the pre-existing shared coupling in
// TouchDispatcher.updateAdaptivePlayback — this file only owns the
// pitch axis and the carrier asset reference). Headphone delivery;
// the ResearchDashboard warns when no headphone route is active.
//
// Pitch mapping (David's acoustics spec, decided 2026-07-06):
//   range 220–880 Hz (A3–A5, two octaves), TOP of canvas = 880 Hz,
//   bottom = 220 Hz, CONTINUOUS glide (not quantized), LINEAR-IN-CENTS
//   so equal screen distance = equal perceived pitch change. The
//   carrier is authored at 440 Hz (the geometric mean), so the cents
//   offset spans exactly ±1200 — half the AVAudioUnitTimePitch ±2400
//   range, comfortable headroom.

import CoreGraphics
import Foundation

enum SpatialSonification {
    /// Seamlessly-looped neutral carrier: band-limited triangle,
    /// 440 Hz, mono 44.1 kHz, integer cycle count (gapless WAV — MP3
    /// encoder padding would click at the loop seam). Steady, no
    /// vibrato: triangle over sine because the richer odd-harmonic
    /// series makes the pitch glide easier to track for children.
    /// Path shape matches the letter-audio convention (bundle-root
    /// relative, resolved by `AudioEngine.resourceURL(for:)`).
    static let carrierToneFile = "Resources/Sonification/spatial_carrier.wav"

    /// Where the carrier resolves, by the same two lookups `AudioEngine`
    /// uses (resource-root path, then the subdirectory API), or nil. The
    /// spatial arm's stimulus AND its demonstration are this one file;
    /// the engine only logs a warning when it is missing, so a study
    /// session checks it up front (ruling C1-6, 2026-09-05).
    static func carrierToneURL() -> URL? {
        let ns = carrierToneFile as NSString
        let name = (ns.lastPathComponent as NSString).deletingPathExtension
        let ext = ns.pathExtension
        let dir = ns.deletingLastPathComponent
        for bundle in [Bundle.main, Bundle.module] {
            if let root = bundle.resourceURL {
                let candidate = root.appendingPathComponent(carrierToneFile)
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
            if !dir.isEmpty,
               let url = bundle.url(forResource: name, withExtension: ext.isEmpty ? nil : ext, subdirectory: dir) { return url }
            // Flat fallback — the engine's third lookup, for a bundling that
            // flattens the tree. Without it this precondition would refuse
            // the whole arm while the engine still played the file
            // (review 2026-09-05).
            if let url = bundle.url(forResource: name, withExtension: ext.isEmpty ? nil : ext) { return url }
        }
        return nil
    }

    /// Authored frequency of the carrier file, Hz. Pitch offsets are
    /// cents relative to this.
    static let carrierBaseHz: Double = 440

    /// Full mapped span in cents: two octaves, 220–880 Hz.
    static let centsSpan: Float = 2400

    /// Normalized canvas Y (0 = top, UIKit convention) → cents offset
    /// from the 440 Hz carrier. Top = +1200 (880 Hz), mid = 0, bottom
    /// = −1200 (220 Hz). Linear in cents; input clamped to [0, 1].
    static func pitchCents(forNormalizedY y: CGFloat) -> Float {
        let clamped = max(0.0, min(1.0, y))
        return Float(1200.0 - 2400.0 * clamped)
    }
}
