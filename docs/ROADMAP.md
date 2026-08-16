# Roadmap — Primae

See `docs/BAKE_INVARIANTS.md` for permanent bake invariants — apply to every letter, every weight, every bake.

_Single forward-looking work log. Last updated 2026-05-25 against `main` (commit `1f9f5a0`). Only items still requiring work appear here — every shipped item has been removed. Shipped items live in commit history._

---

## At a glance — what's next

### Your ball (asset work + device validation)

| Item | Owner action | Why it matters | Effort |
|---|---|---|---|
| **P6** phoneme audio recordings | Record 90 phoneme recordings (human voice, 3 takes × 30 letters) per `docs/SOUND_PRODUCTION_SPEC.md`, using the IPA target table in Appendix C of `docs/APP_DOCUMENTATION.md`; drop into `Resources/Letters/<base>/` as `<base>_phoneme<n>.mp3` | Phonemic awareness ↔ reading acquisition (Adams 1990); the "Lautwert wiedergeben" toggle is already shipped — without recordings it falls back silently | **XL** (recording-time-bound) |
| **U5** Pencil 2 squeeze validation | iPad with Apple Pencil 2 — confirm squeeze + double-tap fire `replayAudio()` and don't double-fire with finger taps | Code is shipped; just needs verifying the gesture lands as intended on real hardware | **0–1 days on device** |
| **U10** VoiceOver walkthrough | iPad with VoiceOver enabled — walk every screen, watch for skipped elements / misordered focus / Switch Control routing / Dynamic Type clipping | Required before submitting the thesis externally; the partial in-code audit shipped, but the device walkthrough is the load-bearing part | **2–3 hours on device** |

### Engineering ball (in-loop sessions with me)

| Item | What I need from you | Why it can't be autonomous |
|---|---|---|
| **D8** canvas redraw profile | iPad + Instruments time-profile of a high-velocity guided session | No measured evidence of a problem; pre-optimising could break a currently-correct redraw path |

Everything in the **post-thesis** section (F1–F10) waits until the thesis ships.

---

## What's already shipped this session (for context — not action)

This list is intentionally collapsed; the detail lives in commit messages. Removing the duplication that previously lived in `docs/ROADMAP_V5_DEFERRED_NOTES.md`.

- **Thesis data correctness:** condition-tagged samples, timezone header, wallClockSeconds, raw recognition confidence, researcher arm override, input-mode on durations, EXPORT_SCHEMA appendix.
- **Pedagogical features:** self-explanation re-animation on misrecognition, errorless first-3-sessions ramp, daily goal pill, spaced-retrieval testing prompts (P1 — `RetrievalScheduler`, `RetrievalPromptView`, opt-in toggle, motorSimilarity-cluster distractors, `retrievalAccuracy` CSV column), backward-chaining direct-phase toggle (P5), onboarding A/B variants with first-completion lock (U4), phoneme audio infrastructure (P6 — toggle + filename convention + scanner partition).
- **UX:** reward-celebration overlay, Schreibmotorik dimension sparklines, gold-tint token unification, celebration haptic, speech-rate slider, Bob-the-dog start-cue dwell, **full Primae rebrand** (repo + Xcode project + bundle ID + every screen restyled), **dark-mode parity (U11) via Asset-Catalog colorsets** (38 tokens; light + dark variants per colorset; flips via the parent-area Erscheinungsbild picker — System / Hell / Dunkel).
- **Tech debt:** `PaperTransferView` deterministic timing seam, CoreML classifier-closure protocol seam (D3) with 7 pipeline tests, **VM God-object decomposition (D1) fully shipped**: `RecognitionTokenTracker` (D1a, recognition tokens off the VM), `TouchDispatcher` (D1b, touch-session state + `beginTouch`/`updateTouch`/`endTouch` flow + 5 helpers + `mapVelocityToSpeed`), `PhaseTransitionCoordinator` (D1c, `advanceLearningPhase` + post-phase pipeline + `commitCompletion`). VM down from 2350+ to ~2030 lines; CI timeout caps; accessibility partial (Schreibqualität rows collapse to single VoiceOver elements). Dormant infrastructure (`SchemaMigrator` framework, `Spacing.swift` token mirror, `App/PrimaeNativeApp.swift` library-side App stub) was later removed; reintroduce from git history when the consuming feature actually arrives.
- **Stroke geometry workstream:** bake pipeline rewritten with composable arm/joint primitives (5 arm strategies + 7 joint strategies; see `docs/APP_DOCUMENTATION.md` §13). skimage-skeletonize baked into `strokes.json`; Swift loader prefers baked. Line-kind letters with arm/joint primitives ship for A, E, F, H, I, L, T, X, Z + l, v, w, x, z, plus the original M N V W b seeds. v / w apex placement via `joint_fillet_at_intersection` (trim_back=24 / 40). **Phase 2b Track B drift-from-reference gate set** enforced via `bake-gates.yml`: G1 asymmetry-profile (Pearson ≥ 0.2005), G3 perpendicular-deviation-on-straight (≤ 2.05 px), G4 junction-tangent-kink (≤ 4.43°). G2 turn-angle Pearson investigated 2026-05-23, not viable as freeze-gate metric. G5 (2026-05-24) wires the gates into CI. Open follow-up for the bake pipeline (Light + future fonts only; Regular ships as hand-calibrated artifact since `6a85811c`): Q-class topology (Q a_l ä_l g_l q_l ü_l) and ß resolver work.

---

Effort key: **S** = under 1 day · **M** = 1–3 days · **L** = 3+ days · **XL** = multi-week
Priority key: **P1** = thesis-blocking · **P2** = thesis-strengthening · **P3** = post-thesis polish

Detail sections follow with effort, file list, citations, failure modes per item.

---

## 1. THESIS-CRITICAL

### P6 — Phoneme audio recordings *(infrastructure on main; audio assets pending)*
**Effort:** XL (recording + voice direction work) · **Priority:** P1

Phonemic awareness (Adams 1990) predicts later reading acquisition; pairing handwriting practice with the *sound* the letter makes (`/a/` as in *Affe*) instead of just its name (`/aː/`) is curriculum-aligned for German Volksschule.

**What's already in code (on `main`).**
- `LetterAsset.phonemeAudioFiles: [String]` — populated by `LetterRepository.partitionPhonemeAudio` from the bundle scan.
- `enablePhonemeMode: Bool` UserDefaults toggle, threaded through `TracingDependencies` and the VM.
- All 7 audio call sites (replay, variants, autoplay, begin-touch reload, direct-phase first-tap, load() prime) routed through `activeAudioFiles(for:)` helper. Toggle-on with no phoneme recordings → silent fallback to letter-name set.
- SettingsView "Lautwert" section with the toggle + Adams 1990 caption.

**What's still needed.**
1. **Audio recordings** following the convention `<base>_phoneme<n>.<ext>` per Appendix C in `docs/APP_DOCUMENTATION.md`. Three takes per letter (different voices for child preference). 30 letters × 3 takes = 90 recordings.
2. Per-letter IPA target table is in Appendix C; the recorded-phoneme production procedure (no-schwa Anlaut articulation, D6 stop-consonant handling, recording-session checklist) is in `docs/SOUND_PRODUCTION_SPEC.md`. Clean-up (trim silence, normalise to -16 LUFS, export at 44.1 kHz mono mp3) is the per-file labour.
3. **Bundle wiring.** Drop the files into `PrimaeNative/Resources/Letters/<base>/`. Repository scan picks them up automatically; no Swift code changes required.
4. **Verification checklist** (in the appendix): toggle on → tap → phoneme plays; two-finger swipe cycles through takes; toggle off → name resumes.

**Citations.**
- Adams, M. J. (1990). *Beginning to Read: Thinking and Learning about Print*. MIT Press.
- Krech, E.-M. et al. (2009). *Deutsches Aussprachewörterbuch*. de Gruyter.

---

## 2. PILOT STUDY — freeze items & known issues

_Consolidated from the former `PILOT_READINESS.md` (2026-06-20). The decision rationale for everything here lives in `docs/DECISIONS.md`; this section holds the **work** (freeze items) and the **open issues/residuals**._

### Freeze items — HIGH (pilot cannot run as designed without these)

| # | Item | Type | Reuse / notes |
|---|------|------|---------------|
| H1 | `PilotAudioCondition: { phoneme, spatial, silent }` enum + assignment. _(2026-07-06: the third arm was redesigned from `arbitrarySound` to `spatial` — spatial 2D sonification, pen Y→pitch / X→pan on a shared carrier tone; the assignment machinery is unchanged.)_ Pedagogical flow held constant (D1), so this is the audio dimension only. **SHIPPED (`279d553`, 2026-06-20)** — orthogonal to `ThesisCondition` (UUID byte 15, decorrelated from byte 0), with override, enrollment, and exporter stamping; `PilotAudioConditionAssignmentTests`. | Build | Slotted into existing UUID-modulo assignment + override + enrollment + per-arm exporter, as planned. |
| H2 | Arm-aware audio selection — `activeAudioFiles(for:)` branches on the pilot arm. **SHIPPED (`b212e82`, 2026-06-20; arm redesigned 2026-07-06)** — `.silent → []`, `.spatial → [SpatialSonification.carrierToneFile]` (one shared, letter-independent carrier; deliberately no name-audio fallback), `.phoneme → phoneme/name per toggle` (H2.1 tightened this; see known issues); `AudioArmRoutingTests`. | Build | Single chokepoint as planned. Both sound arms share the `setAdaptivePlayback` rate+pan coupling; the spatial arm ADDITIONALLY drives pitch from pen Y (`setSpatialPitch`, per-tick, spatial-only) — the arms are matched on rate+pan and differ in pitch-drive + sound identity (reframed matching discipline; DECISIONS.md update pending David's sign-off). |
| H3 | Silent-arm codepath. **SHIPPED (with H2, `b212e82`)** — `.silent` returns `[]` and every read site short-circuits on an empty list, so no file loads and no coupling fires. `AudioEngine.swift` untouched (stable/fragile). | Build | Delivered via the H2 chokepoint, as planned. |
| H4 | ~~Arbitrary-sound asset set~~ **SUPERSEDED (2026-07-06):** the third arm is now spatial 2D sonification; its only asset — the seamless 440 Hz triangle carrier `Resources/Sonification/spatial_carrier.wav` — is bundled. No per-letter abstract sounds are needed; the Groß-Vogt abstract-sound design ask is off the critical path. (DECISIONS.md D2-supersession entry pending David's sign-off.) | — | `SOUND_PRODUCTION_SPEC.md` §abstract-sounds is now stale against code — flagged, not yet edited (thesis-substance adjacency). |
| H5 | P6 phoneme recordings — **narrowed by the 5-letter study set (2026-07-06): 0/5 needed** (A I M F L → /a/ /ɪ/ /m/ /f/ /l/; 15 if the 3-takes convention is kept), down from 0/90. All five are vowels/continuants — loopable, so the D6 stop-consonant problem is MOOT for the study set. **RECORDED (human voice) per `docs/SOUND_PRODUCTION_SPEC.md` — ElevenLabs is NOT used for phonemes** (it returns letter names/words, not isolated phones). David records these himself. | Assets | Was XL at 90; now S. Intake path is ready: drop `<base>_phoneme<n>.mp3` into `Resources/Letters/<BASE>/` (all five folders exist), `partitionPhonemeAudio` routes them automatically. |
| H6 | In-app sound-off post-test — **build all three, selectable in Settings:** (a) recognition, (b) production, (c) letter-sound. No test-mode flow exists today (app is all learning/practice). | Build | Strong reuse: `FreeWriteScorer` (production, as-is), `RetrievalPromptView` (recognition + hear→tap letter-sound, as-is), `LetterScheduler` (letter set), Settings-toggle pattern (selection), new `PostTestResult` Codable record (overload-with-defaults pattern). MUST-BUILD-NEW: a `PostTestController` orchestrator (~100–200 lines, parallel to `LearningPhaseController`, NOT a 5th LearningPhase case); distractor-picker; researcher start-screen. Audio suppression via the H2 chokepoint. |

> H5 overlaps §1 P6 above — same recordings, two views: §1 is the thesis-critical work item, this row is its pilot-arm dependency.

### Known issues / residuals

_Pilot-blocking and tracked-not-built issues consolidated from PILOT_READINESS (2026-06-20)._

**Known issue — CalibrationStore override-shadow (pilot-blocking).**
- This shadow is now a thesis-truth-condition: Ch.5's reframe asserts every child traces the identical frozen stimulus, which is false on a device where CalibrationStore overrides outrank the bundle for Druckschrift. Fix (study-mode guard + cleared overrides) is required before the pilot, not optional hardening.
- **RESOLVED — `studyMode` mechanism complete and operable (CI-green):** the `studyMode` flag (off by default, persisted) + the `resolvedStrokes(for:)` guard + the researcher toggle + the (font-scoped) clear-overrides control are all built, reachable in ResearchDashboardView, and CI-green (commits `84b759e`, `fd2b789`). The thesis-truth-condition now has a working, reachable mechanism.
  - **Precise guard invariant (cite THIS, not the broader version):** the calibration override is read in exactly **two** places — the guarded resolve `resolvedStrokes(for:)` (`TracingViewModel.swift:250`) and the export path `loadAllEffectiveStrokes` (`:1729`). `studyMode` ON forces bundle geometry at the guarded resolve. NOTE: multi-cell **word mode** loads non-active cells' bundle strokes directly (`:1667`) WITHOUT going through `resolvedStrokes` — this is safe (that path never reads an override), but it means the precisely-true invariant is "**the override is read in 2 sites**," NOT "all scored geometry routes through one chokepoint." Ch.5's identical-frozen-stimulus truth-condition rests on this, so cite the 2-read-sites invariant.
  - **clear-overrides scope is FONT-SCOPED, not global:** the clear-overrides control — and the new-participant reset's calibration wipe, which calls the same `clearAllCalibrations()` — resolves to `clearAll(for: vm.schriftArt)`, deleting only the **active** font's calibration directory; other `SchriftArt` calibration dirs survive. Harmless for the Druckschrift-only pilot (the active font IS the pilot font), but the wipe is **not global**.
  - **Test coverage:** bundle target pinned by `StrokeGeometryGoldenTests`; additionally `StudyModeGuardTests.swift` exercises the guard against a **real persisted override** (ON → bundle, OFF → override) — stronger proof than the golden test alone.
  - Remaining deferred: the post-guard on-device golden layer pinning the font-derived bbox→cell mapping (waits on the new font).

**Known issue — phoneme arm depends on `enablePhonemeMode` (pilot-blocking, H2.1).**
- H2 routes `activeAudioFiles(for:)` on the audio arm, but the `.phoneme` branch deliberately preserves the legacy parent toggle: `enablePhonemeMode ? phonemes : name audio`. This keeps casual/non-enrolled users byte-identical. **The cost:** a phoneme-arm study device with `enablePhonemeMode` OFF plays the letter **name** audio (`/aː/`) instead of the **phoneme** (`/a/`) — a silent confound that corrupts the IV with **no error surfaced**. The `.silent` and `.spatial` arms are unaffected (they ignore the toggle).
- **RESOLVED — H2.1 shipped (`724d664`, 2026-06-20):** when `studyMode` is on, the `.phoneme` arm forces `phonemeAudioFiles` regardless of the toggle, resolved at **letter-load** in `activeAudioFiles(for:)` (`TracingViewModel.swift:843`), never on the per-tick `updateAdaptivePlayback` path — the matching-discipline coupling stays file-list-agnostic. `studyMode` OFF preserves the exact pre-pilot toggle behaviour (casual users byte-identical). Tests cover both toggle states under `studyMode`.
- **Remaining residual (LOGGED, not silent — closed by H5, not by code):** a letter with no phoneme recording (the H5/P6 gap) still degrades to name audio on a phoneme-arm study device; `pilotAudioLogger.warning` names the letter at letter-load frequency, and the ResearchDashboard phoneme-coverage census (`7efccb0`) surfaces the gap before a session. The true fix is recording the phonemes (H5).

**Known issue — new-participant reset→relaunch window (low-risk, tracked not built).**
- The "Neuer Teilnehmer" reset (ResearchDashboard) regenerates participant identity (new UUID → re-randomised arms) but the running VM holds `thesisCondition`/`audioCondition` as `let` captured at init, so the new arms only take effect on app relaunch — enforced by a "Neustart erforderlich" alert.
- **Residual:** if a proctor ignores that alert, exits the parent area, and lets a child trace BEFORE relaunching, that record carries the **new participantId** but the **old arm** — a **mislabeled (not dropped)** record. (`recordedAt > enrolledAt`, so it survives the exporter's pre-enrolment filter.) The opposite failure — a real record silently dropped for `recordedAt < enrolledAt` — is impossible: `enrolledAt` is stamped at reset and all post-relaunch records are strictly later.
- **Mitigated by protocol:** after reset the device sits in the parent-gated research tab (no tracing surface) and the relaunch alert directs an immediate restart, so the window requires the proctor to actively ignore it.
- **Optional hardening (not built):** gate `recordPhaseSession` until relaunch after a reset (e.g. a "reset pending" flag that suppresses recording until the arms are re-seeded). Low-risk for a proctored single-session pilot; tracked here, not built.

**Investigated — Fréchet primary measure is cross-lift-safe (no fix needed, 2026-06).**
- The cross-pen-lift concatenation in the Fréchet primary measure (`FreeWriteScorer.score` → `formAccuracy` → `referencePolyline`) was investigated and found **Fréchet-SAFE**. `referencePolyline` concatenates all strokes into one polyline and resamples by arc length, bridging each lift gap with a phantom diagonal — but discrete Fréchet couples the trace's gap-bridge to the reference's gap-bridge at matching arc-length fractions, so the phantom diagonal **cannot inflate the score beyond the real per-stroke error** (empirically **≤1.4% on real letters, 0 in most cases, always toward HIGHER scores** — removing inflation can only reduce distance).
- The genuine cross-lift "tank" the older docstring describes was on the **Hausdorff `formAccuracyShape`** (freeform / Werkstatt path), which is **already per-stroke-densified**. It is NOT the recorded thesis measure.
- **No fix to the primary measure is warranted.** Threading `strokeStartIndices` through the outcome variable to shift it ≤1.4% would add risk for no benefit; the guarded-geometry "strong reason" is absent.
- **Replica validation** (faithful Double-precision reimplementation of referencePolyline + arc-length resample + discrete-Fréchet DP + `radius*3` scaling): real **A / T / H** (multi-stroke) and **I** (single-stroke) bundle letters, plus synthetic **long-gap**, **length-mismatch**, and **gross-displacement** regimes. Single-stroke moved exactly 0; multi-stroke moved ≤+0.017, always up.

---

## 3. UX — DEFERRED

### U5 — Apple Pencil 2 squeeze *(wired on main; needs device validation)*
**Effort:** S (already done in code) — but **0–1 days for device validation** · **Priority:** P3

**Status.** Wired into `PencilAwareCanvasOverlay`. `UIPencilInteraction` is installed lazily; squeeze and double-tap both trigger `vm.replayAudio()`. Devices without `UIPencilInteraction` support pass nil and the interaction is never installed.

**What's needed before merging to main.** Real iPad with Apple Pencil 2nd gen, in your hand. Check:
- Squeeze fires the audio replay (not a "switch tools" default action).
- Double-tap (the legacy gesture) also fires the audio replay.
- Finger-only sessions never invoke the handler.
- Audio doesn't double-fire when squeeze + finger-tap occur in rapid succession.

If any of those fails on device, the fix is a tweak in `Coordinator.pencilInteractionDidTap`.

---

### U10 — Accessibility audit *(partial shipped; full audit needs device)*
**Effort:** S–M · **Priority:** P3

**What's already done (on `main`).**
- Schreibqualität dimension rows collapse to one VoiceOver element per row ("Form, 78 Prozent") instead of three separate focuses.
- Reward badges, daily-goal pill, settings additions, celebration overlay all carry combined-element labels + hints.
- Sparkline view is `accessibilityHidden(true)`.

**What's still needed (real iPad with VoiceOver enabled).**
- Walk every screen in VoiceOver order. Watch for skipped elements, misordered focus, ambiguous labels.
- Verify the order of focus in `SchuleWorldView` after a phase advance — does the "Weiter" button get focus before the celebration is announced, or vice versa?
- Switch Control routing — direct-phase dot taps need to be reachable via the switch.
- AssistiveTouch overlay — confirm the touch-handler hierarchy doesn't block AssistiveTouch's hit-testing.
- Dynamic Type stress test — the dashboard rows should not clip at the largest accessibility text size.

**Recommendation.** Schedule 2–3 hours with VoiceOver enabled on the iPad before submitting the thesis to anyone external.

---

## 4. TECHNICAL DEBT

### D8 — Canvas redraw frequency profile
**Effort:** S (profile only) — could expand to M if a real bottleneck surfaces · **Priority:** P3

**Why deferred.** No measured evidence of a problem. On an M-class iPad it's probably fine; on an older iPad (A12 / iPad 8th gen) high-velocity drawing might drop frames because the freeWriteRecorder appends per touch event, the VM publishes the change, the canvas re-renders, the canvas re-builds the path, the GPU rasterises.

**What to do.**
1. Open Instruments → Time Profiler → run a guided session for ~30 seconds at high velocity.
2. Check the SwiftUI Update Profiler for `tracingCanvas` body invocations / second.
3. If sustained >60 invocations / sec, two cuts available:
   - Wrap static layers in `Equatable` subviews (glyph image, ghost lines, start dots only change when `currentLetterName` / `schriftArt` / `showGhost` / `phaseController.showCheckpoints` change). `.equatable()` lets SwiftUI skip body re-eval when those don't change.
   - Throttle recorder writes to ~30 Hz (every other touch event). Coalescing halves redraw count without the child noticing.

**Recommendation.** Don't pre-optimise. Profile only after a real classroom user reports lag or the device-test job reports a frame drop.

---

### D9 — Renderer architecture open questions
**Effort:** M (design + impl) · **Priority:** P3

Carried forward from the now-removed `docs/RENDERING.md` "Open questions for renderer implementation" section (migrated here 2026-05-25; RENDERING.md itself deleted 2026-06-20, its rendering model consolidated into `docs/BAKE_INVARIANTS.md` §5). Four polish-tier renderer-architecture questions, none answered in code today:

1. **Default display band width + finger/pencil scaling logic.** `TracingCanvasView` uses hardcoded `lineWidth` values per layer (6 / 8 / 12 / 14) and modulates pencil ink via `8 + pressure * 14`; there's no finger/pencil mode switch for the display band itself, and no scaling logic relating display-band width to letter render size. Decide: smooth crossfade vs hard switch on input-device detection.
2. **Mid-stroke device change support.** Touch type is read at touch-down and not re-evaluated mid-stroke. Decide whether to detect (and how to handle: re-style mid-stroke, ignore, snap to one or the other).
3. **Pencil scoring tolerance band tuning.** `StrokeTracker` uses `checkpointRadius * radiusMultiplier` for difficulty adaptation; there's no pencil-vs-finger tolerance split. The now-removed RENDERING.md (model now in `docs/BAKE_INVARIANTS.md` §5) suggested starting at 50% of the display band's half-width — needs derivation against real device data.
4. **Glyph fade-out vs persistent visibility during tracing.** Typical learn-to-write apps fade the display glyph as the child traces over it; Primae currently keeps it persistent. Decide based on classroom observation / pedagogy literature.

**Why deferred.** Polish-tier UX questions; current rendering is functional. None of these blocks the thesis.

**Trigger to revisit.** Post-thesis F1 (App Store readiness) is a natural moment to revisit display-band tuning. The other three can wait for classroom-data evidence.

---

### D10 — Self-hosted CI runner toolchain drift — RE-BROKEN 2026-07-02 (was RESOLVED 2026-06-19)

**Re-break (2026-07-02, run 28597659598, commit `ae1884f` — docs/design-system-only, no Swift).** The predicted failure mode arrived, in a new costume: `Device Test (MacBook self-hosted)` now dies at xcodebuild startup with `CoreSimulator is out of date. Current version (1155.4.0) is older than build version (1166.0.0)` (DVTCoreSimulatorAdditionsErrorDomain code 3). Xcode-beta updated but the Mac's CoreSimulator framework didn't — exactly the caveat below. The hosted macos-26 job on the same SHA is green, so this is **runner-infra, not code**. Local op for David: install pending macOS/Xcode-beta component updates on the MacBook (or `sudo xcodebuild -runFirstLaunch`), then re-run the job.

**Original 2026-06-19 incident (`simctl` not found) — resolved; kept as history:**
**Effort:** S (a couple of local commands on the runner machine) · **Priority:** P2 — precondition for on-device golden-test work

**Symptom.** The `Device Test (MacBook self-hosted)` CI job fails at its first step, "List available iPad simulators", with `xcrun: error: unable to find utility "simctl", not a developer tool or in PATH`. It dies before compilation. The hosted `Build & Test — iPad Simulator (macos-26 / Xcode 26)` job builds and runs the full suite on the same SHA and is green — so a red overall badge from this is **runner-infra, not code** (first observed on the docs-only commit `3f9cda3`, 2026-06-19).

**Root cause.** The self-hosted MacBook's active developer directory is unset or points at CLT-only / a missing toolchain, so `xcrun simctl` can't resolve. Prior runs were green through 2026-05-31, so something changed on that machine since (Xcode path, OS update, or toolchain removal).

**Fix (local op on the runner machine — David runs it, NOT a claudebox task).** The runner has **Xcode-beta**, not release Xcode — `/Applications/Xcode.app` does not exist on that machine, only `/Applications/Xcode-beta.app`. What worked (2026-06-19):
```
sudo xcode-select -s /Applications/Xcode-beta.app/Contents/Developer
sudo xcodebuild -license accept
```
After which `xcrun simctl list devices` resolved (iOS 26.5 sims present) and `xcode-select -p` confirmed the beta path.

**Caveat (keep visible).** The runner now builds against a **BETA toolchain**. This will break again the same way whenever Xcode-beta updates/relocates or a release Xcode is installed without repointing. The durable fix is to keep `xcode-select` pointed at whatever Xcode is actually installed (or install release Xcode for stability).

**Priority flag.** This is a **precondition for the planned geometry golden-test / characterization work**: any golden test that depends on the on-device runner cannot be trusted until the runner is healthy. Fix before building the golden-test net — not necessarily before then.

---

## 5. POST-THESIS

These are worthwhile additions once the thesis ships. None of them is a thesis-blocker.

### F1 — App Store readiness pass
**Effort:** L · **Priority:** P1 (post-thesis)

Privacy Manifest shipped 2026-07-07 (`UserDefaults` CA92.1 + file-timestamp C617.1 for the container writes; CoreML has no required-reason category, so nothing to declare there). `ITSAppUsesNonExemptEncryption=NO` shipped the same day. Remaining: app icon set at every required size. iPad screenshots (5–7 stills covering Schule / Werkstatt / Fortschritte / Eltern-Dashboard). Marketing copy in German + English. App Store Connect "Privacy Practices" section: "Daten werden auf dem Gerät gespeichert; keine Übertragung." TestFlight build with crash-reporting opt-in.

### F2 — Lowercase letters + diacritics complete
**Effort:** XL (subsumes T1's full-alphabet scope) · **Priority:** P1 (post-thesis if T1 ships demo set only)

26 lowercase + Ä Ö Ü ß as full citizens. ~30 letters × 2–3 hours each = 60–90 person-hours.

### F3 — CloudKit sync
**Effort:** L · **Priority:** P1 (post-thesis)

A child using the app on multiple iPads should see unified streak + progress. Implement as a CloudKit-backed sync that pushes `ProgressRecord` and `StreakRecord` snapshots after each phase completion. Privacy: zone-per-participant, no PII, opt-in at first launch. Depends on F1. (Scaffolding for this — `CloudSyncService` protocol + `NullSyncService` + `SyncCoordinator` — was removed from `main` to drop dormant code; reintroduce together with the real CloudKit conformer.)

### F4 — Teacher dashboard (multi-child)
**Effort:** L · **Priority:** P2

Per-classroom view that shows N children's progress side-by-side. Auth via "School Code" (a 6-letter shared secret per teacher). Read-only initially; later add per-child homework assignment. Depends on F3.

### F5 — Numbers + basic punctuation
**Effort:** M · **Priority:** P2

Add `0–9` and the period/comma/question-mark glyphs. Infrastructure is letter-agnostic; ~12 new bundled glyphs.

### F6 — Additional cursive scripts
**Effort:** L · **Priority:** P2

The `SchriftArt` enum has five cases; only Druckschrift (Primae) and Schreibschrift (Playwrite AT) are bundled. Add Grundschrift, Vereinfachte Ausgangsschrift, and Schulausgangsschrift once a license-compatible font ships. The code path is already in place — just unblock with font licensing.

### F7 — Apple Watch streak companion
**Effort:** M · **Priority:** P3

A single complication that shows the current streak. Tapping opens the Schule world. WatchKit extension + WCSession to read `streak.json` from the App Group. Depends on F1.

### F8 — Mac Catalyst
**Effort:** M · **Priority:** P3

`Package.swift` already targets `macOS 15.0`. Polish keyboard mappings (arrow keys for letter nav, Return to advance) and ship a Catalyst build. Depends on F1.

### F9 — Localization beyond German
**Effort:** M · **Priority:** P3

Architecture is German-only by design (curriculum-specific). For German-speaking children abroad, English UI labels with German letter content might help bilingual classrooms. Wrap UI strings in `Localizable.strings`; ship `de` (canonical) and `en` (UI only — letter content stays German).

### F10 — Switch Control + AssistiveTouch overlay
**Effort:** S–M · **Priority:** P3

For motor-impaired children, expose the direct-phase dot tap as a Switch Control target and render a parallel "Switch Control hint" overlay that highlights the next-expected dot in high contrast.

### F11 — iOS 27 SDK move
**Effort:** S–M · **Priority:** P1 (post-pilot; hard deadline if the App Store mandates the iOS 27 SDK, projected ~April 2027 — unconfirmed as of 2026-07-07)

Per the 2026-07-07 readiness audit the app already satisfies both mandatory iOS 27 migrations (never used `UIDesignRequiresCompatibility`; pure SwiftUI App lifecycle), uses none of the reported deprecations (`UIScreen.main`, SceneKit), and no AVAudioSession / AVSpeechSynthesizer deprecations surfaced — `AudioEngine.swift` is unthreatened. The move is therefore a toolchain bump, gated on:
- **Xcode 27 stability** — early betas crash the compiler; there is a known inliner crash with exactly our configuration, `-default-isolation MainActor` + `-O` (swiftlang/swift#88173). **Verify a Release build, not just Debug CI, before adopting.**
- **CI availability** — no `macos-27` hosted runner and no Xcode 27 on the `macos-26` image yet.
- Optional modernization to fold in: Icon Composer layered `.icon` (current icon is the classic PNG light/dark/tinted set — still works) and a String Catalog if F9 localization happens.

### F12 — Xcode MCP bridge *(declined 2026-08-15; revisit post-pilot)*
**Effort:** S to adopt · **Priority:** P3 (post-pilot only)

An Xcode MCP bridge would let a session drive builds / tests / simulators directly instead of shelling out to `xcodebuild`. **Declined for now**, and the reason is structural rather than a matter of taste: this project exposes **two build surfaces** — the SPM package (`Package.swift` → `PrimaeNative`, where `PrimaeNativeTests` actually lives) and `Primae/Primae.xcodeproj` (three schemes) — and a bridge binds to one workspace at a time. A bridge pointed at the wrong surface reports green for a target nobody meant to validate, and that failure is silent: a green is a green. Not an acceptable risk while the study configuration is frozen and heading into device validation, where a false green propagates straight into the pilot.

Conditions for revisiting, after the pilot has run:
- The bridge can be pinned explicitly to a named workspace **and** scheme, and that pin is checked in — not inferred per session.
- It reports which surface it built, in its output, on every invocation.
- The `xcodebuild` invocations in this file and CLAUDE.md remain the documented fallback, so a bridge failure degrades to the known-good path.

**If adopted, it must be declared in a tracked `.mcp.json` at the repo root — never in `~/.claude.json`.** A user-level registration is invisible to the repo, unreviewable in a diff, and would not travel with a fresh clone: two sessions on the same commit could then be validating different targets with no record of the difference.

---

## Recommended ordering for the next sprint

The at-a-glance table at the top of this file is the authoritative version. Repeated here as a flow:

1. **P6 phoneme recordings** — studio recording (human voice) per `docs/SOUND_PRODUCTION_SPEC.md` + drop-into-bundle; no device needed.
2. **U5 + U10 device validation** — single iPad session: 30 minutes for the Pencil 2 squeeze check, 2–3 hours for the VoiceOver walkthrough. Get these out of the way before a thesis reviewer ever opens the app.

**D8 canvas redraw profile** is post-thesis polish — schedule once there's classroom-data evidence of a need (or an Instruments hint of a problem). **F1–F11** are post-thesis full features.

---

_Update this file by removing rows as they ship, not by adding ✅ markers — the deferred / open list should always read as a forward-looking work log. Shipped items live in commit history._
