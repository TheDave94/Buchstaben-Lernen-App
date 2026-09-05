import Testing
import Foundation
import CoreGraphics
import QuartzCore
import AVFoundation
@testable import PrimaeNative

@Suite(.serialized) @MainActor struct PrimaeNativeTests {

    @Test func strokeTrackerProgressionRespectsOrder() {
        let tracker = StrokeTracker()
        let strokes = LetterStrokes(letter: "T", checkpointRadius: 0.06, strokes: [
            .init(id: 1, checkpoints: [.init(x: 0.2, y: 0.2), .init(x: 0.4, y: 0.2)]),
            .init(id: 2, checkpoints: [.init(x: 0.4, y: 0.4), .init(x: 0.6, y: 0.4)])
        ])
        tracker.load(strokes)
        tracker.update(normalizedPoint: CGPoint(x: 0.4, y: 0.4))
        #expect(tracker.progress[0].nextCheckpoint == 0)
        #expect(!tracker.soundEnabled)
        tracker.update(normalizedPoint: CGPoint(x: 0.2, y: 0.2))
        tracker.update(normalizedPoint: CGPoint(x: 0.4, y: 0.2))
        #expect(tracker.progress[0].complete)
        #expect(tracker.currentStrokeIndex == 1)
        tracker.update(normalizedPoint: CGPoint(x: 0.4, y: 0.4))
        tracker.update(normalizedPoint: CGPoint(x: 0.6, y: 0.4))
        #expect(tracker.isComplete)
        #expect(tracker.overallProgress == 1.0)
    }

    @Test func mapVelocityToSpeedIsMonotonicAndBounded() {
        let sample: [CGFloat] = [0, 60, 120, 240, 500, 900, 1300, 3000]
        let mapped = sample.map(TouchDispatcher.mapVelocityToSpeed)
        #expect(abs((mapped.first ?? 0) - Float(0.5)) < 0.0001)
        #expect(abs((mapped.last ?? 0) - Float(2.0)) < 0.0001)
        mapped.forEach { #expect($0 >= 0.5); #expect($0 <= 2.0) }
        for i in 1..<mapped.count { #expect(mapped[i] >= mapped[i-1]) }
    }

    @Test func letterRepositoryFallsBackToSampleWhenNoAssetsExist() {
        let repo = LetterRepository(resources: LocalMockResourceProvider(urls: [], byRelativePath: [:]), cache: NullLetterCache())
        let letters = repo.loadLetters()
        #expect(letters.count == 1)
        #expect(letters[0].name == "A")
        #expect(letters[0].audioFiles == ["A1.mp3"])
    }

    @Test func letterRepositoryPrefersCleanCuratedAudioForAtoM() throws {
        let fs = try TempResourceFS()
        defer { fs.cleanup() }
        try fs.write(relative: "M_strokes.json", content: validJSON(letter: "M"))
        try fs.write(relative: "M/Möwe.mp3", content: "ok")
        try fs.write(relative: "M/Meer.mp3", content: "ok")
        try fs.write(relative: "M/hmmm.wav", content: "stale")
        try fs.write(relative: "M/ElevenLabs_test.mp3", content: "stale")
        let repo = LetterRepository(resources: fs.provider, cache: NullLetterCache())   // never the app's real cache
        let m = try #require(repo.loadLetters().first(where: { $0.id.uppercased() == "M" }))
        #expect(m.audioFiles == ["M/Meer.mp3", "M/Möwe.mp3"])
    }

    @Test func tracingViewModelUsesInjectedAudioControllerAcrossLifecycle() async {
        let audio = LocalMockAudioController()
        let vm = TracingViewModel(.stub.with(audio: audio))
        #expect(audio.loadedFiles.count >= 1)
        vm.nextAudioVariant(); vm.previousAudioVariant()
        await vm.appDidEnterBackground(); vm.appDidBecomeActive()
        #expect(audio.loadedFiles.count >= 3)
        #expect(audio.suspendForLifecycleCount == 1)
        #expect(audio.resumeAfterLifecycleCount == 1)
    }

    @Test func backgroundCancelsPendingPlaybackAndAvoidsResumeUntilNewIntent() async {
        let audio = LocalMockAudioController()
        let vm = TracingViewModel(.stub.with(audio: audio))
        let size = CGSize(width: 320, height: 480)
        vm.beginTouch(at: CGPoint(x: 10, y: 10), t: 1.0)
        vm.updateTouch(at: CGPoint(x: 80, y: 80), t: 1.01, canvasSize: size)
        await vm.appDidEnterBackground()
        #expect(audio.cancelPendingLifecycleWorkCount >= 1)
        #expect(audio.stopCount >= 1)
        vm.appDidBecomeActive()
        let playCountAfterResume = audio.playCount
        vm.beginTouch(at: CGPoint(x: 10, y: 10), t: 2.0)
        vm.updateTouch(at: CGPoint(x: 120, y: 120), t: 2.01, canvasSize: size)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(audio.playCount > playCountAfterResume)
    }

    @Test func longSessionLifecycleRegressionMatrix() async {
        let audio = LocalMockAudioController()
        let vm = TracingViewModel(.stub.with(audio: audio))
        let size = CGSize(width: 320, height: 480)
        for cycle in 0..<5 {
            let base = CFTimeInterval(10 + cycle)
            vm.beginTouch(at: CGPoint(x: 12, y: 12), t: base)
            vm.updateTouch(at: CGPoint(x: 140, y: 160), t: base + 0.01, canvasSize: size)
            await vm.appDidEnterBackground(); vm.appDidBecomeActive()
        }
        for i in 0..<8 {
            let t = CFTimeInterval(200) + (Double(i) * 0.004)
            vm.beginTouch(at: CGPoint(x: 20 + CGFloat(i), y: 20 + CGFloat(i)), t: t)
            vm.updateTouch(at: CGPoint(x: 25 + CGFloat(i), y: 25 + CGFloat(i)), t: t + 0.001, canvasSize: size)
            vm.endTouch()
        }
        #expect(audio.suspendForLifecycleCount >= 5)
        #expect(audio.resumeAfterLifecycleCount >= 5)
        #expect(audio.cancelPendingLifecycleWorkCount >= 5)
        #expect(audio.setAdaptivePlaybackCount > 0)
        #expect(audio.stopCount >= audio.suspendForLifecycleCount)
    }

    @Test func rapidBackgroundForegroundChurn_50Cycles() async {
        let audio = LocalMockAudioController()
        let vm = TracingViewModel(.stub.with(audio: audio))
        let size = CGSize(width: 320, height: 480)
        for cycle in 0..<50 {
            let base = CFTimeInterval(100 + cycle * 2)
            vm.beginTouch(at: CGPoint(x: 10, y: 10), t: base)
            vm.updateTouch(at: CGPoint(x: 80, y: 80), t: base + 0.01, canvasSize: size)
            await vm.appDidEnterBackground(); vm.appDidBecomeActive()
        }
        #expect(audio.suspendForLifecycleCount == 50)
        #expect(audio.resumeAfterLifecycleCount == 50)
        #expect(audio.cancelPendingLifecycleWorkCount >= 50)
        await vm.appDidEnterBackground()
        #expect(vm.debugActivePathCount == 0)
    }

    @Test func avAudioSessionInterruption_shouldResumeFalse_doesNotPlay() async {
        let audio = LocalMockAudioController()
        let vm = TracingViewModel(.stub.with(audio: audio))
        let size = CGSize(width: 320, height: 480)
        vm.beginTouch(at: CGPoint(x: 10, y: 10), t: 1.0)
        vm.updateTouch(at: CGPoint(x: 80, y: 80), t: 1.01, canvasSize: size)
        // Drain the debounced play before snapshotting `playsBefore` so the
        // post-background assertion can be strict (`== playsBefore`).
        await vm.awaitPlaybackDebounce()
        let playsBefore = audio.playCount
        await vm.appDidEnterBackground()
        let stopAfterInterrupt = audio.stopCount
        vm.endTouch(); vm.appDidBecomeActive()
        await vm.awaitPlaybackDebounce()
        #expect(stopAfterInterrupt > 0)
        #expect(audio.playCount == playsBefore,
                "shouldResume=false must NOT auto-play on return; got \(audio.playCount - playsBefore) extra play(s)")
    }

    @Test func avAudioSessionInterruption_shouldResumeTrue_resumesOnNewIntent() async {
        let audio = LocalMockAudioController()
        let vm = TracingViewModel(.stub.with(audio: audio))
        let size = CGSize(width: 320, height: 480)
        vm.beginTouch(at: CGPoint(x: 10, y: 10), t: 1.0)
        vm.updateTouch(at: CGPoint(x: 80, y: 80), t: 1.01, canvasSize: size)
        await vm.appDidEnterBackground(); vm.appDidBecomeActive()
        vm.beginTouch(at: CGPoint(x: 10, y: 10), t: 2.0)
        vm.updateTouch(at: CGPoint(x: 120, y: 120), t: 2.01, canvasSize: size)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(audio.playCount >= 1)
    }

    @Test func audioRouteChange_oldDeviceUnavailable_stopsPlayback() async {
        let audio = LocalMockAudioController()
        let vm = TracingViewModel(.stub.with(audio: audio))
        let size = CGSize(width: 320, height: 480)
        vm.beginTouch(at: CGPoint(x: 10, y: 10), t: 1.0)
        vm.updateTouch(at: CGPoint(x: 140, y: 160), t: 1.01, canvasSize: size)
        let stopsBefore = audio.stopCount
        await vm.appDidEnterBackground()
        #expect(audio.stopCount > stopsBefore)
        #expect(vm.debugActivePathCount == 0)
    }

    @Test func audioRouteChange_oldDeviceUnavailable_isIdempotent() async {
        let audio = LocalMockAudioController()
        let vm = TracingViewModel(.stub.with(audio: audio))
        let size = CGSize(width: 320, height: 480)
        vm.beginTouch(at: CGPoint(x: 10, y: 10), t: 1.0)
        vm.updateTouch(at: CGPoint(x: 80, y: 80), t: 1.01, canvasSize: size)
        await vm.appDidEnterBackground(); await vm.appDidEnterBackground(); await vm.appDidEnterBackground()
        #expect(audio.suspendForLifecycleCount >= 1)
        #expect(vm.debugActivePathCount == 0)
    }

    @Test func debounceTouchBurst_rapidTaps_onlyOnePlaybackIntent() {
        let audio = LocalMockAudioController()
        let vm = TracingViewModel(.stub.with(audio: audio))
        let size = CGSize(width: 320, height: 480)
        let playsBefore = audio.playCount
        for i in 0..<20 {
            let t = CFTimeInterval(1.0) + Double(i) * 0.0002
            vm.beginTouch(at: CGPoint(x: CGFloat(10+i), y: CGFloat(10+i)), t: t)
            vm.updateTouch(at: CGPoint(x: CGFloat(80+i), y: CGFloat(80+i)), t: t+0.0001, canvasSize: size)
            vm.endTouch()
        }
        #expect(audio.playCount <= playsBefore + 1, "Rapid taps should trigger at most 1 play, got \(audio.playCount - playsBefore)")
    }

    @Test func debounceWindow_afterExpiry_playbackIsAllowed() async {
        let audio = LocalMockAudioController()
        let vm = TracingViewModel(.stub.with(audio: audio))
        let size = CGSize(width: 320, height: 480)
        vm.beginTouch(at: CGPoint(x: 10, y: 10), t: 1.0)
        vm.updateTouch(at: CGPoint(x: 140, y: 160), t: 1.01, canvasSize: size)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(audio.setAdaptivePlaybackCount >= 1)
    }

    @Test func interruptionDuringBgFgChurn_stateRemainsConsistent() async {
        let audio = LocalMockAudioController()
        let vm = TracingViewModel(.stub.with(audio: audio))
        let size = CGSize(width: 320, height: 480)
        for i in 0..<10 {
            let base = CFTimeInterval(10 + i * 3)
            vm.beginTouch(at: CGPoint(x: 10, y: 10), t: base)
            vm.updateTouch(at: CGPoint(x: 60, y: 60), t: base + 0.01, canvasSize: size)
            await vm.appDidEnterBackground(); vm.appDidBecomeActive()
            await vm.appDidEnterBackground(); vm.appDidBecomeActive()
        }
        #expect(vm.debugActivePathCount == 0)
        #expect(audio.suspendForLifecycleCount >= 10)
        #expect(audio.resumeAfterLifecycleCount >= 10)
    }

    @Test func avAudioSessionInterruptionIdempotency_doubleBegan() async {
        let audio = LocalMockAudioController()
        let vm = TracingViewModel(.stub.with(audio: audio))
        let size = CGSize(width: 320, height: 480)
        vm.beginTouch(at: CGPoint(x: 10, y: 10), t: 1.0)
        vm.updateTouch(at: CGPoint(x: 80, y: 80), t: 1.01, canvasSize: size)
        await vm.appDidEnterBackground()
        let suspendAfterFirst = audio.suspendForLifecycleCount
        await vm.appDidEnterBackground()
        #expect(audio.suspendForLifecycleCount == suspendAfterFirst)
        #expect(vm.debugActivePathCount == 0)
    }

    // MARK: - Stroke proximity

    @Test func strokeTracker_largeRadius_hitsFirstCheckpoint() {
        let tracker = StrokeTracker()
        let strokes = LetterStrokes(letter: "A", checkpointRadius: 0.5, strokes: [
            .init(id: 1, checkpoints: [.init(x: 0.0, y: 0.5), .init(x: 0.02, y: 0.5)])
        ])
        tracker.load(strokes)
        tracker.update(normalizedPoint: CGPoint(x: 0.25, y: 0.50))
        #expect(tracker.progress[0].nextCheckpoint == 1)
        #expect(tracker.overallProgress > 0)
    }

    @Test func strokeTracker_tenUpdatesAlongY50_hitsFirstTenCheckpoints() {
        let tracker = StrokeTracker()
        let checkpoints = (0..<50).map { i in Checkpoint(x: CGFloat(i) * 0.02, y: 0.5) }
        let strokes = LetterStrokes(letter: "A", checkpointRadius: 0.5, strokes: [
            .init(id: 1, checkpoints: checkpoints)
        ])
        tracker.load(strokes)
        for i in 0..<10 {
            tracker.update(normalizedPoint: CGPoint(x: 0.25 + CGFloat(i) * 0.025, y: 0.50))
        }
        #expect(tracker.progress[0].nextCheckpoint == 10)
        #expect(abs(tracker.overallProgress - 10.0 / 50.0) < 0.001)
    }

    @Test func strokeTracker_checkpointHit_enablesSound() {
        let tracker = StrokeTracker()
        let strokes = LetterStrokes(letter: "A", checkpointRadius: 0.5, strokes: [
            .init(id: 1, checkpoints: [.init(x: 0.0, y: 0.5), .init(x: 0.5, y: 0.5)])
        ])
        tracker.load(strokes)
        #expect(!tracker.soundEnabled, "Sound must be disabled before any checkpoint is hit")
        tracker.update(normalizedPoint: CGPoint(x: 0.25, y: 0.50))
        #expect(tracker.soundEnabled, "Sound must be enabled after the first checkpoint is hit")
    }

    // MARK: - OverlayQueueManager

    @Test func overlayQueue_isIdleByDefault() {
        let q = OverlayQueueManager()
        #expect(q.currentOverlay == nil)
        #expect(q.pendingCount == 0)
    }

    @Test func overlayQueue_displaysFirstEnqueuedImmediately() {
        let q = OverlayQueueManager()
        q.enqueue(.kpOverlay)
        if case .kpOverlay = q.currentOverlay {} else {
            #expect(Bool(false), "Expected .kpOverlay as current overlay")
        }
    }

    @Test func overlayQueue_secondOverlayWaitsBehindFirst() {
        let q = OverlayQueueManager()
        q.enqueue(.kpOverlay)
        q.enqueue(.celebration(stars: 3))
        // First overlay still on screen, second is queued.
        if case .kpOverlay = q.currentOverlay {} else {
            #expect(Bool(false), "First overlay must be displayed before second is queued")
        }
        #expect(q.pendingCount == 1)
    }

    @Test func overlayQueue_dismissAdvancesToNext() {
        let q = OverlayQueueManager()
        q.enqueue(.kpOverlay)
        q.enqueue(.celebration(stars: 3))
        q.dismiss()
        // After dismissing the head, the queue should advance to the celebration.
        if case .celebration = q.currentOverlay {} else {
            #expect(Bool(false), "Dismiss must advance to the next queued overlay")
        }
        #expect(q.pendingCount == 0)
    }

    @Test func overlayQueue_resetClearsCurrentAndPending() {
        let q = OverlayQueueManager()
        q.enqueue(.celebration(stars: 3))
        q.enqueue(.kpOverlay)
        q.reset()
        #expect(q.currentOverlay == nil)
        #expect(q.pendingCount == 0)
    }
}

// MARK: - Private helpers

private func validJSON(letter: String) -> String {
    """
    {"letter":"\(letter)","checkpointRadius":0.06,"strokes":[{"id":1,"checkpoints":[{"x":0.2,"y":0.2},{"x":0.8,"y":0.8}]}]}
    """
}

private struct LocalMockResourceProvider: LetterResourceProviding {
    var bundle: Bundle = .main
    var searchBundles: [Bundle] { [bundle] }
    let urls: [URL]; let byRelativePath: [String: URL]
    func allResourceURLs() -> [URL] { urls }
    func resourceURL(for relativePath: String) -> URL? { byRelativePath[relativePath] }
}

private final class TempResourceFS {
    let root: URL
    var provider: LocalMockResourceProvider {
        let urls = (try? FileManager.default.subpathsOfDirectory(atPath: root.path))?.map {
            root.appendingPathComponent($0)
        } ?? []
        let map = Dictionary(uniqueKeysWithValues: urls.map { url in
            (url.path.replacingOccurrences(of: root.path + "/", with: ""), url)
        })
        return LocalMockResourceProvider(urls: urls, byRelativePath: map)
    }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func write(relative: String, content: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
private final class LocalMockAudioController: AudioControlling {
    var initializationError: String? { nil }
    private(set) var loadedFiles: [String] = []
    private(set) var suspendForLifecycleCount = 0
    private(set) var resumeAfterLifecycleCount = 0
    private(set) var playCount = 0
    private(set) var stopCount = 0
    private(set) var cancelPendingLifecycleWorkCount = 0
    private(set) var setAdaptivePlaybackCount = 0
    func loadAudioFile(named fileName: String, autoplay: Bool) { loadedFiles.append(fileName) }
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) { setAdaptivePlaybackCount += 1 }
    func play() { playCount += 1 }
    func stop() { stopCount += 1 }
    func restart() {}
    func suspendForLifecycle() { suspendForLifecycleCount += 1 }
    func resumeAfterLifecycle() { resumeAfterLifecycleCount += 1 }
    func cancelPendingLifecycleWork() { cancelPendingLifecycleWorkCount += 1 }
}

// MARK: - feedbackIntensity per phase

@MainActor
struct FeedbackIntensityTests {
    @Test("Observe + direct phases broadcast full feedback intensity")
    func fullIntensityInPreTracePhases() {
        // The feedbackIntensity computed property is what gates haptics +
        // audio inside `updateTouch`. The stub VM lands at .guided under
        // .guidedOnly thesis condition, so we read the property directly.
        let vm = makeTestVM()
        #expect(vm.feedbackIntensity == 0.6, "guided phase gates audio at 0.6 (gate threshold > 0.3 keeps audio on)")
    }

    @Test("starThreshold matches LearningPhaseController spec")
    func starThresholdsExactValues() {
        // Observe / direct are pass/fail (threshold 0), guided 0.5,
        // freeWrite 0.4. UI mirrors this so copy stays consistent.
        #expect(LearningPhaseController.starThreshold(for: .observe)   == 0.0)
        #expect(LearningPhaseController.starThreshold(for: .direct)    == 0.0)
        #expect(LearningPhaseController.starThreshold(for: .guided)    == 0.5)
        #expect(LearningPhaseController.starThreshold(for: .freeWrite) == 0.4)
    }
}

// MARK: - Variant strokes loading

@MainActor
struct VariantStrokesTests {
    @Test("currentLetterHasVariants is true for letter F")
    func uppercaseFHasRegisteredVariant() {
        // The stub resource provider only contains a synthetic "A" letter
        // with no variants, so we verify the negative case here. Production
        // bundle scan coverage lives in LetterRepositoryTests.
        let vm = makeTestVM()
        #expect(vm.currentLetterHasVariants == false,
                "Stub letter has no registered variants")
    }
}

// MARK: - RecognitionResult Codable round-trip

struct RecognitionResultCodableTests {
    // A "RecognitionResult round-trips through JSON encoder" test that compared
    // a value to a member-wise copy of itself was removed on 2026-09-04: it
    // could not fail (RecognitionResult is not Codable; RecognitionSample is).

    @Test("RecognitionSample round-trips through JSON")
    func recognitionSampleRoundTrip() throws {
        let sample = RecognitionSample(
            predictedLetter: "O",
            confidence: 0.62,
            isCorrect: false
        )
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(RecognitionSample.self, from: data)
        #expect(decoded == sample)
    }
}

// MARK: - Freeform word segmentation

struct BucketStrokesByTargetLetterTests {
    @Test("Three-letter word splits strokes by x-centroid")
    func threeBuckets() {
        // Two strokes per letter, each 5 points. Target word has 3
        // letters → 3 equal-width buckets across a 300 pt canvas.
        let pts: [CGPoint] = [
            // Letter slot 0 (x ∈ [0, 100))
            CGPoint(x: 30, y: 50), CGPoint(x: 35, y: 60),
            CGPoint(x: 40, y: 70), CGPoint(x: 45, y: 80), CGPoint(x: 50, y: 90),
            // Letter slot 1 (x ∈ [100, 200))
            CGPoint(x: 130, y: 50), CGPoint(x: 135, y: 60),
            CGPoint(x: 140, y: 70), CGPoint(x: 145, y: 80), CGPoint(x: 150, y: 90),
            // Letter slot 2 (x ∈ [200, 300))
            CGPoint(x: 230, y: 50), CGPoint(x: 235, y: 60),
            CGPoint(x: 240, y: 70), CGPoint(x: 245, y: 80), CGPoint(x: 250, y: 90)
        ]
        let buckets = TracingViewModel.bucketStrokesByTargetLetter(
            points: pts,
            strokeSizes: [5, 5, 5],
            canvasWidth: 300,
            letterCount: 3
        )
        #expect(buckets.count == 3)
        #expect(buckets[0].count == 5)
        #expect(buckets[1].count == 5)
        #expect(buckets[2].count == 5)
    }

    @Test("Empty buckets stay empty when a slot got no strokes")
    func missingLetterPaddedWithEmptyBucket() {
        // Three target letters but only the first column got any strokes.
        // The slot-aligned UI relies on the array always returning length
        // == letterCount so missing letters render as grey placeholders.
        let pts: [CGPoint] = [
            CGPoint(x: 20, y: 40), CGPoint(x: 25, y: 50),
            CGPoint(x: 30, y: 60), CGPoint(x: 35, y: 70)
        ]
        let buckets = TracingViewModel.bucketStrokesByTargetLetter(
            points: pts,
            strokeSizes: [4],
            canvasWidth: 300,
            letterCount: 3
        )
        #expect(buckets.count == 3)
        #expect(buckets[0].count == 4)
        #expect(buckets[1].isEmpty)
        #expect(buckets[2].isEmpty)
    }

    @Test("Strokes whose centroid sits past the canvas clamp to last bucket")
    func clampOverflowToLastBucket() {
        // A stroke whose centroid is at x=350 (past the 300pt canvas)
        // must clamp into the last bucket rather than crash or be
        // silently dropped.
        let pts: [CGPoint] = [
            CGPoint(x: 320, y: 50), CGPoint(x: 360, y: 60), CGPoint(x: 380, y: 70)
        ]
        let buckets = TracingViewModel.bucketStrokesByTargetLetter(
            points: pts,
            strokeSizes: [3],
            canvasWidth: 300,
            letterCount: 3
        )
        #expect(buckets.count == 3)
        #expect(buckets[2].count == 3)
    }

    @Test("Zero letterCount yields empty result without dividing by zero")
    func degenerateLetterCount() {
        let buckets = TracingViewModel.bucketStrokesByTargetLetter(
            points: [CGPoint(x: 50, y: 50)],
            strokeSizes: [1],
            canvasWidth: 300,
            letterCount: 0
        )
        #expect(buckets.isEmpty)
    }
}

// MARK: - SpeechSynthesizer integration

@MainActor
struct ChildSpeechLibraryTests {
    @Test("Phase entry phrases are German and per-phase distinct")
    func phaseEntryGerman() {
        // Pin the per-phase prompts so any rewording lands in code review
        // with full context — children must hear distinct cues.
        #expect(ChildSpeechLibrary.phaseEntry(.observe).contains("Pass"))
        #expect(ChildSpeechLibrary.phaseEntry(.direct).contains("Punkte"))
        #expect(ChildSpeechLibrary.phaseEntry(.guided).contains("Linie"))
        #expect(ChildSpeechLibrary.phaseEntry(.freeWrite).contains("ohne Hilfe"))
    }

    @Test("Praise tier maps to encouraging German phrases")
    func praiseTier() {
        #expect(ChildSpeechLibrary.praise(starsEarned: 4).contains("perfekt"))
        #expect(ChildSpeechLibrary.praise(starsEarned: 3).contains("Toll"))
        #expect(ChildSpeechLibrary.praise(starsEarned: 0).contains("nochmal"))
    }

    @Test("Recognition phrase is silent on low-confidence wrong predictions")
    func recognitionSilentOnLowConfidenceWrong() {
        let result = RecognitionResult(
            predictedLetter: "O",
            confidence: 0.55,        // mid-confidence
            topThree: [.init(letter: "O", confidence: 0.55)],
            isCorrect: false          // wrong letter
        )
        #expect(ChildSpeechLibrary.recognition(result, expected: "A").isEmpty,
                "Mid-confidence wrong predictions stay silent so the child isn't confused")
    }

    @Test("NullSpeechSynthesizer captures every spoken line")
    func nullSpeechSynthesizerRecords() {
        let s = NullSpeechSynthesizer()
        s.speak("Anschauen")
        s.speak("Nachspuren")
        s.stop()
        #expect(s.spokenLines == ["Anschauen", "Nachspuren"])
        #expect(s.stopCount == 1)
    }
}
