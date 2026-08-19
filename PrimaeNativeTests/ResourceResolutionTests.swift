// Resource-resolution regression net.
//
// WHY THIS FILE EXISTS. The CoreML model resolved through a path nobody
// had verified and was dark for three months — `recognition_predicted`
// empty in 194 of 194 recognition-bearing records across 41 sessions —
// because a missing model is DESIGNED to degrade quietly. `cb7291d`
// fixed that one resource and pinned it with `BundleResolutionTests`.
//
// Every other bundled resource had the same shape and none of the same
// coverage. Each of these fails silently by design:
//
//   spatial_carrier.wav  the spatial arm plays nothing, which is
//                        behaviourally IDENTICAL to the silent control
//                        arm — a corrupted independent variable that
//                        looks like a valid one
//   fonts                `urls.isEmpty` logs a warning and returns; the
//                        app renders in the system face
//   effect sounds        `systemFallback` chimes, or for tick_stroke
//                        (fallback nil) plays nothing at all
//   letter audio         "no audio files found" is an issue entry, not
//                        a failure
//
// The pre-existing arm-routing tests could not see any of this:
//
//   #expect(vm.activeAudioFiles(for: asset()) == [SpatialSonification.carrierToneFile])
//
// asserts a String constant against itself and never touches the disk.
// Delete the carrier and every one of those tests still passes.
//
// WHAT "RESOLVES" MEANS HERE. Each assertion goes through `PrimaeBundle`,
// the resolver the app itself uses, and — except where noted — through
// the PACKAGE bundle specifically rather than `PrimaeBundle`'s `.main`
// last resort. The package bundle is the one that exists in both layouts:
// nested in `PrimaeNative.framework` in the app, and nested in the same
// framework inside `PrimaeNativeTests.xctest` under test. Proving a
// resource resolves there is what makes app and test agree; a test that
// accepted the `.main` fallback would pass on a host that embeds a copy
// while the package bundle shipped without it.

import Testing
import Foundation
@testable import PrimaeNative

@Suite struct ResourceResolutionTests {

    /// Resolution restricted to the PACKAGE bundle — `PrimaeBundle`'s
    /// `.main` probe deliberately excluded. See the file header.
    private static func resolvesInPackageBundle(_ relativePath: String) -> Bool {
        let bundle = PrimaeBundle.resources
        for root in [bundle.bundleURL, bundle.resourceURL].compactMap({ $0 }) {
            if FileManager.default.fileExists(
                atPath: root.appendingPathComponent(relativePath).path) { return true }
        }
        return false
    }

    private static func resolvesInPackageBundle(firstOf paths: [String]) -> Bool {
        paths.contains { resolvesInPackageBundle($0) }
    }

    // MARK: - The pilot's independent variable

    /// THE one that matters most. The spatial arm's only sound is this
    /// single letter-independent carrier. If it stops shipping, that arm
    /// becomes the silent arm and the between-arm contrast the study is
    /// built on silently collapses to two conditions wearing three labels.
    @Test("the spatial arm's carrier tone is bundled")
    func spatialCarrierResolves() {
        #expect(Self.resolvesInPackageBundle(SpatialSonification.carrierToneFile),
                """
                \(SpatialSonification.carrierToneFile) is not in the package bundle. \
                The spatial pilot arm has no sound and is indistinguishable from \
                the silent control arm.
                """)
    }

    // MARK: - Fonts

    /// Probes `PrimaeFonts.registrations` itself rather than a copy of the
    /// list. A test carrying its own copy proves the copy.
    @Test("every registered font face resolves")
    func everyRegisteredFontResolves() {
        let missing = PrimaeFonts.registrations.filter { name, ext in
            !Self.resolvesInPackageBundle(
                firstOf: PrimaeBundle.layouts(dir: "Fonts", name: name, ext: ext))
        }.map { "\($0.name).\($0.ext)" }

        #expect(missing.isEmpty,
                """
                \(missing.count) of \(PrimaeFonts.registrations.count) registered faces \
                are not bundled: \(missing.joined(separator: ", ")). \
                registerAll() logs a warning and returns — the app renders in the system face.
                """)
    }

    /// The renderer probes fonts on its own path, for glyph rendering
    /// rather than UI text. Both paths, both asserted.
    @Test("the renderer's font probe resolves the default face")
    func rendererFontProbeResolves() {
        #expect(Self.resolvesInPackageBundle(
            firstOf: PrimaeLetterRenderer.fontLayouts("Primae-Regular", "otf")),
                "PrimaeLetterRenderer.makeFont cannot resolve Primae-Regular — glyph rendering falls back")
    }

    // MARK: - Effect sounds

    /// `tick_stroke` passes `systemFallback: nil`, so its absence is
    /// inaudible and unlogged past a single `log.info`.
    @Test("every effect sound PromptPlayer plays is bundled")
    func effectSoundsResolve() {
        let effects = ["tap", "tap_wrong", "tick_stroke"]
        let missing = effects.filter {
            !Self.resolvesInPackageBundle(firstOf: PromptPlayer.effectLayouts($0))
        }
        #expect(missing.isEmpty,
                "effect sounds not bundled: \(missing.joined(separator: ", ")) — these degrade to system chimes or silence")
    }

    // MARK: - Spoken prompts

    /// The 14 prompt MP3s have never been committed: `Resources/Prompts/README.md`
    /// documents the AVSpeechSynthesizer fallback as the expected state until
    /// `scripts/generate_prompts.py` is run and the takes are copied in.
    ///
    /// So absence is NOT the failure. A PARTIAL set is: one misnamed or
    /// missing take among thirteen present ones degrades that single prompt
    /// to TTS, in a different voice from its neighbours, with nothing raised.
    /// All-or-none is the invariant that holds in both worlds.
    @Test("bundled prompt MP3s are all-or-none, never a partial set")
    func promptMP3sAreAllOrNone() {
        let keys = PromptPlayer.PromptKey.allCases
        let present = keys.filter {
            Self.resolvesInPackageBundle(
                firstOf: PrimaeBundle.layouts(dir: "Prompts", name: $0.rawValue, ext: "mp3"))
        }
        let missing = keys.filter { key in !present.contains { $0 == key } }

        #expect(present.isEmpty || missing.isEmpty,
                """
                partial prompt set: \(present.count) of \(keys.count) bundled, \
                missing \(missing.map(\.rawValue).joined(separator: ", ")). \
                Each missing take degrades to a TTS voice mid-session while its \
                neighbours play a recorded one.
                """)
    }

    // MARK: - Letter assets

    /// Enumerated through the real provider, not a fixture. The study set
    /// is the five letters a pilot participant actually traces.
    @Test("the real bundle carries audio for every study letter")
    func studyLetterAudioResolves() {
        let audioExtensions: Set<String> = ["mp3", "wav", "m4a", "aac", "flac", "ogg"]
        let urls = BundleLetterResourceProvider().allResourceURLs()
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }

        let silent = TrainedLetterSubset.studyLetters.filter { letter in
            !urls.contains { $0.deletingLastPathComponent().lastPathComponent
                .compare(letter, options: .caseInsensitive) == .orderedSame }
        }
        #expect(silent.isEmpty,
                "study letters with no bundled audio: \(silent.joined(separator: ", ")) — they trace in silence in every sound arm")
    }

    /// `_meta.json` records bake-time provenance per weight. Missing, the
    /// repository falls through to defaults without complaint.
    @Test("each bundled letter weight carries its _meta.json")
    func letterWeightMetaResolves() {
        let missing = ["Regular", "Light"].filter {
            !Self.resolvesInPackageBundle("Resources/Letters/\($0)/_meta.json")
        }
        #expect(missing.isEmpty, "weights missing _meta.json: \(missing.joined(separator: ", "))")
    }

    // MARK: - The resolver itself

    /// `PrimaeBundle`'s `.main` probe exists for the host's UIAppFonts
    /// copies. It must not be the only reason a resource resolves — if the
    /// package bundle is absent entirely, every test above is measuring the
    /// host instead.
    @Test("the package resource bundle is present and is not .main")
    func packageBundleIsReal() {
        #expect(PrimaeBundle.resources != .main,
                "resolved to Bundle.main — every assertion in this suite is measuring the host bundle, not the package")
    }
}
