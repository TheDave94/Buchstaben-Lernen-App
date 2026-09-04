// Pins the STUDY_BUILD seam itself: build identity, and the B2 rule
// that `studyMode` defaults ON in a study build and OFF everywhere
// else. The assertions are written per-branch rather than "whatever
// StudyBuild says", so a flag that silently stopped arriving would
// fail the suite instead of agreeing with itself.
//
// Everything here goes through `StudyBuild.resolveStudyMode(in:)` with
// a scratch UserDefaults — constructing a real `TracingDependencies`
// would build a live AudioEngine in the headless simulator.

import Testing
import Foundation
@testable import PrimaeNative

@Suite struct StudyBuildTests {

    /// Read from the production constant, not re-typed: a test that
    /// hardcodes the key would keep passing if the app started writing a
    /// different one.
    private static let key = StudyBuild.studyModeDefaultsKey

    /// Isolated defaults domain — never touches the device's own state.
    private func scratchDefaults(_ name: String) -> UserDefaults {
        let suite = "de.flamingistan.primae.tests.studybuild.\(name)"
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    @Test("Build identity matches the compilation condition")
    func buildIdentity() {
        #if STUDY_BUILD
        #expect(StudyBuild.isActive)
        #expect(StudyBuild.marker == "PRIMAE_BUILD_STUDY")
        #else
        #expect(!StudyBuild.isActive)
        #expect(StudyBuild.marker == "PRIMAE_BUILD_NORMAL")
        #endif
    }

    @Test("B2 — studyMode defaults ON in a study build, OFF otherwise")
    func studyModeDefault() {
        #if STUDY_BUILD
        #expect(StudyBuild.studyModeDefault)
        #else
        #expect(!StudyBuild.studyModeDefault)
        #endif
    }

    @Test("Unset key resolves to the build default")
    func unsetKeyUsesBuildDefault() {
        let defaults = scratchDefaults("unset")
        let resolved = StudyBuild.resolveStudyMode(in: defaults, key: Self.key)
        #if STUDY_BUILD
        #expect(resolved, "study build must start in study mode")
        #else
        #expect(!resolved, "normal build must be unchanged")
        #endif
    }

    @Test("Normal build: a stored value wins over the default; study build: a stored OFF is IGNORED")
    func storedValueWins() {
        let defaults = scratchDefaults("stored")
        defaults.set(false, forKey: Self.key)
        #if STUDY_BUILD
        // Ruling Q1 (2026-09-04): the study binary cannot be configured
        // into a non-study state. A stored OFF — left by an earlier
        // normal build on the same device, or by a tap — must not win.
        #expect(StudyBuild.resolveStudyMode(in: defaults, key: Self.key),
                "a study build must stay in study mode with OFF stored")
        #else
        // The toggle survives for device prep on a normal build, so it
        // must beat the default once a proctor has actually set it.
        #expect(!StudyBuild.resolveStudyMode(in: defaults, key: Self.key))
        #endif
        defaults.set(true, forKey: Self.key)
        #expect(StudyBuild.resolveStudyMode(in: defaults, key: Self.key))
    }
}
