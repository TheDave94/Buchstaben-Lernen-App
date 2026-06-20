// ThesisCondition.swift
// PrimaeNative
//
// A/B test infrastructure for thesis evaluation.
// Controls which pedagogical features are active so learning outcomes
// can be compared across conditions.

import Foundation

/// Pedagogical condition for thesis A/B evaluation.
///
/// Non-enrolled installs always get `.threePhase`. The case name
/// predates the `direct` phase; rawValues are preserved for backward-
/// compatible decode of historical dashboard JSON.
enum ThesisCondition: String, Codable, CaseIterable, Sendable {
    /// Full four-phase flow: observe → direct → guided → freeWrite.
    /// Case stays named `threePhase` to keep the Codable rawValue stable.
    case threePhase

    /// Guided tracing only — skips observe, direct, and freeWrite phases.
    case guidedOnly

    /// Guided tracing with fixed difficulty — no adaptive checkpoint radius.
    case control

    /// German display label for the parent dashboard and thesis reports.
    var displayName: String {
        switch self {
        case .threePhase: return "Vier Phasen"
        case .guidedOnly: return "Nur Nachspuren"
        case .control:    return "Kontrollgruppe"
        }
    }

    /// The default condition for this install. Non-enrolled installs
    /// get `.threePhase`; enrolled installs get the stable UUID-derived
    /// arm. A researcher-set override wins over modulo derivation.
    static var defaultForInstall: ThesisCondition {
        // Manual override beats byte-modulo so small cohorts (n < 30)
        // can hit exact balance instead of expectation imbalance.
        if let manual = ParticipantStore.conditionOverride {
            return manual
        }
        return ParticipantStore.isEnrolled
            ? .assign(participantId: ParticipantStore.participantId)
            : .threePhase
    }

    /// Deterministically assign a participant to a condition from a
    /// stable UUID. Same UUID → same condition, so assignment can't
    /// drift mid-study. Invoked only when `isEnrolled == true`.
    static func assign(participantId: UUID) -> ThesisCondition {
        // First UUID byte is uniformly distributed for v4 UUIDs.
        let byte = participantId.uuid.0
        switch Int(byte) % ThesisCondition.allCases.count {
        case 0:  return .threePhase
        case 1:  return .guidedOnly
        default: return .control
        }
    }
}

/// Persists a per-install participant UUID for stable A/B cohort
/// assignment. Survives app updates via UserDefaults; a clean reinstall
/// resets the assignment (acceptable for thesis pilots — no iCloud
/// entitlement is configured).
enum ParticipantStore {
    private static let key = "de.flamingistan.primae.participantId"
    private static let enrolledKey = "de.flamingistan.primae.thesisEnrolled"
    /// Timestamp captured when `isEnrolled` flips on. The CSV exporter
    /// filters phase-session rows older than this date so pre-enrollment
    /// activity doesn't pollute the `.threePhase` arm.
    private static let enrolledAtKey = "de.flamingistan.primae.thesisEnrolledAt"
    private static let conditionOverrideKey = "de.flamingistan.primae.thesisConditionOverride"
    private static let audioConditionOverrideKey = "de.flamingistan.primae.audioConditionOverride"

    /// Researcher-set thesis arm. When non-nil, `defaultForInstall`
    /// returns this verbatim, bypassing the byte-modulo assignment.
    static var conditionOverride: ThesisCondition? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: conditionOverrideKey) else { return nil }
            return ThesisCondition(rawValue: raw)
        }
        set {
            if let value = newValue {
                UserDefaults.standard.set(value.rawValue, forKey: conditionOverrideKey)
            } else {
                UserDefaults.standard.removeObject(forKey: conditionOverrideKey)
            }
        }
    }

    /// Researcher-set pilot audio arm. When non-nil,
    /// `PilotAudioCondition.defaultForInstall` returns this verbatim,
    /// bypassing the byte-modulo assignment. Independent of
    /// `conditionOverride` (the pedagogical axis) — the two override keys
    /// can be set separately.
    static var audioConditionOverride: PilotAudioCondition? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: audioConditionOverrideKey) else { return nil }
            return PilotAudioCondition(rawValue: raw)
        }
        set {
            if let value = newValue {
                UserDefaults.standard.set(value.rawValue, forKey: audioConditionOverrideKey)
            } else {
                UserDefaults.standard.removeObject(forKey: audioConditionOverrideKey)
            }
        }
    }

    /// The participant's UUID, generated on first call and persisted.
    static var participantId: UUID {
        if let raw = UserDefaults.standard.string(forKey: key),
           let uuid = UUID(uuidString: raw) {
            return uuid
        }
        let new = UUID()
        UserDefaults.standard.set(new.uuidString, forKey: key)
        return new
    }

    /// Whether this install participates in the thesis A/B study.
    /// When `false`, `TracingDependencies.live` pins the condition to
    /// `.threePhase`.
    static var isEnrolled: Bool {
        get { UserDefaults.standard.bool(forKey: enrolledKey) }
        set {
            let wasEnrolled = isEnrolled
            UserDefaults.standard.set(newValue, forKey: enrolledKey)
            // Stamp the enrolment timestamp the first time enrolment
            // flips on. Don't overwrite on toggle-off-then-on or
            // legitimate study data would be filtered as pre-enrolment.
            if newValue, !wasEnrolled, enrolledAt == nil {
                UserDefaults.standard.set(Date(), forKey: enrolledAtKey)
            }
        }
    }

    /// Wall-clock time the install joined the study. `nil` for never-
    /// enrolled installs. The CSV exporter discards phase-session rows
    /// older than this date.
    static var enrolledAt: Date? {
        UserDefaults.standard.object(forKey: enrolledAtKey) as? Date
    }
}
