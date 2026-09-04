import UIKit
import CoreGraphics
import QuartzCore
import Foundation

@MainActor
@Observable
public final class TracingViewModel {

    // MARK: - Public observable state

    var showGhost           = false
    /// True shows every bundled letter; false limits to the 7 demo
    /// letters (A, F, I, K, L, M, O). Default true; flag remains for a
    /// future "thesis demo" mode.
    var showAllLetters      = true
    var pencilPressure: CGFloat? = nil
    var pencilAzimuth: CGFloat   = 0
    var showDebug           = false
    /// Calibration mode — hides other debug panels so they don't sit
    /// on top of the calibrator controls. Only meaningful with
    /// `showDebug` true.
    var showCalibration     = false
    /// Drops all learning-phase overlays during calibration so the
    /// calibrator's dots aren't buried under phase UI.
    var isCalibrating: Bool { showDebug && showCalibration }

    /// Bottom-screen band reserved for the calibrator's UI bar.
    /// `TracingCanvasView` shrinks the glyph by this much during
    /// calibration; `StrokeCalibrationOverlay` shrinks its skeleton/
    /// bbox/handle math by the same amount. The two MUST agree or
    /// glyph and skeleton drift apart (see commit 1871466c → revert
    /// 74dcb11b).
    static let calibratorBottomInset: CGFloat = 180
    var letterOrdering: LetterOrderingStrategy = .motorSimilarity
    var schriftArt: SchriftArt = .druckschrift {
        didSet {
            guard oldValue != schriftArt,
                  !letters.isEmpty, letterIndex < letters.count else { return }
            scriptStrokeCache.removeAll(keepingCapacity: true)
            PrimaeLetterRenderer.clearCache()
            // Invariant: variants are druckschrift-only. Clear the
            // variant on every script change so the impossible state
            // never becomes observable.
            if schriftArt != .druckschrift {
                showingVariant = false
                variantStrokeCache = nil
            }
            // Glyph is rendered as a vector path each frame; the next
            // Canvas redraw picks up the new font automatically.
            reloadStrokeCheckpoints(for: letters[letterIndex])
            // Tracker resets to empty checkpoints; zero the bar so the
            // previous font's progress doesn't linger until next touch.
            progress = 0
        }
    }
    /// Forwarded from `TransientMessagePresenter`.
    var toastMessage: String? { messages.toastMessage }
    var currentLetterName   = "A"
    var canvasSize: CGSize  = CGSize(width: 1024, height: 1024) {
        didSet {
            guard oldValue != canvasSize,
                  !letters.isEmpty, letterIndex < letters.count else { return }
            // Re-layout BEFORE checkpoint reload — reload reads each
            // cell's frame to map strokes into cell-local space.
            grid.layout(in: canvasSize, schriftArt: schriftArt)
            reloadStrokeCheckpoints(for: letters[letterIndex])
        }
    }

    /// Read-only view of the grid's cells for the canvas renderer.
    var gridCells: [LetterCell] { grid.cells }

    /// Current grid preset — exposed so the canvas can compute cell
    /// frames from the live Canvas `size`, sidestepping the
    /// first-render window where `vm.canvasSize` hasn't caught up.
    var gridPreset: InputPreset { grid.preset }

    /// Active cell index. Canvas scopes active-only scaffolding to it.
    var gridActiveCellIndex: Int { grid.activeCellIndex }

    /// Active-cell frame in canvas pixels for multi-cell layouts;
    /// `nil` for single-cell. Overlays that map glyph coordinates
    /// (DirectPhaseDotsOverlay) need this for word mode.
    var multiCellActiveFrame: CGRect? {
        grid.cells.count > 1 ? grid.activeCell.frame : nil
    }

    /// Rendered word layout — non-nil for `.word` sequences after a
    /// successful CoreText layout; canvas blits this so Schreibschrift
    /// ligatures aren't cropped per glyph.
    var gridWordRendering: PrimaeLetterRenderer.WordRendering? { grid.wordRendering }

    /// Cell-fraction strokes (0..1 of the cell's own frame) for the cell
    /// at `index`. JSON strokes are bbox-relative; this remaps them
    /// through the cell's glyph rect so the renderer and tracker share
    /// one coordinate system regardless of cell aspect ratio.
    func gridCellStrokes(at index: Int) -> LetterStrokes? {
        guard index < grid.cells.count else { return nil }
        let cellLetter = grid.cells[index].item.letter
        let raw: LetterStrokes?
        if cellLetter == currentLetterName {
            raw = glyphRelativeStrokes
        } else {
            raw = letters.first(where: { $0.name == cellLetter })?.strokes
        }
        guard let raw else { return nil }
        let cellSize = grid.cells[index].frame.size
        // Word mode: `cellSize` is a per-character frame from
        // CTLineGetGlyphRuns, which is already snug around the ink.
        // Skip the 10 % padding `normalizedGlyphRect` applies for
        // single-letter cells so checkpoints align with the rendered
        // word image instead of sitting ~5 % inside it.
        let cellPad: CGFloat = grid.wordRendering == nil ? 0.10 : 0.0
        guard cellSize.width > 0, cellSize.height > 0,
              let gr = PrimaeLetterRenderer.normalizedGlyphRect(
                for: cellLetter, canvasSize: cellSize,
                schriftArt: schriftArt,
                openTypeFeatures: PrimaeLetterRenderer.openTypeFeatures(
                    for: cellLetter, schriftArt: schriftArt, variant: showingVariant),
                pad: cellPad) else {
            return raw
        }
        let mapped = raw.strokes.map { def in
            StrokeDefinition(
                id: def.id,
                checkpoints: def.checkpoints.map { cp in
                    Checkpoint(
                        x: gr.minX + cp.x * gr.width,
                        y: gr.minY + cp.y * gr.height
                    )
                }
            )
        }
        return LetterStrokes(letter: raw.letter,
                             checkpointRadius: raw.checkpointRadius
                                 * sqrt(gr.width * gr.height),
                             strokes: mapped)
    }

    /// Letter at cell `index`. Canvas uses this for per-cell glyph
    /// rendering in word mode.
    func gridCellLetter(at index: Int) -> String? {
        guard index < grid.cells.count else { return nil }
        return grid.cells[index].item.letter
    }

    /// Exposed for debug UI and tests.
    var inputModeDetector: InputModeDetector { detector }

    /// Pencil touchesBegan forwarder. Feeds the detector and re-applies
    /// the grid preset so the layout splits before the stroke
    /// completes; tracking is cell-aware so touches still feed the
    /// active cell correctly.
    func pencilDidTouchDown() {
        let priorKind = detector.effectiveKind
        detector.observeTouchBegan(isPencil: true)
        if priorKind != detector.effectiveKind,
           letters.indices.contains(letterIndex) {
            reapplyGridPreset()
            reloadStrokeCheckpoints(for: letters[letterIndex])
        }
    }

    /// Finger touchesBegan forwarder; feeds the detector hysteresis
    /// counter for pencil-session demotion.
    func fingerDidTouchDown() {
        detector.observeTouchBegan(isPencil: false)
    }

    /// Rebuild the grid's sequence + preset for the detector's mode.
    ///   - `.finger`: length-1 singleLetter sequence.
    ///   - `.pencil`: repetition sequence broadcasting the current
    ///     letter across the preset's default cell count.
    func reapplyGridPreset() {
        guard letters.indices.contains(letterIndex) else { return }
        let letter = letters[letterIndex]
        let usePencil = detector.effectiveKind == .pencil
        let preset: InputPreset = usePencil ? .pencil : .finger
        let sequence: TracingSequence = usePencil
            ? .repetition(letter.name, count: preset.cellCount)
            : .singleLetter(letter.name)
        grid.load(sequence: sequence, preset: preset)
        grid.layout(in: canvasSize, schriftArt: schriftArt)
        // Preset changes alter cell frames; the idempotency cache
        // doesn't include preset state, so force a rebuild.
        lastCheckpointKey = nil
    }
    var progress: CGFloat   = 0
    var isPlaying           = false
    var activePath: [CGPoint] = []
    /// Snapshot of the just-completed activePath so the child can still
    /// see what they wrote for ~5 s after the phase transition clears
    /// `activePath`. Cleared by a delayed task scheduled in
    /// `resetForPhaseTransition`, or immediately on the next touch.
    var lingeringInk: [CGPoint] = []
    private var lingeringInkClearTask: Task<Void, Never>? = nil
    /// Updated by `PhaseTransitionCoordinator.commitCompletion`.
    var currentDifficultyTier: DifficultyTier = .standard

    // MARK: - Learning phase state

    var learningPhase: LearningPhase { phaseController.currentPhase }
    var phaseScores: [LearningPhase: CGFloat] { phaseController.phaseScores }
    var isPhaseSessionComplete: Bool { phaseController.isLetterSessionComplete }

    /// Whether stroke-start dots render in the current phase
    /// (Pearson & Gallagher 1983 GRRM).
    var showCheckpoints: Bool { phaseController.showCheckpoints }

    /// Phase-driven ghost-line visibility, composed with user toggle.
    /// observe + guided ON; direct + freeWrite OFF (direct uses the
    /// numbered dots + arrow; freeWrite withdraws all scaffolding per
    /// Schmidt & Lee's Guidance Hypothesis).
    var showGhostForPhase: Bool {
        switch phaseController.currentPhase {
        case .observe, .guided:    return true
        case .direct, .freeWrite:  return false
        }
    }

    /// Guidance-fading intensity (Schmidt & Lee 2005). Gates haptics +
    /// checkpoint ticks; letter-sound audio is NOT gated since the
    /// phoneme is the glyph's auditory anchor, not guidance feedback.
    /// observe/direct=1.0, guided=0.6, freeWrite=0.0.
    var feedbackIntensity: CGFloat {
        switch phaseController.currentPhase {
        case .observe:   return 1.0
        case .direct:    return 1.0
        case .guided:    return 0.6
        case .freeWrite: return 0.0
        }
    }

    /// Stroke data for the calibration overlay (canvas-mapped).
    var strokeDefinition: LetterStrokes? { strokeTracker.definition }

    /// The single resolution chokepoint for a letter's scored,
    /// bbox-relative strokes. In study mode the on-device
    /// `CalibrationStore` override is bypassed so the scored path returns
    /// the identical frozen *bundle* stimulus — the thesis-truth-condition
    /// behind Ch.5's "every child traces the identical frozen stimulus"
    /// claim (`StrokeGeometryGoldenTests` pins this `letter.strokes`
    /// target). Otherwise the saved user calibration wins, unchanged.
    /// Used by the three scored-geometry sites only — deliberately NOT by
    /// `loadAllEffectiveStrokes` (the calibrator export must still see
    /// overrides).
    func resolvedStrokes(for letter: LetterAsset) -> LetterStrokes {
        if studyMode { return letter.strokes }
        return calibrationStore.strokes(for: letter.name, schriftArt: schriftArt)
            ?? letter.strokes
    }

    /// Raw glyph-relative strokes (0-1 within bbox). Non-Druckschrift
    /// always uses bundle JSON (committed calibrations in
    /// `strokes_schulschrift.json` are authoritative). Druckschrift
    /// prefers the user-calibrated Application Support file (unless
    /// `studyMode` bypasses it — see `resolvedStrokes(for:)`).
    var glyphRelativeStrokes: LetterStrokes? {
        guard !letters.isEmpty, letterIndex < letters.count else { return nil }
        if showingVariant, let vs = variantStrokeCache { return vs }
        if let ss = activeScriptStrokes { return ss }
        let letter = letters[letterIndex]
        return resolvedStrokes(for: letter)
    }

    /// Active-letter strokes mapped from bbox-relative to cell-fraction
    /// (via the active cell's glyph rect). Canvas dots, guide animation,
    /// and observe-phase playback all consume these so screen positions
    /// match the rendered ghost regardless of cell aspect ratio. Falls
    /// through to bbox-relative when the cell hasn't laid out yet.
    var rawGlyphStrokes: LetterStrokes? {
        guard !letters.isEmpty, letterIndex < letters.count else { return nil }
        let letter = letters[letterIndex]
        let bbox: LetterStrokes
        if showingVariant, let vs = variantStrokeCache {
            bbox = vs
        } else if let ss = activeScriptStrokes {
            bbox = ss
        } else {
            bbox = resolvedStrokes(for: letter)
        }
        let cellSize = grid.activeCell.frame.size
        guard cellSize.width > 0, cellSize.height > 0,
              let gr = PrimaeLetterRenderer.normalizedGlyphRect(
                for: currentLetterName, canvasSize: cellSize,
                schriftArt: schriftArt,
                openTypeFeatures: currentGlyphFeatures) else {
            return bbox
        }
        let mapped = bbox.strokes.map { def in
            StrokeDefinition(
                id: def.id,
                checkpoints: def.checkpoints.map { cp in
                    Checkpoint(
                        x: gr.minX + cp.x * gr.width,
                        y: gr.minY + cp.y * gr.height
                    )
                }
            )
        }
        return LetterStrokes(letter: bbox.letter,
                             checkpointRadius: bbox.checkpointRadius
                                 * sqrt(gr.width * gr.height),
                             strokes: mapped)
    }

    /// True when the current letter has a variant in the active
    /// script. Variant files are Druckschrift-only for now, so the
    /// button stays hidden in Schreibschrift to avoid rendering a
    /// print path over a cursive glyph.
    var currentLetterHasVariants: Bool {
        // Study sessions pin the standard stroke form: a child-reachable
        // variant toggle would swap F's scorer reference geometry
        // mid-study (different checkpoint count + radius).
        guard !studyMode, !letters.isEmpty, letterIndex < letters.count,
              schriftArt == .druckschrift else { return false }
        return !(letters[letterIndex].variants?.isEmpty ?? true)
    }

    /// OpenType feature tags to apply when rendering the current
    /// letter — pulls the alternate glyph (e.g. curled-k via `ss02`)
    /// when `showingVariant` is on. Empty otherwise.
    var currentGlyphFeatures: [String] {
        guard !letters.isEmpty, letterIndex < letters.count else { return [] }
        let name = letters[letterIndex].name
        return PrimaeLetterRenderer.openTypeFeatures(for: name,
                                                    schriftArt: schriftArt,
                                                    variant: showingVariant)
    }
    /// Stars earned in the current session (0-3).
    var starsEarned: Int { phaseController.starsEarned }
    /// Maximum achievable stars; guidedOnly/control = 1, threePhase = 4
    /// — showing 4 placeholders for a single-phase condition would be
    /// a between-arms confound.
    var maxStars: Int { phaseController.maxStars }
    /// Phases active in the current condition (drives the dot HUD so
    /// single-phase conditions don't render empty placeholders).
    var activePhases: [LearningPhase] { phaseController.activePhases }

    // MARK: - FreeWrite phase data (forwarded from FreeWritePhaseRecorder)

    /// Accumulated canvas-space touch points for free-write scoring.
    var freeWritePoints: [CGPoint] { freeWriteRecorder.points }
    /// CACurrentMediaTime timestamps for each accumulated free-write point.
    var freeWriteTimestamps: [CFTimeInterval] { freeWriteRecorder.timestamps }
    /// Digitiser force at each accumulated free-write point (0 = finger / no data).
    var freeWriteForces: [CGFloat] { freeWriteRecorder.forces }
    /// Checkpoints completed per second in guided / freeWrite. Note
    /// the unit: checkpoints, not strokes — the name matters for
    /// motor-rhythm correlations.
    var checkpointsPerSecond: CGFloat { freeWriteRecorder.checkpointsPerSecond }
    /// Raw, order-invariant spatial deviation of the measured freeWrite
    /// trace via stroke correspondence, or nil if none was measured. The
    /// study's PRIMARY accuracy outcome — see
    /// `PhaseSessionRecord.spatialDeviation` and `StrokeProcessMeasures`.
    var lastFreeWriteSpatialDeviation: CGFloat? { freeWriteRecorder.lastSpatialDeviation }
    /// Stroke count/order/direction of the measured freeWrite trace, or
    /// nil if none was measured. The study's SECONDARY process outcomes
    /// (2026-09-03) — see `PhaseSessionRecord.strokeCount` and siblings.
    var lastFreeWriteStrokeProcess: StrokeProcessMeasures? { freeWriteRecorder.lastStrokeProcess }
    /// Most recent four-dimension Schreibmotorik assessment.
    var lastWritingAssessment: WritingAssessment? { freeWriteRecorder.lastAssessment }
    /// Last guided-phase score, captured for the "Nachspuren fertig"
    /// feedback band.
    var lastGuidedScore: CGFloat? { freeWriteRecorder.lastGuidedScore }
    /// Normalised freeWrite touch path for the KP overlay.
    var freeWritePath: [CGPoint] { freeWriteRecorder.path }
    /// Stroke-start indices so the KP overlay can break the polyline
    /// at lifts instead of bridging gaps with phantom diagonals.
    var freeWriteStrokeStartIndices: [Int] { freeWriteRecorder.strokeStartIndices }

    /// All captured raw freeWrite traces — read by the exporter so the
    /// JSON archive carries the lossless traces alongside the records.
    var rawTraces: [RawTrace] { rawTraceStore.traces }

    /// Snapshot the current freeWrite buffer as a raw trace and persist
    /// it (re-analysis insurance), returning its id — or nil if there's
    /// nothing to capture. Called at phase exit BEFORE the buffer clears
    /// on the next letter load. Writing the trace FIRST (then the linking
    /// record) means a crash leaves at most an orphan trace, never a
    /// record pointing at a missing trace.
    func captureFreeWriteTrace() -> UUID? {
        guard !freeWritePoints.isEmpty else { return nil }
        let trace = RawTrace(
            id: UUID(),
            letter: currentLetterName,
            recordedAt: Date(),
            points: freeWritePoints,
            timestamps: freeWriteTimestamps,
            forces: freeWriteForces,
            strokeStartIndices: freeWriteStrokeStartIndices,
            canvasSize: canvasSize
        )
        rawTraceStore.append(trace)
        return trace.id
    }

    /// Whether the user is tracing the variant stroke form.
    var showingVariant: Bool = false
    /// Paper-transfer phase enabled (thesis setting).
    var enablePaperTransfer: Bool = false {
        didSet {
            UserDefaults.standard.set(enablePaperTransfer,
                forKey: "de.flamingistan.primae.enablePaperTransfer")
        }
    }
    /// Freeform-mode picker entry exposed; default on.
    var enableFreeformMode: Bool = true {
        didSet {
            UserDefaults.standard.set(enableFreeformMode,
                forKey: "de.flamingistan.primae.enableFreeformMode")
        }
    }
    /// Play the phoneme (/a/) instead of the letter name (/aː/);
    /// falls back to name audio when a letter ships no phoneme set so
    /// the toggle never produces silence.
    var enablePhonemeMode: Bool = false {
        didSet {
            UserDefaults.standard.set(enablePhonemeMode,
                forKey: "de.flamingistan.primae.enablePhonemeMode")
            // Reset the variant cursor so a swipe doesn't index out
            // of the new population.
            audioIndex = 0
        }
    }
    /// Study mode for pilot devices: bypass the on-device
    /// `CalibrationStore` override so the scored path returns the frozen
    /// *bundle* stimulus (the thesis-truth-condition behind Ch.5's
    /// identical-across-arms claim). Off by default, so default behavior
    /// is unchanged. Geometry-only — affects nothing but
    /// `resolvedStrokes(for:)`. Persisted like the other research flags
    /// so a configured study device stays in study mode across relaunches.
    var studyMode: Bool = false {
        didSet {
            UserDefaults.standard.set(studyMode,
                forKey: StudyBuild.studyModeDefaultsKey)
        }
    }
    /// Opt-in spaced-retrieval prompts before every Nth letter; off
    /// by default (research feature, parents enable).
    var enableRetrievalPrompts: Bool = false {
        didSet {
            UserDefaults.standard.set(enableRetrievalPrompts,
                forKey: "de.flamingistan.primae.enableRetrievalPrompts")
        }
    }
    /// Built once in init; counter persists across runs via UserDefaults.
    let retrievalScheduler: RetrievalScheduler = RetrievalScheduler()
    /// Reverse direct-phase tap order — last stroke first
    /// (Spooner et al. 2014). Off by default; affects direct phase
    /// only, guided + freeWrite always run canonical order.
    var enableBackwardChaining: Bool = false {
        didSet {
            UserDefaults.standard.set(enableBackwardChaining,
                forKey: "de.flamingistan.primae.enableBackwardChaining")
        }
    }

    // MARK: - Recognition + freeform state (forwarded from FreeformController)

    /// Owns the freeform fields. VM owns the methods (they touch
    /// audio / recognizer / speech / stores). Views observe via
    /// forwarders.
    private let freeform = FreeformController()

    /// Most recent CoreML recognition result. Cleared on letter load
    /// and phase reset.
    private(set) var lastRecognitionResult: RecognitionResult?

    /// Idempotency gate for in-flight recognition Tasks; state-clearing
    /// transitions cancel so late completions are dropped.
    private let recognitionTokens = RecognitionTokenTracker()

    var writingMode: WritingMode {
        get { freeform.writingMode }
        set { freeform.writingMode = newValue }
    }
    var freeformSubMode: FreeformSubMode {
        get { freeform.freeformSubMode }
        set { freeform.freeformSubMode = newValue }
    }
    var freeformTargetWord: FreeformWord? { freeform.freeformTargetWord }
    var freeformPoints: [CGPoint] { freeform.freeformPoints }
    var freeformStrokeSizes: [Int] { freeform.freeformStrokeSizes }
    var freeformActivePath: [CGPoint] { freeform.freeformActivePath }
    var freeformWordResults: [RecognitionResult] { freeform.freeformWordResults }
    var freeformWordResultSlots: [RecognitionResult?] { freeform.freeformWordResultSlots }
    var freeformRecognitionDelay: TimeInterval {
        get { freeform.freeformRecognitionDelay }
        set { freeform.freeformRecognitionDelay = newValue }
    }
    var isWaitingForRecognition: Bool { freeform.isWaitingForRecognition }
    var isRecognizing: Bool { freeform.isRecognizing }
    var freeformCanvasSize: CGSize { freeform.freeformCanvasSize }
    var hasRecognitionCompleted: Bool { freeform.hasRecognitionCompleted }
    var isRecognitionModelAvailable: Bool? { freeform.isRecognitionModelAvailable }
    /// Form-accuracy from the last freeform recognition (0–1).
    var lastFreeformFormScore: CGFloat? { freeform.lastFreeformFormScore }

    /// Serialised canvas overlay scheduler. Canonical post-freeWrite
    /// order: kpOverlay → recognitionBadge → paperTransfer →
    /// celebration.
    let overlayQueue = OverlayQueueManager()

    // MARK: - Direct phase state

    /// Stroke indices whose start dot has been tapped in direct phase.
    private(set) var directTappedDots: Set<Int> = []
    /// True while the correct (next-expected) dot should pulse harder.
    var directPulsingDot: Bool = false
    /// 700 ms timer for clearing `directPulsingDot`; stored so rapid
    /// wrong taps don't accumulate orphaned Tasks.
    private var directPulsingTask: Task<Void, Never>? = nil
    /// Stroke whose direction arrow is briefly shown after a tap.
    var directArrowStrokeIndex: Int? = nil

    /// Next-expected dot index. With `enableBackwardChaining` the list
    /// iterates in reverse (Spooner et al. 2014); default off.
    var directNextExpectedDotIndex: Int {
        guard let rawStrokes = rawGlyphStrokes else { return 0 }
        let indices: [Int] = enableBackwardChaining
            ? Array(rawStrokes.strokes.indices).reversed()
            : Array(rawStrokes.strokes.indices)
        for i in indices where !directTappedDots.contains(i) { return i }
        return rawStrokes.strokes.count
    }

    // MARK: - Animation guide state

    /// Normalized 0–1 point for the animated guide dot; canvas scales
    /// to screen coords. Forwarded from AnimationGuideController.
    var animationGuidePoint: CGPoint? { animation.guidePoint }

    // MARK: - Onboarding state

    var isOnboardingComplete: Bool = false
    private(set) var onboardingStep: OnboardingStep = .welcome
    /// Onboarding variant locked at first `markComplete` so a later
    /// Settings toggle can't change the historical record.
    var onboardingVariant: OnboardingVariant = .full
    var onboardingProgress: Double { onboardingCoordinator.progress }

    // MARK: - Private dependencies

    private let repo: LetterRepository
    /// Active cell's stroke tracker. The reference is stable for a
    /// single-letter session; it shifts to the next cell on advance
    /// in multi-cell sequences.
    var strokeTracker: StrokeTracker { grid.activeCell.tracker }
    /// Schreibheft grid representation of the current sequence. Drives
    /// the canvas renderer via `gridCells` / `gridPreset`.
    let grid = SequenceGridController(
        sequence: .singleLetter(""),
        preset: .finger
    )

    /// Finger / pencil detector with hysteresis. Receives every
    /// touch-began event from the overlays; `effectiveKind` drives
    /// grid preset promotion.
    let detector = InputModeDetector()
    let audio: AudioControlling
    let haptics: HapticEngineProviding
    /// Persistent letter-progress store. External readers consume the
    /// read-only `allProgress` / `progress(for:)` forwarders below.
    /// `internal` so `PhaseTransitionCoordinator` can mutate it.
    let progressStore: ProgressStoring

    /// Read-only @Observable mirror of `progressStore.allProgress`.
    /// Stored, not computed: the underlying store isn't @Observable,
    /// so mutations there don't fire SwiftUI updates. Call
    /// `refreshProgressMirror()` after every store write.
    private(set) var allProgress: [String: LetterProgress] = [:]

    /// Resync the @Observable mirror from `progressStore`. Call after
    /// any store mutation.
    func refreshProgressMirror() {
        allProgress = progressStore.allProgress
    }

    /// Per-letter progress lookup.
    func progress(for letter: String) -> LetterProgress {
        progressStore.progress(for: letter)
    }

    /// Completions today (drives the daily-goal pill).
    var completionsToday: Int { progressStore.completionsToday }
    /// Parent-configurable daily goal; default 3.
    var dailyGoal: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: "de.flamingistan.primae.dailyGoal")
            return v > 0 ? v : 3
        }
        set {
            UserDefaults.standard.set(max(1, newValue), forKey: "de.flamingistan.primae.dailyGoal")
        }
    }
    let streakStore: StreakStoring
    let dashboardStore: ParentDashboardStoring
    /// Cold per-trial raw freeWrite traces (re-analysis insurance).
    private let rawTraceStore: RawTraceStoring
    let thesisCondition: ThesisCondition
    /// Pilot audio arm for this participant. Stamped onto every recorded
    /// session (H1); per-arm audio playback routing is H2.
    let audioCondition: PilotAudioCondition
    /// Trained 3-of-5 study-letter subset for this participant (third
    /// assignment axis). Filters the practice pool under `studyMode`;
    /// stamped onto every recorded session for trained/untrained
    /// partitioning in analysis.
    let trainedSubset: TrainedLetterSubset
    private let onboardingStore: OnboardingStoring
    private let notificationScheduler: LocalNotificationScheduler
    var adaptationPolicy: any AdaptationPolicy
    private var onboardingCoordinator: OnboardingCoordinator
    var phaseController: LearningPhaseController
    /// Set immediately before a `startPostTest(letter:)` load and consumed
    /// at the top of `load(letter:)` — see H6 there. Kept as a one-shot
    /// flag rather than a parameter threaded through every `load` call
    /// site, since only one caller ever needs it.
    private var pendingPostTestOverride = false
    /// In-flight pre-task sound-arm demonstration (see
    /// `PreTaskDemonstration` and `armPreTaskDemonstration`). Cancelled
    /// on every fresh letter load and the moment a real touch begins
    /// (`TouchDispatcher.beginTouch`), so a scripted demo point is never
    /// still writing to `setAdaptivePlayback`/`setSpatialPitch` once the
    /// child's own trace starts driving them.
    private var preTaskDemoTask: Task<Void, Never>?
    private let letterScheduler: LetterScheduler
    private let calibrationStore: CalibrationStore
    private let letterRecognizer: LetterRecognizerProtocol
    /// German speech synthesiser; non-readers hear scores as speech
    /// rather than seeing numeric dashboards.
    let speech: SpeechSynthesizing
    /// Bundled MP3 prompts (phase entries, praise tiers, paper cues,
    /// retrieval). Falls back to `speech` when missing; dynamic
    /// per-letter content goes through `speech` directly.
    let prompts: any PromptPlaying
    /// FreeWrite buffers + session timing + scoring.
    let freeWriteRecorder = FreeWritePhaseRecorder()

    // MARK: - Private playback / touch state

    var letters: [LetterAsset]          = []
    var letterIndex                      = 0
    private var variantStrokeCache: LetterStrokes? = nil
    /// Per-script stroke cache; invalidated in `schriftArt.didSet`.
    private var scriptStrokeCache: [SchriftArt: LetterStrokes] = [:]
    var audioIndex                       = 0
    /// Start of the current foreground window. Cleared on background
    /// so the session-duration timer doesn't tick while the iPad
    /// sleeps.
    var letterLoadTime: CFTimeInterval?
    /// Accumulated foreground-only practice time across
    /// background/foreground cycles for the current letter.
    var letterActiveTimeAccumulated: TimeInterval = 0
    /// Wall-clock `Date` of letter load. Distinct from `letterLoadTime`
    /// (CACurrentMediaTime) — survives background cycles.
    var letterLoadedDate: Date?
    var didCompleteCurrentLetter         = false
    /// Captured at selection so `schedulerEffectivenessProxy` has a
    /// real correlation value.
    var lastScheduledLetterPriority: Double = 0
    /// Two-phase init seam: built with a no-op callback, real
    /// `[weak self]` wired after `self` is initialised.
    let playback: PlaybackController
    private let messages: TransientMessagePresenter
    private let animation: AnimationGuideController
    /// Observe-phase cycle counter for auto-advance after the second loop.
    private var observeCycleCount: Int = 0
    /// Idempotency key for `reloadStrokeCheckpoints`. Reset when source
    /// data changes (e.g. calibration save).
    private var lastCheckpointKey: CheckpointBuildKey?

    /// Touch-session state + begin/update/endTouch flow. Two-phase
    /// init pattern (back-reference wired after init).
    let touchDispatcher: TouchDispatcher

    /// Phase-transition pipeline (scoring, post-freeWrite overlays,
    /// controller advance, completion). Two-phase init pattern.
    let phaseTransitions: PhaseTransitionCoordinator

    // MARK: - Init

    @MainActor
    public convenience init() { self.init(.live) }

    @MainActor
    init(_ deps: TracingDependencies = .live) {
        self.audio                  = deps.audio
        self.progressStore          = deps.progressStore
        // Study sessions: the ONLY audio is the arm's designated sound.
        // Silencing at the injection seam kills every other feedback
        // channel at once — TTS (phase cues, praise, retry lines),
        // prompt MP3s, the celebration chime, tap/buzz/tick effects,
        // and haptics — in ALL arms, so the silent arm is actually
        // silent and the sound arms carry no uncontrolled audio.
        self.haptics                = deps.studyMode ? NullHapticEngine() : deps.haptics
        self.repo                   = deps.repo
        self.streakStore            = deps.streakStore
        self.dashboardStore         = deps.dashboardStore
        self.rawTraceStore          = deps.rawTraceStore
        self.onboardingStore        = deps.onboardingStore
        self.notificationScheduler  = deps.notificationScheduler
        self.thesisCondition        = deps.thesisCondition
        self.audioCondition         = deps.audioCondition
        self.trainedSubset          = deps.trainedSubset
        self.enablePaperTransfer    = deps.enablePaperTransfer
        self.enableFreeformMode     = deps.enableFreeformMode
        self.enablePhonemeMode      = deps.enablePhonemeMode
        self.studyMode              = deps.studyMode
        self.enableRetrievalPrompts = deps.enableRetrievalPrompts
        self.enableBackwardChaining = deps.enableBackwardChaining
        self.letterRecognizer       = deps.letterRecognizer
        // Same studyMode silencing rationale as `haptics` above.
        self.speech                 = deps.studyMode ? NullSpeechSynthesizer() : deps.speech
        self.prompts                = deps.studyMode ? NullPromptPlayer() : deps.makePromptPlayer(deps.speech)
        // Control condition uses fixed difficulty so the manipulation
        // can't confound the phase-progression IV. Study devices pin
        // difficulty at the standard tier for the same reason — the
        // pilot's IV is the audio arm, and an adapting checkpoint
        // radius would vary the guided task between children.
        self.adaptationPolicy       = deps.adaptationPolicy ?? (
            deps.thesisCondition == .control || deps.studyMode
                ? FixedAdaptationPolicy(currentTier: .standard)
                : MovingAverageAdaptationPolicy()
        )

        // Honour any recorded variant so post-hoc analysis sees the
        // first-encounter variant for this participant; otherwise
        // fall back to the parent's toggle.
        let useShort = UserDefaults.standard.bool(forKey: "de.flamingistan.primae.useShortOnboarding")
        let recordedVariant = deps.onboardingStore.variantUsed
        let activeVariant: OnboardingVariant = recordedVariant ?? (useShort ? .short : .full)
        self.onboardingVariant = activeVariant

        var coordinator = OnboardingCoordinator(steps: activeVariant.steps)
        if let savedStep = deps.onboardingStore.savedStep,
           activeVariant.steps.contains(savedStep) {
            coordinator.resume(at: savedStep)
        }
        self.onboardingCoordinator = coordinator
        self.onboardingStep        = coordinator.currentStep
        self.isOnboardingComplete  = deps.onboardingStore.hasCompletedOnboarding
        self.phaseController = LearningPhaseController(condition: deps.thesisCondition)
        // Study pins: the pilot is Druckschrift-only and its letter
        // order must be identical across children/devices — a stray
        // device setting must not swap the stimulus geometry or the
        // sequence. Session-only (init assignment skips the didSets,
        // so the stored parent settings survive studyMode).
        self.schriftArt = deps.studyMode ? .druckschrift : deps.schriftArt
        self.letterOrdering = deps.studyMode ? .motorSimilarity : deps.letterOrdering

        // Per-VM controllers from factories so tests can swap any one
        // without subclassing.
        self.messages         = deps.makeMessagePresenter()
        self.animation        = deps.makeAnimationGuide()
        self.calibrationStore = deps.makeCalibrationStore()
        self.letterScheduler  = deps.makeLetterScheduler()

        haptics.prepare()
        // Two-phase init: build with a no-op callback, wire the real
        // `[weak self]` once every stored property is assigned.
        let pb = deps.makePlaybackController(deps.audio) { _ in }
        self.playback = pb
        // Same pattern for touchDispatcher / phaseTransitions.
        let td = TouchDispatcher()
        self.touchDispatcher = td
        let ptc = PhaseTransitionCoordinator()
        self.phaseTransitions = ptc
        pb.onIsPlayingChanged = { [weak self] in self?.isPlaying = $0 }
        td.vm = self
        ptc.vm = self
        letters = repo.loadLettersFast()
        // Seed the mirror so the rail badge + gallery pick up
        // pre-existing progress on first render.
        allProgress = progressStore.allProgress
        // Surface startup audio failures as a brief toast.
        if let audioError = deps.audio.initializationError {
            messages.show(toast: audioError)
        }
        guard let first = letters.first else { return }
        // Don't play the phase cue at init — the audio session
        // hasn't settled and would produce ~2 s of crackle.
        load(letter: first, playPhaseCue: false)
    }

    // MARK: - Toggles

    func toggleGhost()             { showGhost.toggle();         toast("Hilfslinien \(showGhost ? "an" : "aus")") }

    /// Switch between standard and variant stroke form. Reloads
    /// checkpoints + resets tracing progress; phase state unchanged.
    func toggleVariant() {
        guard currentLetterHasVariants, letters.indices.contains(letterIndex) else { return }
        let letter = letters[letterIndex]
        showingVariant.toggle()
        if showingVariant && variantStrokeCache == nil {
            variantStrokeCache = loadVariantStrokesFromBundle(for: letter)
        }
        lastCheckpointKey = nil
        strokeTracker.reset()
        progress = 0
        activePath.removeAll(keepingCapacity: true)
        reloadStrokeCheckpoints(for: letter)
        toast(showingVariant ? "Variante" : "Standard")
    }

    private func loadVariantStrokesFromBundle(for letter: LetterAsset) -> LetterStrokes? {
        guard let variantID = letter.variants?.first else { return nil }
        return repo.loadVariantStrokes(for: letter.name, variantID: variantID)
    }

    /// Bundle strokes for the active script (loads
    /// `strokes_<variantID>.json` on first access). `nil` for
    /// Druckschrift (uses LetterAsset directly) or when no variant
    /// file exists. Driven by `SchriftArt.bundleVariantID`.
    private var activeScriptStrokes: LetterStrokes? {
        guard !letters.isEmpty, letterIndex < letters.count,
              let variantID = schriftArt.bundleVariantID else { return nil }
        if let cached = scriptStrokeCache[schriftArt] { return cached }
        guard let loaded = repo.loadVariantStrokes(
            for: letters[letterIndex].name, variantID: variantID) else { return nil }
        scriptStrokeCache[schriftArt] = loaded
        return loaded
    }

    // MARK: - Accessibility

    var accessibilityCanvasLabel: String {
        "Schreibfläche — Buchstabe \(currentLetterName)"
    }

    var accessibilityCanvasValue: String {
        let pct = Int(max(0, min(1, progress)) * 100)
        if pct == 0   { return "Nicht begonnen" }
        if pct == 100 { return "Fertig" }
        return "\(pct) Prozent fertig"
    }

    /// Autoplay the active cell's letter audio on cell advance in
    /// word mode. Always variant 0; silent for letters without audio.
    func autoplayActiveCellLetter() {
        let activeLetter = gridCellLetter(at: gridActiveCellIndex) ?? currentLetterName
        guard let asset = letters.first(where: { $0.name == activeLetter }),
              let first = activeAudioFiles(for: asset).first else { return }
        audio.loadAudioFile(named: first, autoplay: true)
    }

    func replayAudio() {
        // Reloads and autoplays the active cell's letter audio.
        // Silence is acceptable for letters without audio assets.
        let activeLetter = gridCellLetter(at: gridActiveCellIndex)
            ?? currentLetterName
        guard let asset = letters.first(where: { $0.name == activeLetter }) else { return }
        let files = activeAudioFiles(for: asset)
        guard files.indices.contains(audioIndex) else { return }
        audio.loadAudioFile(named: files[audioIndex], autoplay: true)
    }

    /// Audio file list for the active pilot arm (`audioCondition`). The
    /// arm chooses the CONTENT; the adaptive-playback coupling
    /// (TouchDispatcher.updateAdaptivePlayback) is identical for both
    /// sound arms and reads none of this — only the file list differs
    /// (§2.6 matching discipline). Silent returns []; every read site
    /// short-circuits on an empty list, so no file is ever loaded and no
    /// loop can play.
    func activeAudioFiles(for asset: LetterAsset) -> [String] {
        switch audioCondition {
        case .silent:
            return []
        case .spatial:
            // One shared, letter-independent carrier tone: the arm's
            // information channel is pen position (Y→pitch, X→pan), not
            // sound identity. No fallback to name audio: that would leak
            // letter-name content into the non-phonemic arm and confound
            // the contrast. `studyMode` is irrelevant here — the carrier
            // is bundled, so there is nothing to force or degrade to.
            return [SpatialSonification.carrierToneFile]
        case .phoneme:
            // H2.1 — study devices force phoneme content. A phoneme-arm
            // participant must hear the phoneme, never the letter name,
            // regardless of the parent `enablePhonemeMode` toggle (an
            // unset toggle would otherwise corrupt the IV silently). This
            // resolves at letter-load time, never on the per-tick
            // coupling path, so the matching discipline is untouched.
            if studyMode {
                if !asset.phonemeAudioFiles.isEmpty {
                    return asset.phonemeAudioFiles
                }
                // Residual, unavoidable confound: this letter has no
                // phoneme recording (the H5/P6 gap), so the phoneme arm
                // degrades to name audio. Logged — not silent — at
                // letter-load frequency so a study run isn't quietly
                // confounded. The real fix is recording the phoneme (H5).
                pilotAudioLogger.warning(
                    "Phoneme-arm study device: letter '\(asset.name, privacy: .public)' has no phoneme recording — degrading to name audio (H5/P6 gap).")
                return asset.audioFiles
            }
            // Off study devices: preserve the exact pre-pilot toggle so
            // casual users are byte-identical.
            if enablePhonemeMode, !asset.phonemeAudioFiles.isEmpty {
                return asset.phonemeAudioFiles
            }
            return asset.audioFiles
        }
    }

    // MARK: - Pre-task sound-arm demonstration

    /// Cancel any in-flight pre-task demonstration. Called the moment a
    /// real touch begins so the child's own trace is never racing a
    /// scripted demo point for the shared `setAdaptivePlayback`/
    /// `setSpatialPitch` calls — `TouchDispatcher.beginTouch` already
    /// reloads the real per-touch audio file regardless, which alone
    /// would supersede the demo's own file, but cancelling here also
    /// stops the demo's own sweep loop from continuing to run at all.
    func cancelPreTaskDemonstration() {
        preTaskDemoTask?.cancel()
        preTaskDemoTask = nil
    }

    /// Arm the pre-task sound-arm demonstration for a freshly loaded
    /// letter. Pilot-only (gated on `studyMode`, same gate H2.1 uses to
    /// force phoneme content) — casual, non-study sessions are
    /// unaffected. See `PreTaskDemonstration`'s header for the full
    /// rationale and the per-arm content. `duration` defaults to
    /// `PreTaskDemonstration.duration`; overridable so tests don't have
    /// to wait out the full production window.
    ///
    /// Not `private` — called from `load(letter:)`'s two fresh-letter
    /// entry points (observe and direct-to-guided), and directly from
    /// tests.
    func armPreTaskDemonstration(for letter: LetterAsset,
                                 duration: TimeInterval = PreTaskDemonstration.duration) {
        preTaskDemoTask?.cancel()
        preTaskDemoTask = nil
        guard studyMode else { return }
        switch audioCondition {
        case .silent:
            // No added audio — the unchanged ghost-letter animation
            // already running for this letter load IS the matched
            // non-auditory equivalent. See PreTaskDemonstration header.
            return
        case .phoneme:
            guard let first = activeAudioFiles(for: letter).first else { return }
            preTaskDemoTask = Task { [weak self] in
                // `.cancel()` only flips this flag — it does NOT stop
                // the closure from starting, so a task cancelled before
                // it ever ran (e.g. superseded by another
                // `armPreTaskDemonstration` call before this one got a
                // scheduler turn) would otherwise still fire the load
                // below. Checked BEFORE any side effect, not just before
                // the sleep.
                guard let self, !Task.isCancelled else { return }
                self.audio.loadAudioFile(named: first, autoplay: true)
                try? await Task.sleep(for: .seconds(duration))
            }
        case .spatial:
            let samples = PreTaskDemonstration.axisSweep(duration: duration)
            guard !samples.isEmpty else { return }
            preTaskDemoTask = Task { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.audio.loadAudioFile(named: SpatialSonification.carrierToneFile, autoplay: true)
                var previousElapsed: TimeInterval = 0
                for sample in samples {
                    if Task.isCancelled { break }
                    let dt = sample.elapsed - previousElapsed
                    if dt > 0 { try? await Task.sleep(for: .seconds(dt)) }
                    previousElapsed = sample.elapsed
                    if Task.isCancelled { break }
                    self.audio.setAdaptivePlayback(
                        speed: 1.0,
                        horizontalBias: Float(max(-1.0, min(1.0, sample.point.x * 2.0 - 1.0))))
                    self.audio.setSpatialPitch(
                        cents: SpatialSonification.pitchCents(forNormalizedY: sample.point.y))
                }
                if !Task.isCancelled { self.audio.stop() }
            }
        }
    }

    // MARK: - Letter navigation

    func resetLetter() {
        strokeTracker.reset()
        progress = 0
        activePath.removeAll(keepingCapacity: true)
        touchDispatcher.resetVelocity()
        playback.resumeIntent = false
        playback.cancelPending()
        audio.stop()
        playback.forceIdle()
        isPlaying = false
        didCompleteCurrentLetter = false
        messages.clearCompletionState()
        stopGuideAnimation()
        toast("Zurückgesetzt")
    }

    func loadLetter(name: String) {
        guard let idx = letters.firstIndex(where: { $0.name == name }) else { return }
        letterIndex = idx
        load(letter: letters[idx])
        toast("Buchstabe: \(currentLetterName)")
    }

    /// H6 post-test: load one of the two study letters this participant
    /// does NOT train, for a single COLD `freeWrite` pass. `load(letter:)`
    /// normally resets into `observe` (or `guided`, per thesis condition);
    /// this jumps straight to `freeWrite` instead, because reaching
    /// observe or guided at all would BE training the letter — the exact
    /// thing the within-child trained-vs-untrained contrast depends on
    /// not happening. No new export tagging is needed: `trainedSubset` is
    /// already stamped on every `PhaseSessionRecord`, so a freeWrite row
    /// for a letter outside it is already legible as untrained.
    ///
    /// Guarded on `studyMode` and on the letter actually being untrained —
    /// the researcher UI only ever offers the untrained pair, but the VM
    /// re-checks so a stale UI state can't start a real practice session
    /// under the post-test label. `loadLetter` itself is NOT gated by
    /// `visibleLetterNames` (that filter is UI-only), which is what makes
    /// this reachable at all.
    func startPostTest(letter: String) {
        guard studyMode, trainedSubset.untrainedLetters.contains(letter) else { return }
        pendingPostTestOverride = true
        loadLetter(name: letter)
    }

    var allLetterNames: [String] { letters.map(\.name) }

    func nextLetter() {
        let visible = visibleLetterNames
        guard !visible.isEmpty else { return }
        let currentIdx = visible.firstIndex(of: currentLetterName) ?? -1
        let nextName = visible[(currentIdx + 1) % visible.count]
        guard let idx = letters.firstIndex(where: { $0.name == nextName }) else { return }
        letterIndex = idx
        load(letter: letters[idx])
        toast("Buchstabe: \(currentLetterName)")
    }

    func previousLetter() {
        let visible = visibleLetterNames
        guard !visible.isEmpty else { return }
        let currentIdx = visible.firstIndex(of: currentLetterName) ?? 0
        let prevName = visible[(currentIdx - 1 + visible.count) % visible.count]
        guard let idx = letters.firstIndex(where: { $0.name == prevName }) else { return }
        letterIndex = idx
        load(letter: letters[idx])
        toast("Buchstabe: \(currentLetterName)")
    }

    /// Demo word list — Austrian Volksschule 1. Klasse Woche-1
    /// tracing words, ordered shortest → longest. Every word
    /// composes from letters in the demo bundle.
    static let demoWordList: [String] = [
        "OMA", "OMI", "OPA", "MAMA", "PAPA", "LAMA", "KILO", "FILM"
    ]

    func randomLetter() {
        let visible = visibleLetterNames
        guard !visible.isEmpty else { return }
        let randomName = visible[Int.random(in: 0..<visible.count)]
        guard let idx = letters.firstIndex(where: { $0.name == randomName }) else { return }
        letterIndex = idx
        load(letter: letters[idx])
        randomAudioVariant()
        toast("Zufall: \(currentLetterName)")
    }

    func nextAudioVariant() {
        guard !letters.isEmpty else { return }
        let files = activeAudioFiles(for: letters[letterIndex])
        guard !files.isEmpty else { return }
        guard files.indices.contains(audioIndex) else { audioIndex = 0; return }
        audioIndex = (audioIndex + 1) % files.count
        // Autoplay so the long-press UI gesture both switches and previews
        // in one step — no "silent swap" that requires a second tap to hear.
        audio.loadAudioFile(named: files[audioIndex], autoplay: true)
        toast("Ton \(audioIndex + 1) von \(files.count): \(soundLabel(for: files[audioIndex]))")
    }

    func previousAudioVariant() {
        guard !letters.isEmpty else { return }
        let files = activeAudioFiles(for: letters[letterIndex])
        guard !files.isEmpty else { return }
        guard files.indices.contains(audioIndex) else { audioIndex = 0; return }
        audioIndex = (audioIndex - 1 + files.count) % files.count
        audio.loadAudioFile(named: files[audioIndex], autoplay: true)
        toast("Ton \(audioIndex + 1) von \(files.count): \(soundLabel(for: files[audioIndex]))")
    }

    /// Human-friendly label — strips the letter prefix and `.mp3` so
    /// toasts read "Ton 4 von 5: Affe" instead of raw filenames.
    private func soundLabel(for file: String) -> String {
        var label = (file as NSString).deletingPathExtension
        if label.hasPrefix(currentLetterName), label.count > currentLetterName.count {
            label.removeFirst(currentLetterName.count)
        }
        return label.isEmpty ? file : label
    }

    // MARK: - Touch handling (forwarded to TouchDispatcher)

    func beginTouch(at p: CGPoint, t: CFTimeInterval) {
        touchDispatcher.beginTouch(at: p, t: t)
    }

    func updateTouch(at p: CGPoint, t: CFTimeInterval, canvasSize: CGSize) {
        touchDispatcher.updateTouch(at: p, t: t, canvasSize: canvasSize)
    }

    /// Test-only dispatcher state inspection.
    var debugSmoothedVelocity: CGFloat { touchDispatcher.smoothedVelocity }
    var debugIsSingleTouchInteractionActive: Bool { touchDispatcher.isSingleTouchInteractionActive }

    // MARK: - Lifecycle

    public func appDidEnterBackground() async {
        guard playback.appIsForeground else { return }
        playback.appIsForeground = false
        playback.cancelPending()
        endTouch()
        // Stop the active-time timer so backgrounded time isn't
        // counted; the accumulator survives the round-trip.
        if let start = letterLoadTime {
            letterActiveTimeAccumulated += CACurrentMediaTime() - start
            letterLoadTime = nil
        }
        let cmd = playback.transition(to: .idle)
        playback.apply(cmd)
        if cmd == .none { audio.stop(); isPlaying = false }
        audio.suspendForLifecycle()
        // Halt in-flight TTS so the voice doesn't keep talking.
        speech.stop()
        playback.resetPlayIntentClock()
        // Drain disk writes synchronously: iOS's suspension grace
        // window otherwise raced the prior fire-and-forget Tasks and
        // could lose a letter completion seconds before backgrounding.
        await progressStore.flush()
        await streakStore.flush()
        await dashboardStore.flush()
        // The raw trace and the PhaseSessionRecord that links to it live
        // in two separate stores. Draining the record without the trace
        // leaves exactly the dangling `rawTraceID` that the
        // capture-before-record ordering in `PhaseTransitionCoordinator`
        // exists to prevent — and the trial at risk is the last one of a
        // session, because that is when the proctor closes the app.
        await rawTraceStore.flush()
        await onboardingStore.flush()
    }

    public func appDidBecomeActive() {
        playback.appIsForeground = true
        audio.resumeAfterLifecycle()
        // Restart the active-time live slice for this foreground
        // window; the pre-background slice is in the accumulator.
        if letterLoadTime == nil, !didCompleteCurrentLetter {
            letterLoadTime = CACurrentMediaTime()
        }
        if playback.resumeIntent {
            playback.request(playback.state, immediate: true)
        }
        // Refresh daily reminder with current streak
        if isOnboardingComplete {
            notificationScheduler.scheduleDailyReminder(
                currentStreak: streakStore.currentStreak,
                onboardingComplete: true
            )
        }
    }

    func endTouch() {
        touchDispatcher.endTouch()
    }

    // MARK: - Animation guide

    func startGuideAnimation() {
        // Use rawGlyphStrokes so the dot follows the CURRENT script;
        // `letters[..].strokes` would play a Druckschrift path over a
        // Playwrite glyph in Schreibschrift mode.
        guard !letters.isEmpty, letterIndex < letters.count,
              let rawStrokes = rawGlyphStrokes,
              !rawStrokes.strokes.isEmpty else { return }
        // Auto-advance the observe phase after the second cycle so
        // non-reading children aren't stuck waiting on "Tippen".
        observeCycleCount = 0
        animation.onCycleComplete = { [weak self] in
            guard let self else { return }
            self.observeCycleCount += 1
            if self.observeCycleCount >= 2,
               self.phaseController.currentPhase == .observe {
                self.completeObservePhase()
            }
        }
        animation.start(strokes: rawStrokes)
    }

    func stopGuideAnimation() {
        animation.stop()
    }

    // MARK: - Onboarding control

    /// Advance one onboarding step.
    func advanceOnboarding() {
        guard onboardingCoordinator.advance() else { return }
        onboardingStep = onboardingCoordinator.currentStep
        if onboardingCoordinator.isComplete {
            // Record the first-completion variant only; re-runs leave
            // the historical record alone.
            onboardingStore.markComplete(variant: onboardingVariant)
            isOnboardingComplete = true
            speakInitialPhaseCueAfterOnboarding()
            // Request notification permission + schedule daily reminder.
            Task { [weak self] in
                guard let self else { return }
                _ = await self.notificationScheduler.requestPermission()
                self.notificationScheduler.scheduleDailyReminder(
                    currentStreak: self.streakStore.currentStreak,
                    onboardingComplete: true
                )
            }
        } else {
            onboardingStore.saveProgress(step: onboardingCoordinator.currentStep)
        }
    }

    /// Skip all onboarding steps immediately.
    func skipOnboarding() {
        onboardingCoordinator.skip()
        onboardingStep = onboardingCoordinator.currentStep
        onboardingStore.markComplete(variant: onboardingVariant)
        isOnboardingComplete = true
        speakInitialPhaseCueAfterOnboarding()
    }

    /// Play the phase-entry prompt right after onboarding finishes —
    /// the cue at the end of `load(letter:)` is gated on
    /// isOnboardingComplete and skipped during init, so refire here.
    private func speakInitialPhaseCueAfterOnboarding() {
        prompts.play(
            ChildSpeechLibrary.phaseEntryPromptKey(phaseController.currentPhase),
            fallbackText: ChildSpeechLibrary.phaseEntry(phaseController.currentPhase)
        )
    }

    /// Reset onboarding so it replays. Re-reads the parent variant
    /// preference; the historical `variantUsed` is preserved.
    func restartOnboarding() {
        onboardingStore.reset()
        let useShort = UserDefaults.standard.bool(forKey: "de.flamingistan.primae.useShortOnboarding")
        let recordedVariant = onboardingStore.variantUsed
        onboardingVariant = recordedVariant ?? (useShort ? .short : .full)
        onboardingCoordinator = OnboardingCoordinator(steps: onboardingVariant.steps)
        onboardingStep = onboardingCoordinator.currentStep
        isOnboardingComplete = false
    }

    // MARK: - Learning phase control

    /// Forwards to PhaseTransitionCoordinator.
    func advanceLearningPhase() {
        phaseTransitions.advance()
    }

    /// Run the recognizer on the freeWrite buffer. Result drives
    /// celebration vs retry routing in the coordinator.
    func runRecognizerForFreeWrite(score: CGFloat) {
        let pts = freeWritePoints
        let breaks = freeWriteRecorder.strokeStartIndices
        let size = canvasSize
        let expected = currentLetterName
        // FreeformController owns the spinner flag — only one
        // recognition is ever in flight.
        freeform.isRecognizing = true
        // Form-accuracy history feeds the calibrator's practised-letter
        // boost; empty on first encounter (skipped path). NOT
        // `recognitionAccuracy` — that is the recognizer's own past
        // CONFIDENCE, a different instrument from "has this child
        // historically formed this letter well" (2026-09-04 fix; see
        // `ProgressStoring.recordCompletion` and `formAccuracyHistory`).
        let history = (progressStore.progress(for: expected)
                       .formAccuracyHistory ?? [])
                      .map { CGFloat($0) }
        let token = recognitionTokens.issue()
        Task { [weak self, letterRecognizer] in
            let result = await letterRecognizer.recognize(
                points: pts, strokeStartIndices: breaks,
                canvasSize: size, expectedLetter: expected,
                historicalFormScores: history)
            guard let self else { return }
            await MainActor.run {
                guard self.recognitionTokens.isStillActive(token) else { return }
                self.freeform.isRecognizing = false
                self.lastRecognitionResult = result
                if let r = result {
                    self.progressStore.recordRecognitionSample(
                        letter: expected, result: r)
                    self.refreshProgressMirror()
                }
                self.phaseTransitions.completePostFreeWriteRecognition(
                    score: score, result: result)
            }
        }
    }

    /// Record the paper-transfer self-assessment and advance the queue.
    func submitPaperTransfer(score: Double) {
        progressStore.recordPaperTransferScore(for: currentLetterName, score: score)
        refreshProgressMirror()
        overlayQueue.dismiss()
    }

    /// Tap-to-continue completion of the observe phase.
    func completeObservePhase() {
        guard phaseController.currentPhase == .observe else { return }
        stopGuideAnimation()
        advanceLearningPhase()
    }

    /// Direct-phase dot tap. Correct order: confirmation audio +
    /// arrow, advances. Wrong order: gentle haptic, pulse the
    /// correct dot.
    func tapDirectDot(index: Int) {
        guard phaseController.currentPhase == .direct else { return }
        guard let rawStrokes = rawGlyphStrokes else { return }
        let total = rawStrokes.strokes.count
        guard index < total, !directTappedDots.contains(index) else { return }

        if index == directNextExpectedDotIndex {
            // The DirectPhaseDotsOverlay tap handler wraps this in
            // `withAnimation`; the curve lives at the call site so
            // the VM doesn't import SwiftUI.
            directTappedDots.insert(index)
            haptics.fire(.checkpointHit)
            // Per-tap chime: distinct confirmation per dot. Letter
            // audio plays only on first tap; replaying it per dot
            // was perceived as noisy duplication of the observe demo.
            prompts.playTapChime()
            // Brief directional arrow along the stroke path.
            directArrowStrokeIndex = index
            // Defer the final-dot phase advance until the arrow has
            // finished rendering so the last stroke gets its cue too.
            let isLastTap = directTappedDots.count >= total
            Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(1.2))
                if self.directArrowStrokeIndex == index {
                    self.directArrowStrokeIndex = nil
                }
                if isLastTap, self.phaseController.currentPhase == .direct {
                    self.haptics.fire(.letterCompleted)
                    self.advanceLearningPhase()
                }
            }
        } else {
            // Wrong dot — gentle haptic + lower-pitched buzz that
            // bypasses the mute switch (same path as the correct
            // chime) so the child hears the contrast.
            haptics.fire(.offPath)
            prompts.playWrongTapChime()
            directPulsingDot = true
            directPulsingTask?.cancel()
            directPulsingTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .milliseconds(700))
                self.directPulsingDot = false
                self.directPulsingTask = nil
            }
        }
    }

    /// Apply calibrated bbox-relative checkpoints (the JSON shape).
    /// Maps through the live cell's glyph rect into cell-fraction
    /// before loading the tracker so proximity hit-tests share frame
    /// with the renderer's ghost path.
    func applyCalibration(_ strokes: [[CGPoint]]) {
        let defs = strokes.enumerated().map { (i, pts) in
            StrokeDefinition(id: i + 1, checkpoints: pts.map { cp in
                Checkpoint(x: cp.x, y: cp.y)
            })
        }
        let bboxStrokes = LetterStrokes(letter: currentLetterName, checkpointRadius: 0.05, strokes: defs)
        let cellSize = grid.activeCell.frame.size
        guard cellSize.width > 0, cellSize.height > 0,
              let gr = PrimaeLetterRenderer.normalizedGlyphRect(
                for: currentLetterName, canvasSize: cellSize,
                schriftArt: schriftArt,
                openTypeFeatures: currentGlyphFeatures) else {
            strokeTracker.load(bboxStrokes)
            return
        }
        let mapped = bboxStrokes.strokes.map { def in
            StrokeDefinition(
                id: def.id,
                checkpoints: def.checkpoints.map { cp in
                    Checkpoint(
                        x: gr.minX + cp.x * gr.width,
                        y: gr.minY + cp.y * gr.height
                    )
                }
            )
        }
        strokeTracker.load(LetterStrokes(letter: bboxStrokes.letter,
                                         checkpointRadius: bboxStrokes.checkpointRadius
                                             * sqrt(gr.width * gr.height),
                                         strokes: mapped))
    }

    /// Load the spaced-repetition-recommended letter.
    func loadRecommendedLetter() {
        // Study sessions use a fixed deterministic order, never the
        // spaced-repetition scheduler (letter order must not diverge
        // with performance). Defensive: the celebration overlay that
        // normally triggers this is itself gated off under studyMode.
        if studyMode {
            nextLetter()
            return
        }
        // Confirmation haptic on celebration "Weiter".
        haptics.fire(.letterCompleted)
        let available = visibleLetterNames
        let scored = letterScheduler.prioritized(available: available,
                                                  progress: progressStore.allProgress)
        // Reset the queue when nothing's available so the celebration
        // doesn't strand the child.
        guard let best = scored.first,
              let idx  = letters.firstIndex(where: { $0.name == best.letter }) else {
            overlayQueue.reset()
            return
        }
        // Capture priority for `schedulerEffectivenessProxy`.
        lastScheduledLetterPriority = best.priority
        letterIndex = idx
        load(letter: letters[idx])
        toast("Empfohlen: \(currentLetterName)")
        // Slot a retrieval prompt ahead of tracing when the scheduler
        // says it's time and the letter has enough prior completions.
        if enableRetrievalPrompts {
            let prog = progressStore.progress(for: best.letter)
            if retrievalScheduler.shouldPrompt(for: best.letter, progress: prog) {
                let distractors = retrievalDistractors(for: best.letter, from: available)
                overlayQueue.enqueue(.retrievalPrompt(letter: best.letter, distractors: distractors))
            }
        }
    }

    /// Pick two distractors. Prefers motor-similarity cluster-mates
    /// (within ±5 rank) for pedagogical value; falls back to random
    /// pool members when the pool is small.
    private func retrievalDistractors(for target: String, from pool: [String]) -> [String] {
        let candidates = pool.filter { $0 != target }
        guard !candidates.isEmpty else { return [] }
        let order = LetterOrderingStrategy.motorSimilarity.orderedLetters()
        let rank: (String) -> Int = { letter in
            order.firstIndex(of: letter) ?? Int.max
        }
        let targetRank = rank(target)
        let near = candidates
            .filter { abs(rank($0) - targetRank) <= 5 }
            .shuffled()
            .prefix(2)
        if near.count == 2 { return Array(near) }
        return Array(candidates.shuffled().prefix(2))
    }

    /// Record the retrieval outcome and dismiss the overlay.
    func submitRetrievalAnswer(letter: String, correct: Bool) {
        progressStore.recordRetrievalAttempt(letter: letter, correct: correct)
        refreshProgressMirror()
        haptics.fire(correct ? .letterCompleted : .offPath)
        // 0.6 s delay so the colour-coded reveal renders before the
        // overlay dismisses.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            await MainActor.run { self?.overlayQueue.dismiss() }
        }
    }

    /// The 5-letter pilot stimulus set (uppercase-only in study
    /// sessions), read from its single owner in Core rather than
    /// re-declared. Anlaut phonemes /a/ /ɪ/ /m/ /f/ /l/ are all vowels
    /// or continuants, so every study letter is loopable (moots D6).
    private let studyBaseLetters = Set(TrainedLetterSubset.studyLetters)

    /// Visible letters, sorted by `letterOrdering`. `studyMode` pins the
    /// pool to the 5-letter UPPERCASE pilot stimulus set regardless of
    /// `showAllLetters`; outside study sessions the app stays
    /// full-alphabet (`showAllLetters` defaults true and is not flipped).
    var visibleLetterNames: [String] {
        let pool: [String]
        if studyMode {
            // Practice pool = the participant's trained 3 of the 5
            // study letters (uppercase). The H6 post-test covers all 5;
            // the untrained 2 are the within-child baseline.
            pool = letters
                .filter {
                    studyBaseLetters.contains($0.baseLetter)
                    && trainedSubset.letters.contains($0.baseLetter)
                    && $0.letterCase == .upper
                }
                .map(\.name)
        } else if showAllLetters {
            pool = letters.map(\.name)
        } else {
            pool = letters.filter { studyBaseLetters.contains($0.baseLetter) }.map(\.name)
        }
        let order = letterOrdering.orderedLetters()
        let rankMap = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return pool.sorted { a, b in
            let ra = rankMap[a.uppercased()] ?? Int.max
            let rb = rankMap[b.uppercased()] ?? Int.max
            return ra == rb ? a < b : ra < rb
        }
    }

    var activeStrokeIndex: Int { strokeTracker.currentStrokeIndex }
    /// Whether the stroke at `index` has been completed.
    func isStrokeCompleted(_ index: Int) -> Bool {
        strokeTracker.progress.indices.contains(index) && strokeTracker.progress[index].complete
    }

    func resetForPhaseTransition() {
        strokeTracker.reset()
        guard letters.indices.contains(letterIndex) else { return }
        reloadStrokeCheckpoints(for: letters[letterIndex])
        progress = 0
        // Snapshot the just-finished trace so the canvas keeps showing
        // it for ~5 s while the next phase comes up — child sees their
        // own ink survive the transition rather than blink away.
        if !activePath.isEmpty {
            lingeringInk = activePath
            lingeringInkClearTask?.cancel()
            lingeringInkClearTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                self.lingeringInk = []
            }
        }
        activePath.removeAll(keepingCapacity: true)
        lastRecognitionResult = nil
        recognitionTokens.cancel()
        // didCompleteCurrentLetter means "letter session done"; the
        // sequence-completion path on guided sets it true, but only
        // the guided *phase* is done, so reset here to keep the
        // freeWrite auto-advance gate working across guided→freeWrite.
        didCompleteCurrentLetter = false
        // Preserve lastGuidedScore across clearAll — the guided→
        // freeWrite path sets it immediately before we get here, and
        // SchuleWorldView's "Nachspuren fertig" card needs it.
        let savedGuidedScore = freeWriteRecorder.lastGuidedScore
        freeWriteRecorder.clearAll()
        freeWriteRecorder.lastGuidedScore = savedGuidedScore
        // Stop the previous phase's guide animation before deciding
        // whether to restart — otherwise it scans into freeWrite/direct.
        stopGuideAnimation()
        if phaseController.currentPhase == .freeWrite {
            freeWriteRecorder.startSession()
        } else if phaseController.currentPhase == .guided {
            freeWriteRecorder.startGuidedSpeedTracking()
            // Same animator as observe; auto-advance-after-2-cycles
            // is gated on `currentPhase == .observe` so calling it
            // here runs the scan without affecting progression.
            startGuideAnimation()
        }
        directTappedDots.removeAll()
        directPulsingTask?.cancel()
        directPulsingTask = nil
        directPulsingDot = false
        directArrowStrokeIndex = nil
        // Phase transitions can fire mid-stroke from updateTouch; if
        // the gesture is then interrupted (incoming call, Control
        // Centre swipe), the active flag would strand true and reject
        // future touches. Reset goes through the dispatcher.
        touchDispatcher.resetTouchState()
        playback.resumeIntent = false
        playback.cancelPending()
        audio.stop()
        playback.forceIdle()
        isPlaying = false
    }

    // MARK: - Parent dashboard access

    var dashboardSnapshot: DashboardSnapshot { dashboardStore.snapshot }
    var currentStreak: Int { streakStore.currentStreak }
    var longestStreak: Int { streakStore.longestStreak }
    /// Achievement events the child has unlocked. Surfaced in the
    /// Fortschritte badge gallery.
    var earnedRewards: Set<RewardEvent> { streakStore.earnedRewards }

    enum SpeedTrendDirection { case improving, stable, declining }

    /// Aggregate writing-speed trend across all practiced letters.
    /// Returns nil when fewer than two speed samples exist for any letter.
    var writingSpeedTrend: SpeedTrendDirection? {
        let trends = progressStore.allProgress.values
            .compactMap(\.speedTrend)
            .filter { $0.count >= 2 }
        guard !trends.isEmpty else { return nil }
        var totalRelGain = 0.0
        var count = 0
        for trend in trends {
            let half = max(1, trend.count / 2)
            let oldAvg = trend.prefix(half).reduce(0.0, +) / Double(half)
            let newAvg = trend.suffix(trend.count - half).reduce(0.0, +) / Double(trend.count - half)
            guard oldAvg > 0 else { continue }
            totalRelGain += (newAvg - oldAvg) / oldAvg
            count += 1
        }
        guard count > 0 else { return nil }
        let avg = totalRelGain / Double(count)
        if avg > 0.10 { return .improving }
        if avg < -0.10 { return .declining }
        return .stable
    }

    // MARK: - Debug

    #if DEBUG
    var debugActivePathCount: Int { activePath.count }
    /// Raw-name of the participant's assigned A/B condition. Surfaced in the
    /// dashboard's debug-only Forschungsmetriken section so a researcher can
    /// confirm at a glance which arm the device is on.
    var thesisConditionRawName: String { thesisCondition.rawValue }

    /// Test-only deterministic await for the playback debounce window.
    /// Lets integration tests skip the real wall-clock sleep that made
    /// `fastTouch_triggersPlay` flaky on slow CI runners.
    func awaitPlaybackDebounce() async {
        await playback.pendingTransition?.value
    }

    /// Test-only inspection of the D-1 active-time accumulator.
    /// Exposed so the suite can pin the
    /// background-pauses-the-timer / foreground-resumes-it contract
    /// without the integration overhead of a full session-complete
    /// path. nil when a foreground window is currently open.
    var debugLetterLoadTime: CFTimeInterval? { letterLoadTime }
    var debugLetterActiveTimeAccumulated: TimeInterval { letterActiveTimeAccumulated }
    #endif

    // MARK: - Private helpers

    /// Load a letter into the canvas + reset phase state.
    ///
    /// `playPhaseCue: false` skips the spoken phase prompt at the
    /// end of this method. The init-time call (`load(letter: first)`
    /// from `init(_:)`) passes `false` because the audio engine
    /// hasn't finished bringing up its session, AVSpeech / the
    /// PromptPlayer would queue speech against a half-warm
    /// pipeline, and the resulting clip is what plays as ~2 s of
    /// crackle when a returning user opens the app straight to the
    /// main screen. Subsequent loads (user picks a letter, the
    /// scheduler advances after a celebration) all default to
    /// `playPhaseCue: true` because by then the app is settled.
    private func load(letter: LetterAsset, playPhaseCue: Bool = true) {
        phaseController.reset()
        // H6 post-test override, consumed here so it never leaks into the
        // NEXT letter load. Landing directly in freeWrite is already a
        // supported shape below (activePhases requires .threePhase, which
        // studyMode always runs under) — the "if phaseController.currentPhase
        // == .freeWrite" checks further down already handle starting the
        // freeWriteRecorder session correctly for a phase reached this way.
        if pendingPostTestOverride {
            pendingPostTestOverride = false
            phaseController.resume(at: .freeWrite)
        }
        freeWriteRecorder.clearAll()
        showingVariant = false
        variantStrokeCache = nil
        scriptStrokeCache.removeAll(keepingCapacity: true)
        // FreeformController owns lastFreeformFormScore now — clearing the
        // freeform buffers as part of letter load resets it alongside.
        freeform.clearBuffers()
        lastRecognitionResult = nil
        recognitionTokens.cancel()
        overlayQueue.reset()
        directTappedDots.removeAll()
        directPulsingTask?.cancel()
        directPulsingTask = nil
        directPulsingDot = false
        directArrowStrokeIndex = nil
        showGhost                      = false
        currentLetterName              = letter.name
        // Only point at which the detector can downgrade from .pencil
        // back to .finger — see InputModeDetector for the hysteresis
        // rule. Runs BEFORE reapplyGridPreset so the grid reflects
        // post-reset state.
        detector.resetForSequenceChange()
        // Build the grid BEFORE loading stroke checkpoints: reapplyGridPreset
        // creates fresh LetterCell instances with brand-new StrokeTrackers,
        // and `strokeTracker` is now a computed alias for grid.activeCell.tracker.
        // Loading into the old grid's tracker would be thrown away here.
        reapplyGridPreset()
        reloadStrokeCheckpoints(for: letter)
        // Errorless-learning ramp for the first three sessions on a
        // new letter. The MovingAveragePolicy starts at `.standard`
        // for every letter regardless of prior exposure; widening
        // the radius on the first few encounters supports motor-
        // pattern formation without repeated near-miss failure on
        // novel letters (Skinner 1958; Terrace 1963). From session 4
        // the policy tier drives the radius again.
        // Errorless-learning ramp — suppressed in study sessions: the
        // radius must be identical for every child regardless of prior
        // exposure (guided difficulty is held constant, like the
        // adaptation policy).
        let priorCompletions = progressStore.progress(for: letter.name).completionCount
        if !studyMode, priorCompletions < 3 {
            strokeTracker.radiusMultiplier = max(
                strokeTracker.radiusMultiplier,
                DifficultyTier.easy.radiusMultiplier
            )
        }
        progress                       = 0
        audioIndex                     = 0
        didCompleteCurrentLetter       = false
        letterLoadTime                 = CACurrentMediaTime()
        letterActiveTimeAccumulated    = 0
        letterLoadedDate               = Date()
        messages.clearCompletionState()
        activePath.removeAll(keepingCapacity: true)
        touchDispatcher.resetTouchState()
        playback.resumeIntent   = true
        playback.cancelPending()
        stopGuideAnimation()
        // Auto-start stroke animation in observe phase, or skip phases entirely
        // when the letter has no strokes (lowercase/umlaut placeholders) — there's
        // nothing to demonstrate, and isComplete would otherwise report vacuous success.
        if phaseController.currentPhase == .observe {
            // Use the active script's strokes (rawGlyphStrokes) for both the
            // empty-strokes skip check and the animation payload so
            // Schreibschrift mode animates the Playwrite path, not the
            // Druckschrift skeleton from letter.strokes.
            let observeStrokes = rawGlyphStrokes ?? letter.strokes
            if observeStrokes.strokes.isEmpty {
                phaseController.advance(score: 1.0)  // skip observe
                if phaseController.currentPhase == .direct {
                    phaseController.advance(score: 1.0)  // skip direct (no dots to tap)
                }
            } else {
                animation.startAfterDelay(0.3, strokes: observeStrokes)
                armPreTaskDemonstration(for: letter)
            }
        }
        // If we land directly in guided or freeWrite (e.g. after skipping phases or
        // for thesis conditions that omit observe/direct), start the speed clock now.
        if phaseController.currentPhase == .freeWrite {
            freeWriteRecorder.startSession()
            // H6 post-test: deliberately NO demonstration — reaching
            // this letter at all is a cold, untrained probe, and a
            // demonstration would train the very thing the probe
            // depends on not having happened.
            preTaskDemoTask?.cancel()
            preTaskDemoTask = nil
        } else if phaseController.currentPhase == .guided {
            freeWriteRecorder.startGuidedSpeedTracking()
            startGuideAnimation()
            armPreTaskDemonstration(for: letter)
        }
        if let firstAudio = activeAudioFiles(for: letter).first {
            audio.loadAudioFile(named: firstAudio, autoplay: false)
            playback.request(.idle, immediate: true)
            // Audio plays in response to touches via the playback state machine;
            // no observe-phase auto-play (it would loop silently behind onboarding
            // and start immediately on letter switch without any user action).
        }
        // Speak the initial phase prompt once a fresh letter loads.
        // Phase *transitions* are spoken from `advanceLearningPhase`;
        // this site covers the very first phase a child sees per
        // letter (typically observe, but can be guided when the
        // thesis condition skips observe/direct or when an empty-
        // strokes letter auto-skipped). Empty-strokes letters that
        // vacuously land at .guided also land here, so a child
        // still gets a verbal cue rather than silence.
        //
        // Gated on onboarding completion: this method runs once
        // during VM init (`load(letter: first)` in `init(_:)`),
        // which fires *before* SwiftUI decides whether to show
        // OnboardingView. Speaking here on a first-run install
        // makes the welcome screen play 2 s of "Pass jetzt gut
        // auf!" while the child looks at the onboarding cards —
        // confusing audio for content the screen doesn't show.
        // Once onboarding completes, every subsequent letter load
        // is post-onboarding and the cue is welcome.
        if isOnboardingComplete && playPhaseCue {
            prompts.play(
                ChildSpeechLibrary.phaseEntryPromptKey(phaseController.currentPhase),
                fallbackText: ChildSpeechLibrary.phaseEntry(phaseController.currentPhase)
            )
        }
    }

    private func randomAudioVariant() {
        let files = activeAudioFiles(for: letters[letterIndex])
        guard !files.isEmpty else { return }
        audioIndex = Int.random(in: 0..<files.count)
        audio.loadAudioFile(named: files[audioIndex], autoplay: false)
        playback.request(.idle, immediate: true)
    }

    func showCompletionHUD() {
        // Reward-class feedback — off in study sessions (audit C2).
        guard !studyMode else { return }
        messages.show(completion: "🎉 \(currentLetterName) geschafft!")
    }

    /// Reload stroke checkpoints mapped to canvas-normalised coordinates (0–1).
    /// Pass `usingSize` to override `self.canvasSize` — used by `updateTouch` to
    /// guarantee the mapping size equals the size used to normalise the touch point.
    /// Idempotent: a rebuild with the same (letter, size, schriftArt) as the
    /// prior successful rebuild is skipped, so the rotation safety-net window
    /// in `updateTouch` and repeated `canvasSize.didSet` triggers at the same
    /// dimensions don't burn CPU re-mapping unchanged data. The cache hit is
    /// gated on `strokeTracker.definition != nil` so any path that resets the
    /// tracker (resetLetter, phase transition) automatically misses and rebuilds
    /// without each reset site having to remember to invalidate the key.
    func reloadStrokeCheckpoints(for letter: LetterAsset, usingSize size: CGSize? = nil) {
        // Stroke coordinates in JSON are glyph-relative (0–1 within bounding box).
        // Map to per-cell-normalised coordinates using each cell's glyph rect,
        // so a multi-cell layout runs each cell's tracker in its own
        // cell-local 0–1 space. For a length-1 finger sequence the single
        // cell's frame equals the whole canvas, so the mapping is identical
        // to the pre-grid canvas-wide checkpoints.
        //
        // Source-of-truth priority: variant (when toggled) → per-script JSON
        // → user calibration → bundle default.
        let effectiveSize = size ?? canvasSize
        let key = CheckpointBuildKey(letter: letter.name, size: effectiveSize, schriftArt: schriftArt, showingVariant: showingVariant)
        if key == lastCheckpointKey, strokeTracker.definition != nil { return }
        let source: LetterStrokes
        if showingVariant, let vs = variantStrokeCache {
            source = vs
        } else if let ss = activeScriptStrokes {
            source = ss
        } else {
            source = resolvedStrokes(for: letter)
        }
        for cell in grid.cells {
            let cellLetter = cell.item.letter
            // Per-cell source: the loaded letter keeps its full override
            // chain (variant / script / calibration). Other letters (word
            // mode: the non-first cells) fall back to the bundle's default
            // Druckschrift strokes for that letter. Unknown letters skip.
            let cellSource: LetterStrokes
            if cellLetter == letter.name {
                cellSource = source
            } else if let cellAsset = letters.first(where: { $0.name == cellLetter }) {
                cellSource = cellAsset.strokes
            } else {
                continue
            }
            let cellSize = cell.frame.size
            guard cellSize.width > 0, cellSize.height > 0 else {
                // Pre-layout state (e.g. during init before onAppear) — fall
                // back to the source strokes so the tracker at least has
                // definition loaded; the next layout pass will rebuild.
                cell.tracker.load(cellSource)
                continue
            }
            // JSON stroke checkpoints are glyph-bbox-relative (0..1 of
            // the rendered glyph's bbox). Map them through the cell's
            // glyph rect into cell-fraction coords (0..1 of the cell)
            // so proximity hit-tests and the renderer share one frame.
            // Skip the remap when the rect lookup fails so the tracker
            // at least has a definition; pre-layout passes also fall
            // through this branch.
            if let gr = PrimaeLetterRenderer.normalizedGlyphRect(
                for: cellLetter, canvasSize: cellSize,
                schriftArt: schriftArt,
                openTypeFeatures: PrimaeLetterRenderer.openTypeFeatures(
                    for: cellLetter, schriftArt: schriftArt, variant: showingVariant)) {
                let mappedStrokes = cellSource.strokes.map { def in
                    StrokeDefinition(
                        id: def.id,
                        checkpoints: def.checkpoints.map { cp in
                            Checkpoint(
                                x: gr.minX + cp.x * gr.width,
                                y: gr.minY + cp.y * gr.height
                            )
                        }
                    )
                }
                cell.tracker.load(LetterStrokes(
                    letter: cellSource.letter,
                    checkpointRadius: cellSource.checkpointRadius
                        * sqrt(gr.width * gr.height),
                    strokes: mappedStrokes
                ))
            } else {
                cell.tracker.load(cellSource)
            }
        }
        lastCheckpointKey = key
    }

    /// The effective stroke definition for every loaded letter — the
    /// calibration when one's been saved, the bundle default otherwise.
    /// This is what the calibrator's "Alle" button ships so a session
    /// can be exported even when the user hasn't tapped Speichern on
    /// each individual letter.
    func loadAllEffectiveStrokes() -> [String: LetterStrokes] {
        var out: [String: LetterStrokes] = [:]
        for letter in letters {
            let resolved = calibrationStore.strokes(for: letter.name,
                                                    schriftArt: schriftArt)
                ?? letter.strokes
            out[letter.name] = resolved
        }
        return out
    }

    /// Wipes every persisted calibration for the active script and
    /// reloads the current letter so the bundle takes over immediately.
    /// Used after shipping a new bundle that supersedes the on-device
    /// calibration set.
    func clearAllCalibrations() {
        calibrationStore.clearAll(for: schriftArt)
        lastCheckpointKey = nil
        if letters.indices.contains(letterIndex) {
            reloadStrokeCheckpoints(for: letters[letterIndex])
        }
    }

    /// Single clean-slate action for a new enrollee on a shared study
    /// device. The caller MUST have exported first (researcher-gated in
    /// ResearchDashboard) — this is irreversible. Wipes every
    /// participant-scoped data store, clears on-device calibrations, and
    /// regenerates participant identity (new UUID → re-randomised arms,
    /// cleared overrides, fresh enrolment). Device/parent config is
    /// preserved. Returns the new participant UUID.
    ///
    /// The new arm assignment takes effect on the NEXT app launch — the
    /// VM captures `thesisCondition` / `audioCondition` as `let` at init —
    /// so the caller surfaces a "relaunch required" prompt.
    @discardableResult
    func resetForNewParticipant() -> UUID {
        dashboardStore.reset()          // PhaseSessionRecords, letterStats, durations
        progressStore.resetAll()        // all LetterProgress
        streakStore.reset()             // streak + stars
        rawTraceStore.reset()           // cold raw freeWrite traces
        clearAllCalibrations()          // on-device stroke overrides (active SchriftArt)
        let newID = ParticipantStore.startNewParticipant()  // new UUID + arms + enrolment
        refreshProgressMirror()         // clear the SwiftUI progress mirror
        return newID
    }

    /// Persist calibrated glyph-relative checkpoints. Delegates to CalibrationStore
    /// and re-applies the new data to the tracker so the current letter reflects
    /// the calibration immediately without navigating away and back.
    func persistCalibratedStrokes(_ strokes: [[CGPoint]], for letter: String) {
        calibrationStore.persist(strokes, for: letter, schriftArt: schriftArt)
        guard letters.indices.contains(letterIndex) else { return }
        // Calibration replaces the source checkpoint set, so the (letter, size)
        // idempotency cache no longer reflects what's loaded — invalidate it
        // before the rebuild call so the cache check doesn't short-circuit us.
        lastCheckpointKey = nil
        reloadStrokeCheckpoints(for: letters[letterIndex])
    }

    /// Variant that persists to an explicit schriftArt — required when the
    /// active schriftArt has just changed (the calibrator's navigation
    /// auto-save fires after vm.schriftArt has already become the new
    /// value, so the unsaved edits belong to the PREVIOUS schriftArt). No
    /// tracker reload here because the live tracker is already loading
    /// the new schriftArt; restamping the previous one would fight that.
    func persistCalibratedStrokes(_ strokes: [[CGPoint]],
                                   for letter: String,
                                   schriftArt: SchriftArt) {
        calibrationStore.persist(strokes, for: letter, schriftArt: schriftArt)
    }

    func toast(_ text: String) {
        messages.show(toast: text)
    }

    /// Idempotency key for `reloadStrokeCheckpoints`. Equal keys mean the cached
    /// strokeTracker contents are still valid for the requested mapping —
    /// (letter changes invalidate via name; rotations via size; font swaps via
    /// schriftArt). Calibration changes invalidate manually since the source
    /// data is not in this key.
    private struct CheckpointBuildKey: Equatable {
        let letter: String
        let size: CGSize
        let schriftArt: SchriftArt
        let showingVariant: Bool
    }

    // MARK: - Freeform writing mode

    /// Switch the app into freeform writing. Clears any in-progress guided
    /// state and starts a fresh blank canvas. The reference letter is
    /// whatever the child last tapped in the letter picker — that name
    /// travels with us as the comparison target.
    func enterFreeformMode(subMode: FreeformSubMode = .letter) {
        freeform.writingMode = .freeform
        freeform.freeformSubMode = subMode
        clearFreeformCanvas()
        freeform.freeformTargetWord = subMode == .word
            ? FreeformWordList.all.first : nil
        // Halt any in-progress phase audio/animation so freeform is quiet.
        stopGuideAnimation()
        audio.stop()
        playback.forceIdle()
        isPlaying = false
        // Probe the recognizer so the freeform footer can distinguish
        // "still thinking" from "model not available" on first paint.
        // Two-flag idempotency: the value flag (`isRecognitionModelAvailable
        // == nil`) gates *re-probing* once the answer is known, while the
        // in-flight flag (`isProbingModel`) gates a second dispatch during
        // the dispatch→result window — without it, rapid freeform-mode
        // toggles spawn redundant CoreML model loads.
        if freeform.isRecognitionModelAvailable == nil, !freeform.isProbingModel {
            freeform.isProbingModel = true
            Task { [weak self, letterRecognizer] in
                let available = await letterRecognizer.isModelAvailable()
                await MainActor.run {
                    self?.freeform.isRecognitionModelAvailable = available
                    self?.freeform.isProbingModel = false
                }
            }
        }
        toast(subMode == .word ? "Wort schreiben" : "Freies Schreiben")
    }

    /// Return to guided tracing mode. Re-loads the current letter so
    /// phase state and strokes are rebuilt fresh.
    func exitFreeformMode() {
        freeform.writingMode = .guided
        freeform.freeformSubMode = .letter
        freeform.freeformTargetWord = nil
        clearFreeformCanvas()
        if letters.indices.contains(letterIndex) {
            load(letter: letters[letterIndex])
        }
    }

    /// Wipe the freeform drawing buffer without leaving freeform mode.
    /// Used by the "Nochmal" button after a recognition result.
    func clearFreeformCanvas() {
        freeform.clearBuffers()
        lastRecognitionResult = nil
        recognitionTokens.cancel()
    }

    /// Pick the next target word for freeform word mode.
    func selectFreeformWord(_ word: FreeformWord) {
        freeform.freeformTargetWord = word
        freeform.freeformSubMode = .word
        clearFreeformCanvas()
    }

    /// Begin a freeform stroke. Mirrors `beginTouch` but skips all
    /// checkpoint / phase / audio side effects. Cancels any pending
    /// recognition debounce so the recognizer waits for THIS stroke to
    /// finish — critical for multi-stroke letters like A, E, F.
    func beginFreeformTouch(at p: CGPoint) {
        guard writingMode == .freeform else { return }
        freeform.pendingRecognitionTask?.cancel()
        freeform.pendingRecognitionTask = nil
        freeform.isWaitingForRecognition = false
        freeform.freeformActivePath = [p]
    }

    func updateFreeformTouch(at p: CGPoint, canvasSize size: CGSize) {
        guard writingMode == .freeform else { return }
        // Record the freeform canvas dimensions separately — we don't
        // touch `canvasSize` because its didSet rebuilds the guided-mode
        // stroke tracker and fires needless work during a blank-canvas
        // stroke. Recognition uses the size passed into submit.
        freeform.freeformCanvasSize = size
        // Skip microscopic repeats — keeps the buffer from ballooning on
        // a palm rest or a stationary touch.
        if let last = freeform.freeformActivePath.last,
           hypot(p.x - last.x, p.y - last.y) < 1.0 { return }
        freeform.freeformActivePath.append(p)
    }

    /// End a freeform stroke. In letter sub-mode this arms a debounced
    /// recognition call — the child has `freeformRecognitionDelay`
    /// seconds to start the next stroke before the recognizer runs.
    /// Multi-stroke letters (A, E, F, H, K, T, X …) need this window so
    /// they don't get classified after only their first stroke. Word
    /// sub-mode waits for the explicit "Fertig" button regardless.
    func endFreeformTouch() {
        guard writingMode == .freeform else { return }
        if freeform.freeformActivePath.count >= 2 {
            freeform.freeformStrokeSizes.append(freeform.freeformActivePath.count)
            freeform.freeformPoints.append(contentsOf: freeform.freeformActivePath)
        }
        freeform.freeformActivePath.removeAll(keepingCapacity: true)

        if freeform.freeformSubMode == .letter, freeform.freeformPoints.count >= 2 {
            scheduleFreeformLetterRecognition()
        }
    }

    /// Arm a debounced recognition call. Cancels any previously-armed
    /// task first so a rapid stroke sequence only produces ONE
    /// recognition call, fired `freeformRecognitionDelay` seconds after
    /// the most recent pen-lift.
    private func scheduleFreeformLetterRecognition() {
        freeform.pendingRecognitionTask?.cancel()
        freeform.isWaitingForRecognition = true
        let delay = freeform.freeformRecognitionDelay
        freeform.pendingRecognitionTask = Task { [weak self] in
            let nanos = UInt64((delay * 1_000_000_000).rounded())
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self else { return }
            self.freeform.isWaitingForRecognition = false
            self.recognizeFreeformLetter()
        }
    }

    private func recognizeFreeformLetter() {
        let pts = freeform.freeformPoints
        let size = freeform.freeformCanvasSize.width > 0
            ? freeform.freeformCanvasSize : canvasSize
        freeform.isRecognizing = true
        freeform.hasRecognitionCompleted = false
        let token = recognitionTokens.issue()
        Task { [weak self, letterRecognizer] in
            let result = await letterRecognizer.recognize(
                points: pts, canvasSize: size, expectedLetter: nil)
            guard let self else { return }
            await MainActor.run {
                guard self.recognitionTokens.isStillActive(token) else { return }
                self.freeform.isRecognizing = false
                self.freeform.hasRecognitionCompleted = true
                self.lastRecognitionResult = result
                if let result {
                    self.freeform.lastFreeformFormScore = self.freeformFormAccuracy(
                        points: pts, canvasSize: size,
                        predictedLetter: result.predictedLetter)
                    self.recordFreeformCompletion(result: result)
                    // Verbal mirror of the freeform popup's headline so a
                    // child who can't read still hears whether the model
                    // recognised their letter. Empty string returns are
                    // intentional silence (low confidence).
                    // W-30: recognizer was called with expectedLetter: nil,
                    // so result.isCorrect is always false — ChildSpeechLibrary
                    // would never take the positive "Du hast ein X geschrieben!"
                    // branch. In freeform mode the prediction IS the answer
                    // (there is no wrong letter), so synthesise a corrected
                    // result that treats the top prediction as correct.
                    let corrected = RecognitionResult(
                        predictedLetter: result.predictedLetter,
                        confidence: result.confidence,
                        topThree: result.topThree,
                        isCorrect: true)
                    let line = ChildSpeechLibrary.recognition(
                        corrected, expected: result.predictedLetter)
                    if !line.isEmpty { self.speech.speak(line) }
                } else {
                    self.freeform.lastFreeformFormScore = nil
                }
            }
        }
    }

    /// Score how closely the freeform path matches the recognized
    /// letter's reference strokes — using the **currently selected
    /// font's** stroke definition, not the Druckschrift default. A
    /// child practising Schreibschrift draws a curvy A that should be
    /// scored against the cursive reference, and a child practising
    /// Druckschrift the angular one. Returns nil when the letter has
    /// no bundled reference for the active font.
    ///
    /// Delegates the maths to `FreeWriteScorer.formAccuracyShape` —
    /// bounding-box normalisation, per-stroke densification, and
    /// symmetric Hausdorff happen there.
    private func freeformFormAccuracy(points: [CGPoint],
                                      canvasSize: CGSize,
                                      predictedLetter: String) -> CGFloat? {
        guard canvasSize.width > 0, canvasSize.height > 0,
              points.count >= 2,
              let reference = referenceStrokes(forLetterNamed: predictedLetter,
                                               schrift: schriftArt)
        else { return nil }
        return FreeWriteScorer.formAccuracyShape(
            tracedPoints: points,
            reference: reference
        )
    }

    /// Resolve a letter name (e.g. "A", "f", "ß") to the stroke
    /// definition for the given script. Schreibschrift /
    /// Grundschrift / Vereinfachte Ausgangsschrift /
    /// Schulausgangsschrift each ship per-letter `strokes_<id>.json`
    /// in the bundle (loaded via `LetterRepository.loadVariantStrokes`);
    /// Druckschrift uses the primary `LetterAsset.strokes`. Falls back
    /// to Druckschrift if a variant isn't bundled for this letter so
    /// new fonts don't have to ship the full alphabet to be useful.
    private func referenceStrokes(forLetterNamed name: String,
                                   schrift: SchriftArt) -> LetterStrokes? {
        let candidates = [name, name.uppercased(), name.lowercased()]
        if let variantID = schrift.bundleVariantID {
            for candidate in candidates {
                if let variant = repo.loadVariantStrokes(
                    for: candidate, variantID: variantID) {
                    return variant
                }
            }
        }
        // Druckschrift, or variant not bundled for this letter — fall
        // back to the primary strokes.json. Better to score against the
        // print form than to drop the metric entirely.
        for candidate in candidates {
            if let asset = letters.first(where: { $0.name == candidate }) {
                return asset.strokes
            }
        }
        return nil
    }

    /// Submit a finished freeform word. Assigns each completed stroke to
    /// one of `target.word.count` equal-width columns by its x-centroid,
    /// then recognises each column independently. Overlapping handwritten
    /// letter bounding boxes (M bleeds into A) no longer collapse into a
    /// single cluster — each stroke belongs to exactly one bucket even
    /// when the child's writing overlaps. `freeformWordResultSlots` holds
    /// one entry per target letter (nil when the column got no strokes)
    /// so the UI can draw grey placeholder chips for missing letters.
    func submitFreeformWord() {
        guard writingMode == .freeform, freeformSubMode == .word,
              let target = freeform.freeformTargetWord,
              !freeform.freeformPoints.isEmpty else { return }

        let segmentationWidth = freeform.freeformCanvasSize.width > 0
            ? freeform.freeformCanvasSize.width : canvasSize.width
        let targetLetters = Array(target.word)
        let buckets = Self.bucketStrokesByTargetLetter(
            points: freeform.freeformPoints,
            strokeSizes: freeform.freeformStrokeSizes,
            canvasWidth: segmentationWidth,
            letterCount: targetLetters.count
        )
        let size = freeform.freeformCanvasSize.width > 0
            ? freeform.freeformCanvasSize : canvasSize

        freeform.isRecognizing = true
        freeform.hasRecognitionCompleted = false
        // Pre-compute per-letter recognition history on the main
        // actor so the detached Task can look it up without re-
        // entering the VM's isolation. Activates the calibrator's
        // practised-letter boost for whichever targets the child has
        // history on. Words with repeated letters (MAMA, OMMA) map
        // the same letter twice; both lookups return the same
        // scores, so collapsing duplicates with `{ first, _ in first }`
        // is semantically equivalent and sidesteps the
        // `Dictionary(uniqueKeysWithValues:)` duplicate-key trap.
        let historyByLetter: [String: [CGFloat]] = Dictionary(
            targetLetters.map { ch -> (String, [CGFloat]) in
                let key = String(ch)
                // formAccuracyHistory, not recognitionAccuracy — see the
                // 2026-09-04 fix note on runRecognizerForFreeWrite.
                let scores = (progressStore.progress(for: key).formAccuracyHistory ?? [])
                              .map { CGFloat($0) }
                return (key, scores)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let token = recognitionTokens.issue()
        Task { [weak self, letterRecognizer] in
            var slots: [RecognitionResult?] = []
            for i in 0..<targetLetters.count {
                let seg = i < buckets.count ? buckets[i] : []
                guard seg.count >= 2 else { slots.append(nil); continue }
                let expected = String(targetLetters[i])
                let r = await letterRecognizer.recognize(
                    points: seg, canvasSize: size, expectedLetter: expected,
                    historicalFormScores: historyByLetter[expected] ?? [])
                slots.append(r)
            }
            guard let self else { return }
            await MainActor.run {
                guard self.recognitionTokens.isStillActive(token) else { return }
                self.freeform.isRecognizing = false
                self.freeform.hasRecognitionCompleted = true
                let present = slots.compactMap { $0 }
                self.freeform.freeformWordResultSlots = slots
                self.freeform.freeformWordResults = present
                if let last = present.last {
                    self.lastRecognitionResult = last
                }
                self.recordFreeformWordCompletion(
                    target: target, results: present)
            }
        }
    }

    private func recordFreeformCompletion(result: RecognitionResult) {
        // Freeform letter sessions record under the predicted letter so
        // the dashboard tallies what the child actually wrote (not what
        // they were trying to write — the latter is nil in freeform).
        let label = result.predictedLetter.uppercased()
        progressStore.recordFreeformCompletion(letter: label, result: result)
        refreshProgressMirror()
    }

    private func recordFreeformWordCompletion(target: FreeformWord,
                                              results: [RecognitionResult]) {
        for r in results {
            let label = r.predictedLetter.uppercased()
            progressStore.recordFreeformCompletion(letter: label, result: r)
        }
        refreshProgressMirror()
    }

    // MARK: - Segmentation

    /// Assign every stroke to one of `letterCount` equal-width columns
    /// by the x-coordinate of its centroid. Works even when the child's
    /// handwriting overlaps horizontally — each stroke is a unit and
    /// ends up in exactly one bucket regardless of what the other
    /// strokes do. Returns an array of length `letterCount`; empty
    /// buckets stay empty (caller pads those as missing letters in the
    /// UI). Strokes whose centroid falls outside the canvas clamp to
    /// the nearest bucket rather than being dropped, so a child who
    /// started writing a bit to the right of the visual guides still
    /// gets their strokes accounted for.
    static func bucketStrokesByTargetLetter(
        points: [CGPoint],
        strokeSizes: [Int],
        canvasWidth: CGFloat,
        letterCount: Int
    ) -> [[CGPoint]] {
        guard letterCount > 0, canvasWidth > 0, !strokeSizes.isEmpty else {
            return Array(repeating: [], count: max(letterCount, 0))
        }
        let bucketWidth = canvasWidth / CGFloat(letterCount)
        var buckets: [[CGPoint]] = Array(repeating: [], count: letterCount)
        var cursor = 0
        for strokeLen in strokeSizes {
            let endIdx = min(cursor + strokeLen, points.count)
            guard endIdx > cursor else { cursor = endIdx; continue }
            let strokePoints = Array(points[cursor..<endIdx])
            cursor = endIdx
            let sumX = strokePoints.reduce(0.0) { $0 + $1.x }
            let centroidX = sumX / CGFloat(strokePoints.count)
            let raw = Int((centroidX / bucketWidth).rounded(.down))
            let idx = min(letterCount - 1, max(0, raw))
            buckets[idx].append(contentsOf: strokePoints)
        }
        return buckets
    }
}
