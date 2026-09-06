// AudioEngine+Loudness.swift
// PrimaeNative
//
// Per-file loudness normalisation, kept OUT of AudioEngine.swift for the
// same reason as AudioEngine+SpatialPitch (LESSONS.md: that file must
// not grow surface area). Ruling AE-2 (2026-09-06): a per-letter
// loudness difference between phoneme recordings is a systematic
// within-arm confound — some letters would simply be louder than others
// for reasons unrelated to the study, along the very vowel/continuant
// line the letter set spans. So every file the engine loads is played at
// a gain that brings its RMS to ONE target, whatever level it was
// recorded or rendered at.
//
// The target is the bundled spatial carrier's own RMS (measured
// 2026-09-06: 16-bit PCM, peak 8231 = −12.0 dBFS, rms/peak 0.5825 →
// 0.1463 full-scale). The verified carrier therefore plays at unity gain
// — nothing about the spatial arm's stimulus changes — and the phoneme
// arm's files are matched to it, which also removes the between-arm
// level difference the thesis records as a limitation.

import AVFoundation
import Foundation
import OSLog

extension AudioEngine {
    /// RMS (full-scale, all channels pooled) every loaded file is
    /// normalised to. See the file header for where the number comes from.
    static let loudnessTargetRMS: Float = 0.1463

    /// Gain clamp. A file more than 18 dB off target is played at the
    /// clamp and logged — it is a production defect
    /// (SOUND_PRODUCTION_SPEC), not something to hide with gain.
    static let loudnessGainRange: ClosedRange<Float> = 0.125...8.0

    private static let loudnessLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "PrimaeNative",
        category: "AudioEngine.loudness")

    /// Cached per URL: the file is decoded once per process, not on every
    /// touch-down (`loadAudioFile` runs at each touch-down and before
    /// every play).
    private static var loudnessGainCache: [URL: Float] = [:]

    /// Full-scale RMS of the whole file, all channels pooled; nil when the
    /// file cannot be read or holds no samples. Opens its OWN reader so the
    /// engine's scheduled `AVAudioFile` keeps its frame position.
    static func fileRMS(at url: URL) -> Float? {
        guard let file = try? AVAudioFile(forReading: url),
              file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channels = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0, channelCount > 0 else { return nil }
        var sum: Double = 0
        for c in 0..<channelCount {
            let p = channels[c]
            for i in 0..<frames { let v = Double(p[i]); sum += v * v }
        }
        let rms = (sum / Double(frames * channelCount)).squareRoot()
        return rms.isFinite ? Float(rms) : nil
    }

    /// Gain that brings the file at `url` to `loudnessTargetRMS`, clamped
    /// to `loudnessGainRange`; 1.0 when the file cannot be measured
    /// (logged — the file then plays as recorded).
    static func loudnessGain(forFileAt url: URL) -> Float {
        if let cached = loudnessGainCache[url] { return cached }
        let gain: Float
        if let rms = fileRMS(at: url), rms > 0 {
            let raw = loudnessTargetRMS / rms
            gain = min(loudnessGainRange.upperBound, max(loudnessGainRange.lowerBound, raw))
            if gain != raw {
                loudnessLog.warning("\(url.lastPathComponent, privacy: .public): rms \(rms, privacy: .public) needs gain \(raw, privacy: .public), clamped to \(gain, privacy: .public) — re-produce the file at the spec's loudness target.")
            } else {
                loudnessLog.debug("\(url.lastPathComponent, privacy: .public): rms \(rms, privacy: .public) → gain \(gain, privacy: .public)")
            }
        } else {
            gain = 1.0
            loudnessLog.error("\(url.lastPathComponent, privacy: .public): could not measure RMS — playing at unity gain.")
        }
        loudnessGainCache[url] = gain
        return gain
    }

    /// Test seam: forget cached measurements.
    static func resetLoudnessCache() { loudnessGainCache.removeAll() }
}
