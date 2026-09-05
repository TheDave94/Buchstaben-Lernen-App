// FontRegistration.swift
// PrimaeNative — Theme
//
// Register the bundled Primae / PrimaeText / Playwrite AT fonts with
// CoreText. The fonts ship inside the SPM resource bundle
// (`Bundle.module`), not the main bundle, so the `UIAppFonts`
// Info.plist key can't reach them — we register programmatically with
// `CTFontManagerRegisterFontsForURLs`. Call `PrimaeFonts.registerAll()`
// once at app launch (host app's `App.init()`). Idempotent.

import CoreText
import Foundation
import os.log

public enum PrimaeFonts {

    /// Bundled font filenames (no extension). Keep in sync with the
    /// files in `PrimaeNative/Resources/Fonts/` and
    /// `INFOPLIST_KEY_UIAppFonts` in `Primae.xcodeproj`.
    /// `internal`, not `private`: `ResourceResolutionTests` asserts every
    /// entry resolves. A test with its own copy of this list proves the
    /// copy, not the app.
    static let registrations: [(name: String, ext: String)] = [
        ("Primae-Light",                "otf"),
        ("Primae-LightCursive",         "otf"),
        ("Primae-Semilight",            "otf"),
        ("Primae-SemilightCursive",     "otf"),
        ("Primae-Regular",              "otf"),
        ("Primae-Cursive",              "otf"),
        ("Primae-Semibold",             "otf"),
        ("Primae-SemiboldCursive",      "otf"),
        ("Primae-Bold",                 "otf"),
        ("Primae-BoldCursive",          "otf"),
        ("PrimaeText-Light",            "otf"),
        ("PrimaeText-LightCursive",     "otf"),
        ("PrimaeText-Semilight",        "otf"),
        ("PrimaeText-SemilightCursive", "otf"),
        ("PrimaeText-Regular",          "otf"),
        ("PrimaeText-Cursive",          "otf"),
        ("PrimaeText-Semibold",         "otf"),
        ("PrimaeText-SemiboldCursive",  "otf"),
        ("PrimaeText-Bold",             "otf"),
        ("PrimaeText-BoldCursive",      "otf"),
        ("PlaywriteAT-Regular",         "ttf"),
    ]

    /// Already-registered marker. Prevents log spam when callers
    /// invoke `registerAll()` multiple times in a session.
    nonisolated(unsafe) private static var didRegister = false
    private static let log = Logger(subsystem: "buchstaben.primae", category: "fonts")

    /// Register every bundled face. Safe to call repeatedly.
    public static func registerAll() {
        guard !didRegister else { return }
        // Latched only after at least one URL resolved (below); a first
        // call before the resource bundle is resolvable must stay
        // retryable or the session runs on the system font (class two).

        // Resolution goes through `PrimaeBundle`, whose `.main` probe covers
        // the host's `INFOPLIST_KEY_UIAppFonts` copies. Previously this used
        // `Bundle.module`, which calls `fatalError` when it cannot resolve
        // (`cb7291d`), behind a `urls.isEmpty` warning that degraded the whole
        // type system to the system font with nothing failing.
        let urls: [URL] = registrations.compactMap { name, ext in
            PrimaeBundle.resourceURL(firstOf: PrimaeBundle.layouts(dir: "Fonts", name: name, ext: ext))
        }

        defer { if !urls.isEmpty { didRegister = true } }
        guard !urls.isEmpty else {
            log.warning("PrimaeFonts.registerAll: no font URLs resolved — Resources/Fonts/ may be missing from the bundle.")
            return
        }

        var errorRef: Unmanaged<CFArray>?
        let ok = CTFontManagerRegisterFontsForURLs(
            urls as CFArray,
            .process,
            &errorRef
        )
        if !ok, let errArray = errorRef?.takeRetainedValue() as? [CFError] {
            // Code 105 is `kCTFontManagerErrorAlreadyRegistered` —
            // expected on repeat calls; ignore.
            for err in errArray {
                let code = CFErrorGetCode(err)
                if code == 105 { continue }
                log.error("PrimaeFonts: register failed code=\(code) desc=\(CFErrorCopyDescription(err) as String? ?? "?")")
            }
        }
    }
}
