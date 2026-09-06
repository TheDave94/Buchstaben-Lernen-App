//
//  AudioLoudnessTests.swift
//  PrimaeNativeTests
//
//  Ruling AE-2 (2026-09-06): every file the engine loads plays at one
//  RMS. Driven, not read: two synthetic files 12 dB apart must come out
//  at the same level after the gain, and the bundled carrier — whose
//  RMS defines the target — must play at unity. Pure file measurement;
//  no AVAudioEngine, so it runs on the simulator.
//

import Testing
import Foundation
import AVFoundation
@testable import PrimaeNative

@MainActor
struct AudioLoudnessTests {

    /// Writes a mono 44.1 kHz float WAV of a 440 Hz sine at the given
    /// peak amplitude (RMS = peak / √2) and returns its URL.
    private func sineFile(peak: Float, seconds: Double = 0.5) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("loudness-\(peak)-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(44_100 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let p = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            p[i] = peak * sin(2 * .pi * 440 * Float(i) / 44_100)
        }
        try file.write(from: buffer)
        return url
    }

    @Test("two files 12 dB apart play at the same RMS after the gain")
    func gainEqualisesLevels() throws {
        AudioEngine.resetLoudnessCache()
        let loud  = try sineFile(peak: 0.8)   // rms 0.566
        let quiet = try sineFile(peak: 0.2)   // rms 0.141
        defer { try? FileManager.default.removeItem(at: loud); try? FileManager.default.removeItem(at: quiet) }
        let rmsLoud  = try #require(AudioEngine.fileRMS(at: loud))
        let rmsQuiet = try #require(AudioEngine.fileRMS(at: quiet))
        // Failure half: as recorded, the two differ by 4× (12 dB).
        #expect(abs(rmsLoud / rmsQuiet - 4.0) < 0.05, "fixture: \(rmsLoud) vs \(rmsQuiet)")
        let gLoud  = AudioEngine.loudnessGain(forFileAt: loud)
        let gQuiet = AudioEngine.loudnessGain(forFileAt: quiet)
        // Back: both land on the target within 1 %.
        let target = AudioEngine.loudnessTargetRMS
        #expect(abs(rmsLoud * gLoud - target) / target < 0.01, "loud: \(rmsLoud * gLoud) vs \(target)")
        #expect(abs(rmsQuiet * gQuiet - target) / target < 0.01, "quiet: \(rmsQuiet * gQuiet) vs \(target)")
        #expect(gLoud < 1 && gQuiet > 1)
    }

    /// AE-2a: onset and decay must not drag the measured level down.
    /// A file with 30 % linear ramp-in and ramp-out around a steady
    /// middle measures as its middle, not as its whole-file average.
    @Test("the RMS is taken over the steady state, not onset and decay")
    func steadyStateExcludesOnsetAndDecay() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("envelope-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = 44_100
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let p = buffer.floatChannelData![0]
        let peak: Float = 0.5
        for i in 0..<frames {
            let t = Float(i) / Float(frames)
            let env: Float = t < 0.3 ? t / 0.3 : (t > 0.7 ? (1 - t) / 0.3 : 1)
            p[i] = peak * env * sin(2 * .pi * 440 * Float(i) / 44_100)
        }
        try file.write(from: buffer)
        let measured = try #require(AudioEngine.fileRMS(at: url))
        let steady: Float = peak / Float(2).squareRoot()            // 0.354
        // Whole-file RMS of this envelope: mean square = peak²/2 · (0.4 + 2·0.3/3) = peak²/2 · 0.6
        let wholeFile: Float = steady * Float(0.6).squareRoot()     // 0.274
        // The −6 dB gate keeps the upper halves of the ramps (env ≥ 0.5):
        // expected ≈ 0.906 · steady for this envelope (computed by hand:
        // mean square (0.4·1 + 0.3·0.583)/0.7 = 0.821). Whole-file would
        // be 0.775 · steady.
        #expect(abs(measured - steady) / steady < 0.12, "steady-state rms \(measured) should be ≈ 0.91 × \(steady)")
        #expect(measured > wholeFile * 1.10, "whole-file rms \(wholeFile) must NOT be what is measured; got \(measured)")
    }

    @Test("the bundled carrier defines the target and plays at unity")
    func carrierIsUnity() throws {
        AudioEngine.resetLoudnessCache()
        let url = try #require(SpatialSonification.carrierToneURL())
        let rms = try #require(AudioEngine.fileRMS(at: url))
        let gain = AudioEngine.loudnessGain(forFileAt: url)
        #expect(abs(gain - 1.0) < 0.02, "carrier rms \(rms) → gain \(gain); the target is the carrier's own RMS")
    }

    @Test("a file far off target is clamped and an unreadable one plays at unity")
    func clampAndFallback() throws {
        AudioEngine.resetLoudnessCache()
        let whisper = try sineFile(peak: 0.005)   // rms 0.0035 → raw gain ≈ 41 → clamped 8
        defer { try? FileManager.default.removeItem(at: whisper) }
        #expect(AudioEngine.loudnessGain(forFileAt: whisper) == AudioEngine.loudnessGainRange.upperBound)
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString).wav")
        #expect(AudioEngine.loudnessGain(forFileAt: missing) == 1.0)
    }

    @Test("the gain is measured once per file")
    func gainIsCached() throws {
        AudioEngine.resetLoudnessCache()
        let url = try sineFile(peak: 0.5)
        let first = AudioEngine.loudnessGain(forFileAt: url)
        try FileManager.default.removeItem(at: url)   // a re-measure would now fail → 1.0
        #expect(AudioEngine.loudnessGain(forFileAt: url) == first)
    }
}
