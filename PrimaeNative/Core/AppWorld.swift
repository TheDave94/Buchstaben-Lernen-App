// AppWorld.swift
// PrimaeNative
//
// Top-level navigation for the three-world child UI. The world-
// switcher rail flips between cases. Parent / research surfaces live
// behind a parental gate and aren't reachable from this enum.

import Foundation

/// One of the three child-facing worlds.
enum AppWorld: String, CaseIterable, Identifiable, Sendable {
    /// Buchstaben-Schule — guided four-phase letter learning.
    case schule
    #if !STUDY_BUILD
    /// Schreibwerkstatt — freeform letter and word writing.
    case werkstatt
    /// Meine Fortschritte — child-facing progress / stars / streak.
    case fortschritte
    #endif

    var id: String { rawValue }

    /// SF Symbol used by the world-switcher rail and any in-world chrome.
    var icon: String {
        switch self {
        case .schule:       return "book.fill"
        #if !STUDY_BUILD
        case .werkstatt:    return "pencil.tip"
        case .fortschritte: return "star.fill"
        #endif
        }
    }

    /// Short German label shown underneath the rail icon.
    var label: String {
        switch self {
        case .schule:       return "Schule"
        #if !STUDY_BUILD
        case .werkstatt:    return "Werkstatt"
        case .fortschritte: return "Sterne"
        #endif
        }
    }

    /// Full VoiceOver-friendly German name.
    var accessibilityLabel: String {
        switch self {
        case .schule:       return "Buchstaben-Schule"
        #if !STUDY_BUILD
        case .werkstatt:    return "Schreibwerkstatt"
        case .fortschritte: return "Meine Fortschritte"
        #endif
        }
    }
}
