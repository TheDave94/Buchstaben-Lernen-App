// SpeechSynthesizer.swift
// PrimaeNative
//
// German voice playback for child-facing verbal feedback. Built on
// AVSpeechSynthesizer for on-device German voices (Anna/Petra/Markus
// when installed) — no network calls, no API keys.
//
// PromptPlayer is the canonical path for the static recorded phrases;
// this synthesizer owns the dynamic templated phrases (recognition
// outcomes, retrieval correction) and acts as the fallback for
// PromptPlayer when an MP3 is missing.

import AVFoundation
import Foundation

// MARK: - Protocol seam

/// Async-free TTS API for child-facing verbal feedback. Tests use
/// `NullSpeechSynthesizer` which records spoken lines.
@MainActor
protocol SpeechSynthesizing {
    /// Speak `text` in German. Utterances queue natively — call
    /// `stop()` first to interrupt.
    func speak(_ text: String)
    /// Halt any in-flight or queued utterance.
    func stop()
    /// Parent-tunable rate; `nil` restores the default.
    func setRate(_ rate: Float?)
}

extension SpeechSynthesizing {
    func setRate(_ rate: Float?) {}
}

// MARK: - Production implementation

/// AVSpeechSynthesizer-backed TTS. Picks the best installed German
/// voice at instantiation. If no German voice is present the
/// synthesizer silently no-ops.
@MainActor
final class AVSpeechSpeechSynthesizer: SpeechSynthesizing {

    private let synthesizer = AVSpeechSynthesizer()
    private let germanVoice: AVSpeechSynthesisVoice?

    /// Default 0.5 reads too fast for a 5-year-old; 0.42 is comfortably
    /// slow without sounding artificially dragged.
    var rate: Float = 0.42

    func setRate(_ rate: Float?) {
        self.rate = rate ?? 0.42
    }
    /// Slight upward shift to match the warm child-friendly tone the
    /// recorded letter audio uses.
    var pitchMultiplier: Float = 1.05

    init() {
        let germanVoices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("de") }
        let enhanced = germanVoices.first(where: { $0.quality == .enhanced })
        self.germanVoice = enhanced
            ?? germanVoices.first
            ?? AVSpeechSynthesisVoice(language: "de-DE")
        // Default `usesApplicationAudioSession = true` shares the
        // AudioEngine's `.playback` session. Disabling it would put
        // the synth on a private session incompatible with the letter-
        // sound pipeline.
    }

    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = germanVoice
        utterance.rate = rate
        utterance.pitchMultiplier = pitchMultiplier
        // 0.9 keeps the spoken feedback slightly under the AudioEngine's
        // letter sound so the child hears both layered.
        utterance.volume = 0.9
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }
}

// MARK: - Null implementation (tests, previews)

/// Records every spoken line for test assertions; drives no audio.
@MainActor
final class NullSpeechSynthesizer: SpeechSynthesizing {
    private(set) var spokenLines: [String] = []
    private(set) var stopCount: Int = 0

    func speak(_ text: String) { spokenLines.append(text) }
    func stop() { stopCount += 1 }
    func clear() { spokenLines.removeAll(); stopCount = 0 }
}

// MARK: - Phrase library

/// Centralised German feedback phrases — co-locating every phrase the
/// child hears keeps view layout free of hardcoded strings.
enum ChildSpeechLibrary {

    /// Phase entry prompts. Imperative + short so the utterance
    /// finishes before the child plausibly touches the canvas
    /// (AudioEngine's per-touch session reconfiguration cuts TTS short).
    static func phaseEntry(_ phase: LearningPhase) -> String {
        switch phase {
        case .observe:    return "Pass jetzt gut auf!"
        case .direct:     return "Tipp die Punkte der Reihe nach an."
        case .guided:     return "Fahr die Linie nach."
        case .freeWrite:  return "Und jetzt ohne Hilfe."
        }
    }

    /// Praise spoken on guided / freeWrite stroke completion. 0-star
    /// stays warm — "probier nochmal" without judgement.
    static func praise(starsEarned: Int) -> String {
        switch starsEarned {
        case 4: return "Wow, das war perfekt! Super gemacht."
        case 3: return "Toll gemacht!"
        case 2: return "Gut gemacht!"
        case 1: return "Schon gut! Probier's nochmal."
        default: return "Probier's gleich nochmal."
        }
    }

    /// Recognition badge announcement. Corrections use imperative
    /// phrasing ("schreib nochmal ein A") — a 5-year-old needs a
    /// concrete next action.
    static func recognition(_ result: RecognitionResult, expected: String) -> String {
        if result.isCorrect {
            if result.confidence > 0.7 {
                return "Du hast ein \(expected) geschrieben! Super!"
            } else {
                return "Das sieht aus wie ein \(expected). Gut gemacht!"
            }
        }
        if result.confidence > 0.7 {
            return "Das sieht eher nach \(result.predictedLetter) aus. Schreib nochmal ein \(expected)."
        }
        // Low-confidence misses stay silent at the badge level. Caller
        // is expected to gate on confidence before speaking.
        return ""
    }

    /// Paper-transfer prompts spoken alongside the matching screen.
    static let paperTransferShow = "Schau dir den Buchstaben gut an."
    static let paperTransferWrite = "Jetzt schreibst du den Buchstaben auf Papier."
    static let paperTransferAssess = "Wie ist dein Buchstabe geworden?"

    /// Spaced-retrieval modal headline — spoken on appear.
    static let retrievalQuestion = "Welchen Buchstaben hörst du?"

    /// Spoken after every letter completes. The on-screen star row
    /// carries the gradation; audio is always a warm "Super gemacht!".
    static let celebration = "Super gemacht!"

    // MARK: - PromptPlayer mapping

    /// Map a learning phase to the PromptKey for its bundled MP3.
    static func phaseEntryPromptKey(_ phase: LearningPhase) -> PromptPlayer.PromptKey {
        switch phase {
        case .observe:   return .phaseObserve
        case .direct:    return .phaseDirect
        case .guided:    return .phaseGuided
        case .freeWrite: return .phaseFreeWrite
        }
    }

}
