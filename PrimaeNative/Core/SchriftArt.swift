import Foundation

/// Handwriting scripts the app can render. `druckschrift` is Primae (print)
/// and `schreibschrift` is Playwrite AT (cursive); the other three are
/// Bundesland-specific German school scripts wired up for the future but
/// not yet bundled as fonts.
public enum SchriftArt: String, Codable, CaseIterable {
    case druckschrift
    case schreibschrift
    case grundschrift
    // The raw value retains the original misspelling
    // ("vereinfachteAusgangschrift", missing the genitive-s) so
    // persisted user-default selections and bundled font/strokes
    // filenames keep resolving without a migration.
    case vereinfachteAusgangsschrift = "vereinfachteAusgangschrift"
    case schulausgangsschrift

    /// Font resource filename (without extension). PrimaeLetterRenderer
    /// probes `.otf` then `.ttf` so the stem stays extension-agnostic.
    public var fontFileName: String {
        switch self {
        case .druckschrift:              return "Primae-Regular"
        // Playwrite AT (Austrian cursive, SIL OFL 1.1). Not an exact
        // Schulschrift 1995 clone, hence the generic UI label.
        case .schreibschrift:            return "PlaywriteAT-Regular"
        case .grundschrift:              return "Grundschrift-Regular"
        case .vereinfachteAusgangsschrift: return "VereinfachteAusgangschrift-Regular"
        case .schulausgangsschrift:      return "Schulausgangsschrift-Regular"
        }
    }

    /// German display label shown in the UI.
    public var displayName: String {
        switch self {
        case .druckschrift:              return "Druckschrift"
        case .schreibschrift:            return "Schreibschrift"
        case .grundschrift:              return "Grundschrift"
        case .vereinfachteAusgangsschrift: return "Vereinfachte Ausgangsschrift"
        case .schulausgangsschrift:      return "Schulausgangsschrift"
        }
    }

    /// The variantID `LetterRepository.loadVariantStrokes` uses to
    /// locate this script's stroke JSON (e.g. "schulschrift" →
    /// `Letters/Regular/<letter>/strokes_schulschrift.json`). nil for
    /// `.druckschrift` since it uses the primary `strokes.json`.
    /// To add a new script: add an enum case, return its variantID
    /// here, ship `strokes_<id>.json` alongside the font.
    public var bundleVariantID: String? {
        switch self {
        case .druckschrift:              return nil
        case .schreibschrift:            return "schulschrift"
        case .grundschrift:              return "grundschrift"
        case .vereinfachteAusgangsschrift: return "vereinfachteAusgangschrift"
        case .schulausgangsschrift:      return "schulausgangsschrift"
        }
    }
}
