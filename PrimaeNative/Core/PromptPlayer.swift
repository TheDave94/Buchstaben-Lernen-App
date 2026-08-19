// PromptPlayer.swift
// PrimaeNative
//
// Plays the bundled MP3 phrases the child hears during practice.
// Falls back to AVSpeechSynthesizer when the MP3 for a given key
// isn't bundled, so the app works before
// `scripts/generate_prompts.py` has run. Dynamic per-letter phrases
// (recognition feedback, retrieval correction) bypass this and go
// through the synthesizer directly.

import AudioToolbox
import AVFoundation
import Foundation
import os.log

/// Public surface of `PromptPlayer`. Tests use `NullPromptPlayer` —
/// real AVAudioPlayer setup costs enough wall-clock time (~10–20 ms
/// on simulator) to push rapid-tap tests past the playback debounce.
@MainActor
protocol PromptPlaying: AnyObject {
    func play(_ key: PromptPlayer.PromptKey, fallbackText: String)
    func stop()
    func playSuccessChime()
    func playTapChime()
    func playWrongTapChime()
    func playStrokeTick()
}

/// No-op stub used by tests and previews.
@MainActor
final class NullPromptPlayer: PromptPlaying {
    func play(_ key: PromptPlayer.PromptKey, fallbackText: String) {}
    func stop() {}
    func playSuccessChime() {}
    func playTapChime() {}
    func playWrongTapChime() {}
    func playStrokeTick() {}
}

@MainActor
final class PromptPlayer: PromptPlaying {

    /// Stable identifiers for pre-recorded phrases. Raw value is the
    /// filename stem in `Resources/Prompts/<key>.mp3` — keep in sync
    /// with the PROMPTS table in `scripts/generate_prompts.py`.
    enum PromptKey: String, CaseIterable {
        case phaseObserve   = "phase_observe"
        case phaseDirect    = "phase_direct"
        case phaseGuided    = "phase_guided"
        case phaseFreeWrite = "phase_freewrite"
        case praise4 = "praise_4"
        case praise3 = "praise_3"
        case praise2 = "praise_2"
        case praise1 = "praise_1"
        case praise0 = "praise_0"
        case paperShow   = "paper_show"
        case paperWrite  = "paper_write"
        case paperAssess = "paper_assess"
        case retrievalQuestion = "retrieval_question"
        case celebration = "celebration"
    }

    private let speech: SpeechSynthesizing
    private var player: AVAudioPlayer?
    /// Lazy cache of effect-sound players. AVAudioPlayer inherits the
    /// AudioEngine's `.playback` session so these effects bypass the
    /// iPad ringer switch. Lazy because pre-loading shifts timing
    /// enough to push rapid-tap tests past the playback debounce.
    private var effectPlayers: [String: AVAudioPlayer] = [:]
    /// Effect names that failed to load — cached so the bundle isn't
    /// re-probed on every play call.
    private var missingEffects: Set<String> = []
    private let log = Logger(subsystem: "buchstaben.primae", category: "prompts")

    init(fallbackSpeech: SpeechSynthesizing) {
        self.speech = fallbackSpeech
    }

    /// Play the prompt audio for `key`, falling back to
    /// `speech.speak(fallbackText)` when the bundled MP3 is missing.
    /// Stops BOTH pipelines on entry — `AVSpeechSynthesizer.speak()`
    /// queues utterances, so without `speech.stop()` rapid letter-
    /// skipping stacks the phase cue N+1 deep.
    func play(_ key: PromptKey, fallbackText: String) {
        player?.stop()
        speech.stop()
        guard let url = Self.locate(key) else {
            log.info("Prompt missing for '\(key.rawValue, privacy: .public)' — falling back to TTS.")
            speech.speak(fallbackText)
            return
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            p.play()
            player = p
        } catch {
            log.error("AVAudioPlayer failed for '\(key.rawValue, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            speech.speak(fallbackText)
        }
    }

    func stop() {
        player?.stop()
        speech.stop()
    }

    /// Letter-completion celebration. Uses a system sound so it fires
    /// even while the letter-sound pipeline is reconfiguring.
    func playSuccessChime() {
        AudioServicesPlaySystemSound(1322)
    }

    /// Correct dot-tap click. AVAudioPlayer route bypasses the device
    /// mute switch via the AudioEngine's `.playback` session.
    func playTapChime() {
        playEffect(name: "tap", systemFallback: 1104)
    }

    /// Wrong-tap buzz — same mute-bypass route, lower pitched.
    func playWrongTapChime() {
        playEffect(name: "tap_wrong", systemFallback: 1053)
    }

    /// Beat played when StrokeTracker flips a stroke to complete.
    func playStrokeTick() {
        playEffect(name: "tick_stroke", systemFallback: nil)
    }

    /// Lazy effect playback: load + cache on first call. Falls back
    /// to `systemFallback` when the asset isn't bundled; pass nil to
    /// skip silently.
    private func playEffect(name: String, systemFallback: SystemSoundID?) {
        if let p = effectPlayers[name] {
            p.currentTime = 0
            p.play()
            return
        }
        if missingEffects.contains(name) {
            if let id = systemFallback { AudioServicesPlaySystemSound(id) }
            return
        }
        if let p = loadEffectPlayer(name: name) {
            effectPlayers[name] = p
            p.play()
        } else {
            missingEffects.insert(name)
            if let id = systemFallback { AudioServicesPlaySystemSound(id) }
        }
    }

    /// Bundle-relative layouts for an effect sound. Shared with
    /// `ResourceResolutionTests`, so the test probes the list the player
    /// walks rather than a copy of it that can drift.
    static func effectLayouts(_ name: String) -> [String] {
        PrimaeBundle.layouts(dir: "Prompts", name: name, ext: "wav")
    }

    private func loadEffectPlayer(name: String) -> AVAudioPlayer? {
        guard let url = PrimaeBundle.resourceURL(firstOf: Self.effectLayouts(name)),
              let p = try? AVAudioPlayer(contentsOf: url) else {
            log.info("\(name, privacy: .public).wav not bundled — falling back to system sound.")
            return nil
        }
        p.prepareToPlay()
        return p
    }

    // MARK: - Bundle lookup

    /// Probe `<key>.mp3` across the layouts SPM/Xcode bundling produces.
    ///
    /// Was `Bundle.module` + `url(forResource:)`. `Bundle.module` calls
    /// `fatalError` when it cannot resolve, which turns a missing resource
    /// into a launch crash in a test host — the hazard `PrimaeBundle` was
    /// extracted to remove (`cb7291d`). One resolver, so there is no second
    /// path for a lookup to succeed through by accident.
    static func locate(_ key: PromptKey) -> URL? {
        PrimaeBundle.resourceURL(
            firstOf: PrimaeBundle.layouts(dir: "Prompts", name: key.rawValue, ext: "mp3"))
    }
}
