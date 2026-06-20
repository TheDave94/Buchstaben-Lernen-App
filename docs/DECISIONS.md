# Decisions — Primae pilot study

**Purpose.** The single decision ledger for the pilot study: locked decisions, open design decisions (D-series), their evidence bases, and the design constraints that govern them. Read this for *why* the pilot is shaped the way it is.

Companion docs: `docs/ROADMAP.md` holds the *work* (pilot freeze items H1–H6, known issues/residuals); `docs/PROJECT_STATUS.md` holds the *capability census*; `docs/SOUND_PRODUCTION_SPEC.md` holds the sound-asset *production procedure*. This file holds *decisions*. (Consolidated from the former `PILOT_READINESS.md`, 2026-06-20.)

**Study design (locked 2026-05-29).** Three-arm between-subjects pilot: phoneme sonification / engagement-matched arbitrary-sound / silent control. N≈40 kindergarten/Vorschule. Single session 10–20 min. Sound-off post-test. Framed as a pilot throughout.

**Governance (David, 2026-05-30).**
- No in-app consent / minor-assent UX required; KUG ethics does not require committee approval for this pilot. → consent UX is NOT a freeze item.
- All design decisions are David's; supervisors expected to follow sound reasoning (no external approval gate). Quality control is the soundness of the design itself — there is no committee backstop, so the reasoning must hold.

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

## Open design decisions (David's, no external gate)

| # | Decision | Why it matters | Status |
|---|----------|----------------|--------|
| D2 | Arbitrary-sound arm design: what IS the engagement-matched, non-phonemic, coupling-matched control loop? | A wrong control confounds the central phoneme contrast — no committee backstop. Must be loopable + speed-couplable; must run the identical coupling path (matching discipline). Liking-match informed by the listening study. | RESOLVED 2026-06-20 — **distinct abstract sound per letter** (structure decided; asset *design* is the Groß-Vogt execution ask, not the decision). See *D2 — RESOLVED* below. |
| D3 | Post-test outcome design: what each of the 3 modes measures; scoring; recognition distractor choice; production prompt (NB: a sound prompt in a sound-off test is a contradiction — resolve). Which is the PRIMARY outcome. | Defines what the study measures. | OPEN — prime Seither-Preisler item |
| D4 | Which outcomes to RUN in the pilot. Build-all-three decided (H6); *running* all three in a 10–20 min kindergarten session is a methods question (attention budget; multiple-comparison load on N≈40). Settings toggle moves this to pilot-run time; does not dissolve it. | Session feasibility + analysis validity | Build all three (decided); run-selection deferred |
| D6 | Stop-consonant under continuous looping. The loop+speed-couple principle works naturally for continuants (/m/, /f/, /l/ stretch and loop). Stops (/b/, /k/, /t/) have no steady state to loop/stretch. What does the phoneme arm play for stops? (Also applies to the arbitrary loop.) Intersects the no-schwa spec. | Phoneme-arm fidelity for ~⅓ of letters | OPEN — sound-domain, likely Groß-Vogt |
| D7 | Pitch coupling. The `pitchCents` knob is wired but undriven. The thesis prose leaves the acoustic parameter unspecified, so adding pitch is **fidelity-permissible** (neither described nor contradicted) — IF applied identically across phoneme+arbitrary arms (matching discipline). | Intervention enrichment with documented multi-parameter caveat | RESOLVED 2026-05-30 — **pitch IN the pilot.** Rationale: (a) fidelity-permissible per thesis prose; (b) closest same-age precedents — Ecalle 2021 (5yo, trajectory→pitch+brightness, sonification group beat controls) and Groß-Vogt 2024 (first-graders, pen-y→pitch) — both used pitch without reported harm; both FULL-read and already cited in §2.6; (c) no contraindication in the coupling sweep (see *Evidence base for D7* below); (d) already wired (`pitchCents` knob). **CONDITIONS (non-negotiable):** (1) **matching discipline** — identical pitch coupling in BOTH phoneme and arbitrary arms, only the audio file differs (the shared `setAdaptivePlayback` path makes this automatic); (2) **honest framing** — in Ch.5/methodology, pitch is a design choice consistent with precedents, NOT an evidence-backed component; (3) **documented limitation** — the pilot intervention is a three-parameter coupling (rate+pan+pitch), so an effect cannot be attributed to any single parameter; single-parameter isolation is an explicit future-study direction. |
| D7-sub | Pitch mapping target — `pitchCents` is wired but what movement parameter drives it is undecided (y-position? curvature? something else?). Matched across arms per D7 condition (1). | Defines the pitch axis of the three-parameter coupling | OPEN — decide at build time |

> Freeze items (H1–H6) that these decisions gate now live in `docs/ROADMAP.md` → *Pilot study — freeze items*.

---

## D2 — RESOLVED (2026-06-20): arbitrary arm = distinct abstract sound per letter

> **Production detail: see [`docs/SOUND_PRODUCTION_SPEC.md`](SOUND_PRODUCTION_SPEC.md)** — the procedure companion for producing both pilot sound-asset sets (phonemes + abstract sounds) to one standard. This ledger keeps the *decision/status*; the spec keeps the *how*.

The arbitrary-sound control arm is a DISTINCT, NON-REFERENTIAL abstract sound per letter — structurally parallel to the phoneme arm (unique sound per letter), differing from it in exactly ONE dimension: whether that per-letter sound is a phoneme or a meaningless designed sound.

Rationale: This isolates the variable of interest (phonemic vs. non-phonemic coupled sound) while controlling for letter-DISTINCTNESS. A single shared sound (rejected) would confound non-phonemic-ness with non-distinctness — the phoneme arm gives each letter a distinct anchor, so the control must too. A small assigned bank (rejected) introduces un-pre-registered sound-collision variance. Letter-associative (Affe/Auto, rejected) risks teaching the letter via Anlaut association (covert second intervention) AND can't cover the full alphabet coherently (no unambiguous associative sound exists for many letters).

Downstream commitments (NOT yet done):
- ~[N] abstract sounds to DESIGN (one per letter in the pilot set): non-referential, mutually distinct, distinct from the phonemes, and sustainable under continuous time-stretch/loop (same steady-state constraint as the phonemes — D6-adjacent).
- ENGAGEMENT-UNIFORMITY is the validity burden: the set must be perceptually matched (no sound accidentally more/less engaging than the phonemes or each other). This is where Groß-Vogt's sonification expertise applies — D2's DECISION is made; the EXECUTION (designing perceptually-matched sounds) is the Groß-Vogt ask.
- ACCIDENTAL-MEANING AUDIT before the pilot: naive-ear pass over the full set to flag any sound that evokes a word/animal/object (which would re-introduce Anlaut contamination). Pre-pilot QA step.
- H4 wiring (drop-in once sounds exist): the arbitraryAudioFiles slot is built and waiting (commits 279d553/b212e82); H4 sources the assets into it.

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

## Evidence base for D7 (pitch RESOLVED)

**Same-age precedents (FULL-read, already cited in thesis §2.6):**
- **Ecalle et al. 2021** (Hum Mov Sci): 5-year-olds, sonification group (trajectory → pitch + brightness) outperformed controls on letter learning. Pitch present in the intervention, no reported harm.
- **Groß-Vogt et al. 2024**: first-graders, pen y-position → pitch mapping. Pitch present, no reported harm.

**Adult-only coupling-sweep papers (abstract-only):** Maslovat, Effenberg & Schmitz 2018, Ghai 2019, Frid. Surveyed at abstract level for the evidence-AGAINST question; LOW/VERY-LOW Ch-2-relevance.

**Honesty note.** The verdict "keep speed-coupling; pitch defensible" rests on an **abstract-level literature survey** (adequate for the evidence-AGAINST question, since a contraindicating study would surface in its abstract), **NOT full reads**. The same-age justification (Ecalle 2021, Groß-Vogt 2024) IS full-read (already cited in the thesis). The adult pitch papers (Effenberg & Schmitz 2018, Ghai 2019) are abstract-only and would need full reads only if Ch.5 methodology cites them.

**Conclusion.** No contraindication for adding pitch to the coupling. Pitch joins rate + pan as the third coupling parameter, under the three D7 conditions (matching discipline, honest framing, documented multi-parameter limitation).

---

## Related separate workstreams (not the Primae freeze)

**Listening study — a SEPARATE app David will build.** Not a Primae mode. Tests non-phoneme sounds; out of scope for the Primae freeze.
- **Apparatus:** smiley scale (liking measure); possibly voiceover questions triggering speech-to-text OR audio recording to capture the child's spoken answer (for association/connection judgments). NB: STT on young children's speech is unreliable (phonology, noise, single-word utterances) — audio-record-for-later-human-coding is likely the safer primary method, STT a nice-to-have.
- **Design:** varies sound-to-letter **association strength** along a continuum (clearly-related → loosely-related) to find how loose a connection children still accept as "belonging" to the letter; **liking** measured orthogonally (not assumed to track association); small letter set; across sound categories (phoneme / nature-environment-animal / machine-city-instrument).
- **Origin:** David's original vision was multiple letter-associable sound categories per letter; deferred from the app because clearly-associable non-phoneme sounds couldn't be reliably sourced. The phoneme remains Primae's (and the pilot's) primary sound; other categories are an **evidence-gated future offering** contingent on this study.
- **Relationship to the pilot:** the liking data feeds the arbitrary-arm (D2) engagement-match selection. Note the control wants high liking-match; association-strength is a separate axis (a strongly letter-associable non-phoneme control would shrink the phoneme contrast — relevant to a future richer study, not this pilot's control).
- **Measurement-design caveat:** graded association judgments by young children are a real validity challenge (acquiescence bias, etc.) — a Seither-Preisler item when that app is built.
- **Status:** own document when built; this is the brief cross-reference.

**Thesis-relevant papers (deliberate §2.1/§2.2 recon + citation-candidate survey, 2026-05-30):**
- **Bara-2018, Zemlock-2018:** CONFIRMED REDUNDANT for Chapter 2 (existing cites cover their points). They remain load-bearing in this ledger only — Bara-2018 → D5 evidence base; Zemlock-2018 → production-helps frame.
- **Coupling-sweep papers (Maslovat, Effenberg & Schmitz 2018, Ghai 2019, Frid):** LOW/VERY-LOW Ch-2-relevance, NOT Ch-2-bound.
- **Seyll & Content 2022:** the survey's ONE find — integrated into §2.2 ¶4 as a single-sentence qualification of the variability prediction (committed separately in the thesis repo, `35a0419`).
- **No remaining Chapter-2 citation work pending.**

---

## Out of scope for the freeze
- Consent/assent UX (governance).
- Listening study (separate app, above).
- Post-thesis features (F1–F10, gated on thesis ship per ROADMAP).
- U5 Pencil-2 squeeze device validation (P3), U10 VoiceOver walkthrough (P3) — pre-existing P3, not pilot-blocking.

---

## Sequencing

No human-gated blockers remain (no ethics/committee dependency). Everything is build-David-controls or design-David-decides. The HIGH freeze items (arms H1–H3, arbitrary-sound H4+D2, P6 H5, post-test H6+D3 — all in `docs/ROADMAP.md` → *Pilot study*) are pilot-blocking. The `direct` cut (D5) is a separate scoped change. The design decisions D2 (arbitrary sound) and D3 (post-test outcomes) gate their respective builds and should be settled well — D2/D6 are the prime Groß-Vogt sanity-checks (sound domain); D3 is the prime Seither-Preisler item. The pitch question (D7) is RESOLVED (pitch IN the pilot, under three conditions); D7-sub (what movement parameter drives pitch) is open and decided at build time.
