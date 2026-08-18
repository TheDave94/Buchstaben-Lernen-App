// Fonts.swift
// PrimaeNative — Theme
//
// Type ramp + font-family helpers wrapping the bundled "Primae" /
// "PrimaeText" / "Playwrite AT" families. Fonts live in
// `Resources/Fonts/` and are loaded by `PrimaeFonts.registerAll()`
// (the SPM bundle path); `INFOPLIST_KEY_UIAppFonts` covers main-
// bundle copies. Type scale mirrors `--fz-*` in
// `design-system/colors_and_type.css`.

import SwiftUI

// MARK: - Sizes

enum FontSize {
    /// 13 pt — caption / metadata.
    static let xs: CGFloat   = 13
    /// 15 pt — small body / dense list.
    static let sm: CGFloat   = 15
    /// 17 pt — base body / default label.
    static let base: CGFloat = 17
    /// 20 pt — emphasised body / button label.
    static let md: CGFloat   = 20
    /// 24 pt — section heading.
    static let lg: CGFloat   = 24
    /// 32 pt — page heading / world title.
    static let xl: CGFloat   = 32
    /// 44 pt — display heading.
    static let xxl: CGFloat  = 44
    /// 64 pt — hero display.
    static let xxxl: CGFloat = 64
    /// 96 pt — splash / celebrate display.
    static let xxxxl: CGFloat = 96
    /// 220 pt — the giant traceable letter on the canvas.
    static let glyph: CGFloat = 220
}

// MARK: - Family helpers

extension Font {
    /// Display family (Primae). Constructs the Font directly with the
    /// PostScript name; we don't chain `.weight(weight)` because the
    /// bundled OTFs aren't variable fonts and SwiftUI logs a "Unable
    /// to update Font Descriptor's weight" bug-report on every render
    /// when the weight axis is nudged on a non-variable custom font.
    static func display(_ size: CGFloat,
                        weight: Font.Weight = .bold) -> Font {
        Font.custom(primaePostScriptName(for: weight, italic: false), size: size)
    }

    /// Text-grade companion family (PrimaeText) — optimised for
    /// smaller sizes and longer prose.
    static func body(_ size: CGFloat,
                     weight: Font.Weight = .regular) -> Font {
        Font.custom(primaeTextPostScriptName(for: weight, italic: false), size: size)
    }

    /// Austrian school cursive (Playwrite AT) — the *real* cursive
    /// specimen for Schreibschrift. Only one weight is bundled.
    static func cursive(_ size: CGFloat) -> Font {
        Font.custom("PlaywriteAT-Regular", size: size)
    }
}

// MARK: - Private — PostScript-name resolution

private func primaePostScriptName(for weight: Font.Weight, italic: Bool) -> String {
    let stem = "Primae"
    let cursive = italic ? "Cursive" : ""
    return weightSuffix(for: weight, stem: stem, cursiveSuffix: cursive)
}

private func primaeTextPostScriptName(for weight: Font.Weight, italic: Bool) -> String {
    let stem = "PrimaeText"
    let cursive = italic ? "Cursive" : ""
    return weightSuffix(for: weight, stem: stem, cursiveSuffix: cursive)
}

/// PostScript-name builder. Files are named e.g. `Primae-Light.otf`,
/// `Primae-Cursive.otf` (regular cursive, no weight prefix),
/// `PrimaeText-SemiboldCursive.otf`.
private func weightSuffix(for weight: Font.Weight, stem: String, cursiveSuffix: String) -> String {
    // No Medium / Heavy / Black face in the bundle — round to nearest.
    let weightToken: String
    switch weight {
    case .ultraLight, .thin, .light:
        weightToken = "Light"
    case .regular, .medium:
        weightToken = cursiveSuffix.isEmpty ? "Regular" : ""  // "Primae-Cursive"
    case .semibold:
        weightToken = "Semibold"
    case .bold, .heavy, .black:
        weightToken = "Bold"
    default:
        weightToken = "Regular"
    }
    let combined = weightToken + cursiveSuffix
    if combined.isEmpty { return "\(stem)-Regular" }
    return "\(stem)-\(combined)"
}
