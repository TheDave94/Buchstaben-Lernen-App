// TestFixtureContractTests.swift
// PrimaeNativeTests
//
// The shared test fixture's own contract.
//
// `TracingDependencies.stub` is the base for nearly every VM-building test
// in the suite, which makes its defaults load-bearing far from where they
// are written. Twice now a property of that fixture has been depended on
// without being asserted:
//
//   1. `studyMode` was left unpinned while the three sibling assignment
//      axes were pinned deliberately. When B2 changed the default to
//      resolve ON in a study build, three haptic tests began failing in the
//      study binary only — and the comments on the three pins, which
//      explained exactly this hazard, did not prevent the fourth being
//      missed. A comment is not a mechanism; these tests are.
//
//   2. The stub letter "A" happens to be inside the stub's trained subset
//      "AFI", so a studyMode practice pool built from the fixture is
//      non-empty. Nothing asserted that, and nothing named it as a
//      requirement — it was a coincidence holding up every test that opts
//      into studyMode.
//
// Both are cheap to state and expensive to rediscover.

import Testing
import Foundation
@testable import PrimaeNative

@Suite @MainActor struct TestFixtureContractTests {

    /// The fixture must not inherit `studyMode` from the build it was
    /// compiled into.
    ///
    /// `StudyBuild.resolveStudyMode()` — the production default — returns
    /// true in a study build (B2). If `.stub` did not pin the value, the
    /// same test source would exercise the study path in one binary and the
    /// normal path in the other, and the suite would quietly stop testing
    /// what it reads as testing. Tests that mean to exercise studyMode opt
    /// in per-call with `.with(studyMode:)`.
    @Test("the shared fixture pins studyMode rather than resolving it")
    func stubPinsStudyMode() {
        #expect(TracingDependencies.stub.studyMode == false,
                "TracingDependencies.stub must pin studyMode explicitly — an unpinned fixture resolves it from the build and makes the suite build-dependent")
    }

    /// The stub letter must survive the studyMode practice-pool filter.
    ///
    /// Under studyMode `visibleLetterNames` narrows to
    /// `studyBaseLetters ∩ trainedSubset.letters ∩ uppercase`. The fixture
    /// satisfies that only because its single letter is "A" and its pinned
    /// subset is `allSubsets[0]` == "AFI". Change either — a different stub
    /// letter, or a different pinned subset — and the intersection empties.
    ///
    /// What that breaks is every test that opts INTO studyMode:
    /// `StudyLetterSetTests`, `StudyCleanConfigTests`,
    /// `AudioArmRoutingTests`' studyMode cases, and
    /// `TracingViewModelHapticTests.studyMode_firesNoHaptics`. They would
    /// not fail on their own subject matter; they would fail on empty
    /// letter names and zero progress, which reads as a tracing or scoring
    /// regression rather than a fixture edit. This test converts that into
    /// one named failure that says which half of the intersection moved.
    ///
    /// (Before `.stub` pinned studyMode this was far wider — it would also
    /// have taken out the six files that never mention studyMode at all.
    /// The pin closed that; this closes the remainder.)
    @Test("the stub letter stays inside the stub's trained subset")
    func stubLetterSurvivesTheStudyModeFilter() {
        let subset = TracingDependencies.stub.trainedSubset
        let normal = TracingViewModel(.stub.with(studyMode: false)).visibleLetterNames
        let study  = TracingViewModel(.stub.with(studyMode: true)).visibleLetterNames

        #expect(!normal.isEmpty,
                "the stub repo supplies no letters at all — this is a fixture problem upstream of studyMode")

        let trained = normal.filter { subset.letters.contains($0.uppercased()) }
        #expect(!trained.isEmpty,
                "no stub letter is in the pinned trained subset \(subset.rawValue) — the fixture's letter and its subset have drifted apart")

        #expect(!study.isEmpty,
                "the studyMode practice pool built from .stub is EMPTY (letters: \(normal), subset: \(subset.rawValue)) — every test that opts into studyMode will now fail on empty letter names rather than on its own subject")
    }
}
