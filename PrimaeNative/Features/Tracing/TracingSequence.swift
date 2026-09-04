import Foundation

/// What a cell is "for": currently only `.primary`. A reserved `.silent`
/// case (decorative, untraced letters in a future word mode) was removed
/// on 2026-09-04: it was never constructed, and its name collided with
/// the study's silent AUDIO ARM (`PilotAudioCondition.silent`), which is
/// the only thing that decides whether a session is silent. Reintroduce
/// under a name that cannot be read as an audio state (e.g. `.decorative`).
enum SlotRole: String, Equatable {
    case primary
}

/// How audio fires across a multi-cell sequence. V1 plays the current
/// cell's per-letter audio on each cell advancement; future work can
/// add `.perSequence(file:)` without touching the grid engine.
enum AudioPolicy: Equatable {
    case perCell
}

/// The shape of a sequence's content. `.singleLetter` is the legacy
/// default — a length-1 sequence equivalent to today's app. `.repetition`
/// and `.word` expand into multi-item sequences through `itemLetters`.
enum SequenceKind: Equatable {
    case singleLetter(String)
    case repetition(letter: String, count: Int)
    case word(String)

    var title: String {
        switch self {
        case .singleLetter(let letter):
            return letter
        case .repetition(let letter, let count):
            return "\(letter)×\(max(1, count))"
        case .word(let word):
            return word
        }
    }

    /// The ordered per-cell letters this kind expands to. `.word` splits
    /// the string into Character-based items so multi-scalar graphemes
    /// like "ß" stay as one item. `.repetition` clamps count ≥ 1 so the
    /// grid engine always sees at least one cell.
    var itemLetters: [String] {
        switch self {
        case .singleLetter(let letter):
            return [letter]
        case .repetition(let letter, let count):
            return Array(repeating: letter, count: max(1, count))
        case .word(let word):
            return word.map { String($0) }
        }
    }
}

/// One target slot within a `TracingSequence`. Carries per-cell
/// overrides — script and variant are nil in v1, inherited from the
/// session. `slotRole` is always `.primary` in v1.
struct SequenceItem: Equatable {
    let letter: String
    let scriptOverride: SchriftArt?
    let variantID: String?
    let slotRole: SlotRole

    init(letter: String,
         scriptOverride: SchriftArt? = nil,
         variantID: String? = nil,
         slotRole: SlotRole = .primary) {
        self.letter = letter
        self.scriptOverride = scriptOverride
        self.variantID = variantID
        self.slotRole = slotRole
    }
}

/// An ordered sequence of target letters the child traces left-to-right.
/// Today's single-letter flow becomes a length-1 sequence via
/// `TracingSequence.singleLetter("A")`; repetition and word modes are
/// expressed through `.repetition`/`.word` kinds but share the same
/// underlying engine.
struct TracingSequence: Equatable, Identifiable {
    let id: UUID
    let title: String
    let items: [SequenceItem]
    let audioPolicy: AudioPolicy
    let kind: SequenceKind

    init(id: UUID = UUID(),
         kind: SequenceKind,
         audioPolicy: AudioPolicy = .perCell,
         scriptOverride: SchriftArt? = nil) {
        self.id = id
        self.kind = kind
        self.audioPolicy = audioPolicy
        self.title = kind.title
        self.items = kind.itemLetters.map {
            SequenceItem(letter: $0, scriptOverride: scriptOverride)
        }
    }

    static func singleLetter(_ letter: String,
                             scriptOverride: SchriftArt? = nil) -> TracingSequence {
        TracingSequence(kind: .singleLetter(letter),
                        scriptOverride: scriptOverride)
    }

    static func repetition(_ letter: String,
                           count: Int,
                           scriptOverride: SchriftArt? = nil) -> TracingSequence {
        TracingSequence(kind: .repetition(letter: letter, count: count),
                        scriptOverride: scriptOverride)
    }

    static func word(_ word: String,
                     scriptOverride: SchriftArt? = nil) -> TracingSequence {
        TracingSequence(kind: .word(word), scriptOverride: scriptOverride)
    }
}
