# Pilot Readiness — Primae App

**Purpose.** The authoritative map of what the Primae app needs to be a valid instrument for the pilot study. Read this first when resuming app-side work. Distinct from PROJECT_STATUS.md / ROADMAP.md, which track *engineering* work (bake pipeline, polish, P6 audio) but do NOT track *pilot-study readiness*. Last consolidated 2026-05-30.

**Study design (locked 2026-05-29).** Three-arm between-subjects pilot: phoneme sonification / engagement-matched arbitrary-sound / silent control. N≈40 kindergarten/Vorschule. Single session 10–20 min. Sound-off post-test. Framed as a pilot throughout.

**Governance (David, 2026-05-30).**
- No in-app consent / minor-assent UX required; KUG ethics does not require committee approval for this pilot. → consent UX is NOT a freeze item.
- All design decisions are David's; supervisors expected to follow sound reasoning (no external approval gate). Quality control is the soundness of the design itself — there is no committee backstop, so the reasoning must hold.

---

## What the app already is (capability census, 2026-05-30)

The app is more complete and sophisticated than a "freeze-triage" frame suggested. The completeness is in the **generic letter-learning dimension**; the **thesis-specific dimension** (pilot arms, phoneme content, sound-off post-test) is the shallow end where the remaining work lands.

**The core sonification mechanism already exists and is the thesis's mechanism.** This is the central census finding and it corrected an earlier mistaken belief that the audio was merely event-triggered playback. The reality:
- `AudioEngine` (AVFoundation: `AVAudioEngine` + `AVAudioPlayerNode` + `AVAudioUnitTimePitch`) plays a **seamlessly looping** audio file with **real-time continuous parameter control**.
- `setAdaptivePlayback(speed:horizontalBias:)`, driven every touch-update by `TouchDispatcher`, maps **smoothed trace velocity → time-stretch rate** (0.5×–2.0×, pitch preserved) and **canvas-x + pencil azimuth → stereo pan**.
- During `guided`/`freeWrite` tracing, the child's writing movement continuously shapes the looping sound in real time. Code comment frames it correctly: "the letter sound is the phonemic anchor for the glyph, not Schmidt & Lee guidance feedback."
- This **is** the thesis's "continuous, trace-coupled sound." David confirmed it is the intended core design principle from the beginning: a loopable sound whose playback speed couples to writing speed, plus a panning mapping. No rebuild needed — the hard part is done as designed.
- Minor precision note: the audio is continuous *during active stroking* but gates off below a velocity threshold and on pencil-lift (activation threshold 22). "Continuous during tracing" is the precise claim; bare "continuous" slightly overstates (relevant only as a possible thesis-prose precision tweak, not a fidelity gap).

**Reusable infrastructure (arm-shape-agnostic, confirmed):**
- Deterministic UUID-modulo condition assignment (stable across sessions) + researcher override; enrollment gating (`isEnrolled`/`enrolledAt`) with pre-enrollment filtering; per-arm metric stratification in the exporter; CSV/TSV/JSON export with `# participantId=` header.
- Condition-stamped Codable records (`PhaseSessionRecord`, `LetterAccuracyStat`, `SessionDurationRecord`, `DashboardSnapshot`), with a 4-overload `recordPhaseSession` pattern that is the established precedent for backward-compatible record extension.
- `FreeWriteScorer.score(tracedPoints:reference:)` — blank-canvas production scorer, decoupled from the guidance UI (scores from points + reference, no UI dependency). Returns a 4-dim `WritingAssessment` (Form/Tempo/Druck/Rhythmus, Marquardt & Söhl 2016).
- `RetrievalPromptView` — already a recognition mini-test (target + distractors + audio cue + `onAnswer(tapped, correct)` callback).
- `LetterScheduler` (priority/`fixedOrder`); `SettingsView` @State+UserDefaults+Toggle pattern; CoreML `LetterRecognizer` (53-class, shipping in freeWrite/Werkstatt).
- `AudioEngine.pitchCents` — independent pitch knob, **wired but currently undriven during tracing** (only `rate` is mapped). Available headroom; intentionally unused (see D7).

**Not problems (confirmed):** zero TODO/FIXME in the Swift codebase; tracing/input/scheduling spine mature and works end-to-end; the audio engine is the thesis mechanism, not a gap.

---

## The governing constraint (from the thesis prose, §2.6)

The thesis commits the app's audio to four things and **deliberately leaves the acoustic coupling parameter unspecified**: content = the **phoneme**; timing = **during tracing / real-time / continuous**; coupling = **to the movement of the trace** (parameter unnamed — "velocity-coupled" was deliberately edited out to "trace-coupled"); form = **Anlaut/no-schwa** (sustained continuants, clean-burst stops).

**The load-bearing constraint (§2.6, the matching discipline):** for the phoneme-vs-arbitrary contrast to isolate phonemic content, the phoneme arm and the arbitrary-sound arm must be **matched on every property of the audio — timing, and in particular any coupling of the sound to the movement of the trace — so the only difference is whether the sound is the letter's phoneme.**

Implications:
- Whatever the coupling is (current rate+pan, or rate+pan+pitch), it must run through the **same shared code path** for both the phoneme and arbitrary arms. The app's architecture already supports this: both arms call the same `setAdaptivePlayback`; only `activeAudioFiles(for:)` returns different files. The shared-path architecture and the matching discipline align perfectly.
- The silent arm has no audio regardless.

---

## Locked decisions

- **D1 — Arm structure: audio-only-varies.** Every participant gets the SAME pedagogical flow; the three arms differ ONLY in audio (phoneme / arbitrary-sound / silent). NOT a crossed pedagogical×audio design. Simplifies the arm build to swap-enum + branch-audio.
- **D5 — `direct` phase: CUT (move to three-phase `observe → guided → freeWrite`).** Decided on a six-paper both-sides evidence read (see "Evidence base for D5"). The pilot will run on the three-phase app — David's standard is methodological soundness, so the studied artifact should match the considered design. Execute as a separate, scoped, tested change. Cut blast-radius: ~12 Swift files + 2 docs + tests; sharpest edge is Codable rawValue backward-compat (preserve `case direct = 1` as deprecated-but-decodable, per the existing `ThesisCondition` precedent). NOT pilot-blocking either way (flow held constant across arms regardless of phase count).

---

## Freeze items — HIGH (pilot cannot run as designed without these)

| # | Item | Type | Reuse / notes |
|---|------|------|---------------|
| H1 | New `PilotAudioCondition: { phoneme, arbitrarySound, silent }` enum + assignment. Pedagogical flow held constant (D1), so this is the audio dimension only. | Build | Slots into existing UUID-modulo assignment + override + enrollment + per-arm exporter. |
| H2 | Arm-aware audio selection — `activeAudioFiles(for:)` currently branches on the `enablePhonemeMode` Settings toggle; must branch on pilot arm. | Build | Single chokepoint: `if arm == .silent { return [] }`; phoneme → phoneme files; arbitrary → arbitrary files. One-function change. Both audio arms keep the identical shared `setAdaptivePlayback` coupling (matching discipline). |
| H3 | Silent-arm codepath — no arm/mode-controlled silent path exists; today silence happens only by omission when an asset is missing. | Build | Cleanest via H2 (return `[]` short-circuits the playback path). Do NOT touch AudioEngine.swift (stable/fragile). |
| H4 | Arbitrary-sound asset set — does not exist. Engagement-matched, coupling-matched, non-phonemic looping audio. **Design not yet decided (D2).** Must be loopable + speed-couplable like the phoneme loops. | Design + assets | Liking-match informed by the separate listening study (below). |
| H5 | P6 phoneme recordings — 0/90 (30 letters × 3 takes), no-schwa spec, ElevenLabs pipeline ready; 7 letters currently have non-phoneme audio. | Assets | XL per stocktake. The sonification engine works; it has almost nothing to sonify yet. |
| H6 | In-app sound-off post-test — **build all three, selectable in Settings:** (a) recognition, (b) production, (c) letter-sound. No test-mode flow exists today (app is all learning/practice). | Build | Strong reuse: `FreeWriteScorer` (production, as-is), `RetrievalPromptView` (recognition + hear→tap letter-sound, as-is), `LetterScheduler` (letter set), Settings-toggle pattern (selection), new `PostTestResult` Codable record (overload-with-defaults pattern). MUST-BUILD-NEW: a `PostTestController` orchestrator (~100–200 lines, parallel to `LearningPhaseController`, NOT a 5th LearningPhase case); distractor-picker; researcher start-screen. Audio suppression via the H2 chokepoint. |

## Open design decisions (David's, no external gate)

| # | Decision | Why it matters | Status |
|---|----------|----------------|--------|
| D2 | Arbitrary-sound arm design: what IS the engagement-matched, non-phonemic, coupling-matched control loop? | A wrong control confounds the central phoneme contrast — no committee backstop. Must be loopable + speed-couplable; must run the identical coupling path (matching discipline). Liking-match informed by the listening study. | OPEN — prime Groß-Vogt (sound domain) sanity-check |
| D3 | Post-test outcome design: what each of the 3 modes measures; scoring; recognition distractor choice; production prompt (NB: a sound prompt in a sound-off test is a contradiction — resolve). Which is the PRIMARY outcome. | Defines what the study measures. | OPEN — prime Seither-Preisler item |
| D4 | Which outcomes to RUN in the pilot. Build-all-three decided (H6); *running* all three in a 10–20 min kindergarten session is a methods question (attention budget; multiple-comparison load on N≈40). Settings toggle moves this to pilot-run time; does not dissolve it. | Session feasibility + analysis validity | Build all three (decided); run-selection deferred |
| D6 | Stop-consonant under continuous looping. The loop+speed-couple principle works naturally for continuants (/m/, /f/, /l/ stretch and loop). Stops (/b/, /k/, /t/) have no steady state to loop/stretch. What does the phoneme arm play for stops? (Also applies to the arbitrary loop.) Intersects the no-schwa spec. | Phoneme-arm fidelity for ~⅓ of letters | OPEN — sound-domain, likely Groß-Vogt |
| D7 (deferred) | Pitch coupling. The `pitchCents` knob is wired but undriven. The thesis prose leaves the acoustic parameter unspecified, so adding pitch is **fidelity-permissible** (neither described nor contradicted) — IF applied identically across phoneme+arbitrary arms (matching discipline). Concern is attentional load on young children (Merritt mechanism), NOT fidelity. | Possible intervention enrichment | DEFERRED pending the auditory-complexity evidence sweep; David open to it; leaning toward reserving for a FUTURE study to keep the pilot intervention clean and interpretable |

---

## Evidence base for D5 (`direct` cut)

Six papers read in full (both sides):
- **Merritt et al. 2020** (Frontiers): instructed stroke order ≤ self-directed for <4.5yo (recognition, novel symbols); effect gone by 4.5yo — below the pilot's ~6yo target. Off-population caution, not a rebuttal.
- **Bara & Bonneton-Botté 2018** (Percept Mot Skills): kindergarten (5y4mo) controlled trial. Visuomotor (motor practice of direction) > visual (arrows-only ≈ `direct`'s shown-not-practiced cue). The arrows-only group LOST. Benefit came from *practicing* direction, not being *shown* it → the work lives in `guided` (tracing), not `direct`.
- **Berninger et al. 1997** (J Educ Psychol): numbered-arrow stroke cues (≈ `direct`) effective only COMBINED with writing-from-memory, not alone; outcomes fluency/composition, not recognition; at-risk first-graders. Supports cues-fused-with-production, not a standalone cue phase.
- **Thibon et al. 2018** (Acta Psychologica; the app's own `direct` citation): purely DESCRIPTIVE (6–9yo kinematics, per-stroke motor programs); no efficacy claim. App §4.4 honestly says so.
- **Zemlock et al. 2018** (Reading and Writing): production > viewing for recognition; any symbol production helps (not stroke-order-specific). Supports having a production phase (`guided`/`freeWrite` already do).
- **Parkinson & Khurana 2007** (abstract only): stroke order primes recognition in ADULTS; may not transfer to children still varying their order.

**Conclusion:** No controlled evidence that a standalone, show-don't-practice, pre-tracing stroke-cue phase aids early letter recognition in the ~6yo regime. The well-supported finding is "motor production helps" — which `guided`/`freeWrite` already deliver. The two closest-analog conditions (Bara arrows-only, Berninger cue-alone) underperformed. By the best-practice standard, `direct` does not earn its place → cut to three-phase.

---

## Related separate workstreams (not the Primae freeze)

**Listening study — a SEPARATE app David will build.** Not a Primae mode. Tests non-phoneme sounds; out of scope for the Primae freeze.
- **Apparatus:** smiley scale (liking measure); possibly voiceover questions triggering speech-to-text OR audio recording to capture the child's spoken answer (for association/connection judgments). NB: STT on young children's speech is unreliable (phonology, noise, single-word utterances) — audio-record-for-later-human-coding is likely the safer primary method, STT a nice-to-have.
- **Design:** varies sound-to-letter **association strength** along a continuum (clearly-related → loosely-related) to find how loose a connection children still accept as "belonging" to the letter; **liking** measured orthogonally (not assumed to track association); small letter set; across sound categories (phoneme / nature-environment-animal / machine-city-instrument).
- **Origin:** David's original vision was multiple letter-associable sound categories per letter; deferred from the app because clearly-associable non-phoneme sounds couldn't be reliably sourced. The phoneme remains Primae's (and the pilot's) primary sound; other categories are an **evidence-gated future offering** contingent on this study.
- **Relationship to the pilot:** the liking data feeds the arbitrary-arm (D2) engagement-match selection. Note the control wants high liking-match; association-strength is a separate axis (a strongly letter-associable non-phoneme control would shrink the phoneme contrast — relevant to a future richer study, not this pilot's control).
- **Measurement-design caveat:** graded association judgments by young children are a real validity challenge (acquiescence bias, etc.) — a Seither-Preisler item when that app is built.
- **Status:** own document when built; this is the brief cross-reference.

**Thesis-relevant papers (separate acquire-read-verify-cite into the closed, CI-green thesis):** Bara-2018 → §2.1 candidate (Bara/Gentaz lineage); Zemlock-2018 → §2.2 candidate (James lab, strengthens production-over-procedure); Merritt-2020 → optional methodological-cautions note.

---

## Out of scope for the freeze
- Consent/assent UX (governance).
- Listening study (separate app, above).
- Post-thesis features (F1–F10, gated on thesis ship per ROADMAP).
- U5 Pencil-2 squeeze device validation (P3), U10 VoiceOver walkthrough (P3) — pre-existing P3, not pilot-blocking.

## Known doc-hygiene fix (independent of the freeze)
- `docs/APP_DOCUMENTATION.md` line 1819 cites Thibon with DOI `10.1016/j.actpsy.2017.11.014` — a typo; the correct DOI is `10.1016/j.actpsy.2017.12.001`. (The §4.4 reference at line 633 has no DOI.) Fix whenever convenient.

## Sequencing
No human-gated blockers remain (no ethics/committee dependency). Everything is build-David-controls or design-David-decides. The HIGH items (arms H1–H3, arbitrary-sound H4+D2, P6 H5, post-test H6+D3) are pilot-blocking. The `direct` cut (D5) is a separate scoped change. The design decisions D2 (arbitrary sound) and D3 (post-test outcomes) gate their respective builds and should be settled well — D2/D6 are the prime Groß-Vogt sanity-checks (sound domain); D3 is the prime Seither-Preisler item. The pitch question (D7) is deferred to the auditory-complexity evidence sweep.
