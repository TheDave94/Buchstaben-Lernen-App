//
//  StudyLaunchTests.swift
//  PrimaeNativeTests
//
//  Audit 2026-09-06 — what a study session looks like at the moment the
//  app launches: which letter is loaded, where the letters came from,
//  and what blocks tracing until a relaunch.
//

import Testing
import Foundation
@testable import PrimaeNative

// MARK: - Fixtures

/// Five study letters on disk, one trivial stroke each, no audio. Used
/// where the single-letter `StubResourceProvider` cannot show anything
/// about subset selection.
private final class FiveLetterProvider: LetterResourceProviding {
    var bundle: Bundle = .main
    var searchBundles: [Bundle] { [bundle] }

    private static let root: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FiveLetterResources-\(UUID().uuidString)", isDirectory: true)
        for letter in TrainedLetterSubset.studyLetters {
            let letterDir = dir.appendingPathComponent("Letters/Regular/\(letter)", isDirectory: true)
            try? FileManager.default.createDirectory(at: letterDir, withIntermediateDirectories: true)
            let strokes: [String: Any] = [
                "letter": letter,
                "checkpointRadius": 0.1,
                "strokes": [["id": 1, "checkpoints": [["x": 0.2, "y": 0.5], ["x": 0.8, "y": 0.5]]]]
            ]
            let data = try! JSONSerialization.data(withJSONObject: strokes)
            try? data.write(to: letterDir.appendingPathComponent("strokes.json"))
        }
        return dir
    }()

    func allResourceURLs() -> [URL] {
        guard let e = FileManager.default.enumerator(at: Self.root,
                                                     includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        return e.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    func resourceURL(for relativePath: String) -> URL? {
        let url = Self.root.appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

private final class EmptyProvider: LetterResourceProviding {
    var bundle: Bundle = .main
    var searchBundles: [Bundle] { [bundle] }
    func allResourceURLs() -> [URL] { [] }
    func resourceURL(for relativePath: String) -> URL? { nil }
}

/// A cache that "remembers" a previous build's letters.
private final class StaleCache: LetterCacheStoring {
    let stored: [LetterAsset]
    init(_ stored: [LetterAsset]) { self.stored = stored }
    func save(_ letters: [LetterAsset]) throws(LetterRepositoryError) {}
    func load() throws(LetterRepositoryError) -> [LetterAsset] { stored }
    func clear() {}
}

@MainActor
private final class SpyAudio: AudioControlling {
    var initializationError: String? { nil }
    private(set) var loadedFiles: [String] = []
    private(set) var autoplayFlags: [Bool] = []
    func loadAudioFile(named: String, autoplay: Bool) { loadedFiles.append(named); autoplayFlags.append(autoplay) }
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) {}
    func play() {}
    func stop() {}
    func restart() {}
    func suspendForLifecycle() {}
    func resumeAfterLifecycle() {}
    func cancelPendingLifecycleWork() {}
}

private func staleLetter(_ id: String) -> LetterAsset {
    LetterAsset(id: id, name: id, audioFiles: [],
                strokes: LetterStrokes(letter: id, checkpointRadius: 0.05,
                                       strokes: [StrokeDefinition(id: 1, checkpoints: [Checkpoint(x: 0.5, y: 0.5)])]))
}

// MARK: - Tests

@MainActor
struct StudyLaunchTests {

    /// The repository sorts by name, so `letters.first` was "A" on every
    /// device — an UNTRAINED letter for the four subsets without A,
    /// fully traceable because `load(letter:)` never consults the
    /// trained-subset filter, and armed with A's demonstration before
    /// any cold probe of A.
    @Test("a study session launches on the first TRAINED letter, never on an untrained one")
    func studyLaunchLoadsFirstTrainedLetter() throws {
        var deps = TracingDependencies.stub
        deps.repo = LetterRepository(resources: FiveLetterProvider(), cache: NullLetterCache())
        deps.studyMode = true
        deps.audioCondition = .silent        // no phoneme precondition
        deps.trainedSubset = try #require(TrainedLetterSubset(rawValue: "FIL"))
        let vm = TracingViewModel(deps)
        #expect(vm.studyPreconditionFailure == nil, "\(String(describing: vm.studyPreconditionFailure))")
        #expect(vm.currentLetterName != "A", "A is untrained for FIL and must not be the launch letter")
        #expect(vm.currentLetterName == vm.visibleLetterNames.first,
                "launch letter \(vm.currentLetterName) is not the first of the trained pool \(vm.visibleLetterNames)")
        #expect(vm.trainedSubset.letters.contains(vm.currentLetterName))
        #expect(vm.letters.indices.contains(vm.letterIndex)
                && vm.letters[vm.letterIndex].name == vm.currentLetterName,
                "letterIndex must point at the loaded letter, or the arrows navigate from the wrong place")
    }

    /// A study launch is PARKED: the letter is loaded, nothing runs. The
    /// unparked launch used to run a full unattended observe phase at
    /// app start — demonstration into the headphones, two cycles
    /// auto-advancing into `direct`, and a `completed:false` row on the
    /// proctor's first probe load — all before the pretest.
    @Test("a study launch parks the letter: nothing armed until the observe pill is tapped")
    func studyLaunchIsParked() async throws {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        deps.audioCondition = .phoneme      // the stub letter carries A_phoneme1.mp3
        let audio = SpyAudio()
        deps.audio = audio
        let vm = TracingViewModel(deps)
        #expect(vm.launchParked)
        #expect(vm.learningPhase == .observe)
        #expect(vm.currentLetterName == "A")
        #expect(vm.animation.armedStrokes == nil, "no observe animation before the start")
        #expect(vm.debugLetterLoadTime == nil, "no active time accrues while parked")
        // The demonstration is a Task armed at load; give it turns to fire if it were armed.
        for _ in 0..<50 { await Task.yield() }
        #expect(!audio.autoplayFlags.contains(true), "no demonstration before the start: \(audio.loadedFiles)")
        vm.appDidBecomeActive()
        #expect(vm.debugLetterLoadTime == nil, "a foreground return does not start the clock of a parked letter")

        vm.canvasSize = CGSize(width: 1200, height: 800)
        vm.startParkedLetter()
        #expect(!vm.launchParked)
        #expect(vm.animation.armedStrokes != nil, "the start arms the observe animation")
        #expect(vm.animation.armedStrokes == vm.rawGlyphStrokes, "armed against the laid-out canvas")
        #expect(vm.debugLetterLoadTime != nil)
        vm.startParkedLetter()   // idempotent once running
        #expect(vm.learningPhase == .observe)
    }

    @Test("navigating away un-parks: a real load never stays parked")
    func navigationUnparks() {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        deps.audioCondition = .silent
        let vm = TracingViewModel(deps)
        #expect(vm.launchParked)
        vm.nextLetter()
        #expect(!vm.launchParked)
        #expect(vm.animation.armedStrokes != nil)
    }

    /// Outside a study session the launch letter is armed at init, before
    /// any view exists — against the 1024×1024 placeholder. After the
    /// canvas lays out the armed payload must be the laid-out geometry.
    @Test("an observe animation armed before layout is re-armed with the laid-out canvas")
    func launchAnimationReArmsOnLayout() {
        var deps = TracingDependencies.stub
        deps.studyMode = false
        deps.thesisCondition = .threePhase   // the stub's guidedOnly would start in guided
        let vm = TracingViewModel(deps)
        #expect(vm.learningPhase == .observe)
        let armedAtInit = vm.animation.armedStrokes
        #expect(armedAtInit != nil, "the observe demonstration is armed at init outside a study")
        vm.canvasSize = CGSize(width: 1200, height: 800)
        let laidOut = vm.rawGlyphStrokes
        #expect(vm.animation.armedStrokes == laidOut, "armed payload must equal the post-layout geometry")
        if laidOut != armedAtInit {
            #expect(vm.animation.armedStrokes != armedAtInit)
        }
        vm.animation.stop()
        #expect(vm.animation.armedStrokes == nil)
    }

    @Test("outside a study session the launch letter stays letters.first")
    func casualLaunchUnchanged() {
        var deps = TracingDependencies.stub
        deps.repo = LetterRepository(resources: FiveLetterProvider(), cache: NullLetterCache())
        deps.studyMode = false
        let vm = TracingViewModel(deps)
        #expect(vm.currentLetterName == vm.letters.first?.name)
    }

    /// `loadLetters()` never returns empty: cache, then a synthetic "A".
    /// A study device whose bundle scan fails would trace a previous
    /// build's geometry and stamp ordinary rows. Refuse instead.
    @Test("a study session refuses cached or sample letters when the bundle scan fails")
    func studyRefusesNonBundleLetters() {
        let repo = LetterRepository(resources: EmptyProvider(),
                                    cache: StaleCache([staleLetter("A"), staleLetter("F")]))
        var deps = TracingDependencies.stub
        deps.repo = repo
        deps.studyMode = true
        deps.audioCondition = .silent
        let study = TracingViewModel(deps)
        #expect(study.letters.isEmpty, "the stale cache must not be served under studyMode: \(study.letters.map(\.name))")
        #expect(study.studyPreconditionFailure?.contains("Bundle") == true,
                "\(String(describing: study.studyPreconditionFailure))")
        #expect(study.sessionBlockReason != nil)

        deps.studyMode = false
        let casual = TracingViewModel(deps)
        #expect(casual.letters.map(\.name) == ["A", "F"], "the casual app keeps its cache fallback")
    }

    @Test("loadBundledLettersOnly ignores the cache and the sample letter")
    func bundleOnlyLoadIgnoresFallbacks() {
        let repo = LetterRepository(resources: EmptyProvider(), cache: StaleCache([staleLetter("A")]))
        switch repo.loadBundledLettersOnly() {
        case .success(let letters): Issue.record("expected a failure, got \(letters.map(\.name))")
        case .failure(let error):   #expect(error == .noAssetsFound)
        }
        #expect(repo.loadLetters().map(\.name) == ["A"], "the ordinary load still falls back")
    }

    /// An override is read once at init; without a block a session ran
    /// — and stamped rows — under the UUID-derived arm after the proctor
    /// had chosen a different one.
    @Test("a researcher override blocks tracing until the relaunch")
    func overrideBlocksUntilRelaunch() {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        let vm = TracingViewModel(deps)
        #expect(vm.sessionBlockReason == nil, "\(String(describing: vm.sessionBlockReason))")
        vm.markAssignmentOverrideChanged()
        #expect(vm.sessionBlockReason?.contains("Zuweisung") == true,
                "\(String(describing: vm.sessionBlockReason))")

        deps.studyMode = false
        let casual = TracingViewModel(deps)
        casual.markAssignmentOverrideChanged()
        #expect(casual.sessionBlockReason == nil, "the block is a study-session rule")
    }
}
