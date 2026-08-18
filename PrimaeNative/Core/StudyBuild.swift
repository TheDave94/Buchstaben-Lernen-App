// StudyBuild.swift
// PrimaeNative
//
// The one place that knows whether this binary is a study build.
//
// `STUDY_BUILD` is NOT set by the Xcode project: a project-level
// `SWIFT_ACTIVE_COMPILATION_CONDITIONS` reaches the app target but
// NOT this SwiftPM package target (measured, spike ed055db —
// app=ON / package=OFF). Study builds therefore come from the
// xcodebuild command-line override in `scripts/build_study.sh`,
// which does reach every target.
//
// That leaves one trap: selecting the Primae-Study scheme in Xcode
// and pressing ⌘R would compile the app half out and leave the
// package half fully intact — a binary that looks like a study build
// and is not. The build-identity symbols at the bottom of this file
// close it, and they carry the binary's identity as well.
//
// Exactly one of `primae_build_identity_study` /
// `primae_build_identity_normal` is compiled, and EVERY app build
// configuration names its own with `-u`. That makes the symbol a link
// ROOT: it is present because the link would otherwise have failed,
// not because something in the app happens to reference it. Two
// consequences worth stating, because the first attempt at this got
// both wrong:
//
//   1. The identity cannot be refactored away. Deleting the symbol, or
//      compiling the package's other half, breaks the build — in Xcode
//      and on CI, in BOTH directions. A string literal read only by a
//      view body carries no such guarantee; it attests to nothing the
//      linker had to agree with.
//   2. The check is `nm`, not `strings`. Symbol presence is a fact the
//      linker enforced; a literal's presence is an artefact of how the
//      compiler happened to emit and the linker happened to keep it.

import Foundation

public enum StudyBuild {
    /// Whether the non-study surfaces were compiled out of this binary.
    public static var isActive: Bool {
        #if STUDY_BUILD
        return true
        #else
        return false
        #endif
    }

    /// Human-readable build identity, for display only (the parent-area
    /// banner reads it).
    ///
    /// Do NOT attest to a binary's identity with this. It is a Swift
    /// string literal whose presence depends on emission and linking
    /// details rather than on anything the linker was required to
    /// enforce — a scan for it reported a study binary as "not a study
    /// build" while the link-time guard simultaneously proved the flag
    /// had arrived. The build-identity symbols at the bottom of this
    /// file are the attestable form.
    public static var marker: String {
        #if STUDY_BUILD
        return "PRIMAE_BUILD_STUDY"
        #else
        return "PRIMAE_BUILD_NORMAL"
        #endif
    }

    /// Default for `studyMode` when the device has no stored value.
    ///
    /// ON in a study build (B2): in a binary where the non-study
    /// surfaces do not exist there is no reason for it to be off, and
    /// a proctor who forgets the toggle would otherwise run an
    /// unconstrained session that looks fine. The toggle survives for
    /// device prep, not for switching the study off.
    public static var studyModeDefault: Bool { isActive }

    /// Resolves the effective `studyMode` for a device: a stored value
    /// wins, otherwise the build default applies.
    ///
    /// Split out of `TracingDependencies`' default argument so it can
    /// be tested against a scratch `UserDefaults` — building a real
    /// `TracingDependencies` would construct a live `AudioEngine`,
    /// which is what the headless-simulator TestApp bypass exists to
    /// avoid (see docs/LESSONS.md).
    /// UserDefaults key holding the device's stored `studyMode`. One
    /// declaration so the resolver, the proctor toggle, and the tests
    /// cannot drift apart on the string.
    public static let studyModeDefaultsKey = "de.flamingistan.primae.studyMode"

    public static func resolveStudyMode(
        in defaults: UserDefaults = .standard,
        key: String = StudyBuild.studyModeDefaultsKey
    ) -> Bool {
        guard defaults.object(forKey: key) != nil else { return studyModeDefault }
        return defaults.bool(forKey: key)
    }
}

// MARK: - Build identity (link-enforced)

// `@_cdecl` gives these stable, unmangled symbol names for `-u` to
// reference. Neither is ever called; both exist to be found by the
// linker and then by `nm`. See the file header for why identity is
// carried as a symbol rather than as a string.
//
// Symmetry is the point. Naming only the study half would let a normal
// binary assert nothing about itself, which is exactly the hole that
// let a study binary fail its own identity check while the normal one
// passed.

#if STUDY_BUILD
@_cdecl("primae_build_identity_study")
public func primaeBuildIdentityStudy() {}
#else
@_cdecl("primae_build_identity_normal")
public func primaeBuildIdentityNormal() {}
#endif
