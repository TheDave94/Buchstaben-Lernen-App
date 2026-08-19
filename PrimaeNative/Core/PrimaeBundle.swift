// PrimaeBundle.swift
// PrimaeNative
//
// One resolver for the SwiftPM-generated resource bundle that carries
// this module's `Resources/` tree.
//
// WHY NOT `Bundle.module`. SwiftPM's generated accessor calls
// `fatalError` when it cannot resolve, which turns a missing resource
// into a launch crash in test hosts. `LetterRepository` documented that
// hazard and hand-rolled around it; so did `LetterRecognizer`,
// separately and differently. This is the shared, non-trapping version.
//
// WHY A PATH PROBE AND NOT `url(forResource:withExtension:)`.
// `.copy("Resources")` preserves the tree verbatim, so
// `GermanLetterRecognizer.mlpackage` ships as a DIRECTORY.
// `Bundle.url(forResource:withExtension:)` is unreliable for
// directory-shaped resources — which is why the recogniser reported
// "not found in any bundle" while the letter loader, which ENUMERATES
// `bundle.resourceURL` instead, resolved the same bundle fine. A direct
// path probe with an existence check does not care whether the resource
// is a file or a directory.

import Foundation

enum PrimaeBundle {

    /// `Bundle(for:)` returns whichever bundle contains the compiled
    /// module: `PrimaeNative.framework` in the app, and the same
    /// framework nested inside `PrimaeNativeTests.xctest` under test.
    /// The resource bundle sits inside it in both layouts.
    private final class Anchor {}

    nonisolated private static let resourceBundleName = "PrimaeNative_PrimaeNative"

    /// The resource bundle, or `.main` when it cannot be located.
    ///
    /// Note what is NOT here: `Bundle(identifier: "PrimaeNative_PrimaeNative")`.
    /// That argument is a CFBundleIdentifier, not a filename — the real
    /// identifier is `primae.PrimaeNative.resources`, so the probe was
    /// dead in both former call sites and had been since it was written.
    /// `nonisolated(unsafe)`: the package sets `-default-isolation
    /// MainActor`, and `Bundle` is not `Sendable`. Written once by a pure
    /// lookup, then only read.
    nonisolated(unsafe) static let resources: Bundle = resolveResourceBundle()

    /// The resolution itself, as a `nonisolated` function. As a
    /// `= { … }()` initialiser the closure took the package's MainActor
    /// default and the compiler rejected a main-actor default value in a
    /// `nonisolated(unsafe)` context — measured at :44, not predicted.
    nonisolated private static func resolveResourceBundle() -> Bundle {
        var anchors: [Bundle] = [Bundle(for: Anchor.self), .main]
        anchors.append(contentsOf: Bundle.allFrameworks)
        anchors.append(contentsOf: Bundle.allBundles)

        for anchor in anchors {
            if anchor.bundleURL.lastPathComponent == resourceBundleName + ".bundle" {
                return anchor
            }
            let nested = anchor.bundleURL.appendingPathComponent(resourceBundleName + ".bundle")
            if FileManager.default.fileExists(atPath: nested.path),
               let bundle = Bundle(url: nested) {
                return bundle
            }
        }
        return .main
    }

    /// URL for a path relative to the resource bundle root, verified
    /// against the filesystem. Returns `nil` rather than a URL that does
    /// not exist, so callers can fall back rather than fail later.
    /// `nonisolated` on the MEMBER, not the enum. Marking the enum
    /// `nonisolated` does NOT make its static members callable from a
    /// nonisolated synchronous context — measured, not assumed: the
    /// isolation error at `LetterRecognizer.swift:257` survived it.
    /// `CoreMLLetterRecognizer` is itself `nonisolated` so the model load
    /// can run on a detached Task, and a filesystem probe has no business
    /// hopping to the main actor to satisfy a package-wide default.
    nonisolated static func resourceURL(_ relativePath: String) -> URL? {
        // `.main` last, and deliberately: the host embeds some resources
        // directly (fonts via `INFOPLIST_KEY_UIAppFonts`), so a lookup that
        // misses the package bundle can still legitimately succeed there.
        // It is a probe INSIDE this resolver rather than a second resolver
        // beside it — one path, watched by one test, so a resource that
        // only resolves by accident cannot hide in a fallback nobody reads.
        let roots = [resources.bundleURL, resources.resourceURL, Bundle.main.resourceURL]
        for root in roots.compactMap({ $0 }) {
            let candidate = root.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// First of several candidate layouts that exists.
    ///
    /// `.copy("Resources")` preserves the tree, `.process` flattens toward
    /// the bundle root, and an Xcode copy phase flattens differently again.
    /// Callers pass the layouts their resource can legitimately ship in,
    /// most-specific first, instead of each hand-rolling the same loop.
    nonisolated static func resourceURL(firstOf relativePaths: [String]) -> URL? {
        for path in relativePaths {
            if let url = resourceURL(path) { return url }
        }
        return nil
    }

    /// Bundle-relative layouts a resource under `Resources/<dir>/` can ship in.
    nonisolated static func layouts(dir: String, name: String, ext: String) -> [String] {
        ["Resources/\(dir)/\(name).\(ext)", "\(dir)/\(name).\(ext)", "\(name).\(ext)"]
    }
}
