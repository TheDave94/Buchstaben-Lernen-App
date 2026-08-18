# Primae — Technical Foundation

_A digital handwriting learning app for Austrian first-graders. Master's
thesis technical documentation. All claims here are verifiable against
the source tree at the commit this file was last updated against. The
app's UI is German; this document is in English to match the thesis._

---

## 1. App overview

### 1.1 Purpose

The app teaches a German-speaking child how to write the Latin alphabet
on an iPad. It implements a four-step pedagogical flow per letter
(observe → direct → guided → freeWrite) and accompanies the child's
practice with real-time audio, haptic feedback, on-device CoreML letter
recognition, and per-session writing-quality assessment along four
Schreibmotorik motor dimensions (form, tempo, pressure, rhythm).

The problem being addressed: the Austrian Volksschule curriculum frames
handwriting acquisition as a motor-skill task that benefits from
massed-then-spaced practice with explicit directionality teaching.
Existing tablet handwriting apps either gate every interaction behind a
"correct" tracing path (no transfer to paper) or score nothing at all
(no feedback loop for parents and teachers). This app combines:

* **Pedagogical structure** (gradual release of responsibility) so the
  scaffolding fades as the child progresses, rather than the child
  learning to follow on-screen rails forever.
* **Multidimensional motor assessment** so research can analyse
  handwriting development across four independent dimensions instead of
  collapsing everything into a single accuracy number.
* **A/B-testable thesis infrastructure** so adaptive vs. non-adaptive
  conditions can be compared with stable cohort assignment.

### 1.2 Target audience

5–6 year-old children in **Volksschule 1. Klasse**. The child is the
primary user. A parent / teacher accesses settings and the research
dashboard via a 2-second long-press on the gear icon — children can't
reach those screens accidentally.

### 1.3 Platform

* **iPad** in landscape, iOS 26+. Built against Swift 6.3 / Xcode 26.4.
* Both **finger** and **Apple Pencil** input. Pencil pressure +
  azimuth feed the pressure-control dimension; finger input is treated
  as zero-force.
* The package targets `iOS 26.0` and `macOS 15.0`
  (`Package.swift:6-9`); the Primae Xcode wrapper hosts it on iOS.

### 1.4 Language

The UI is **German throughout**, including all child-facing strings,
parent dashboard labels, settings, accessibility labels, and TTS
utterances. The only English strings in the entire codebase are inside
`#if DEBUG` blocks of the calibration tooling (and even those were
translated in the latest pass — see `StrokeCalibrationOverlay.swift`).

### 1.5 Thesis context

The app ships with built-in A/B test infrastructure
(`Core/ThesisCondition.swift`). When a participant install opts into
the study via `Forschung → Studienteilnahme`, a stable UUID is
deterministically mapped to one of three conditions:

* `.threePhase` — full four-phase flow (observe → direct → guided → freeWrite)
* `.guidedOnly` — guided phase only (skips scaffolding + free writing)
* `.control` — guided phase with **fixed** difficulty (no adaptive radius)

Every persisted phase-session record is tagged with the active
condition (`PhaseSessionRecord.condition`), so the post-hoc CSV / TSV /
JSON export distinguishes data from each arm without any extra
bookkeeping. Non-enrolled installs are pinned to `.threePhase` so a
casual user is never silently dropped into a degraded condition.

---

## 2. Architecture

### 2.1 File tree

#### App entry point

The shipping `@main` is `Primae/Primae/PrimaeApp.swift` (in the Xcode
wrapper), which delegates to either `PrimaeApp.main()` for the
production app or an empty `TestApp.main()` when running under XCTest.
The library target has no `App` struct of its own — Previews and
`swift run` invocations are not currently relied on.

#### `Theme/`
SwiftUI port of the Primae design tokens (see [`design-system/`](../design-system/) at the repo root for the source-of-truth CSS).
| File | Lines | Role |
|------|------:|------|
| `Colors.swift` | 138 | `Color` extension where every named token resolves through the host app's Asset Catalog (`Primae/Primae/Assets.xcassets/Colors/<name>.colorset/`). Each colorset has explicit light + dark variants, so iOS / SwiftUI flip per trait collection without invoking any Swift closure. Replaces an earlier `UIColor(dynamicProvider:)` design that crashed under Swift 6 strict concurrency on the SwiftUI AsyncRenderer thread (see `docs/LESSONS.md`). Re-run `scripts/gen_colorsets.py` to regenerate the colorsets after a design-system update. |
| `Radii.swift` | 24 | `Radii.sm..xxl` + `pill` mirroring `--r-*`. |
| `Fonts.swift` | 132 | `Font.display(_:weight:) / .body(_:weight:) / .cursive(_:)` helpers + `FontSize.xs..glyph` (13–220 pt). PostScript-name resolver picks the bundled Primae / PrimaeText face for a given SwiftUI weight. |
| `FontRegistration.swift` | 116 | `PrimaeFonts.registerAll()` — registers every bundled OTF/TTF with CoreText at app launch via `CTFontManagerRegisterFontsForURLs`. The load-bearing path because the fonts ship in `Bundle.module`, not the main bundle (where `INFOPLIST_KEY_UIAppFonts` would search). |
| `Appearance.swift` | 24 | Resolver mapping the `@AppStorage("primaeAppearance")` string ("system" / "light" / "dark") to SwiftUI's `ColorScheme?` so the host app applies it via `.preferredColorScheme(...)` at the WindowGroup root. The parent-area "Erscheinungsbild" picker writes to this key; flipping it re-renders against the asset-catalog colorsets. |

#### `Components/`
| File | Lines | Role |
|------|------:|------|
| `StickerButton.swift` | 60 | `StickerButtonStyle` ButtonStyle — pill capsule, 14×24 pt padding, white label, tint-coloured halo + ink drop shadow, scale + offset on press. Idiomatic SwiftUI port of `.btn-sticker*` from `design-system/ui_kits/ipad-app/styles.css`. Per-world variants via the `tint:` parameter (`.brand` / `.schule` / `.werkstatt` / `.fortschritte`). |

#### `Core/` (data + algorithms; no SwiftUI)
| File | Lines | Role |
|------|------:|------|
| `Models.swift` | 65 | `LetterAsset`, `LetterStrokes`, `StrokeDefinition`, `Checkpoint`. |
| `AppWorld.swift` | 49 | Three-world enum (`schule`, `werkstatt`, `fortschritte`). |
| `LearningPhase.swift` | 81 | Four-phase enum: `observe`, `direct`, `guided`, `freeWrite`. German display names. |
| `LearningPhaseController.swift` | 175 | Pure-value-type FSM. Star thresholds per phase; ThesisCondition-aware `activePhases`. |
| `LetterOrderingStrategy.swift` | 33 | `motorSimilarity`, `wordBuilding`, `alphabetical` — explicit ordering tables. |
| `SchriftArt.swift` | 63 | Five script enum cases. Currently bundled: Druckschrift (Primae) + Schreibschrift (Playwrite AT). |
| `WritingMode.swift` | small | `guided` vs `freeform`. |
| `ThesisCondition.swift` | 97 | A/B condition + ParticipantStore with stable UUID assignment. |
| `OverlayQueueManager.swift` | 203 | Serialised FIFO of `CanvasOverlay` cases. Modal overlays carry nil duration (wait for explicit dismiss). `enqueueBeforeCelebration` interrupts an already-active celebration or paperTransfer to slot a late-arriving recognition badge ahead of it (C-4 + W-25). |
| `AudioControlling.swift` | small | Protocol seam for the audio engine. |
| `PlaybackStateMachine.swift` | small | Pure FSM idle ↔ active. |
| `AudioEngine.swift` | 382 | ⚠️ **STABLE & FRAGILE** — do NOT modify. AVAudioEngine + AVAudioUnitTimePitch for time-stretching playback. Lifecycle observers via `nonisolated(unsafe)` static dict. |
| `SpeechSynthesizer.swift` | 162 | German `AVSpeechSynthesizer` wrapper. `ChildSpeechLibrary` centralises every TTS phrase. |
| `StrokeTracker.swift` | 96 | Checkpoint proximity tracker. Owns `progress[]` + `radiusMultiplier`. |
| `HapticEngine.swift` | 156 | Protocol + `CoreHapticsEngine` + `UIKitHapticEngine` fallback + `NullHapticEngine` for tests. |
| `DifficultyAdaptation.swift` | 127 | `MovingAverageAdaptationPolicy` with hysteresis + `FixedAdaptationPolicy` for control arm. |
| `ProgressStore.swift` | 400 | Per-letter progress JSON store. Carries phaseScores, speedTrend (cap 50, D-4), recognitionAccuracy + recognitionSamples (cap 10), paperTransferScore, lastVariantUsed, freeformCompletionCount. Schema-versioned (W-17). |
| `ParentDashboardStore.swift` | 497 | Session + phase-record JSON store. `PhaseSessionRecord` carries Schreibmotorik dimensions, session-aligned recognition (D-2), `recordedAt` timestamp (D-3), `inputDevice` (D-6). `SessionDurationRecord` also carries `recordedAt` (D-9). accuracySamples cap 200. Schema-versioned (W-17). |
| `ParentDashboardExporter.swift` | 354 | CSV / TSV / JSON exporter. 15-column per-phase rows; per-letter aggregates with `speedTrend` + `freeformCompletionCount`; per-arm aggregates (`averageFreeWriteScore_<arm>`, `schedulerEffectivenessProxy_<arm>`); `letterByArm` block (D-5). Filters legacy rows when `enrolledAt` is set (D-7/D-8). |
| `StreakStore.swift` | 219 | Daily-streak JSON store + `RewardEvent` enum. `earnedRewards: Set<RewardEvent>` exposed on the protocol so the Fortschritte gallery can render achievement badges. Schema-versioned (W-17). |
| `LocalNotificationScheduler.swift` | small | Daily reminder with quiet hours + streak-aware copy. |
| `OnboardingCoordinator.swift` | 220 | 7-step state machine. U4 adds an `OnboardingVariant` enum (`.full` 7-step, `.short` 3-step) so the cohort can A/B compare onboarding length. The variant the child actually completed is locked into `OnboardingState.variantUsedRaw` on first complete (re-runs don't overwrite) so post-hoc analysis can correlate engagement metrics with the original variant. |
| `LetterScheduler.swift` | 152 | Spaced-repetition prioritiser. Ebbinghaus-style decay. |
| `RetrievalScheduler.swift` | 75 | P1 — every-Nth-letter cadence for retrieval-practice prompts (Roediger & Karpicke 2006). Persisted counter survives relaunch; minimum-prior-completions guard skips testing on never-seen letters. Drives `RetrievalPromptView` via `OverlayQueueManager.retrievalPrompt`. |
| `LetterStars.swift` | small | phaseScores → 0…4 star count. |
| `LetterRecognizer.swift` | 380 | `CoreMLLetterRecognizer` + `StubLetterRecognizer`. nonisolated, runs on `Task.detached`. D3 added a closure-injected classifier seam and the `LetterClassification` framework-agnostic intermediate type so tests can swap a deterministic stub without bundling a `.mlpackage`. |
| `ConfidenceCalibrator.swift` | 119 | Confusable-pair penalty + history boost shim. |
| `FreeWriteScorer.swift` | 372 | Discrete Fréchet, four-dimension `WritingAssessment`, Hausdorff form-accuracy. |
| `FreeformWordList.swift` | small | Demo word library for freeform-word mode. |
| `PrimaeLetterRenderer.swift` | small | OTF-based glyph render → UIImage. SchriftArt-aware. |
| `LetterAnimationGuide.swift` | small | Per-stroke animation timing model. |
| `CalibrationStore.swift` | small | Per-letter user-calibrated stroke persistence. |

#### `Features/Tracing/`
| File | Lines | Role |
|------|------:|------|
| `TracingViewModel.swift` | 2086 | `@MainActor @Observable` central coordinator. Recognition orchestration + per-letter loading. Forwards `beginTouch`/`updateTouch`/`endTouch` to `TouchDispatcher` (D1b) and `advanceLearningPhase()` to `PhaseTransitionCoordinator` (D1c). External readers go through `allProgress` / `progress(for:)` (W-5); collaborators have internal access. `playback`, `touchDispatcher`, and `phaseTransitions` are non-optional `let`s wired through the W-16 two-phase init pattern. Tracks active practice time across background/foreground (D-1). Owns toggles for retrieval prompts (P1), backward chaining (P5), onboarding variant (U4), phoneme mode (P6). |
| `TouchDispatcher.swift` | 365 | `@MainActor` reference type that owns the touch-session state (`isSingleTouchInteractionActive`, last point/timestamp, smoothed velocity, the three tunable knobs) and the `beginTouch`/`updateTouch`/`endTouch` flow plus 5 helpers (resyncCanvasSizeIfNeeded, updateGuidedAndFreeWriteSpeed, fireMovementHaptics, updateAdaptivePlayback, handleStrokeCompletionIfReached) and the static `mapVelocityToSpeed`. Communicates back to the VM via `weak var vm`. D1b — second VM-decomposition slice. |
| `PhaseTransitionCoordinator.swift` | 280 | `@MainActor` reference type that owns the post-phase pipeline: `advance()` (score the active phase, queue post-freeWrite kpOverlay + paperTransfer, advance the phase controller, route to toast+speech or the completion pipeline), `recordSessionCompletion()` (private celebration + per-phase dashboard rows), and `commitCompletion(...)` (durable progress + streak + dashboard, cloud-sync push, difficulty-tier adaptation, completion HUD). Communicates back to the VM via `weak var vm`. D1c — third VM-decomposition slice. |
| `RecognitionTokenTracker.swift` | 60 | Tiny `@MainActor` reference type that owns the UUID token marking the currently-authoritative recognition request. Replaces the duplicated issueToken/stillActive guards previously hand-rolled at three async dispatch sites (D1a, first VM-decomposition slice). |
| `TracingDependencies.swift` | small | DI bundle. `.live` defaults; `.stub` swaps for tests. |
| `TracingCanvasView.swift` | 697 | SwiftUI Canvas: glyph + ghost + ink + KP overlay. Pencil + finger UIKit overlays. |
| `FreeformController.swift` | 113 | Owns freeform state (mode, sub-mode, target word, drawing buffers, recognition state, debounce task). |
| `FreeWritePhaseRecorder.swift` | 213 | Owns the four freeWrite buffers + session timing + Schreibmotorik scoring. Two `assess` overloads: single-cell (with optional `cellFrame` for pencil layouts, C-5) and multi-cell `assess(cellReferences:)` that partitions points by frame and averages per-letter scores for word mode (W-26). |
| `FreeformWritingView.swift` | ~720 | Blank-canvas writing UI. Verbal-only result popup (no metrics shown to children). |
| `RecognitionFeedbackView.swift` | 140 | German verbal-only badge for freeWrite recognition. |
| `CompletionCelebrationOverlay.swift` | small | Stars + "Weiter" button. |
| `PaperTransferView.swift` | 95 | 3 s reference → 10 s write-on-paper → 3-emoji self-assessment. Speaks each prompt. |
| `PhaseDotIndicator.swift` | small | Phase progress visuals. |
| `LetterPickerBar.swift` / `LetterWheelPicker.swift` | small | Letter / word selection chrome. |
| `StrokeCalibrationOverlay.swift` | 521 | DEBUG calibration UI with per-script persistence. |
| `PlaybackController.swift` / `AnimationGuideController.swift` / `TransientMessagePresenter.swift` | small | Per-VM controllers built via factories. |
| `InputModeDetector.swift` / `InputPreset.swift` | small | Finger / pencil hysteresis. |
| `LetterCell.swift` / `SequenceGridController.swift` / `GridLayoutCalculator.swift` / `TracingSequence.swift` | small | Word-mode grid. |

#### `Features/Library/`
| File | Lines | Role |
|------|------:|------|
| `LetterRepository.swift` | 545 | Bundle scan + cache fallback + variant loader. |
| `LetterCache.swift` | small | JSONLetterCache disk cache. |

#### `Features/Navigation/`
| File | Lines | Role |
|------|------:|------|
| `MainAppView.swift` | 86 | Root host. `@AppStorage` persists active world. |
| `WorldSwitcherRail.swift` | 162 | 64 pt rail with world buttons + 2 s long-press gear. |
| `WorldPalette.swift` | small | Per-world palette. |

#### `Features/Worlds/`
| File | Lines | Role |
|------|------:|------|
| `SchuleWorldView.swift` | ~280 | World 1. Hosts `TracingCanvasView` + queue-driven overlays. |
| `WerkstattWorldView.swift` | 126 | World 2. Mode-card panel + `FreeformWritingView`. |
| `FortschritteWorldView.swift` | 298 | World 3. Star + streak header, "Auszeichnungen" badge row (every `RewardEvent` rendered earned/unearned), letter gallery, fluency footer. |

#### `Features/Onboarding/`
| File | Lines | Role |
|------|------:|------|
| `OnboardingView.swift` | 569 | First-run flow with one animated demo per phase. |

#### `Features/Parent/`
| File | Lines | Role |
|------|------:|------|
| `ParentAreaView.swift` | 153 | Parental-gate host. NavigationSplitView with overview / research / settings / export. |
| `ResearchDashboardView.swift` | 343 | Research-only metrics view. Schreibmotorik, KI predictions vs expected, condition arms, scheduler r, raw phase records. |

#### `Features/Dashboard/`
| File | Lines | Role |
|------|------:|------|
| `ParentDashboardView.swift` | ~250 | Adult-grade overview. |
| `PhaseRatesView.swift` / `PracticeTrendChart.swift` | small | Charts. |
| `SettingsView.swift` | 111 | Schriftart / ordering / freeform / paper-transfer / Anzeige (Geisterbuchstabe) / study-enrolment / restart-onboarding. |

#### `Resources/`
* `Letters/<X>/strokes.json` — 26 uppercase + 26 lowercase + Ä Ö Ü ß = 59 letter folders. Every letter has a real baked `strokes.json` produced by `scripts/generate_strokes_auto.py` (see §13). Audio is still demo-scoped (see below).
* `Letters/<X>/strokes_variant.json` — alternate stroke order (uppercase F, H, lowercase r).
* `Letters/<X>/strokes_schulschrift.json` — Schreibschrift script strokes for the demo letters.
* `Letters/<X>/<X><n>.mp3` — recorded letter-name + phoneme audio variants.
* `Fonts/Primae-*.otf` (12 weights) + `PlaywriteAT-Regular.ttf` + `PlaywriteAT-OFL.txt` (license).
* `ML/GermanLetterRecognizer.mlpackage/` — CoreML model + manifest.
* `letter_set.json` — `active_letters: ["A","F","I","K","L","M","O"]`.

#### `PrimaeNativeTests/`
40+ test files using **Swift Testing** (`@Test`, `@Suite`, `#expect`).
Notable: `WritingAssessmentTests`, `LetterSchedulerTests`,
`ParentDashboardStoreTests`, `ParentDashboardExporterTests`,
`ProgressStoreTests`, `LearningPhaseControllerTests`,
`StrokeTrackerTests`, `ConfidenceCalibratorTests`,
`TracingViewModelTests`, `EndToEndTracingSessionTests`. Stubs in
`TestFixtures.swift`.

#### `.github/workflows/`
* `ios-build.yml` — main GitHub Actions runner, macos-26 / Xcode 26.4. Runs `xcodebuild test` on iPad simulator.
* `ipad-device-test.yml` — self-hosted MacBook physical-device test job.

### 2.2 Dependency graph

```
PrimaeNativeApp
  └── @State vm = TracingViewModel()       ← single shared instance
       └── TracingDependencies.live (injected)
            ├── AudioEngine          (AudioControlling)
            ├── JSONProgressStore    (ProgressStoring)
            ├── CoreHapticsEngine    (HapticEngineProviding)
            ├── MovingAverageAdaptationPolicy / FixedAdaptationPolicy
            ├── LetterRepository → JSONLetterCache
            ├── JSONStreakStore
            ├── JSONParentDashboardStore
            ├── JSONOnboardingStore
            ├── LocalNotificationScheduler
            ├── ThesisCondition.defaultForInstall
            ├── SchriftArt        (UserDefaults-persisted)
            ├── LetterOrderingStrategy   (UserDefaults-persisted)
            ├── enablePaperTransfer / enableFreeformMode (UserDefaults)
            ├── CoreMLLetterRecognizer  (LetterRecognizerProtocol)
            └── AVSpeechSpeechSynthesizer (SpeechSynthesizing)

TracingViewModel
  ├── private freeWriteRecorder = FreeWritePhaseRecorder()
  ├── private freeform = FreeformController()
  ├── private grid = SequenceGridController(...)
  ├── private detector = InputModeDetector()
  ├── private phaseController: LearningPhaseController(condition:)
  ├── private adaptationPolicy: any AdaptationPolicy
  ├── private letterScheduler: LetterScheduler
  ├── private calibrationStore: CalibrationStore
  └── let overlayQueue = OverlayQueueManager()
```

`TracingViewModel` is `@MainActor @Observable`. SwiftUI views read its
properties via `@Environment(TracingViewModel.self)`. The VM forwards
~65 observable properties (some via direct storage, some via computed
forwarders to the FreeWritePhaseRecorder / FreeformController /
phaseController / animation / messages collaborators).

There are **no circular dependencies**. The Core layer never imports
from Features. The dependency graph is acyclic (verified by
`Package.swift` being a single target with no internal sub-modules).

### 2.3 Design patterns

* **MVVM**: SwiftUI views are passive observers; `TracingViewModel` is
  the single source of truth. Views never read from stores directly —
  they always go through the VM.
* **Protocol-oriented + dependency injection**: every external
  collaborator (audio, progress store, haptic engine, letter
  recognizer, speech synth, dashboard store, onboarding store, streak
  store, sync service, notification center, adaptation policy) is
  protocol-typed in `TracingDependencies`. Production uses live
  implementations; tests inject `Stub*` types from
  `TestFixtures.swift`.
* **Pure-value-type FSMs** for the deterministic logic: `LearningPhase`,
  `LearningPhaseController`, `PlaybackStateMachine`. They have no I/O
  and are exhaustively unit-tested without mocks.
* **Composition over inheritance**: the W8 God-object refactor pulled
  `FreeWritePhaseRecorder` and `FreeformController` out of the VM and
  composed them in. The VM forwards observable properties so views
  notice nothing.
* **Factories for per-VM controllers**: `TracingDependencies` holds
  factory closures (`makePlaybackController`,
  `makeMessagePresenter`, `makeAnimationGuide`, `makeCalibrationStore`,
  `makeLetterScheduler`) so tests can swap in instant-sleeper variants
  without subclassing.

### 2.4 Data flow

A single touch on the canvas:

```
User finger / pencil
  ↓ (UIKit gesture recognizer in TracingCanvasView)
TracingViewModel.beginTouch / updateTouch / endTouch
  ↓
StrokeTracker.update(normalizedPoint:)        ← checkpoint hit detection
  ↓ (callback)
HapticEngine.fire(.checkpointHit)
  ↓
PlaybackController.request(.active)            ← gated on velocity, feedbackIntensity
  ↓
AudioEngine.setAdaptivePlayback(speed:, hBias:)

(simultaneously, during freeWrite)
  ↓
FreeWritePhaseRecorder.record(point:, t:, force:, canvasSize:)
  ↓ (later, on phase advance)
FreeWriteScorer.score(...) → WritingAssessment
  ↓
ParentDashboardStore.recordPhaseSession(... , assessment:)
  ↓ (background Task)
JSON write to Application Support (atomic, debounced)
```

A phase advance:

```
TracingViewModel.advanceLearningPhase
  ↓
phaseController.advance(score:)              ← mutates currentPhase
  ↓
overlayQueue.enqueue(.kpOverlay)              ← if wasInFreeWrite
overlayQueue.enqueue(.paperTransfer(...))     ← if enablePaperTransfer
recordPhaseSessionCompletion()
  └── overlayQueue.enqueue(.celebration(stars:))
  └── speech.speak(praise(starsEarned:))
  └── ParentDashboardStore.recordPhaseSession (per phase)
  └── ProgressStore.recordCompletion (per letter in word)
  └── StreakStore.recordSession
  └── adaptationPolicy.record(AdaptationSample)
  └── strokeTracker.radiusMultiplier = currentDifficultyTier.radiusMultiplier

(in parallel, async)
runRecognizerForFreeWrite → CoreMLLetterRecognizer.recognize (Task.detached)
  ↓
overlayQueue.enqueueBeforeCelebration(.recognitionBadge(r))
speech.speak(recognition phrase)
ProgressStore.recordRecognitionSample
```

---

## 3. Learning pipeline — detailed

### 3.1 Phase: Observe (Anschauen)

**What the child sees and does**
- The letter glyph rendered in the active script (Druckschrift or Schreibschrift).
- An animated guide dot tracing each stroke in canonical order.
- Numbered start dots indicating where each stroke begins.
- A "Schau mal genau hin." prompt is spoken via TTS on phase entry.
- The child taps anywhere on the overlay to advance — or the phase
  auto-advances after the second full animation cycle so a child who
  can't read isn't stuck.

**What the code does**
- `LearningPhaseController.currentPhase = .observe` (initial state).
- `phaseController.isTouchEnabled` returns `false` — the canvas does
  not record touches.
- `TracingViewModel.startGuideAnimation()` calls
  `AnimationGuideController.start(strokes:)`. The controller publishes
  `guidePoint` which `TracingCanvasView` renders as an orange dot.
- Auto-advance is implemented in
  `TracingViewModel.startGuideAnimation` (line 1058):

  ```swift
  animation.onCycleComplete = { [weak self] in
      guard let self else { return }
      self.observeCycleCount += 1
      if self.observeCycleCount >= 2,
         self.phaseController.currentPhase == .observe {
          self.completeObservePhase()
      }
  }
  ```

**Recorded data**
- `phaseScores[.observe] = 1.0` on completion (pass/fail).
- A `PhaseSessionRecord` row with `phase: "observe"`, `completed: true`,
  `score: 1.0`.

**Trigger to next phase**
- `completeObservePhase()` → `advanceLearningPhase()` → phase becomes
  `.direct`. The verbal prompt for `.direct` ("Tippe die Punkte der
  Reihe nach.") is spoken immediately.

### 3.2 Phase: Direct (Richtung lernen)

**What the child sees and does**
- The same letter glyph is shown.
- A single numbered dot pulses at the next stroke's start position.
- The child taps the dot. On a correct tap: confirmation haptic, brief
  directional arrow along the stroke path, and (on the very first tap)
  a replay of the letter-name audio. On a wrong tap: gentle haptic,
  the correct dot pulses.
- After all strokes' start dots have been tapped in order, the phase
  auto-advances.

**What the code does**
- `LearningPhase.direct.rawValue == 1` — placed between `observe` (0)
  and `guided` (2).
- `DirectPhaseDotsOverlay` (in `TracingCanvasView.swift`) renders only
  the **next-expected** dot so visually overlapping starts (A's two
  diagonals share the apex) don't stack.
- `TracingViewModel.tapDirectDot(index:)` (line 1240):

  ```swift
  if index == directNextExpectedDotIndex {
      directTappedDots.insert(index)
      haptics.fire(.checkpointHit)
      // play letter audio on first tap; show directional arrow
      directArrowStrokeIndex = index
      // defer phase advance until arrow finishes (1.2 s)
  } else {
      haptics.fire(.offPath)
      directPulsingDot = true   // resets after 700 ms
  }
  ```

- Empty-stroke letters skip direct: `load(letter:)` calls
  `phaseController.advance(score: 1.0)` twice in succession to land in
  `.guided`.

**Recorded data**
- `phaseScores[.direct] = 1.0` (pass/fail).
- A `PhaseSessionRecord` row with `phase: "direct"`.

**Trigger to next phase**
- Last correct tap → 1.2-second arrow window → `advanceLearningPhase()`.

### 3.3 Phase: Guided (Nachspuren)

**What the child sees and does**
- The letter glyph plus a faint blue ghost line over each stroke.
- Real-time green ink follows the finger / pencil.
- A "Jetzt fährst du die Linien nach." prompt is spoken on phase
  entry.
- Audio plays in real time when the touch is on-path, with playback
  speed mapping to writing velocity (slow tracing → slow audio,
  fast → fast).
- Haptic ticks on every checkpoint hit.

**What the code does**
- `phaseController.useCheckpointGating == true`: `StrokeTracker`
  enforces stroke order. Each stroke must be traced left-to-right (or
  the canonical direction encoded in `strokes.json`); jumping to the
  next stroke before completing the current one yields no progress.
- `TracingViewModel.updateTouch` (line 818) feeds normalized touch
  points into `strokeTracker.update(normalizedPoint:)`.
- Audio is gated by `feedbackIntensity > 0.3` (line 937) and
  `smoothedVelocity >= playbackActivationVelocityThreshold` (default
  22 pt/s).
- The freeWriteRecorder also tracks `checkpointsPerSecond` during this
  phase via `freeWriteRecorder.updateSpeed(completedCheckpoints:)`.

**Recorded data**
- `phaseScores[.guided] = strokeTracker.overallProgress` (0–1) at the
  moment the phase advances.
- `lastGuidedScore` is captured (FreeformController) so the SchuleWorld
  can show a verbal "Nachspuren fertig" feedback band during the
  freeWrite transition.
- A `PhaseSessionRecord` row.

**Trigger to next phase**
- `strokeTracker.isComplete && hasStrokes` → `advanceLearningPhase()`.

### 3.4 Phase: FreeWrite (Selbst schreiben)

**What the child sees and does**
- The letter glyph remains visible but no ghost lines and no
  checkpoints are shown.
- The child writes the letter from memory.
- A "Jetzt schreibst du den Buchstaben ganz alleine." prompt is spoken
  on entry.
- No haptics, no real-time audio (`feedbackIntensity == 0.0`).
- On lift-off, the child lifts the pen and the phase ends.

**What the code does**
- `feedbackIntensity == 0.0` so `updateTouch` skips haptics and audio
  (lines 891, 918, 937).
- Every touch is appended to four parallel buffers in
  `FreeWritePhaseRecorder`: `points`, `timestamps`, `forces`, `path`
  (the canvas-normalised KP path).
- On `advanceLearningPhase`:
  ```swift
  case .freeWrite:
      guard let def = strokeTracker.definition else { ... }
      score = freeWriteRecorder.assess(
          reference: def, canvasSize: canvasSize
      ).overallScore
  ```
- `FreeWriteScorer.score` returns a `WritingAssessment` — see §4.6.
- Recognition runs on a background `Task.detached`; results land
  asynchronously and enqueue `.recognitionBadge` ahead of the
  celebration via `enqueueBeforeCelebration`.

**Recorded data**
- `phaseScores[.freeWrite] = assessment.overallScore`.
- `WritingAssessment` is stored on `PhaseSessionRecord`'s four
  optional dimension fields.
- `progressStore.recordCompletion(... recognitionResult:)` if recognition
  finished by then; otherwise `recordRecognitionSample` populates
  history when the result lands.

**Trigger to session completion**
- `phaseController.advance(...)` returns false — last phase. The
  celebration overlay shows; "Weiter" loads the next recommended
  letter via the LetterScheduler.

---

## 4. Scientific methods — with citations

Each method is backed by named papers and the implementation site is
explicitly identified. Where the code differs from the paper, the
delta is documented.

### 4.1 Gradual Release of Responsibility (GRR)

**Description.** A pedagogical model where teacher control fades and
learner responsibility rises across stages: "I do" → "We do" → "You
do." The original framing has three phases; the modern reading
(Fisher & Frey, 2013) inserts a guided-practice phase between modelled
demonstration and independent application.

**Papers.**
* Pearson, P. D., & Gallagher, M. C. (1983). The instruction of reading
  comprehension. *Contemporary Educational Psychology*, 8(3), 317–344.
* Fisher, D., & Frey, N. (2013). *Better learning through structured
  teaching: A framework for the gradual release of responsibility* (2nd
  ed.). ASCD.

**Implementation.**
* `Core/LearningPhase.swift` — four `case`s in raw-value order
  `observe / direct / guided / freeWrite`. Each carries a German
  display name, an icon, a stable `rawName` for serialisation.
* `Core/LearningPhaseController.swift` — pure value-type FSM. Field
  comments name the GRR mapping: observe = "I do", direct =
  "Start", guided = "We do", freeWrite = "You do."

**How the implementation differs.** The classic GRR has three phases;
this app inserts a fourth (`direct`) between observe and guided to
explicitly teach stroke directionality (see §4.4). All four phases
participate in gradual release: scaffolding visible (observe + direct)
→ scaffolding interactive (guided) → scaffolding withdrawn (freeWrite).

### 4.2 Guidance Hypothesis — Fading Feedback

**Description.** Schmidt & Lee's guidance hypothesis predicts that
augmented feedback during practice is helpful for performance but can
become a crutch — long-term retention improves when feedback fades as
the learner internalises the task. The app implements an explicit
phase-dependent feedback intensity gate.

**Paper.** Schmidt, R. A., & Lee, T. D. (2005). *Motor control and
learning: A behavioral emphasis* (4th ed.). Human Kinetics.

**Implementation.**
* `Features/Tracing/TracingViewModel.swift` — `feedbackIntensity`
  computed property (line 204):

  ```swift
  var feedbackIntensity: CGFloat {
      switch phaseController.currentPhase {
      case .observe:   return 1.0
      case .direct:    return 1.0
      case .guided:    return 0.6
      case .freeWrite: return 0.0
      }
  }
  ```

* The gate is read at three call sites in `updateTouch`:
  - line 891: `if !wasComplete && isNowComplete, feedbackIntensity > 0 { haptics.fire(...) }`
  - line 918: `if (...stroke or checkpoint changed...), feedbackIntensity > 0 { haptics.fire(...) }`
  - line 937: `let shouldBeActive = ... && feedbackIntensity > 0.3`

  → audio cuts off entirely below 0.3 (so freeWrite is silent), haptics
  cut off entirely below `> 0`.

**How the implementation differs.** The paper describes a continuous
fade; this implementation uses four discrete phase-pinned levels so
the gating thresholds are auditable and can be tested. The 0.3
threshold for audio is chosen so the `.guided` phase (0.6) keeps audio
on while `.freeWrite` (0.0) silences it.

### 4.3 Knowledge of Performance (KP) Visual Overlay

**Description.** Danna & Velay distinguish Knowledge of Results (KR —
"your score was X") from Knowledge of Performance (KP — "you deviated
here"). Children under 8 benefit more from KP than KR because the
process feedback is directly actionable.

**Paper.** Danna, J., & Velay, J.-L. (2015). Basic and supplementary
sensory feedback in handwriting. *Frontiers in Psychology*, 6, 169.

**Implementation.**
* `Features/Tracing/TracingCanvasView.swift` — `freeWriteKPOverlay()`
  function (line 224). After freeWrite completes, the overlay
  superimposes:
  - the reference strokes in **blue** (line width 8, opacity 0.4)
  - the child's path in **green** (line width 4)
  on a darkened background. The child sees exactly where their trace
  diverged from the reference.

* The overlay is now driven by the OverlayQueueManager: rendered when
  `vm.overlayQueue.currentOverlay == .kpOverlay` (line 346 of
  TracingCanvasView). Auto-dismisses after 3 s (the queue's default
  duration for `.kpOverlay`) or on tap (`vm.overlayQueue.dismiss()`).

**How the implementation differs.** Paper compares KP vs KR
empirically; this app provides KP as the default visualisation after
freeWrite. KR (the numeric score) is reserved for the parent-gated
research dashboard and never shown to the child.

### 4.4 Directionality Teaching

**Description.** Thibon, Gerber & Kandel show that children under 8
store motor programs for individual stroke segments rather than the
letter as a whole. Explicitly teaching where each stroke starts (and
in what order) supports the formation of these per-segment motor
programs.

**Paper.** Thibon, L. S., Gerber, S., & Kandel, S. (2018). The
elaboration of motor programs for the automation of letter production.
*Acta Psychologica*, 182, 200–211.

**Implementation.**
* `Core/LearningPhase.swift` — explicit `.direct` case between
  `.observe` and `.guided`.
* `Core/LearningPhaseController.swift` — `useCheckpointGating: false`
  and `showCheckpoints: false` for direct (the dot overlay handles its
  own rendering).
* `Features/Tracing/TracingCanvasView.swift` — `DirectPhaseDotsOverlay`
  inner View. Renders the next-expected stroke's start dot only.
* `Features/Tracing/TracingViewModel.swift` — `tapDirectDot(index:)`
  drives the correct/wrong tap logic + 1.2-second arrow window before
  phase advance.

**How the implementation differs.** Paper observes the phenomenon;
this app builds an explicit pedagogical phase around it. The 1.2-
second arrow timing was chosen empirically so a 5-year-old can perceive
the direction cue before the next dot pulses.

### 4.5 Motor Similarity Letter Ordering

**Description.** Berninger et al. argue that grouping letters by
shared stroke patterns ("motor similarity") during early instruction
promotes faster acquisition than alphabetical or random ordering, by
letting the child re-use motor programs across letters that share
stroke shapes.

**Paper.** Berninger, V. W., Abbott, R. D., Jones, J., Wolf, B. J.,
Gould, L., Anderson-Youngstrom, M., Shimada, S., & Apel, K. (2006).
Early development of language by hand: Composing, reading, listening,
and speaking connections; three letter-writing modes; and fast mapping
in spelling. *Developmental Neuropsychology*, 29(1), 61–92.

**Implementation.**
* `Core/LetterOrderingStrategy.swift` — three strategies as an enum:

  ```swift
  enum LetterOrderingStrategy: String, Codable, CaseIterable {
      case motorSimilarity, wordBuilding, alphabetical

      func orderedLetters() -> [String] {
          switch self {
          case .motorSimilarity:
              return ["I","L","T","F","E","H","A","K","M","N","V","W","X","Y","Z",
                      "C","O","G","Q","S","U","J","B","D","P","R"]
          case .wordBuilding:
              return ["M","A","L","E","I","O","S","R","N","T","D","U","H","G","K",
                      "W","B","P","F","J","V","C","Q","X","Y","Z"]
          case .alphabetical:
              return (Unicode.Scalar("A").value...Unicode.Scalar("Z").value)
                  .compactMap { Unicode.Scalar($0) }.map { String($0) }
          }
      }
  }
  ```

* `TracingViewModel.visibleLetterNames` (line 1321) sorts the loaded
  letters by the active ordering's rank map.
* `SettingsView.swift` exposes the picker.

**How the implementation differs.** Paper proposes the principle but
not a specific 26-letter sequence; the motorSimilarity ordering above
is the app's own choice (vertical → horizontal → diagonal → curved).
The `wordBuilding` strategy is an alternative inspired by Austrian
practice that lets a child form recognisable words (M, A, L → MAL)
within the first dozen letters.

### 4.6 Schreibmotorik 4-Dimension Assessment

**Description.** Marquardt & Söhl (Schreibmotorik Institut)
characterise handwriting motor competency along four dimensions: form
accuracy, tempo (speed consistency), Druck (pressure control), and
rhythm (fluency). Each is independently measurable; an aggregate score
should weight them rather than collapse to one number.

**Paper.** Marquardt, C., & Söhl, K. (2016). *Schreibmotorik:
Schreiben lernen leicht gemacht — Eine Praxishilfe der STEP–
Schreibmotorik-Initiative*. Cornelsen.

**Implementation.**
* `Core/FreeWriteScorer.swift` — `WritingAssessment` struct (line 19):

  ```swift
  struct WritingAssessment: Codable, Equatable {
      let formAccuracy: CGFloat       // discrete Fréchet
      let tempoConsistency: CGFloat   // 1 − CV² of inter-point intervals
      let pressureControl: CGFloat    // 1 − variance of pencil force
      let rhythmScore: CGFloat        // active-time / total-time

      var overallScore: CGFloat {
          formAccuracy * 0.40 + tempoConsistency * 0.25
          + pressureControl * 0.15 + rhythmScore * 0.20
      }
  }
  ```

  Weights sum to **1.0 exactly** (verified by
  `WritingAssessmentTests.testWeightedAccuracySumsToOne`).

* Each dimension's algorithm:
  - `formAccuracy` (line 204): discrete Fréchet distance vs reference
    polyline, normalised by `reference.checkpointRadius * 3.0`.
  - `tempoConsistency` (line 221): CV² of inter-point timestamp deltas;
    excludes gaps > 0.5 s as pen-lifts.
  - `pressureControl` (line 244): 1 − normalised variance over non-zero
    pencil forces; finger touches (force 0) score 1.0 (no pressure
    data to fault).
  - `rhythmScore` (line 261): ratio of active drawing time to total
    session time.

* `Core/ParentDashboardStore.swift` — `PhaseSessionRecord` carries all
  four dimensions as optionals (nil for non-freeWrite phases).
* `ResearchDashboardView.swift` displays the rolling averages with the
  weight (× 0.40, × 0.25, × 0.15, × 0.20) shown.
* CSV / TSV export (line 64): four dimensions as separate columns.

**How the implementation differs.** Paper describes the dimensions
qualitatively; the formulas above are the app's choice of operational
definitions. The 0.40 / 0.25 / 0.15 / 0.20 weights also represent a
pedagogical priority (form first, consistency second) rather than a
peer-reviewed weighting.

### 4.7 Writing Speed / Automatization Tracking

**Description.** The KMK Vereinbarung (German Conference of
Cultural Ministers, 2024 update) explicitly names *Automatisierung der
Bewegungsabläufe* (automatisation of writing movement) as a Grundschule
goal. Speed-trend over sessions is the standard proxy for this.

**Paper.** Kultusministerkonferenz (2024). *Vereinbarung zur Arbeit
in der Grundschule*. Beschluss der Kultusministerkonferenz (revised).

**Implementation.**
* `Features/Tracing/FreeWritePhaseRecorder.swift` — owns
  `checkpointsPerSecond`, recomputed on each touch:

  ```swift
  func updateSpeed(completedCheckpoints: Int,
                   now: CFTimeInterval = CACurrentMediaTime()) {
      guard activePhaseStart > 0 else { return }
      let elapsed = now - activePhaseStart
      guard elapsed > 0.1 else { return }
      checkpointsPerSecond = CGFloat(completedCheckpoints) / CGFloat(elapsed)
  }
  ```

* `Core/ProgressStore.swift` — `LetterProgress.speedTrend: [Double]?`
  capped at **50 entries** (D-4 raised the cap from 5 so the thesis
  export carries the full automatisation trajectory; the scheduler's
  `automatizationBonus` reads halves so longer histories don't
  distort the bonus):

  ```swift
  if trend.count > 50 { trend.removeFirst(trend.count - 50) }
  ```

* `Core/LetterScheduler.swift` — `automatizationBonus(trend:)` (line
  136) reads the speed trend and returns a priority adjustment:
  improving speed → negative bonus (deprioritise letters being
  automatised), stagnant or declining → small positive boost.
* `TracingViewModel.writingSpeedTrend` (line 1466) aggregates across all
  letters: `improving` / `stable` / `declining` based on relative gain
  thresholds (±10 %).
* `FortschritteWorldView` shows this as a verbal trend pill ("aufwärts /
  stabil / abwärts") with no numbers.

**How the implementation differs.** KMK names the goal but not the
metric. `strokesPerSecond` (checkpoints completed per second) is the
app's choice; it normalises across letters of different stroke-count
because it's a rate.

### 4.8 Paper Transfer Self-Assessment

**Description.** Alamargot & Morin show that tablet writing has lower
friction than paper, which can disrupt motor-control strategies. A
parental-research mode lets the child write on real paper after each
freeWrite trial and self-assess the result.

**Paper.** Alamargot, D., & Morin, M.-F. (2015). Does handwriting on a
tablet screen affect students' graphomotor execution? A comparison
between Grades Two and Nine. *Human Movement Science*, 44, 32–41.

**Implementation.**
* `Features/Tracing/PaperTransferView.swift` — full implementation.
  Three phases driven by a `Phase` enum: `.showLetter` (3 s reference
  letter shown) → `.writePaper` (10 s prompt to write on paper) →
  `.assess` (three emoji buttons 😟 / 😐 / 😊 with scores 0.0 / 0.5 /
  1.0).
* Each phase speaks its prompt via TTS:
  `paperTransferShow / paperTransferWrite / paperTransferAssess` from
  `ChildSpeechLibrary`.
* `TracingViewModel.submitPaperTransfer(score:)` records the score on
  `LetterProgress.paperTransferScore` and dismisses the queue.
* Gated behind the `enablePaperTransfer` Settings toggle (off by
  default — research-only).

**How the implementation differs.** Paper compares grade 2 vs grade 9;
this app implements the self-assessment as an opt-in research feature.
Children's self-assessment is a known noisy signal but useful for
transfer-awareness analysis post-hoc.

### 4.9 Letter Variant Exploration

**Description.** The Grundschulverband recommends exposing children to
multiple legitimate variants of the same letter (e.g. two stroke
orderings for F, H) early, so motor programs stay flexible rather than
locking to one canonical form.

**Paper.** Grundschulverband. (2024). *Grundschrift — Förderkartei zur
Schreibmotorik*. Frankfurt am Main: Grundschulverband.

**Implementation.**
* `Core/Models.swift` — `LetterAsset.variants: [String]?` lists
  alternate stroke-order IDs (e.g. `["variant"]`).
* `Features/Library/LetterRepository.swift` — bundle scan looks for
  `Letters/<X>/strokes_variant.json` and registers it as a variant
  (line 295).
* `Features/Library/LetterRepository.swift:529` —
  `loadVariantStrokes(for:variantID:)` loads the variant on demand.
* `TracingViewModel.toggleVariant()` (line 567) swaps the active
  stroke set between standard and variant; the canvas re-maps
  checkpoints accordingly.
* Variants currently shipped: uppercase **F**, uppercase **H**,
  lowercase **r**.

**How the implementation differs.** The Förderkartei lists many
letters; the app ships variants for three (F, H, r) as a demo. The
infrastructure scales to any letter that ships a `strokes_variant.json`.

### 4.10 Spaced Repetition

**Description.** Ebbinghaus's forgetting curve R(t) = e^(−t/S)
predicts exponential memory decay. Cepeda et al.'s meta-analysis
confirms that spaced practice outperforms massed practice when
inter-session interval is calibrated to the desired retention.

**Papers.**
* Ebbinghaus, H. (1885). *Über das Gedächtnis: Untersuchungen zur
  experimentellen Psychologie*. Duncker & Humblot.
* Cepeda, N. J., Pashler, H., Vul, E., Wixted, J. T., & Rohrer, D.
  (2006). Distributed practice in verbal recall tasks: A review and
  quantitative synthesis. *Psychological Bulletin*, 132(3), 354–380.

**Implementation.**
* `Core/LetterScheduler.swift` — weighted prioritiser. Three
  components in [0, 1]:

  ```swift
  let recencyUrgency = 1.0 - exp(-daysSince / memoryStabilityDays)  // Ebbinghaus
  let accuracyDeficit = 1.0 - p.bestAccuracy
  let novelty = 1.0 / (1.0 + Double(p.completionCount))

  let priority = recencyUrgency  * 100 * recencyWeight   // 0.40
               + accuracyDeficit * 100 * accuracyWeight  // 0.35
               + novelty         * 100 * noveltyWeight   // 0.25
               + speedBonus                              // automatisation pull-down
  ```

  `memoryStabilityDays = 7.0` is the baseline (matches typical word-list
  half-decay). `effectiveStabilityDays(for:)` stretches this per-letter
  with a logarithmic practice factor and a [0.5, 1.5] accuracy factor,
  capped at 60 days (W-24). Less-practised or struggling letters keep
  the 7-day baseline; well-practised, accurate letters fade slower —
  matching the SuperMemo SM-2 / Cepeda 2006 expanding-interval rule.

* `TracingViewModel.loadRecommendedLetter()` calls
  `letterScheduler.prioritized(available:, progress:)`, takes the
  highest-priority letter, and stores its priority on
  `lastScheduledLetterPriority` so the dashboard's
  `schedulerEffectivenessProxy` can correlate it with the eventual
  session score.

* `LetterScheduler.fixedOrder()` is the `.control` thesis arm
  scheduler. It scores by `priority = -completionCount` and ignores
  Ebbinghaus / accuracy / novelty entirely, giving round-robin
  delivery so the scheduling effect doesn't confound the phase-
  progression manipulation. (Earlier the constant `priority: 0`
  stalled control children on the first letter forever — review
  item W-23.)

**How the implementation differs.** Ebbinghaus's curve has a single
parameter (memory stability); this app combines that with accuracy and
novelty terms because empirical handwriting practice involves more
than memory decay (children also benefit from low-completion
exposure). The combination is multi-objective rather than purely
predictive.

### 4.11 Adaptive Difficulty (Zone of Proximal Development)

**Description.** Vygotsky's ZPD: tasks just outside what a learner can
accomplish independently maximise learning. Operationally: difficulty
should rise when accuracy is consistently high and fall when it drops.

**Conceptual root.** Vygotsky, L. S. (1978). *Mind in society: The
development of higher psychological processes*. Harvard University
Press. (Original work compiled posthumously from 1930s manuscripts.)

**Implementation.**
* `Core/DifficultyAdaptation.swift` — `MovingAverageAdaptationPolicy`:

  ```swift
  init(windowSize: Int = 10,
       hysteresisCount: Int = 3,
       promotionAccuracyThreshold: CGFloat = 0.85,
       demotionAccuracyThreshold: CGFloat = 0.55,
       initialTier: DifficultyTier = .standard)
  ```

  - 10-sample moving accuracy window
  - Promote when avg ≥ 0.85 for 3 consecutive evaluations
  - Demote when avg ≤ 0.55 for 3 consecutive evaluations
  - Three tiers: `.easy` (radius × 1.5), `.standard` (× 1.0),
    `.strict` (× 0.65)

* The radius multiplier is applied to `StrokeTracker.radiusMultiplier`
  whenever a letter session completes (`commitCompletion`, line 1451).
* `FixedAdaptationPolicy(currentTier: .standard)` is used for the
  `.control` thesis condition so adaptation is disabled and a clean
  comparison is possible.

**How the implementation differs.** ZPD is a qualitative concept; the
operationalisation as a moving-average + hysteresis ladder is the app's
choice. The thresholds (0.85 / 0.55) and the 3-evaluation hysteresis
were chosen to prevent ping-ponging.

### 4.12 Fréchet Distance Scoring

**Description.** The discrete Fréchet distance is the maximum of the
minimum point-to-point distances along two parameterised polylines —
intuitively, "how tightly can a leash bound a person walking along
curve A and a dog walking along curve B?" Formally it is the metric
distance on the space of curves.

**Papers.**
* Fréchet, M. (1906). Sur quelques points du calcul fonctionnel.
  *Rendiconti del Circolo Matematico di Palermo*, 22(1), 1–72.
* Eiter, T., & Mannila, H. (1994). Computing discrete Fréchet
  distance. Technical Report CD-TR 94/64, Christian Doppler Lab for
  Expert Systems, TU Vienna.
* Alt, H., & Godau, M. (1995). Computing the Fréchet distance between
  two polygonal curves. *International Journal of Computational
  Geometry & Applications*, 5(1n02), 75–91.

**Implementation.**
* `Core/FreeWriteScorer.swift:283` — discrete Fréchet via O(nm)
  dynamic programming on a flat array (cache-line efficient,
  iterative bottom-up to avoid stack overflow):

  ```swift
  static func discreteFrechetDistance(_ p: [CGPoint], _ q: [CGPoint]) -> CGFloat {
      let n = p.count, m = q.count
      var dp = [CGFloat](repeating: 0, count: n * m)
      for i in 0..<n {
          for j in 0..<m {
              let d = dist(p[i], q[j])
              let idx = i * m + j
              if i == 0 && j == 0 {
                  dp[idx] = d
              } else if i == 0 {
                  dp[idx] = max(d, dp[j - 1])
              } else if j == 0 {
                  dp[idx] = max(d, dp[(i - 1) * m])
              } else {
                  let prev = min(dp[(i - 1) * m + j],
                                 min(dp[i * m + (j - 1)],
                                     dp[(i - 1) * m + (j - 1)]))
                  dp[idx] = max(d, prev)
              }
          }
      }
      return dp[n * m - 1]
  }
  ```

* `formAccuracy(tracedPoints:reference:)` resamples both polylines to
  the same point count, runs Fréchet, and normalises by
  `reference.checkpointRadius * 3.0`.
* `formAccuracyShape(tracedPoints:reference:)` is an
  order-independent variant for freeform mode: it densifies each
  reference stroke independently (no phantom edge across pen-lifts),
  normalises both sets to the unit box, and uses **symmetric
  Hausdorff** instead of Fréchet so the score is invariant to stroke
  order — appropriate for blank-canvas writing where the child can
  draw the strokes in any sequence.

**How the implementation differs.** Alt & Godau describe the
continuous variant; this implementation uses Eiter & Mannila's
discrete variant which is sufficient for digitised polylines. The
flat-array vs 2D array choice is a cache-locality optimisation that
doesn't change the algorithm's behaviour.

#### 4.12.1 `frechetDistance` — the study's primary accuracy outcome

The exported `frechetDistance` column is the **raw** discrete-Fréchet
distance for one freeWrite trial. It is the same number
`formAccuracy` is derived from, recorded before that derivation
throws information away. State it in the thesis exactly as follows.

**What is compared.**

| | Source | Coordinate frame |
|---|---|---|
| Trace | Every freeWrite touch sample accepted by `TouchDispatcher.updateTouch` (canvas-space, in temporal order) | Mapped to the reference's frame by `(p − frame.origin) / frame.size`, where `frame` is the active cell's frame, or the whole canvas when there is a single cell |
| Reference | `LetterStrokes.strokes[*].checkpoints`, concatenated across strokes in definition order into **one** polyline (`referencePolyline`) | Already normalised 0–1 as stored in `strokes.json` |

Both therefore live in the same normalised **0–1 letter box**, and the
distance is reported in those units — not points, not pixels, and not
device-dependent.

**Resampling.** Both polylines are resampled by `FreeWriteScorer.resample`
to the *same* count of arc-length-equidistant points,
`targetCount = max(total reference checkpoint count, 20)`. This is what
makes a 400-sample trace comparable to a 40-checkpoint reference: the
discrete Fréchet distance is sensitive to point density, so an
unresampled comparison would confound writing speed with shape error.
The first and last points of each polyline are preserved exactly; the
interior points are linearly interpolated along the original segments.

**Granularity: whole letter, not per stroke.** One distance per
freeWrite trial. The reference is concatenated across pen-lifts, so
each lift gap is bridged by a phantom segment; this was investigated
and found Fréchet-safe (≤1.4 % effect on real letters, always toward
*higher* scores) because the coupling matches the trace's own gap
bridge to the reference's at the same arc-length fraction — see the
cross-pen-lift note on `FreeWriteScorer.formAccuracy`. Word / multi-cell
sessions record the **mean** of the per-cell whole-letter distances,
which is legitimate because each cell's trace is normalised into its
own cell-local box; the pilot practises single letters and never
reaches that path.

**What the measure is and is not invariant to.**
* **Not** translation- or scale-invariant beyond the cell-frame
  mapping. A correctly-shaped letter written in the wrong part of the
  box scores worse. (The unit-bbox-normalised, order-independent
  Hausdorff variant `formAccuracyShape` *is* — but that is the
  Werkstatt/freeform measure, not this one.)
* **Not** stroke-order invariant. Fréchet is a parameterised-curve
  metric, so writing the strokes in the wrong order raises the
  distance. This is intended: stroke order is part of what the app
  teaches.
* Lower is better; `0` is a perfect overlay. Unbounded above in
  principle, bounded in practice by the box diagonal (≈ 1.41) for
  traces that stay on the canvas.

**Why raw rather than `formAccuracy`.** `formAccuracy` is
`clamp₀₁(1 − d / (3 · checkpointRadius))`. With the shipped Druckschrift
`checkpointRadius = 0.1` that clamp bites at `d ≥ 0.3`: every trial
worse than that reports exactly `0` and the differences between them
are destroyed. The raw distance has no floor and no ceiling, which is
what a continuous outcome variable for a between-arms comparison
requires. `formAccuracy` is retained unchanged as the child-facing and
weighted-Schreibmotorik input.

#### 4.12.2 `checkpointCoverage` — the secondary accuracy outcome

`StrokeTracker.overallProgress`: reached checkpoints ÷ total
checkpoints, in `[0, 1]`, captured at freeWrite exit.
`resetForPhaseTransition` resets the tracker on entry to freeWrite, so
the recorded value describes the freeWrite pass alone and not the
guided pass before it.

A checkpoint counts as reached only when the live touch point comes
within `checkpointRadius × radiusMultiplier` of it **and** every earlier
checkpoint in that stroke has already been reached — it is a strictly
sequential gate, and strokes advance in definition order.

It is kept as a secondary column for continuity with earlier pilot
rounds, but it **saturates**: any trace that passes within tolerance of
every checkpoint reports `1.0` no matter how badly it wanders between
them. `MeasurementLayerTests.coverageSaturatesWhereFrechetDiscriminates`
pins exactly that case — two traces, identical coverage, clearly
different Fréchet distances. Report Fréchet as the accuracy outcome and
coverage as a descriptive companion.

#### 4.12.3 Per-letter analysis is mandatory — M is a structural outlier

The five study letters are **not** structurally comparable, so time and
accuracy must be analysed **per letter and never pooled**:

| Letter | Strokes | Checkpoints (Regular) |
|--------|---------|-----------------------|
| A | 3 | 40 + 40 + 40 = 120 |
| F | 3 | 40 + 40 + 40 = 120 |
| I | 1 | 40 |
| L | 2 | 40 + 40 = 80 |
| **M** | **1** | **200** |

M is the outlier on both axes at once: it is the only letter that packs
200 sequential checkpoint gates into a **single** stroke, with no
pen-lift at which the tracker re-syncs to a fresh stroke. Coverage
therefore climbs differently for M than for any other letter, and its
trial time is not on the same scale as a 40-checkpoint I. Pooling M with
the rest — or comparing raw seconds across letters — is invalid. Fit
per-letter, or include letter as a factor.

### 4.13 CoreML Letter Recognition

**Description.** A 40 × 40 grayscale CNN trained to classify a stroke
image into one of 53 classes (A–Z, a–z, ß). Used after each freeWrite
trial and inside the freeform writing mode.

**Papers.** (Underlying dataset and model design choices.)
* Cohen, G., Afshar, S., Tapson, J., & van Schaik, A. (2017).
  EMNIST: an extension of MNIST to handwritten letters. *International
  Joint Conference on Neural Networks (IJCNN)*, 2921–2926.
* For Apple's on-device CNN execution: Apple Inc. (2023). *Core ML
  Performance Best Practices*. WWDC session materials.

**Implementation.**
* `Core/LetterRecognizer.swift` — `CoreMLLetterRecognizer`. Marked
  `nonisolated` and runs every call inside `Task.detached(priority:
  .userInitiated)` so the inference path never executes on the main
  thread:

  ```swift
  return await Task.detached(priority: .userInitiated) {
      guard let model = Self.loadModelIfNeeded() else { return nil }
      guard let image = Self.renderToImage(points: points, canvasSize: canvasSize) else {
          return nil
      }
      let request = VNCoreMLRequest(model: model)
      request.imageCropAndScaleOption = .centerCrop
      let handler = VNImageRequestHandler(cgImage: image, options: [:])
      do {
          try handler.perform([request])
          let classifications = request.results as? [VNClassificationObservation] ?? []
          return Self.makeResult(...)
      } catch {
          recognizerLogger.warning("Vision request failed: ...")
          return nil
      }
  }.value
  ```

* `renderToImage(points:canvasSize:)` rasterises the stroke into a
  40 × 40 grayscale `CGContext`: black background, white stroke,
  centered with 4 px padding, line width 2.5 at model resolution. Y-
  axis is flipped so the top-left-origin touch points draw upright.
* `loadModelIfNeeded()` is guarded by `NSLock` so concurrent first
  calls don't double-load. Model is cached as a `nonisolated(unsafe)`
  static.
* If the `.mlpackage` cannot be found in any candidate bundle, the
  recognizer logs a warning and returns nil for every subsequent call
  — the UI shows a "KI-Modell nicht verfügbar" banner rather than
  silently failing.
* `ConfidenceCalibrator.calibrate(...)` post-processes the raw softmax
  probability with two adjustments:
  - Confusable-pair penalty (15 % subtract for letters in
    `{C, c, O, o, S, s, V, v, W, w, X, x, Z, z, P, p, U, u, K, k}`).
  - Optional history boost (10 % multiplicative bump if the child has
    ≥ 5 historical samples averaging ≥ 0.80 form score for the
    expected letter).

**How the implementation differs.** EMNIST is the conceptual model
ancestor; the bundled `.mlpackage` is a custom-trained model on a
German-handwriting-skewed dataset (the precise training corpus is the
thesis author's). The confusable-pair list and history boost are the
app's own calibration layer on top of the raw softmax.

### 4.14 A/B Testing Infrastructure

**Description.** Not a method per se; the app ships with the
infrastructure to support thesis-grade A/B comparison between
adaptive and non-adaptive conditions.

**Implementation.**
* `Core/ThesisCondition.swift`:

  ```swift
  enum ThesisCondition: String, Codable, CaseIterable {
      case threePhase      // full four-phase flow (legacy name preserved for Codable)
      case guidedOnly      // guided phase only
      case control         // guided phase, FixedAdaptationPolicy

      static func assign(participantId: UUID) -> ThesisCondition {
          let byte = participantId.uuid.0
          switch Int(byte) % ThesisCondition.allCases.count {
          case 0:  return .threePhase
          case 1:  return .guidedOnly
          default: return .control
          }
      }
  }
  ```

* `ParticipantStore.participantId` — UUID generated on first call,
  persisted in UserDefaults so cohort assignment is stable across
  launches.
* `ParticipantStore.isEnrolled` — Settings toggle "Studienteilnahme".
  When false (default), `ThesisCondition.defaultForInstall` returns
  `.threePhase` so casual users never get a degraded condition.
* `LearningPhaseController.activePhases` returns
  `LearningPhase.allCases` for `.threePhase` and `[.guided]` for
  `.guidedOnly` / `.control`.
* `TracingDependencies.live` injects `FixedAdaptationPolicy(.standard)`
  for `.control` and `MovingAverageAdaptationPolicy()` for the others.
* Every dashboard write tags the active condition:
  `dashboardStore.recordPhaseSession(... condition: thesisCondition, ...)`.
* CSV / TSV / JSON export carries the condition as a column.

---

## 5. Font system

### 5.1 Primae font family

**What it is.** A custom-designed display font family bundled with the
app. The repo ships **22 OTF files** under `Resources/Fonts/`:
Primae-Regular, -Light, -Semilight, -Semibold, -Bold + cursive
versions of each + a PrimaeText subfamily.

**Why chosen.** The Druckschrift (print) reference glyphs need to
match a typography that's immediately readable to a German first-
grader. Primae was chosen as a clean, sans-serif print face with
balanced stroke widths and clearly distinguishable lowercase forms
(unambiguous a vs g vs q).

**How used.** `Core/PrimaeLetterRenderer.swift` calls CoreText with
`Primae-Regular` to rasterise a letter into a `UIImage` matching the
canvas size. The bounding rect (`normalizedGlyphRect`) tells the
checkpoint mapper where to place stroke checkpoints relative to the
rendered glyph.

### 5.2 Playwrite AT (Schreibschrift)

**What it is.** Playwrite Österreich, an Austrian-school cursive font
released by TypeTogether in 2023 under the **SIL Open Font License
1.1** (`Resources/Fonts/PlaywriteAT-OFL.txt`). Variable TTF.

**Why chosen.** The thesis originally targeted *Österreichische
Schulschrift 1995* (Pesendorfer's official font, mandated by the
Austrian school authority RS 35/2022). That font's OTF was not
available under a license compatible with bundling in a research app,
and we could not source a single-letter version. Playwrite AT is a
practising-Austrian-cursive that approximates Schulschrift 1995 well
enough for the thesis claim of "supports a cursive script" while
remaining legally redistributable.

**How used.** `Core/SchriftArt.swift` returns the font filename per
case:

```swift
public var fontFileName: String {
    switch self {
    case .druckschrift:   return "Primae-Regular"
    case .schreibschrift: return "PlaywriteAT-Regular"
    case .grundschrift:   return "Grundschrift-Regular"            // not bundled
    case .vereinfachteAusgangsschrift: return "VereinfachteAusgangschrift-Regular"  // not bundled — case spelling fixed, font filename kept
    case .schulausgangsschrift:       return "Schulausgangsschrift-Regular"        // not bundled
    }
}
```

The user-facing label for the cursive case is the generic
"**Schreibschrift**", deliberately not "Schulschrift 1995", because
the bundled font is not the official one.

### 5.3 SchriftArt switching

* `TracingDependencies` reads the persisted choice from
  `UserDefaults.standard.string(forKey: "de.flamingistan.primae.selectedSchriftArt")`
  on init. Migration logic maps a legacy `"schulschrift1995"` value to
  `.schreibschrift`.
* `TracingViewModel.schriftArt` setter (line 30) clears the script
  stroke cache, the per-script font cache, re-renders the current
  letter image, and reloads stroke checkpoints in the new script's
  geometry.
* `SettingsView` shows only the two cases that are actually bundled
  (`druckschrift`, `schreibschrift`); the other three enum cases are
  scaffolded for future fonts.

### 5.4 PrimaeLetterRenderer

* `render(letter:size:schriftArt:)` returns a `UIImage` of the glyph
  drawn at the requested size using the SchriftArt's font.
* `normalizedGlyphRect(for:canvasSize:schriftArt:)` returns the
  bounding rectangle (in 0–1 normalized canvas space) of the glyph,
  used to map stroke checkpoints onto the rendered letter.
* `clearCache()` is called from `TracingViewModel.schriftArt.didSet`
  so a font switch doesn't serve stale rasterisations.

---

## 6. Data collection & export

### 6.1 ProgressStore (per letter)

**File.** `Core/ProgressStore.swift`. Stored at
`Application Support/PrimaeNative/progress.json` (atomic, debounced
writes).

**Schema.**
```swift
struct LetterProgress: Codable, Equatable {
    var completionCount: Int = 0
    var bestAccuracy: Double = 0.0
    var lastCompletedAt: Date?
    var phaseScores: [String: Double]?              // "observe" / "direct" / "guided" / "freeWrite"
    var speedTrend: [Double]?                        // last 50 sessions (D-4)
    var paperTransferScore: Double?                  // 1.0 / 0.5 / 0.0
    var lastVariantUsed: String?                     // "variant" or nil
    var recognitionAccuracy: [Double]?               // legacy: last 10 confidences
    var recognitionSamples: [RecognitionSample]?     // last 10 full readings (predictedLetter + confidence + isCorrect)
    var freeformCompletionCount: Int?
}
```

`Store` wrapper additionally holds `completionDates: [Date]` to compute
streaks.

### 6.2 ParentDashboardStore (sessions + phases)

**File.** `Core/ParentDashboardStore.swift`. Stored at
`Application Support/PrimaeNative/dashboard.json`.

**Schema.**
* `LetterAccuracyStat(letter, accuracySamples)` — per letter, capped at
  200 samples (rolling window). Word-mode multi-character keys are
  excluded so `letterStats` stays per-letter (D-11).
* `SessionDurationRecord(dateString, durationSeconds, condition,
  recordedAt?)` — `recordedAt` is the full ISO-8601 timestamp added in
  D-9 so time-of-day analysis is recoverable from the export.
* `PhaseSessionRecord(letter, phase, completed, score,
  schedulerPriority, condition, recordedAt?, formAccuracy?,
  tempoConsistency?, pressureControl?, rhythmScore?,
  recognitionPredicted?, recognitionConfidence?, recognitionCorrect?,
  inputDevice?)` — the dimension fields are populated only on freeWrite
  rows; `recognition*` carry the session-aligned recognition outcome
  (D-2); `recordedAt` is the wall-clock timestamp (D-3); `inputDevice`
  ("finger" / "pencil") disambiguates `pressureControl == 1.0` between
  finger sessions (no force data) and low-variance pencil sessions
  (D-6).

Custom decoders default `condition` to `.threePhase` for pre-migration
records; D-8 then filters those rows from the export when an
`enrolledAt` is set so the legacy fallback can't silently inflate the
threePhase arm.

`recordSession`, `recordPhaseSession`, and `phaseScores(for:)` route
their letter argument through `LetterProgress.canonicalKey(_:)` — the
same shared normaliser `JSONProgressStore` and `JSONStreakStore` use —
so every store agrees that `ß` stays `ß` instead of collapsing to
`"SS"` (review item W-3).

### 6.3 StreakStore (engagement)

**File.** `Core/StreakStore.swift`. Stored at
`Application Support/PrimaeNative/streak.json`.

* `currentStreak`, `longestStreak`, `totalCompletions`,
  `completedLetters: Set<String>`, `earnedRewards: Set<RewardEvent>`.
* `RewardEvent` enum: `firstLetter`, `dailyGoalMet`, `streakDay3`,
  `streakWeek`, `streakMonth`, `allLettersComplete`, `perfectAccuracy`,
  `centuryClub`.
* `recordSession(date:lettersCompleted:accuracy:)` returns any newly
  earned `RewardEvent`s.
* `earnedRewards` is now exposed on the `StreakStoring` protocol so
  the `FortschritteWorldView` "Auszeichnungen" row can render achievement
  badges (earned in colour, unearned desaturated) — closes the
  HIDDEN_FEATURES_AUDIT C.6 gap.

### 6.4 Research export

`Core/ParentDashboardExporter.swift` emits three formats. The CSV / TSV
share a row builder so they stay in lock-step.

**CSV / TSV header row (per-phase section):**
```
letter,phase,completed,score,schedulerPriority,condition,recordedAt,
recognition_predicted,recognition_confidence,recognition_confidence_raw,
recognition_correct,formAccuracy,tempoConsistency,pressureControl,
rhythmScore,inputDevice,audioCondition,trainedSubset,
phaseDurationSeconds,frechetDistance,checkpointCoverage
```

New columns are always appended **last**, so existing consumers keep
their column offsets. Legacy rows decode absent fields as nil and emit
empty strings — never a defaulted `0`, which for `frechetDistance`
would read as a perfect overlay and for `checkpointCoverage` as a blank
page.

**Column → thesis-analysis purpose:**
| Column | Purpose |
|--------|---------|
| `letter` | Per-letter slicing (alphabet effect, frequency analysis). |
| `phase` | Which phase (observe / direct / guided / freeWrite) the session belonged to; needed for any GRR efficacy claim. |
| `completed` | Selection criterion for "successful sessions". |
| `score` | Phase-level accuracy / form score (0–1). |
| `schedulerPriority` | Spaced-repetition scheduler's prediction at the time the letter was recommended; used as the IV in the scheduler-effectiveness Pearson r (per-arm proxy below — cross-arm proxy is invalid because `.control` uses `-completionCount` priorities, not Ebbinghaus). |
| `condition` | Thesis A/B arm — required for between-arm comparisons. |
| `recordedAt` | ISO-8601 wall-clock timestamp (D-3). Required for time-of-day and dated learning-curve analyses. Empty on legacy pre-D-3 rows. |
| `recognition_predicted` | Letter the CoreML model predicted for the freeWrite session. Populated on freeWrite rows since D-2 (was blank under the W-2 workaround); empty on observe / direct / guided rows. |
| `recognition_confidence` | CoreML softmax confidence after `ConfidenceCalibrator` adjustments. Same population rule. |
| `recognition_confidence_raw` | Pre-calibration softmax probability, so the calibrator's effect can be quantified. Same population rule. |
| `recognition_correct` | Whether the prediction matched the expected letter. Same population rule. |
| `formAccuracy` | Schreibmotorik Form dimension (weight 0.40) — the *clamped, rescaled* transform of `frechetDistance`. Child-facing / weighted-score input, **not** the analysis outcome (§4.12.1). |
| `tempoConsistency` | Schreibmotorik Tempo dimension (CV², weight 0.25). |
| `pressureControl` | Schreibmotorik Druck dimension (force variance, weight 0.15). |
| `rhythmScore` | Schreibmotorik Rhythmus dimension (active-time ratio, weight 0.20). |
| `inputDevice` | "finger" or "pencil" — disambiguates `pressureControl == 1.0` between a real finger session (no force data) and a low-variance pencil session (D-6). |
| `audioCondition` | Pilot audio arm (phoneme / spatial / silent) in effect for the row — the pilot's primary between-subjects IV. |
| `trainedSubset` | The participant's trained 3-of-5 study letters (e.g. `"AFI"`), so trained vs untrained can be partitioned per row without a join. |
| `phaseDurationSeconds` | **Time outcome.** freeWrite measured-phase span, first sample → last sample, end-inclusive (§6.4.1). freeWrite rows only. |
| `frechetDistance` | **Primary accuracy outcome.** Raw discrete-Fréchet distance in normalised 0–1 letter-box units; lower is better; unclamped, so it does not saturate. freeWrite rows only. Defined precisely in §4.12.1. |
| `checkpointCoverage` | **Secondary accuracy outcome.** Fraction of reference checkpoints reached during the freeWrite pass (0–1). Saturates at ceiling — see §4.12.2. freeWrite rows only. |

> **Analyse per letter.** The five study letters differ structurally
> (M alone is one stroke of 200 checkpoints). Pooling `frechetDistance`,
> `checkpointCoverage`, or `phaseDurationSeconds` across letters is
> invalid — see §4.12.3.

#### 6.4.1 `phaseDurationSeconds` is end-inclusive

The freeWrite span runs from the **first** touch sample to the **last**
touch sample of the measured phase (`FreeWritePhaseRecorder.measuredSpanSeconds`),
using `CACurrentMediaTime()` deltas.

It deliberately does *not* end at the final stroke's start. Every
accepted touch sample appends a timestamp, so `timestamps.last` is the
last instant the child was writing; ending the span at the last stroke's
*onset* would discard that whole stroke — and for the single-stroke
study letters I and M, that is the entire trial. `MeasurementLayerTests`
pins both the multi-stroke and the single-stroke case.

The trailing 2.0 s quiet window that auto-advances the phase
(`TouchDispatcher.freeWriteQuietSeconds`) is excluded by construction,
because that window only opens after the last sample. Nil when fewer
than two distinct sample instants exist — a span needs two endpoints.

#### 6.4.2 Raw traces make every measure re-derivable

`RawTraceStore` persists each freeWrite trial's full trace — canvas-space
`points`, per-point `timestamps` and `forces`, `strokeStartIndices`, and
the `canvasSize` needed to re-normalise them — and the JSON export
carries them alongside the derived rows, linked by
`PhaseSessionRecord.rawTraceID`. The CSV stays derived-scalars only.

This is the load-bearing property of the whole measurement layer: **any
measure not yet thought of can be computed offline from the archive,
without re-running a single participant.** Every scalar in the per-phase
section — including `frechetDistance` and `phaseDurationSeconds` — is
reproducible from the trace it links to, so a scoring bug found after
data collection is a re-analysis, not a lost cohort.

Capture order is trace-first, then the linking record, so a crash can
leave an orphan trace but never a record pointing at a missing trace.
The store caps at 500 traces and the new-participant reset wipes it
between children; the pilot's ~40 children × 3 trained letters sits far
inside that bound.

Additional sections in the export:
* Per-letter aggregates (`letter,sessionCount,averageAccuracy,trend,
  recognitionSamples,recognitionAvg,speedTrend,freeformCompletionCount`)
  — `speedTrend` is a semicolon-joined trajectory; `freeformCompletionCount`
  surfaces blank-canvas usage that was previously collected but never exported.
* Per-day session durations (`date,recordedAt,durationSeconds,
  wallClockSeconds,condition,inputDevice,letter`) — `recordedAt` is the
  full ISO-8601 timestamp (D-9); `letter` names the practised letter (or
  word label) so per-letter time-to-complete needs no `recordedAt` join.
* Phase-completion rates (one row per phase).
* Aggregate `averageFreeWriteScore`, plus per-arm `averageFreeWriteScore_<arm>`
  rows (D-7).
* `schedulerEffectivenessProxy` (overall Pearson r) plus per-arm
  `schedulerEffectivenessProxy_<arm>` rows (D-10).
* `letterByArm,letter,arm,sampleCount,averageScore` — derived from
  `phaseSessionRecords`, gives a clean per-arm letter-level aggregate
  that the flat `letterStats` (which mixes arms) can't (D-5).
* The four average-Schreibmotorik-dimension rows when ≥ 1 freeWrite
  sample exists.

The first line of every file is `# participantId=<UUID>` so a
researcher can align data across installs. When `enrolledAt` is set,
a second `# enrolledAt=<ISO-8601>` header line documents the cutoff
the exporter applies to discard pre-enrolment rows (D-7) and legacy
rows missing `recordedAt` (D-8).

### 6.5 GDPR / DSGVO considerations

* All stores live in **Application Support** inside the app sandbox.
  Nothing is uploaded — the app has no network sync code at all
  (the CloudKit scaffolding was removed pre-thesis; see ROADMAP F3).
* The participant UUID is **not derived from any device identifier**;
  it is randomly generated on first call (`UUID()` in
  `ParticipantStore.participantId`).
* Cohort enrolment is **opt-in** via a Settings toggle —
  non-enrolled installs are pinned to `.threePhase` and never
  contribute to A/B analysis.
* The CSV / TSV / JSON export is share-sheet driven: the parent /
  researcher exports manually; the app does no automatic transmission.
* No personal identifiers are stored: no name, no birthday, no email.
* CoreML inference is **on-device only** — stroke images never leave
  the iPad.
* For a full DSGVO Art. 13 disclosure note, the export's first line
  exposes the UUID so a participant can request deletion by reference.

---

## 7. Audio system

### 7.1 AudioEngine architecture (DOCUMENT, do NOT modify)

`Core/AudioEngine.swift` (382 lines). Implements `AudioControlling`.

* Built on `AVAudioEngine` + `AVAudioUnitTimePitch` for time-stretching
  playback (so audio speed tracks writing speed without pitch shift).
* Lifecycle observers (route change, interruption, suspend/resume)
  registered through a `nonisolated(unsafe) static` dictionary keyed by
  `ObjectIdentifier` so `deinit` can clean up without entering the
  MainActor.
* Public surface: `loadAudioFile(named:autoplay:)`,
  `setAdaptivePlayback(speed:horizontalBias:)`, `play()`, `stop()`,
  `restart()`, `suspendForLifecycle()`, `resumeAfterLifecycle()`,
  `cancelPendingLifecycleWork()`.

This file is annotated `STABLE & FRAGILE` in `CLAUDE.md` and
`APP_REFERENCE.md`. Any change must be minimal and surgical (catch
blocks, init/deinit structure are particularly load-bearing).

### 7.2 Audio triggering

* On letter load: `audio.loadAudioFile(named: firstAudio,
  autoplay: false)` queues the recorded letter pronunciation.
* On phase advance into observe: animation runs but audio stays idle
  (would loop silently behind onboarding otherwise).
* On `beginTouch`: `audio.loadAudioFile(named: ..., autoplay: false)`
  re-loads since `stop()` clears `currentFile`.
* On `updateTouch`: every frame computes
  `audio.setAdaptivePlayback(speed:, horizontalBias:)` where
  `speed = mapVelocityToSpeed(smoothedVelocity)` (slow tracing → 0.5,
  normal → 1.0, fast → 2.0) and `hBias = canvasNormalized.x * 2 - 1`
  for stereo panning.
* On `endTouch`: `audio.stop()` and the playback state machine forces
  idle.

### 7.3 Proximity-based playback (guided phase)

```swift
let shouldPlayForStroke = strokeTracker.isNearStroke
let shouldBeActive = shouldPlayForStroke
                     && smoothedVelocity >= playbackActivationVelocityThreshold
                     && feedbackIntensity > 0.3
playback.request(shouldBeActive ? .active : .idle, immediate: shouldBeActive)
```

`isNearStroke` is true when the touch is within `checkpointRadius * 3`
of the next checkpoint. The 22 pt/s velocity threshold prevents audio
on stationary touches.

### 7.4 Phase-dependent audio gating

`feedbackIntensity > 0.3` is the audio gate:
* `.observe`: 1.0 → audio on (but touch is disabled anyway).
* `.direct`: 1.0 → letter-name audio on first correct dot tap.
* `.guided`: 0.6 → real-time proximity audio.
* `.freeWrite`: 0.0 → audio silent (post-hoc TTS only).

---

## 8. Haptic system

### 8.1 Triggers

`HapticEngine.fire(_ event: HapticEvent)` is called from
`TracingViewModel.updateTouch` and `tapDirectDot`. Five events:

| Event | Trigger |
|-------|---------|
| `.strokeBegan` | First touch frame after `beginTouch`. |
| `.checkpointHit` | Tracker's `nextCheckpoint` increments, but the stroke isn't yet complete. |
| `.strokeCompleted` | A stroke's last checkpoint was just hit. |
| `.letterCompleted` | All strokes done. |
| `.offPath` | Wrong-dot tap in direct phase. |

### 8.2 Phase-dependent intensity scaling

Every haptic call is gated on `feedbackIntensity > 0` (line 891, 918,
966 of `TracingViewModel`). Result:
* `.observe` / `.direct`: full haptics (1.0).
* `.guided`: full haptics (0.6 > 0; gate uses `> 0` not `> 0.6`, so
  haptics fire as long as feedback isn't fully off).
* `.freeWrite`: zero haptics (0.0).

### 8.3 CoreHaptics patterns

`Core/HapticEngine.swift:118` — `CoreHapticsEngine.hapticPattern(for:)`:

| Event | Pattern (intensity / sharpness / time) |
|-------|----------------------------------------|
| `.strokeBegan` | one transient: 0.4 / 0.3 / 0 s |
| `.checkpointHit` | one transient: 0.6 / 0.7 / 0 s |
| `.strokeCompleted` | two transients: 0.8/0.5/0 s + 0.5/0.3/+0.1 s |
| `.letterCompleted` | three transients: 1.0/0.8/0 s + 0.8/0.5/+0.12 s + 0.6/0.3/+0.24 s (decay tail) |
| `.offPath` | one weak transient: 0.2 / 0.1 / 0 s |

Falls back to `UIKitHapticEngine` (`UIImpactFeedbackGenerator` style
mappings) when CoreHaptics isn't available, and `NullHapticEngine` for
tests.

---

## 9. User interface

### 9.1 Navigation

```
MainAppView (root, requires onboarding complete)
  ├── WorldSwitcherRail (64 pt left rail; @AppStorage active world)
  │     ├── World 1: Schule                    (book.fill icon)
  │     ├── World 2: Werkstatt                 (pencil.tip)
  │     ├── World 3: Fortschritte / Sterne     (star.fill)
  │     └── Gear (2 s long-press → Parent area)
  └── World content
        ├── SchuleWorldView (guided 4-phase tracing)
        ├── WerkstattWorldView (freeform writing)
        └── FortschritteWorldView (star/streak/letter gallery)

Parent gate (fullScreenCover, 2 s long-press on gear):
ParentAreaView (NavigationSplitView)
  ├── Übersicht           → ParentDashboardView
  ├── Forschungs-Daten    → ResearchDashboardView
  ├── Einstellungen       → SettingsView
  └── Datenexport         → ExportCenterView (CSV / TSV / JSON share)
```

### 9.2 TracingCanvasView

* `Canvas` block draws (per cell):
  - Whole-word image (word mode only) at full canvas size — so cursive
    ligatures connect across cells.
  - Per-cell letter glyph via `PrimaeLetterRenderer.render`.
  - Ghost lines from each stroke's checkpoints (gated on
    `showGhostForPhase || (showGhost && learningPhase != .freeWrite)`).
  - Numbered start dots (gated on `phaseController.showCheckpoints`).
  - Animation guide dot during observe.
  - Active-stroke ink path (green, line width 8).
  - Direction arrow during direct phase (1.2 s window).
* Two UIKit overlays:
  - `PencilAwareCanvasOverlay` — captures pencil touches with pressure
    + azimuth.
  - `TouchOverlay` — captures finger touches and a two-finger
    vertical swipe gesture (cycles audio variants).
* The KP overlay (`freeWriteKPOverlay()`) is rendered when
  `vm.overlayQueue.currentOverlay == .kpOverlay`.

### 9.3 Overlay queue

`Core/OverlayQueueManager.swift`. Five `CanvasOverlay` cases:
`.frechetScore(CGFloat)`, `.kpOverlay`, `.recognitionBadge(RecognitionResult)`,
`.paperTransfer(letter: String)`, `.celebration(stars: Int)`.

* Modal overlays (paperTransfer, celebration) carry **nil duration**
  → wait for explicit `.dismiss()`.
* Timed overlays (kpOverlay 3 s, recognitionBadge 3 s, frechetScore
  1.5 s) auto-advance.
* `enqueueBeforeCelebration(_:)` slots a late-arriving recognition
  badge ahead of the celebration regardless of CoreML inference timing.

Canonical post-freeWrite order: kpOverlay → recognitionBadge →
paperTransfer → celebration.

### 9.4 Settings

`Features/Dashboard/SettingsView.swift`:
* **Schriftart**: Druckschrift / Schreibschrift (only the two
  bundled cases shown).
* **Buchstabenreihenfolge**: motorSimilarity / wordBuilding /
  alphabetical.
* **Freies Schreiben**: toggle for the freeform writing mode (default
  on).
* **Anzeige**: "Geisterbuchstabe anzeigen" — half-transparent letter
  while tracing. Was previously toggleable only via the undocumented
  debug long-press; now parent-accessible.
* **Forschung**:
  - "Schreiben auf Papier" — paper transfer toggle (default off).
  - "Studienteilnahme (A/B-Arm)" — opt-in cohort assignment toggle
    (default off).
* **Hilfe**: "Einführung wiederholen" — resets onboarding state.

### 9.5 Parent dashboard

`Features/Dashboard/ParentDashboardView.swift`:
* Übersicht: letters practised, current streak, longest streak,
  practice time (7 days), Schreibqualität (composite %).
* Schreibqualität – Details: per-dimension breakdown (Form, Tempo,
  Druck, Rhythmus) as labelled `ProgressView` bars. Only renders when
  ≥ 1 completed freeWrite session has produced dimension data.
  Surfaces the four Schreibmotorik dimensions individually instead of
  only the composite — closes HIDDEN_FEATURES_AUDIT C.1.
* Phasen: per-phase completion rates.
* Übungsverlauf: 30-day practice trend chart.
* Stärkste Buchstaben: top-5 by accuracy.
* Noch zu üben: letters below 0.70 accuracy.
* Schreiben auf Papier: per-letter paperTransferScore values.
* Erkennungsgenauigkeit: per-letter rolling recognition averages.
* DEBUG-only Forschungsmetriken section.

### 9.6 Research dashboard

`Features/Parent/ResearchDashboardView.swift`. Six sections:
* **Participant header** — UUID + last-session condition.
* **Schreibmotorik** — four metric tiles (Form / Tempo / Druck /
  Rhythmus) with weight annotations + last-session breakdown.
* **KI-Erkennung** — per-letter latest prediction vs expected, with
  green/orange row tinting for correct/incorrect.
* **Studienarm** — count of phase sessions per `ThesisCondition` arm.
* **Spaced-Repetition-Effizienz** — Pearson r between scheduler
  priority and subsequent accuracy improvement.
* **Phasen-Sessions (letzte 20)** — raw table of recent phase records.
* **Buchstaben-Aggregate** — per-letter stats with trend slope.

### 9.7 Onboarding

`Features/Onboarding/OnboardingView.swift` (569 lines). Seven steps:
welcome → traceDemo (observe phase animation of letter A) → directDemo
(direct phase pulse + tap + arrow simulation) → guidedDemo (finger
emoji follows ink trail) → freeWriteDemo (green A) → rewardIntro (4
phase icons + star explanation) → complete.

Each step has a German-only Welcome / Anschauen / Richtung lernen /
Nachspuren / Selbst schreiben / Sterne sammeln title and one or two
sentences of body text. CTAs ("Los geht's!", "Weiter", "Fertig!")
have explicit `.accessibilityLabel`. Adults can long-press the bottom
"Für Eltern: gedrückt halten zum Überspringen" hint to skip.

---

## 10. Testing infrastructure

### 10.1 Test architecture

* **Swift Testing** (`@Test`, `@Suite`, `#expect`) for new tests; a
  small core of XCTest files retained from before the framework
  switch (per `LESSONS.md` instruction not to migrate existing XCTest).
* Tests live in `PrimaeNativeTests/`. The package targets
  `.swiftLanguageMode(.v5)` for the test target only — the main
  target uses Swift 6 with `.defaultIsolation(MainActor.self)`. The
  v5 carve-out exists because `XCTestCase`'s inherited nonisolated
  initialiser conflicts with implicit MainActor isolation under Swift
  6 strict checking.

### 10.2 Stubs (`TestFixtures.swift`)

* `StubAudio` — `AudioControlling` no-op.
* `StubHaptics` — `HapticEngineProviding` no-op.
* `StubProgressStore` — `ProgressStoring` returns empty data, ignores
  writes.
* `StubStreakStore`, `StubDashboardStore`, `StubOnboardingStore`,
  `StubNotificationCenter`, `NullLetterCache`,
  `StubResourceProvider` (with a synthetic A letter that has 50
  checkpoints along y = 0.5).
* `NullSpeechSynthesizer` records every spoken phrase.
* `StubLetterRecognizer.alwaysReturn(predicted:confidence:)` for
  deterministic recognition.
* `MockAudio` (in `TracingViewModelTests.swift`) records every method
  call so tests can assert exact playback / lifecycle behaviour.

### 10.3 What's tested

(46 test files, 647 `@Test` declarations after rounds 3 and 4.)

* All four Schreibmotorik dimensions (`WritingAssessmentTests`).
* Letter scheduler weights, recency saturation, novelty tie-breaking
  (`LetterSchedulerTests`).
* `LetterOrderingStrategy` exact orderings (V3 spec compliance).
* Difficulty adaptation hysteresis (`DifficultyAdaptationTests`).
* Progress / dashboard / streak store JSON round-trip + corrupted-file
  recovery.
* CSV exporter columns including the new recognition-correct +
  Schreibmotorik dimensions.
* OverlayQueueManager ordering, dismissal, reset.
* Stroke tracker proximity, soundEnabled gating.
* Confidence calibrator confusable-pair penalty + history boost.
* End-to-end tracing session (`EndToEndTracingSessionTests`).
* TracingViewModel lifecycle (background / foreground churn,
  showGhost regression, retain cycles).
* Accessibility VoiceOver labels.
* Velocity → audio speed mapping monotonicity.
* `bucketStrokesByTargetLetter` word segmentation including overflow
  clamping and empty buckets.
* `RecognitionResult` Codable round-trip (RecognitionSample).
* `ChildSpeechLibrary` German prompt content + `NullSpeechSynthesizer`
  recording.

### 10.4 CI pipeline

`.github/workflows/ios-build.yml`:
* Runs on **macos-26** with **Xcode 26.4**.
* `xcodebuild test` against the iPad simulator scheme.
* Uploads `/tmp/TestResults.xcresult` and `/tmp/xcode-test.log` as
  artifacts.
* Greps the test log for `error:` / `#expect.*failed` /
  `XCTAssert.*failed` / `Test.*FAILED` and surfaces the matches.

`ipad-device-test.yml` runs on a self-hosted MacBook for physical-
device validation; skipped on this run because the simulator job
failed first.

### 10.5 Tests added in rounds 3 and 4 (audit response)

The round-3 audit identified seven test gaps; all closed:
* `LearningPhaseController.advance()` for the `.control` arm
  (`controlCompletesAfterOne`).
* `LetterScheduler.automatizationBonus` speed-trend ordering pinned
  through `recommendNext` (`automatisationBonusOrdersByTrend`).
* `OverlayQueueManager.enqueueBeforeCelebration` C-4 branch when
  celebration is the active overlay; W-25 branch when paperTransfer
  is the active overlay.
* `JSONProgressStore.recordVariantUsed` and
  `recordPaperTransferScore` round-trip after reload.
* `FreeWriteScorer.formAccuracyShape` — identical, scribble,
  reversed-trace order invariance, empty inputs.
* `fastTouch_triggersPlay` deflaked: awaits
  `vm.awaitPlaybackDebounce()` (a `#if DEBUG` helper that yields on
  `playback.pendingTransition`) instead of sleeping 150 ms.
* `avAudioSessionInterruption_shouldResumeFalse_doesNotPlay`
  tightened from `playCount <= +1` to `== playsBefore`.

Round-4 added contract tests for the recent fixes:
* `progressForwarders_passThroughAndReadOnly` — W-5 forwarders never
  insert into the underlying store on a get.
* `multiCellActiveFrame_isNilForSingleLetter` — pin the W-24
  contract.
* `assess_multiCell_emptyReferencesReturnsZero` and
  `assess_multiCell_filtersPointsByCellFrame` — W-26 multi-cell
  scorer.
* `d1_activeTimeAccumulator_pausesOnBackground` — the duration
  clock pauses on background and restarts on foreground (D-1).

### 10.6 Test coverage gaps (honest)

* **CoreMLLetterRecognizer**: no dedicated unit test for the
  model-loading + Vision-request path. The recognizer is exercised
  end-to-end via integration tests but the renderToImage / loadModel
  internals are unverified.
* **AudioEngine**: only sanity-skipped tests on simulator (lacks AVAudioSession route in CI).
* **PaperTransferView 3 s + 10 s timing**: the visual phase rotation
  uses real `Task.sleep` so it isn't deterministically tested. The
  state-mapping (.showLetter / .writePaper / .assess) is verified by
  inspection rather than assertion.
* **Variant strokes loading**: `LetterRepositoryTests` cover the bundle
  scan; the `toggleVariant()` method on the VM is unit-tested only via
  the no-variant case.
* **freeform recognition debounce**: the 1.2-second debounce is a
  real-time wait; unit tests exercise the controller's state but not
  the timing.

---

## 11. Thesis claims this code supports

| # | Claim | Status | Evidence / gap |
|---|-------|--------|----------------|
| 1 | Four-step gradual release pedagogy for digital handwriting | **SUPPORTED** | `LearningPhase` has 4 cases in canonical order, `LearningPhaseController` enforces sequential advancement, each phase has distinct UI + scoring + scaffolding (see §3, §4.1). |
| 2 | Algorithmic spaced repetition applied to letter learning | **SUPPORTED** | `LetterScheduler` uses Ebbinghaus-style decay + accuracy + novelty weighting (see §4.10). `automatizationBonus` further deprioritises letters being automatised. |
| 3 | Fréchet distance as handwriting similarity metric | **SUPPORTED** | `FreeWriteScorer.discreteFrechetDistance` is the literal Eiter-Mannila implementation (see §4.12). |
| 4 | Four-dimension Schreibmotorik motor assessment on tablet | **SUPPORTED** | `WritingAssessment` struct holds all four dimensions with the documented 0.40/0.25/0.15/0.20 weights summing to 1.0. Each dimension has its own algorithm with a unit test. Dimensions persist on `PhaseSessionRecord` and export as separate CSV columns. |
| 5 | On-device letter recognition via CoreML CNN | **SUPPORTED** | `CoreMLLetterRecognizer` loads `GermanLetterRecognizer.mlpackage` and runs Vision inference on a `Task.detached`. The .mlpackage is bundled in `Resources/ML/` and includes `Manifest.json` + `Data/`. Inference never leaves the device. |
| 6 | Built-in A/B testing comparing adaptive vs. non-adaptive instruction | **SUPPORTED** | `ThesisCondition` provides three arms; `MovingAverageAdaptationPolicy` (adaptive) vs `FixedAdaptationPolicy` (control) selected by `TracingDependencies.live`; `ParticipantStore` persists stable UUID-derived assignment with explicit opt-in (see §4.14). Every dashboard write tags the condition so post-hoc analysis can split arms cleanly. |
| 7 | Fading feedback implements the guidance hypothesis | **SUPPORTED** | `feedbackIntensity` is a four-step fade (1.0 → 1.0 → 0.6 → 0.0), gates audio (> 0.3) and haptics (> 0) at three call sites in `updateTouch` (see §4.2). |
| 8 | Privacy-preserving on-device inference | **SUPPORTED** | The `CoreMLLetterRecognizer` runs entirely locally; the app contains no network sync code so nothing is transmitted; the participant UUID is randomly generated, not derived from device identifiers; export is share-sheet driven (manual). The data flow is verifiable from `TracingDependencies.live` (see §6.5). |

**Partially supported claims worth flagging in the thesis:**

* "Five-script support" — the SchriftArt enum has five cases but only
  Druckschrift (Primae) and Schreibschrift (Playwrite AT) are bundled.
  Grundschrift, Vereinfachte Ausgangsschrift, and Schulausgangsschrift
  are scaffolded for future work but won't render without a font drop.
* "Full alphabet coverage" — 26 uppercase + 26 lowercase + Ä Ö Ü ß
  all have a real baked `strokes.json` (the bake pipeline in §13 has
  shipped line-kind geometry for E F H I L T X Z + l v w x z plus
  multi-stroke A, with M N V W b as the original primitive-test seeds;
  remaining letters use the BFS-derived fallback path). **Audio**
  ships for 7 letters only (A F I K L M O); the other 52 letters
  render fine but fall back to TTS for any prompt that would normally
  use a recording.

---

## 12. Bibliography

In APA 7 format, sorted alphabetically.

Alamargot, D., & Morin, M.-F. (2015). Does handwriting on a tablet
screen affect students' graphomotor execution? A comparison between
Grades Two and Nine. *Human Movement Science*, 44, 32–41.
https://doi.org/10.1016/j.humov.2015.08.011

Alt, H., & Godau, M. (1995). Computing the Fréchet distance between
two polygonal curves. *International Journal of Computational
Geometry & Applications*, 5(1n02), 75–91.
https://doi.org/10.1142/S0218195995000064

Berninger, V. W., Abbott, R. D., Jones, J., Wolf, B. J., Gould, L.,
Anderson-Youngstrom, M., Shimada, S., & Apel, K. (2006). Early
development of language by hand: Composing, reading, listening, and
speaking connections; three letter-writing modes; and fast mapping in
spelling. *Developmental Neuropsychology*, 29(1), 61–92.
https://doi.org/10.1207/s15326942dn2901_5

Cepeda, N. J., Pashler, H., Vul, E., Wixted, J. T., & Rohrer, D.
(2006). Distributed practice in verbal recall tasks: A review and
quantitative synthesis. *Psychological Bulletin*, 132(3), 354–380.
https://doi.org/10.1037/0033-2909.132.3.354

Cohen, G., Afshar, S., Tapson, J., & van Schaik, A. (2017). EMNIST: An
extension of MNIST to handwritten letters. In *Proceedings of the
International Joint Conference on Neural Networks (IJCNN)* (pp.
2921–2926). IEEE. https://doi.org/10.1109/IJCNN.2017.7966217

Danna, J., & Velay, J.-L. (2015). Basic and supplementary sensory
feedback in handwriting. *Frontiers in Psychology*, 6, 169.
https://doi.org/10.3389/fpsyg.2015.00169

Ebbinghaus, H. (1885). *Über das Gedächtnis: Untersuchungen zur
experimentellen Psychologie*. Duncker & Humblot.

Eiter, T., & Mannila, H. (1994). *Computing discrete Fréchet
distance* (Tech. Rep. No. CD-TR 94/64). Christian Doppler Laboratory
for Expert Systems, Technische Universität Wien.

Fisher, D., & Frey, N. (2013). *Better learning through structured
teaching: A framework for the gradual release of responsibility* (2nd
ed.). ASCD.

Fréchet, M. (1906). Sur quelques points du calcul fonctionnel.
*Rendiconti del Circolo Matematico di Palermo*, 22(1), 1–72.
https://doi.org/10.1007/BF03018603

Grundschulverband. (2024). *Grundschrift — Förderkartei zur
Schreibmotorik*. Frankfurt am Main: Grundschulverband.

Kultusministerkonferenz. (2024). *Vereinbarung zur Arbeit in der
Grundschule* (revised). Berlin: Kultusministerkonferenz.

Marquardt, C., & Söhl, K. (2016). *Schreibmotorik: Schreiben lernen
leicht gemacht — Eine Praxishilfe der STEP-Schreibmotorik-Initiative*.
Cornelsen.

Pearson, P. D., & Gallagher, M. C. (1983). The instruction of reading
comprehension. *Contemporary Educational Psychology*, 8(3), 317–344.
https://doi.org/10.1016/0361-476X(83)90019-X

Schmidt, R. A., & Lee, T. D. (2005). *Motor control and learning: A
behavioral emphasis* (4th ed.). Human Kinetics.

Thibon, L. S., Gerber, S., & Kandel, S. (2018). The elaboration of
motor programs for the automation of letter production. *Acta
Psychologica*, 182, 200–211.
https://doi.org/10.1016/j.actpsy.2017.12.001

Vygotsky, L. S. (1978). *Mind in society: The development of higher
psychological processes* (M. Cole, V. John-Steiner, S. Scribner, & E.
Souberman, Eds.). Harvard University Press.

---

## 13. Stroke generation pipeline

The `strokes.json` files the app loads from `Resources/Letters/<X>/`
are baked offline by `scripts/generate_strokes_auto.py` from the
**rendered glyph** of `Primae-Regular.otf` (or another bundled font
for variant scripts). The pipeline is what every shipped letter goes
through. This section documents the architecture as of `main`; the
historical four-agent audit that motivated the current arm/joint
primitive split lives in `docs/STROKE_AUDIT.md`.

### 13.1 Pipeline at a glance

For each letter `X`:

1. **Rasterise.** `rasterize(letter, font_path)` draws the glyph at
   `RASTER_SIZE` (1024×1024) and returns a binary mask of the ink.
2. **Distance transform.** `scipy.ndimage.distance_transform_edt`
   produces a per-pixel `dt` (distance to nearest non-ink pixel) used
   for medial-axis snapping, end-distance-from-outline targeting, and
   gate analyses.
3. **Skeletonise.** `skimage.morphology.skeletonize` produces a
   deterministic 1-pixel-wide centerline. The Swift loader prefers
   this baked skeleton over any runtime-derived version (commit
   `77f1c22`); the bake-only path means the Swift side never re-derives
   the centerline at app launch.
4. **Author spec.** `LETTERS[letter]` (in `generate_strokes_auto.py`)
   declares each stroke as either `{"kind": "line", "anchors": [...]}`
   (chord-based composition through arm/joint primitives) or
   `{"path": [...]}` (Dijkstra-on-DT centerline routing through the
   ink — used for curved strokes like `b`'s bowl).
5. **Resolve anchors.** Each named anchor (`TL`, `BC`, `MR`, `T`,
   `UPPER_TOUCH`, etc.) resolves to a pixel via `resolve_anchor`. Names
   are font-independent — adding a new font requires zero per-letter
   tweaking. The bake aborts loudly if any anchor fails to resolve.
6. **Synthesise centerline.** For `line` strokes, run the arm and joint
   primitives (§13.3, §13.4) to produce a continuous polyline through
   the resolved anchors. For `path` strokes, route Dijkstra-on-DT
   between consecutive anchors.
7. **Resample.** `resample_uniform` resamples each stroke's polyline
   to a fixed checkpoint count.
8. **Gates.** Three numeric gates filter regressions: overshoot
   (samples leaving the mask), reversal (cosine-flip between adjacent
   tangents), and max-turn. Skip-index sets bypass gates at known
   discontinuities (apex windows for sharp/fillet joints — see §13.6).
9. **Write JSON.** Per-letter `strokes.json` lands in
   `PrimaeNative/Resources/Letters/<X>/`. The Swift loader reads it
   directly; nothing is re-derived at runtime.

### 13.2 Stroke spec architecture (`LETTERS` dict)

The `LETTERS` dict at the top of `generate_strokes_auto.py` is the
**authoritative spec table**. It replaces the old `LETTER_OVERRIDES`
name from the May audit — the dict now carries full per-stroke
construction specs, not just override coordinates. Each entry is a
list of `StrokeSpec` dicts in the order the child traces them.

Two stroke kinds coexist:

* **`{"kind": "line", "anchors": [a0, a1, …, an]}`** — chord-based
  composition. The polyline visits each anchor in order; for each
  consecutive pair `(a_k, a_k+1)` an **arm primitive** (§13.3)
  synthesises an arm polyline, and for each interior anchor `a_k`
  (`0 < k < n`) a **joint primitive** (§13.4) decides how the two
  adjacent arms meet.
* **`{"path": [a0, a1, …, an]}`** — Dijkstra-on-distance-transform
  centerline routing. Used for curved strokes where straight chords
  would cut whitespace; tip anchors get DT-gradient extension before
  routing (`extend_tip_inward`). The current curve-kind set is just
  `b`; the workstream for `l, t, f, j, r, i` is open and tracked in
  `docs/ROADMAP.md`.

`line` strokes accept optional parallel arrays `"arms"` (length
`n_anchors - 1`) and `"joints"` (length `n_anchors - 2`). Each entry
is either:

* `None` — use the default strategy (`smoothed_medial_axis` arm /
  `cubic_bezier_clamped` joint with `max_handle=70`).
* `"strategy_name"` — named strategy with default parameters.
* `{"strategy": "name", **params}` — named strategy with per-slot
  parameter overrides.

The default pair is what M / N / V / W (initial primitive-test seeds)
ship; the line-kind workstream's subsequent letters override per-slot.

### 13.3 Arm primitives (`ARM_STRATEGIES`)

Five strategies are registered. Each takes the rough anchor pixels at
both ends, the arm index `k`, and the total `n_arms`, plus the mask /
dt / skeleton fields. Each returns a list of `(x, y)` polyline points.

| Strategy | What it does | When to use |
|---|---|---|
| `chord` | Straight chord between the two rough anchors. 2-point polyline. | Tracer-test placeholder; not used by any shipped letter. |
| `bfs_raw` | BFS skeleton path, no smoothing. | Tracer-test placeholder. |
| `lsq_line` | Total-least-squares (SVD) line through trimmed BFS pixels; projects both endpoints onto the fit. | Replaced by `straight_line`; retained for byte-identity reference. |
| `smoothed_medial_axis` | BFS path with joint-adjacent trimming + moving-average smoothing. **Default.** | What M / N / V / W shipped at commit `6cf5740`; default for any letter that doesn't override. |
| `straight_line` | LSQ fit through skeleton pixels, project both endpoints, trim joint-adjacent ends, rasterise. | The line-kind workstream's primary arm. Supports asymmetric LSQ trimming (`fit_trim_start_pct` / `fit_trim_end_pct`), end-point overrides (`start_pixel` / `end_pixel` — used by shared-apex and T-junction pre-passes), and `end_distance_from_outline` (walk the fitted line until the dt target is hit — used for E / F / L bar equidistance). |

The `straight_line` arm's `end_distance_from_outline` option is what
makes E / F / L's three (or two) horizontal bars terminate at the same
distance from the right outline, despite the LSQ projection of TR / MR
/ BR each landing on a slightly different x. Without it, the bars
would visibly stagger.

### 13.4 Joint primitives (`JOINT_STRATEGIES`)

Seven strategies are registered. Each takes the two arms' polylines,
plus the mask / dt / anchor fields, and returns a joint dict carrying
the sampled polyline segments plus metadata (V, P_end, P_start,
trim_back, skip_indices, …) or `None` if the joint can't be
constructed (parallel arms, reversal, etc.).

| Strategy | What it does | When to use |
|---|---|---|
| `sharp` | Hard angular meeting at the natural arm endpoint, no smoothing. | Tracer-test placeholder. |
| `family_a_fillet` | Inscribed band-side fillet at the medial-axis joint, angle-adaptive apex offset. | Pre-line-kind construction (commit `4d6c286`); retained for byte-identity reference. |
| `quadratic_bezier_at_V` | Quadratic Bézier with control point at the math intersection V of the two fitted lines, exact C1 tangent continuity. | Pre-line-kind construction (commit `5592b63`); reference. |
| `cubic_bezier_clamped` | Cubic Bézier with both control points clamped at most `max_handle=70` toward V. | **Default joint.** What M / N / V / W ship. |
| `sharp_meeting` | True angular meeting at V (the math intersection of the two arm-line extrapolations), with skip-index marking around the apex sample. | Convex peaks where the V sits inside the cap rounding; used by line-kind M / N / V / W / Z. |
| `sharp_meeting_at_intersection` | As above, plus the bridge segments from each arm's natural endpoint to V are explicitly sampled. The contiguous out-of-mask window at the apex is recorded in `skip_indices`. | Default for line-kind multi-corner letters (M N V W Z). |
| `fillet_at_intersection` | Cubic Bézier arc between two trim points offset `trim_back` pixels back from V along each arm's tangent. Both Bézier control points sit at V, so the arc interpolates with tangent continuity at the seams and the midpoint sits 3/4 of the way from the chord-midpoint to V. Bridges from each natural arm endpoint to the trim point keep the chain continuous. | Apex placement for lowercase `v` (trim_back=24) and `w` (trim_back=40 uniform across all three joints). The `trim_back` parameter is what controls how far the rounded apex sits above the cap rounding — verified visually via the sweep workflow (§13.7). |

### 13.5 Multi-stroke letter machinery

Several letter-level pre-passes run before per-stroke construction so
that strokes sharing anchors meet exactly:

* **Per-letter anchor cache** (commit `f18cae5`). Same anchor name
  referenced across multiple strokes resolves once, snaps once, and is
  reused. Required for any multi-stroke letter where two strokes meet
  at a named anchor.
* **Letter-level line-fit pre-pass.** Each `straight_line` arm's LSQ
  fit (BFS path → SVD → centroid + direction) is computed once and
  cached by `(stroke_idx, arm_idx)`. Downstream shared-apex and
  T-junction pre-computes consume this cache.
* **Shared-apex pre-compute** (commit `e9cd0f3`). When the same anchor
  name terminates two `straight_line` arms across different strokes
  (e.g. `A`'s shared `T` apex on both BL→T and BR→T diagonals), the
  pre-compute intersects the two fitted arm lines and injects the
  intersection point as `start_pixel` / `end_pixel` into each arm via
  `arm_straight_line`'s override hook. Both strokes terminate on the
  exact same pixel.
* **T-junction pre-compute** (commit `e9cd0f3`). When a crossbar's
  endpoint lands on another stroke's centerline (`A`'s ML/MR meeting
  the diagonals; `E`/`F`/`H`/`L`/`T`'s horizontal arms meeting the
  vertical stem), the pre-compute finds the perpendicular foot of the
  crossbar endpoint on the host stroke's centerline and injects it as
  the arm's start/end pixel. Specified per-arm with
  `"t_junction_start": <host_stroke_idx>` / `"t_junction_end": …`.

These three pre-passes are what made the line-kind bulk commit
(`bd4e2d5`) possible: E / F / H / I / L / T / X / Z + l / v / w / x / z
restructured to multi-stroke specs with T-junctioned crossbars while
keeping M / N / V / W / b byte-identical.

### 13.6 Gates, skip-indices, determinism

The bake runs three numeric gates per stroke as a regression filter:

1. **Gate 1 — overshoot.** Count of polyline samples falling outside
   the ink mask. Skip-indexed samples are excluded.
2. **Gate 2 — reversal.** Count of consecutive-tangent pairs whose
   cosine is below `REVERSAL_COSINE_CUTOFF` (default −0.1, ≈ > 96°
   turn — direction flip). Skip-indexed samples are excluded.
3. **Gate 3 — max-turn.** Worst angular turn between any two
   consecutive tangents, in degrees.

All tuning constants (gate cutoff, arm trim percent, smoothing window,
cubic-Bézier max-handle, family-A fillet cap fraction, walk-plateau
slope threshold, fillet bridge reversal tolerance) are named at the
top of `scripts/generate_strokes_auto.py` so any sweep over them edits
one place. `scripts/render_sweep_grid.py` carries the same
`REVERSAL_COSINE_CUTOFF` named constant so the gate definition
matches across the bake script and the sweep tooling.

`sharp_meeting`, `sharp_meeting_at_intersection`, and
`fillet_at_intersection` joints mark their apex window in
`skip_indices`. For concave valleys (W's BL / BR, V's BC) the window
collapses to just the apex sample; for convex peaks where V sits
inside the cap rounding, it's a contiguous out-of-mask window around
the apex. Without skip-indices, gates 1 + 2 would flag every sharp
meeting as a reversal artefact.

The bake is **deterministic**: byte-identical output across repeated
runs is a release-blocking property. There's also a `b` **firewall** —
at commit `a803d9d` `b`'s `strokes.json` was hand-validated as
correct. Every subsequent script change is required to produce
byte-identical `b_l/strokes.json`. Any diff to `b` flags a regression
in shared code before it lands.

Both properties are codified in `scripts/verify_bake.sh` — it bakes
the LETTERS dict three times into a tmp dir, asserts byte-identity
across the three bakes, and diffs against HEAD's checked-in
`strokes.json` for every letter the dict covers. Exits non-zero on
drift. Run it before any commit that touches `generate_strokes_auto.py`.

### 13.6.1 Font-hash drift check

`generate_strokes_auto.py` writes `_meta.json` alongside the per-letter
`strokes.json` files, recording the SHA-256 of `Primae-Regular.otf`
used at bake time. On launch, `LetterRepository.verifyBakeMetadataOnce`
reads that hash, computes the SHA-256 of the bundled font, and emits
an OSLog warning if they diverge — that's the signature of a font
update without a re-bake, which would silently render strokes against
the wrong glyph. Never fatal; the app keeps running on the cached
polylines.

### 13.7 Visual sweep workflow

For any geometric or visual question with finite candidate options or
a single tunable parameter, the project's authoring rule is
**render-and-compare BEFORE proposing or committing a specific
construction**. The full workflow is captured in `CLAUDE.md` under
"Visual sweep workflow"; the short version:

1. Identify candidates (typically 4–6, including current `main` as
   baseline).
2. Author each variant as a `LETTERS[letter]` spec dict.
3. Drop the variants into a JSON document (`letters` + `variants` keys —
   see the `scripts/render_sweep_grid.py` module docstring for shape).
4. Run `python3 scripts/render_sweep_grid.py variants.json` — it bakes
   each variant, runs the numeric gates, and composes a contact-sheet
   PNG (rows = letters, cols = variants) with per-panel gate counts +
   per-joint metrics (V_sd, P_end dt, apex_sd).
5. Present the grid to the author. Wait for selection.
6. Set chosen value, bake, commit, push as a **single** commit.

Numeric gates filter; visual judgment decides. This is what shipped
the `v` / `w` `joint_fillet_at_intersection` trim_back values
(24 / 40 respectively) after the cubic-bezier-clamped sweep produced a
flat-bottomed U instead of the desired diagonal V.

### 13.8 Authoring a new letter

Operationally, adding or revising a letter is:

1. **Add a `LETTERS[letter]` entry** with anchors and per-stroke
   `arms` / `joints` overrides. Start from the closest already-shipped
   letter; copy its spec.
2. **Run the bake** for just that letter:
   `python3 scripts/generate_strokes_auto.py X`.
3. **Verify gates pass** in stdout; if not, debug via
   `scripts/skeleton_audit.py X` (per-letter skeleton diagnostics).
4. **Render a sweep grid** comparing the new letter against any
   plausible alternatives — `python3 scripts/render_sweep_grid.py
   variants.json`.
5. **Visual review** — eyeball the grid; pick the best column.
6. **Bake the chosen variant for all affected letters**, then run
   `./scripts/verify_bake.sh` to confirm determinism + byte-identity
   for unchanged letters (the b firewall is checked here too).
7. **Single commit** capturing the spec change + regenerated
   `strokes.json` files + a commit message describing the construction
   choice (and what was ruled out and why).

The script is at `scripts/generate_strokes_auto.py`. Auxiliary tooling
(skeleton audit, calibration → override, app-icon, letter-audio) is
in `scripts/` and documented in `scripts/README.md`.

---

# Appendix A — Architecture Quick Reference

_Compact one-page architecture map. Drilldown lives in §2 above._

```
PrimaeNativeApp
└── MainAppView                     ← root, hosts WorldSwitcherRail + worlds
    ├── WorldSwitcherRail           ← persistent left rail; gear long-press → Parent Area
    ├── SchuleWorldView             ← guided 4-phase letter learning (observe → direct → guided → freeWrite)
    │   └── TracingCanvasView       ← Canvas: glyph + ghost + active path + KP overlay
    ├── WerkstattWorldView          ← freeform letter / word writing
    │   └── FreeformWritingView     ← blank canvas + result popup (verbal only)
    ├── FortschritteWorldView       ← child-facing star/streak/letter gallery
    └── ParentAreaView (parental gate)
        ├── ParentDashboardView     ← practice-time, per-letter accuracy, phase rates
        ├── ResearchDashboardView   ← Schreibmotorik dimensions, KI predictions, condition arms
        ├── SettingsView            ← schriftArt / ordering / paper-transfer / freeform / phoneme toggles
        └── ExportCenterView        ← CSV / TSV / JSON share-sheet export
```

`TracingViewModel` is a single shared `@Observable` instance created in `PrimaeNativeApp` and injected via `.environment(vm)`. All worlds read from it; only the calibrator and parent area mutate it directly.

## Key data flow on freeWrite end

```
endTouch → advanceLearningPhase
  ├─ runRecognizerForFreeWrite (background Task)
  ├─ overlayQueue.enqueue(.kpOverlay)
  ├─ overlayQueue.enqueue(.paperTransfer) [if enabled]
  ├─ phaseController.advance → recordPhaseSessionCompletion
  │   ├─ overlayQueue.enqueue(.celebration)
  │   ├─ speech.speak(praise)
  │   └─ progressStore + dashboardStore + streakStore writes
  └─ recognizer Task → overlayQueue.enqueueBeforeCelebration(.recognitionBadge)
                     + speech.speak(recognition message)
```

The OverlayQueueManager serialises every overlay so the child sees one at a time in canonical order: kpOverlay → recognitionBadge → paperTransfer → celebration. Timed cases (kpOverlay 3 s, recognitionBadge 3 s) auto-advance; modal cases (paperTransfer, celebration) wait for explicit dismiss. `rewardCelebration` (U1) auto-advances after 2.5 s.

## Verbal feedback wiring

Children can't read fluently yet, so every numeric metric the data model captures is **only** spoken or rendered as visual encouragement (stars, colour swatches). Speech triggers:

| Trigger | Phrase source |
|---------|---------------|
| `load(letter:)` initial phase | `ChildSpeechLibrary.phaseEntry(currentPhase)` |
| `advanceLearningPhase` transition | `ChildSpeechLibrary.phaseEntry(newPhase)` |
| `recordPhaseSessionCompletion` | `ChildSpeechLibrary.praise(starsEarned:)` |
| Recognition result lands (freeWrite) | `ChildSpeechLibrary.recognition(result, expected)` |
| Freeform recognition lands | `ChildSpeechLibrary.recognition(result, expected: predicted)` |
| `PaperTransferView` phase rotation | `paperTransferShow / Write / Assess` |
| `appDidEnterBackground` | `speech.stop()` |

## Letters with full support

**Geometry (strokes.json):** all 59 letters (26 upper + 26 lower + Ä Ö Ü ß)
ship a real baked `strokes.json`, produced by the bake pipeline documented
in §13. Coverage by primitive class:

* **Line-kind via arm/joint primitives** (§13.3): A, E, F, H, I, L, T, X,
  Z + l, v, w, x, z, plus the original primitive-test seeds M N V W b.
* **BFS-walks-skeleton fallback** (the historical path): everything else,
  including curve-heavy letters and Q-class bowl-with-tail topology
  pending the workstream noted in `docs/ROADMAP.md` and `docs/STROKE_AUDIT.md`.

**Audio:** 7 letters ship recordings (A F I K L M O). The other 52
folders contain `strokes.json` but no MP3s — phase scaffolding still
runs (the empty-strokes-skip branch is no longer triggered), and prompts
that would normally play a recording fall back to TTS.

---

# Appendix B — Research Export Schema

_Reference for analysts working with the CSV / TSV / JSON exports produced by `ParentDashboardExporter`. Update this appendix whenever the exporter shape changes._

## File-level header lines

Every CSV / TSV begins with comment lines starting `#`:

| Header | Source | Meaning |
|---|---|---|
| `# participantId=<UUID>` | `ParticipantStore.participantId` | Stable per-install UUID. Persists across reinstall via iCloud KV. |
| `# enrolledAt=<ISO-8601>` | `ParticipantStore.enrolledAt` | First time the install opted into the thesis study. Only present when set. |
| `# timezone=<IANA>` | `TimeZone.current.identifier` | Device timezone at export time. Useful for interpreting `recordedAt` columns. |

Then a blank line, followed by five data sections.

## Section 1 — Per-letter aggregates

One row per letter the child has practised.

| Column | Type | Source | Range | Purpose |
|---|---|---|---|---|
| `letter` | string | `LetterAccuracyStat.letter` | A–Z, Ä, Ö, Ü, ß (uppercase) | Slicing key. |
| `sessionCount` | int | `accuracySamples.count` | ≥ 0 | How often practised. |
| `averageAccuracy` | float | `LetterAccuracyStat.averageAccuracy` | 0–1 | Mean session score. |
| `trend` | float | `LetterAccuracyStat.trend` | signed slope | Linear-regression slope over trailing 10 samples. |
| `recognitionSamples` | int | `LetterProgress.recognitionAccuracy.count` | 0–10 | CoreML readings retained. |
| `recognitionAvg` | float | mean of `recognitionAccuracy` | 0–1 | Mean **calibrated** confidence. |
| `speedTrend` | float-list (`;` joined) | `LetterProgress.speedTrend` | up to 50 | D-4 raised cap from 5 → 50. |
| `freeformCompletionCount` | int / blank | `LetterProgress.freeformCompletionCount` | ≥ 0 | Werkstatt-mode completions. |
| `retrievalAccuracy` | float / blank | mean of `LetterProgress.retrievalAttempts` (cap 10) | 0–1 | P1 — fraction of retrieval-prompt answers that were correct. Empty for letters never tested or when the parent's "Erinnerungstest" toggle was off. |

## Section 2 — Per-day session durations

| Column | Type | Source | Purpose |
|---|---|---|---|
| `date` | string | `SessionDurationRecord.dateString` | `yyyy-MM-dd` (device-local). |
| `recordedAt` | ISO-8601 / blank | `SessionDurationRecord.recordedAt` | D-9: time-of-day analysis. |
| `durationSeconds` | float | `SessionDurationRecord.durationSeconds` | **Active** practice time. Pauses on background (D-1). |
| `wallClockSeconds` | float / blank | `SessionDurationRecord.wallClockSeconds` | T4: total time including backgrounded intervals. |
| `condition` | string | `SessionDurationRecord.condition` | `threePhase` / `guidedOnly` / `control`. |
| `inputDevice` | string / blank | `SessionDurationRecord.inputDevice` | T7: `finger` / `pencil` / blank. |
| `letter` | string / blank | `SessionDurationRecord.letter` | The practised letter (or word label) — per-letter time-to-complete without a `recordedAt` join. Blank for legacy records. |

`condition == threePhase` does not imply four phases ran — the case label predates the `direct` phase.

## Section 3 — Per-phase records

One row per phase × letter session, chronological order. Filtered by `enrolledAt` (D-7) and pre-D-3 nil-recordedAt rows are dropped when `enrolledAt` is set (D-8).

| Column | Source | Purpose |
|---|---|---|
| `letter` | `PhaseSessionRecord.letter` | Per-letter slicing. |
| `phase` | `PhaseSessionRecord.phase` | `observe` / `direct` / `guided` / `freeWrite`. |
| `completed` | `PhaseSessionRecord.completed` | Selection criterion. |
| `score` | `PhaseSessionRecord.score` | Phase-level accuracy / form score (0–1). |
| `schedulerPriority` | `PhaseSessionRecord.schedulerPriority` | Scheduler priority at letter selection. |
| `condition` | `PhaseSessionRecord.condition` | A/B arm. |
| `recordedAt` | `PhaseSessionRecord.recordedAt` | D-3: dated learning curves. |
| `recognition_predicted` | `PhaseSessionRecord.recognitionPredicted` | CoreML top-1 letter (freeWrite rows since D-2). |
| `recognition_confidence` | `PhaseSessionRecord.recognitionConfidence` | **Post**-calibration softmax. |
| `recognition_confidence_raw` | `PhaseSessionRecord.recognitionConfidenceRaw` | T5: **pre**-calibration softmax. |
| `recognition_correct` | `PhaseSessionRecord.recognitionCorrect` | Match expectation? |
| `formAccuracy` | `PhaseSessionRecord.formAccuracy` | Schreibmotorik dim 1 (weight 0.40) — the clamped, rescaled transform of `frechetDistance`. Child-facing input, not the analysis outcome. |
| `tempoConsistency` | `PhaseSessionRecord.tempoConsistency` | dim 2 (CV², weight 0.25). |
| `pressureControl` | `PhaseSessionRecord.pressureControl` | dim 3 (force variance, weight 0.15). |
| `rhythmScore` | `PhaseSessionRecord.rhythmScore` | dim 4 (active-time ratio, weight 0.20). |
| `inputDevice` | `PhaseSessionRecord.inputDevice` | D-6: disambiguates `pressureControl == 1.0`. |
| `audioCondition` | `PhaseSessionRecord.audioCondition` | Pilot audio arm: `phoneme` / `spatial` / `silent`. Appended after `inputDevice` so pre-pilot CSV parsers stay positionally compatible. |
| `trainedSubset` | `PhaseSessionRecord.trainedSubset` | The participant's trained 3-of-5 study letters (e.g. `AIM`) — partition trained vs untrained rows. Blank for legacy records. |
| `phaseDurationSeconds` | `PhaseSessionRecord.phaseDurationSeconds` | **Time outcome.** freeWrite rows only: measured-phase time = first sample → last sample, end-inclusive (§6.4.1). Excludes the trailing 2.0 s quiet-window auto-advance (`freeWriteQuietSeconds`) by construction; that constant is identical across arms. Blank otherwise. |
| `frechetDistance` | `PhaseSessionRecord.frechetDistance` | **Primary accuracy outcome.** Raw discrete-Fréchet distance, normalised 0–1 letter-box units, 6 dp, lower = better, unclamped. freeWrite rows only; blank otherwise and for legacy rows. Full definition in §4.12.1. |
| `checkpointCoverage` | `PhaseSessionRecord.checkpointCoverage` | **Secondary accuracy outcome.** Reached ÷ total reference checkpoints for the freeWrite pass (0–1, 4 dp). Saturates at ceiling — §4.12.2. freeWrite rows only; blank otherwise and for legacy rows. |

> Blank ≠ 0 in this section. A `0` in `frechetDistance` means a perfect
> overlay and a `0` in `checkpointCoverage` means no checkpoint was
> reached; rows that never measured the quantity are empty.

**Analyse per letter.** A, F, I, L, M are not structurally comparable —
M alone is a single stroke of 200 checkpoints. Do not pool
`frechetDistance`, `checkpointCoverage`, or `phaseDurationSeconds`
across letters (§4.12.3).

## Section 3b — Raw traces (JSON export only)

The JSON archive carries a `rawTraces` array the CSV/TSV omit. Each
entry is one freeWrite trial: `id`, `letter`, `recordedAt`, `points`
(canvas-space), `timestamps`, `forces`, `strokeStartIndices`, and
`canvasSize`. Join to Section 3 on `PhaseSessionRecord.rawTraceID`.

Normalised coordinates are recovered losslessly as
`points[i] / canvasSize`; the normalised path is not stored because it
would be redundant. This archive is what makes every scalar above
re-derivable offline — see §6.4.2.

## Section 4 — Aggregate metrics (`metric,value`)

- `phaseCompletionRate_<phase>` per LearningPhase.
- `averageFreeWriteScore` (cross-arm).
- `schedulerEffectivenessProxy` (cross-arm Pearson r — interpret with caution; `.control` priorities don't share scale with the other arms).
- Per-arm: `averageFreeWriteScore_<arm>`, `schedulerEffectivenessProxy_<arm>` (D-7 / D-10).
- Per-AUDIO-arm: `averageFreeWriteScore_audio_<audioArm>` — the pilot's primary between-subjects IV, stratified alongside (not instead of) the pedagogical axis.
- Schreibmotorik dimension means: `averageFormAccuracy`, `averageTempoConsistency`, `averagePressureControl`, `averageRhythmScore` (when ≥ 1 freeWrite session has dimensions).

## Section 5 — Per-arm letter aggregates (D-5)

`letterByArm,<letter>,<arm>,<sampleCount>,<averageScore>` — derived from `phaseSessionRecords` so between-arm letter-level analyses have a clean source.

Audio-axis twin: `letterByAudioArm,<letter>,<audioArm>,<sampleCount>,<averageScore>` (own sub-header row), same derivation keyed on `audioCondition`.

## JSON export

Contains the full `DashboardSnapshot` plus a `thesisMetrics` block. Use it when you need raw `recognitionSamples`; CSV / TSV is the tabular surface.

---

# Appendix C — Phoneme audio authoring guide (P6)

_Companion guide for ROADMAP §P6 — phoneme audio integration. The
recorded-phoneme production procedure (no-schwa articulation, D6 stop
handling, recording checklist) lives in `docs/SOUND_PRODUCTION_SPEC.md`;
this appendix holds the integration details + the per-letter IPA target table._

## Why phonemes

The app's existing audio plays the **letter name** (German /aː/, /beː/, …). Phonemic awareness — recognising the *sound* `A` makes (/a/ as in *Affe*) — is the load-bearing pre-reading skill German Volksschule curricula teach in parallel with handwriting. Adding phoneme audio lets the parent toggle between names and sounds (Adams 1990; *Beginning to Read*).

## Filename convention

Drop phoneme recordings into the existing per-letter directory:

```
PrimaeNative/Resources/Letters/<base>/
    <base>_phoneme1.mp3
    <base>_phoneme2.mp3        # optional second voice / take
    <base>_phoneme3.mp3        # optional third voice / take
```

`<base>` is the **uppercase** letter directory (`A`–`Z`, `Ä`, `Ö`, `Ü`, `ß`). The leaf filename must contain `_phoneme` (case-insensitive) — that's the partition rule in `LetterRepository.partitionPhonemeAudio`. Existing letter-name recordings (`A1.mp3`, etc.) keep working unchanged; the repository scan picks up both populations.

Supported formats: `.mp3`, `.wav`, `.m4a`, `.aac`, `.flac`, `.ogg`.

## Recommended specs

- 44.1 kHz / 48 kHz, 16-bit / 192 kbps mp3 or higher
- 0.6–1.2 seconds per take
- ≤ 50 ms pre-roll silence
- Loudness target `-16 LUFS` to match existing letter-name tracks

## Voice variants

The existing layout ships 1–3 takes per letter (`A1.mp3`, `A2.mp3`, `A3.mp3`). The child cycles via two-finger swipe. Phonemes inherit the same gesture: swipe cycles `<base>_phoneme1`, `_phoneme2`, `_phoneme3`.

Recommended mix:
1. Neutral adult German voice (clear articulation; matches existing letter-name set)
2. Second adult voice in different timbre
3. A higher-pitched / younger-sounding take — Mayer & Sims (1994) personalisation principle suggests peer-aged voice boosts engagement

## Production — recorded, not synthesised

The pilot phoneme set is **recorded by a human voice**, not generated by ElevenLabs: a TTS engine returns the letter *name* or a word, not a sustained isolated phone, and gives no control over the no-schwa articulation. The full production procedure — the no-schwa Anlaut rule, the D6 stop-consonant handling, and the recording-session checklist — lives in `docs/SOUND_PRODUCTION_SPEC.md`. The articulation target per letter is the IPA table below.

The articulation rule, in one line: speak only the German phoneme, not the letter name — for `A` produce `/a/` as in *Affe*, not `/aː/` as in the alphabet song; brief and clean, under ~1 second, no schwa, no syllable.

## German phoneme reference (target IPA per letter)

| Letter | Phoneme | German example |
|---|---|---|
| A | /a/ | *Affe* |
| B | /b/ | *Ball* |
| C | /ts/ or /k/ | *Cent* / *Computer* (use /k/ as primary) |
| D | /d/ | *Dach* |
| E | /ɛ/ or /eː/ | *Bett* / *Esel* (use /ɛ/) |
| F | /f/ | *Fisch* |
| G | /ɡ/ | *Gabel* |
| H | /h/ | *Haus* |
| I | /ɪ/ or /iː/ | *Igel* (use /ɪ/) |
| J | /j/ | *Jahr* |
| K | /k/ | *Kuh* |
| L | /l/ | *Löwe* |
| M | /m/ | *Maus* |
| N | /n/ | *Nase* |
| O | /ɔ/ or /oː/ | *Ofen* (use /ɔ/) |
| P | /p/ | *Papa* |
| Q | /kv/ | *Quelle* (digraph; record as a unit) |
| R | /ʁ/ or /ɐ/ | *Rad* (German R, not rolled Spanish) |
| S | /s/ or /z/ | *Sonne* (use /z/ at word start) |
| T | /t/ | *Tisch* |
| U | /ʊ/ or /uː/ | *Uhu* (use /ʊ/) |
| V | /f/ | *Vater* (German V usually /f/) |
| W | /v/ | *Wasser* |
| X | /ks/ | *Hexe* (digraph) |
| Y | /y/ or /ʏ/ | *Yacht* (rare; use /y/) |
| Z | /ts/ | *Zoo* (always /ts/, not English /z/) |
| Ä | /ɛ/ | *Äpfel* |
| Ö | /ø/ or /œ/ | *Öl* |
| Ü | /y/ or /ʏ/ | *Über* |
| ß | /s/ | *Straße* (unvoiced — important: NOT /z/) |

Citation: Krech, E.-M. et al. (2009). *Deutsches Aussprachewörterbuch*. de Gruyter.

## Verification checklist

After dropping new files into the bundle:
1. Run the app, Settings → Lautwert → toggle "Lautwert wiedergeben" on.
2. Tap a letter that has phoneme recordings — phoneme plays, not the name.
3. Two-finger vertical swipe cycles through takes (toast: "Ton 1 von 3" etc.).
4. Tap a letter without phoneme recordings — letter-name fallback plays, never silence.
5. Toggle Lautwert off — name audio resumes immediately.

## Coverage tracking

Status values: ⏳ pending · 🟡 partial (1–2 voices) · ✅ complete (3 voices).

| Letter | Status | Voices | Notes |
|---|---|---|---|
| (add rows as letters are recorded) | | | |

---

---

_End of document. Last updated 2026-05-14 against `main` (commit `e76d8a5`) after the line-kind stroke workstream — §13 added covering the bake pipeline, ARM_STRATEGIES + JOINT_STRATEGIES registries, multi-stroke machinery, gates / skip-indices, and the visual sweep workflow. Outstanding work lives in `docs/ROADMAP.md`. The historical four-agent audit that motivated this work lives in `docs/STROKE_AUDIT.md`. Code-level invariants (read before touching fragile code) live separately in `docs/LESSONS.md` — that file is a contributor guardrail, not reference documentation, and is intentionally kept out-of-band so a maintainer reads it in full instead of skimming an appendix._
