# SOUND_PRODUCTION_SPEC.md — Pilot sound-asset production

> **Status 2026-09-04 — partly superseded (supervisor ruling C3-5: the
> document is stale, not the app).** This procedure was written for the
> full-alphabet phoneme set and for an abstract-sound set that PREDATE
> the five-letter study design (A, F, I, L, M; 2026-07-06) and the
> spatial third arm (same date; DECISIONS D2 superseded). What the pilot
> needs from this document is §3 (shared constraints), §4.1 (no-schwa
> Anlaut rule) and §4.3 (recording checklist) applied to FIVE recordings:
> `A_phoneme<n>`, `F_phoneme<n>`, `I_phoneme<n>`, `L_phoneme<n>`,
> `M_phoneme<n>` in `Resources/Letters/<Letter>/`. The D6 stop-consonant
> question (§4.2) does not arise for these five. §5 (abstract set) and the
> "two sets to one standard" framing apply to the full-scale study's
> fourth arm (thesis Ch.7), not to the pilot. Since 2026-09-04 the app
> REFUSES to start a phoneme-arm study session while any of the five
> recordings is missing (ruling C3-6), so their absence cannot be missed.
>
> **Scope (original).** The working procedure for producing the two pilot sound-asset
> sets — the **phoneme** set (recorded) and the **abstract-sound** set
> (designed) — to one consistent technical and perceptual standard.
>
> **Companion to [`DECISIONS.md`](DECISIONS.md).** That file is the
> decision ledger (what was decided, what is open: D2, D6, D7, the
> listening study); the pilot work items (H1–H6) live in
> [`ROADMAP.md`](ROADMAP.md). This file is the *procedure* (how to produce
> the assets once those decisions allow). Decisions are referenced here,
> **not re-derived** — if a decision changes, it changes in DECISIONS and
> this doc follows.
>
> The matching discipline (§2.6 of the thesis / DECISIONS) is the
> spine of this whole document: the two sets must be identical on **every**
> audio property except one — whether the per-letter sound is a phoneme.
> Everything below exists to hold that single-difference invariant.

---

## 1. The two sets

| Set | Origin | Production owner | Why this origin |
|-----|--------|------------------|-----------------|
| **Phonemes** | **RECORDED** (human voice, studio) | David (recording) | A phoneme is a specific human speech sound; it must be voiced, not synthesised. **ElevenLabs was evaluated and rejected** — it is a text-to-speech / letter-name synthesiser, not built for *isolated-phoneme* production: prompted with a letter it returns the letter **name** or a word, not a sustained isolated phone (`/m/`, `/a/`), and offers no control over the no-schwa articulation the pilot requires (§4). The existing `scripts/generate_letter_audio.py` ElevenLabs path produces the **letter-name / word** population (`audioFiles`), which is a different asset class from the phoneme population. |
| **Abstract sounds** | **DESIGNED** (synthesis / sound-design) | Groß-Vogt (execution) | The D2 decision (one distinct non-referential sound per letter) is a *design* problem in the sonification domain. The **decision** is settled (see DECISIONS → *D2 — RESOLVED 2026-06-20*); the **execution** — designing a perceptually-matched, non-referential set — is the Groß-Vogt ask. |

Both sets ship into the same app audio pipeline and must therefore meet the
**same** technical format and the **same** coupling-survival constraints
(§2, §3).

---

## 2. Target format — CODE-CONFIRMED

These values were verified against the bundled assets and the audio engine,
not assumed. Sources cited inline.

| Property | Value | Verified against |
|----------|-------|------------------|
| Container / codec | **MP3 — MPEG-1 Audio Layer III**, CBR | `file` on bundled `A1.mp3`, `Mmmmm.mp3`, `Ffffff.mp3` |
| Bitrate | **128 kbps** | same |
| Sample rate | **44.1 kHz** | same |
| Channels | **Mono (Monaural)** — see §2.1, load-bearing | same |
| Tagging | ID3v2.4 (incidental) | same |
| Phoneme filename convention | **`<base>_phoneme<n>.<ext>`** (case-insensitive; matched by the `_phoneme` substring) | `LetterRepository.partitionPhonemeAudio` + `findAudioAssets`; comment at `LetterRepository.swift:336` and `:367` |
| Abstract filename convention | **TBD by H4** — suggested `<base>_arbitrary<n>.<ext>` to parallel the phoneme convention; the sourcing into `arbitraryAudioFiles` is the H4 wiring, not yet built | `Models.swift` (`arbitraryAudioFiles` field exists); `activeAudioFiles` returns it verbatim (`TracingViewModel.swift:835`) |

**Current state:** **zero** `_phoneme` files are bundled today (`find … -iname
'*_phoneme*'` → 0). The descriptive files in each letter folder (`A1.mp3`,
`Mmmmm.mp3`, `Affe.mp3`, …) are the legacy **letter-name / word** population
(`audioFiles`), not phonemes. Producing the phoneme set *is* closing the
H5/P6 gap.

### 2.1 Mono is load-bearing — CODE-CONFIRMED

The source files **must be mono**. Two independent lines of evidence agree:

1. **The bundled convention is already mono** — every phoneme-class `.mp3`
   inspected reports *Monaural*. (The lone `M/hmmm.wav` is a stereo PCM
   outlier and is *not* a phoneme-convention file.)
2. **The engine adds the pan itself.** The coupling sets
   `player.pan` on the `AVAudioPlayerNode` (`AudioEngine.swift:181`). Pan on
   a player node spatialises a **mono** source across the stereo field; a
   **stereo** source is instead treated as a left/right *balance*, which
   collapses the intended x-position spatialisation and breaks matching
   parity between the two arms. The signal chain is
   `player → AVAudioUnitTimePitch → mainMixerNode`
   (`AudioEngine.swift:84–87`), i.e. a single mono player feeding the
   stretch/pitch unit then the mixer.

> **Deliver mono. Do not deliver stereo and assume the engine will fold it.**

---

## 3. Shared constraints (both sets)

Every asset, phoneme or abstract, must satisfy all of these:

- **Loopable / steady-state.** The sound plays as a continuous loop while
  the child traces; it must have a stable steady-state region that loops
  indefinitely without a perceptible seam or evolving timbre. (The
  stop-consonant exception is D6 — §4.2.)
- **Survives the three-parameter coupling.** During tracing the loop is
  driven through — CODE-CONFIRMED at `AudioEngine.setAdaptivePlayback`
  (`:177–182`) + `TouchDispatcher.updateAdaptivePlayback` (`:285–302`):
  - **rate** — `timePitch.rate`, velocity → time-stretch, **clamped
    0.5×–2.0×** (`minPlaybackRate`/`maxPlaybackRate`), formant-preserving
    (`AVAudioUnitTimePitch`);
  - **pan** — `player.pan`, canvas-x mapped to ±1 **plus** a pencil-azimuth
    term (`cos(azimuth)·0.2`), clamped ±1;
  - **pitch** — `pitchCents` → `timePitch.pitch`. Wired but **not yet driven
    inside `setAdaptivePlayback`** (default 0); D7 (RESOLVED 2026-05-30) puts
    pitch *in* the pilot, and **what movement parameter drives it is D7-sub
    (open)**. Design every asset to survive a pitch shift regardless.

  The asset must still sound clean and intelligible across the full
  rate range and under pitch shift — no aliasing, no muddy artefacts at 0.5×,
  no chipmunk at 2.0×.
- **Consistent loudness.** Normalise every asset across **both** sets to one
  integrated-loudness target (recommend an LUFS target with a fixed true-peak
  ceiling) so no sound is incidentally louder/quieter — a loudness mismatch
  is an engagement confound (§5, §6).
- **Clean, seamless loop.** Trim at zero crossings; no click, pop, or
  breath at the loop boundary; no DC offset.
- **Child-appropriate.** Comfortable level, no startle transients, no harsh
  high-frequency content; pleasant over many repetitions.
- **The confirmed bundle format** (§2): mono, 44.1 kHz, MP3 128 kbps, named
  per convention.

---

## 4. Phoneme set (RECORDED)

### 4.1 The no-schwa Anlaut articulation rule

> **Playback-side normalisation (ruling AE-2, 2026-09-06).** The engine
> measures each file's RMS once at load and plays it at the gain that
> brings it to the bundled carrier's RMS (0.1463 full-scale, −16.7 dBFS;
> `AudioEngine+Loudness.swift`), clamped to ±18 dB and logged when the
> clamp bites. Per-letter loudness therefore cannot vary with the
> recording's level — but produce the takes at the loudness target
> anyway: a file that needs the clamp is a production defect.

Record the **isolated phone**, sustained, with **no trailing schwa and no
letter name**:

- ✅ `/aː/` (the vowel itself), `/fːː/`, `/mːː/`, `/lːː/`, `/sːː/`
- ❌ "Ah", "Eff", "Em" — that is the letter **name** (already covered by the
  `audioFiles` word/name population).
- ❌ "buh", "kuh", "tuh" — a consonant **plus a schwa vowel**. The schwa is a
  second speech sound; it contaminates the phoneme and (for stops) smuggles
  in a vowel the pilot is not coupling.

This is the single most important phoneme-recording rule: the arm's entire
validity is that the child hears the letter's **phoneme**, nothing more.

### 4.2 The D6 stop-consonant problem — OPEN, settle WITH Groß-Vogt first

Continuants (`/m/ /f/ /l/ /s/ /n/ /r/`, all vowels) have a steady state that
loops and time-stretches naturally — **record these now.** Stops (`/b/ /p/
/t/ /k/ /d/ /g/`) have **no steady state**: the sound *is* a transient burst,
so it cannot be looped or stretched the way a continuant can. This is **D6,
OPEN** in DECISIONS, and per that ledger it applies to **both arms**
(an abstract loop must also handle whatever the stop letters get).

Candidate handlings (decision is D6, not this doc — laid out so the
recording session can be planned):

| Option | What it is | Cost |
|--------|-----------|------|
| (a) Release + voicing | Record the burst + a short voiced tail; loop the tail | Risks re-introducing a schwa-like vowel (§4.1 tension) |
| (b) One-shot, un-looped | Play the stop once per proximity event, not as a loop | Breaks loop/stretch **parity** with continuants and with the abstract arm — a matching-discipline hazard |
| (c) Exclude stop-initial letters | Keep the pilot letter set to continuant-initial letters | Shrinks the letter set; must be justified in Ch.5 |
| (d) Engine special-case | Detect stops and drive the coupling differently for them | Adds an arm-asymmetric code path — highest matching risk |

> **Gate:** do **not** record the stop phonemes until D6 is settled **with
> Groß-Vogt**. Continuant phonemes are unblocked and can be recorded in the
> first session.

### 4.3 Recording-session checklist

- [ ] Quiet, treated room; consistent mic + distance + gain across the whole
      session (and re-create it if a second session is needed for stops).
- [ ] One speaker for the whole set (timbre consistency).
- [ ] Per phone: several takes; sustain continuants long enough to extract a
      clean steady-state loop region.
- [ ] **No schwa, no letter name** (§4.1) — monitor live; re-take any take
      that drifts into a name or a `+ə`.
- [ ] Capture mono (or fold to mono at export — never deliver stereo, §2.1).
- [ ] Continuants only this session unless D6 is already settled (§4.2).
- [ ] Post: trim to a seamless loop at zero crossings; normalise to the
      shared loudness target (§3); export to the confirmed format and the
      `<base>_phoneme<n>.<ext>` name (§2).
- [ ] After import, **re-run the phoneme-coverage census** (§7).

---

## 5. Abstract set (DESIGNED)

The decision is **D2 — RESOLVED 2026-06-20** (DECISIONS): *one
distinct, non-referential abstract sound per letter*, structurally parallel
to the phoneme arm and differing in exactly one dimension (phoneme vs.
meaningless designed sound). **This doc does not re-derive that decision** —
see the D2-RESOLVED note for the rationale and the rejected alternatives.

**Design constraints (the execution of D2):**

- **Non-referential — THE core requirement.** The sound must not evoke a
  word, animal, object, or action. Any referent re-introduces an Anlaut-style
  association and becomes a covert second intervention, collapsing the
  phoneme-vs-non-phoneme contrast.
- **Mutually distinct.** Each letter gets its *own* recognisable sound (this
  is what makes the set parallel to the phonemes — the control must give each
  letter a distinct anchor, not a shared one).
- **Distinct from the phonemes.** No abstract sound should be mistakable for
  a speech phone.
- **Continuant by design.** Build them as steady-state loopable textures, so
  **D6 is a non-issue for this set** — there is no reason to design a
  "stop-like" abstract sound.
- **Pitch-shift-safe.** Must survive the rate+pan+pitch coupling (§3) without
  artefacts.

**Engagement-matching is handled by the SEPARATE listening study, not guessed
here.** Pipeline: Groß-Vogt designs a **candidate pool** → the listening
study (a separate app, see DECISIONS → *Related separate workstreams*)
measures **liking** on the smiley scale → a **liking-matched** subset is
selected so the abstract set's engagement matches the phoneme set's. Liking
is the matched axis; association-strength is a *separate* axis the control
deliberately keeps low.

**Accidental-meaning audit — pre-pilot QA gate.** Before the pilot, a
naive-ear pass over the **full** selected set flags any sound that
accidentally evokes a word/animal/object. Any flagged sound is replaced.
This is a hard gate, not advisory — a single accidental referent
re-contaminates the contrast.

---

## 6. Matching cross-check

Each audio property × both arms × is it matched? The **one** intended
mismatch is "carries phonemic meaning" — that is the independent variable.
Everything else must be ✓.

| Property | Phoneme arm | Abstract arm | Matched? |
|----------|-------------|--------------|----------|
| Unique sound per letter | Yes (the phoneme) | Yes (distinct abstract sound) | ✓ |
| Coupling path (rate+pan+pitch) | shared `setAdaptivePlayback` | shared `setAdaptivePlayback` | ✓ (same code path; only the file differs) |
| Loudness | normalised to shared target | normalised to shared target | ✓ |
| Stretch / loop behaviour | steady-state continuant | steady-state continuant by design | ✓ (stops = D6 exception, §4.2) |
| Format (mono / 44.1k / mp3) | yes | yes | ✓ |
| Engagement / liking | baseline | liking-matched via listening study | ✓ |
| Accidental referent | n/a (the phoneme *is* the intended referent) | audited to none (§5 gate) | ✓ |
| **Carries phonemic meaning** | **YES** | **NO** | **✗ ← the one intended difference (the IV)** |

> This table doubles as the **Ch.5/Ch.6 validity paragraph**: it is the
> argument that the two arms differ on phonemic content and nothing else.

---

## 7. Open dependencies & order of operations

**Open dependencies (gates, owned in DECISIONS):**

- **D6 (stop-consonants)** — OPEN; blocks recording the *stop* phonemes
  (continuants are unblocked). Settle with Groß-Vogt.
- **Listening study** — blocks *final selection* of the abstract set
  (engagement/liking match). Designing the candidate pool is not blocked.
- **Pilot letter set** — not yet frozen; it defines *N* (how many of each
  sound) and which letters are stop-initial (feeds D6).
- **Format confirmation** — ✅ closed by this doc (§2).

**Suggested order of operations:**

1. **Lock the pilot letter set** → fixes *N* and the stop-initial subset.
2. **Record the continuant phonemes now** (no-schwa, §4) — unblocked.
3. **Settle D6 with Groß-Vogt** → record or handle the stop phonemes.
4. **Design the abstract candidate pool** (Groß-Vogt; non-referential,
   continuant, distinct).
5. **Run the listening study** → liking-match → select the abstract set.
6. **Accidental-meaning audit** (pre-pilot QA gate, §5).
7. **Import both sets** to the confirmed format/names (`<base>_phoneme<n>`;
   abstract slot per H4), then **re-run the phoneme-coverage census**
   (ResearchDashboard, committed `7efccb0`) to confirm no letter still
   degrades to name audio.
8. **H4 / H5 wiring** drop-in — the `arbitraryAudioFiles` / phoneme slots are
   already built and waiting; this step only sources the assets into them.
