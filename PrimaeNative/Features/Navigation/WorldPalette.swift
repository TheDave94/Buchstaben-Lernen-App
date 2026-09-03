// WorldPalette.swift
// PrimaeNative
//
// World tints + chrome surface tokens. Forwards into the Primae
// design system (`Theme/Colors.swift`), so values flip light/dark.

import SwiftUI

enum WorldPalette {

    /// Per-world soft background tint. The spec is a single soft
    /// tinted band over the paper canvas; we keep the LinearGradient
    /// signature so existing `.background(...)` call sites are unchanged.
    static func background(for world: AppWorld) -> LinearGradient {
        let soft = softTint(for: world)
        return LinearGradient(
            colors: [soft, Color.paperDeep],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    /// Primary accent — rail icons, phase dots, sticker buttons,
    /// any active-state chrome.
    static func accent(for world: AppWorld) -> Color {
        switch world {
        case .schule:       return .schule
        #if !STUDY_BUILD
        case .werkstatt:    return .werkstatt
        case .fortschritte: return .fortschritte
        #endif
        }
    }

    /// Soft tint — start of the hero-band gradient and the inactive
    /// background of rail buttons.
    static func softTint(for world: AppWorld) -> Color {
        switch world {
        case .schule:       return .schuleSoft
        #if !STUDY_BUILD
        case .werkstatt:    return .werkstattSoft
        case .fortschritte: return .fortschritteSoft
        #endif
        }
    }
}

// MARK: - Shared surface tokens

/// Back-compat namespace pointing at the Primae design tokens. Values
/// auto-resolve light/dark via the underlying `Color.*`.
enum AppSurface {
    /// Card / pill body — bright surface over `--paper-deep`.
    static let card     = Color.paper
    /// Hairline border around `card`.
    static let cardEdge = Color.paperEdge
    /// Subdued body label — replaces `.secondary` on pastel/paper
    /// backgrounds where the system grey washes out.
    static let prompt   = Color.ink
    /// Caption-weight label — slightly lighter than `prompt`.
    static let caption  = Color.inkSoft
    /// Mastered-letter tile fill — `--success-soft`. Used in the
    /// gallery and picker so mastered letters look identical
    /// everywhere.
    static let mastered = Color.successSoft
    /// Glyph foreground paired with `mastered`.
    static let masteredText = Color.success
    /// `WorldSwitcherRail` paper band — both stops on `paperDeep`-
    /// adjacent so the gradient reads as a flat paper band.
    static let railTop    = Color.paper
    static let railBottom = Color.paperDeep
    /// Unified gold / star tint — routes through `--star`.
    static let starGold = Color.star
}
