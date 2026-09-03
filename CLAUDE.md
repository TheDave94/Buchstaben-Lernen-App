# CLAUDE.md — Primae (Letter Learning App)

> Brand: **Primae** (formerly "Buchstaben-Lernen-App"). Everything carries the new name: the GitHub repo (`TheDave94/Primae`), Xcode project, scheme, host app, host folder (`Primae/`), Swift Package target (`PrimaeNative`), test target (`PrimaeNativeTests`), bundle identifier (`de.flamingistan.primae`), and the SPM relative path (`../../Primae`). Pre-rebrand UserDefaults keys (`de.flamingistan.buchstaben.*`) moved to `de.flamingistan.primae.*` — the app is in alpha so existing test-device state is intentionally reset. The local working tree is `/opt/repos/Primae`, matching the SPM relative path.

## Project Overview
iPad app for teaching German children (ages 5-6) to trace letters. Built with SwiftUI, Swift 6.3, targeting iOS 26+ (the SPM manifest targets iOS 26.0). Academic thesis project.

## Bounded autonomy

This is a thesis project: David is the primary author, Claude Code is reviewer + executor of agreed tasks. Two collaboration patterns coexist — be explicit about which one is active before acting.

**Five principles.**
1. **Default to action within scope.** Inside an agreed spec, execute — don't re-check at every step.
2. **Spec is the contract.** What was agreed in conversation is what ships. Drift back to conversation if the work outgrows the spec.
3. **Investigate before deciding.** Read the code / data before proposing a fix. Cheap to read, expensive to undo.
4. **Preserve the working setup.** Existing patterns are load-bearing until proven otherwise. Don't refactor on a side-quest.
5. **David picks direction, Claude picks implementation.** The "what" and "why" come from David; the "how" can be Claude's call within scope.

**Two patterns.**
- **Spec-then-execute (autonomous on engineering).** David scopes the spec in conversation; Claude implements + tests + commits + pushes + watches CI. Used for tactical engineering: bake changes, UI fixes, refactors, test additions. [[feedback_visual_approval_gate]] still gates any visual change inside this pattern.
- **Review-only (Claude proposes, David executes).** Used for thesis-substance docs — anything an examiner will read for narrative or methodology rationale (e.g. a future `docs/METHODOLOGY.md`, claims, decision-log prose). Claude drafts structure / redlines / suggests phrasing; the text that ships is David's voice. Don't merge prose into thesis-substance files without David's explicit sign-off on each section.

**Stop and surface (don't proceed autonomously) when:**
1. Scope grew past the agreed spec.
2. Two valid paths exist and the choice changes the artefact materially.
3. Evidence contradicts the spec (e.g. doc says X, code does Y).
4. A change touches a load-bearing doc (CLAUDE.md, BAKE_INVARIANTS.md, LESSONS.md Part B, claims in APP_DOCUMENTATION.md §11, docs/DECISIONS.md, research_data/spec_decision/framing.md, research_data/phase2b_gates/*.md).
5. A change touches **thesis-substance prose** (METHODOLOGY.md decision sections, examiner-facing claims, supervisor sign-off lines). Always switch to review-only.

## Two-repo working setup

This Primae code repo (`/opt/repos/Primae`) has a sibling thesis repo at `/opt/repos/master-thesis` (remote on Forgejo: https://git.flamingistan.com/David/master-thesis — NOT GitHub). Each repo has a different working mode — do not mix them.

**Primae (this repo): spec-then-execute mode.** Claude Code commits autonomously within agreed scope. Standard workflow as described in the Bounded autonomy section above.

**Thesis repo: scaffold-and-assist mode ONLY.** Claude Code may:
- Read files freely for cross-reference.
- Draft baseline prose for new chapter sections (David iterates after — never ship Claude's prose as-is).
- Find citations for claims David has written; format references in APA per the KUG Leitfaden.
- Proofread wording, spelling, terminology consistency (German/English mixing especially).

Claude Code may NOT:
- Commit to the thesis repo without per-commit David approval.
- Decide what the thesis argues — substance is David's.
- Auto-sync thesis prose to match METHODOLOGY.md (the thesis chapter is a deliberate argument, not a code description; drift toward "describe current code" is a failure mode to actively avoid).
- Push to the thesis remote without explicit instruction.

When METHODOLOGY.md in Primae gets a new or revised decision entry, Claude Code may draft a corresponding prose update for the thesis chapter and surface it for David's review. The thesis chapter updates are deliberate acts, not auto-syncs.

David's stated thesis-AI workflow: baseline drafting + reference legwork + final spelling/wording pass. Substance iteration is David's. The KUG affidavit at submission will disclose this.

## Session boundaries — code work vs thesis prose

This repo and `master-thesis` share working sessions today, and that's the primary context-pressure source — recent sessions have pegged the 1M-token ceiling and `/compact`ed 13–19 times. Split deliberately:

- **One axis per session.** A session is either Swift code work (feature impl, sweep cycles, baking, CI watching) **or** thesis prose work (drafting `content/*.typ`, citation hunting, bibliography curation). Not both in one session. The two-repo working setup is also a two-session setup.
- **Phase / milestone = session boundary.** When a sweep cycle, a feature, or a chapter section wraps, summarise the outcome into `~/.claude/projects/-opt-repos-Primae/memory/project_primae.md` and start a fresh session for the next phase.
- **For thesis-only sessions, start CC from `/opt/repos/master-thesis`** rather than this tree. CC creates a separate project workspace and memory namespace there; you get a clean context budget per side.

User-level `~/.claude/CLAUDE.md` has the general output discipline (Bash caps, ranged Reads, test-output verbatim) — it applies here.

## Architecture
- **Main target**: Uses `.defaultIsolation(MainActor.self)` — all types are implicitly @MainActor
- **Test target**: Uses `.swiftLanguageMode(.v5)` — do NOT change this
- **CI**: GitHub Actions on hosted macos-26 runners with Xcode 26.4 (simulator matrix: iPad Pro 13-inch (M5) + iPad (A16))
- **Remotes**: `origin` is the Forgejo forge at `https://git.flamingistan.com/David/Primae.git` — that is where you push. The GitHub repo `TheDave94/Primae` is a **push mirror** of the forge, not the origin: branches and workflow files reach it automatically, with nobody pushing to GitHub directly. CI runs there, so `gh run list --repo TheDave94/Primae` is the right way to read results and the wrong way to imagine the data flows.
- **Learning phases**: observe → direct → guided → freeWrite (managed by PhaseController)
- **Stroke data**: JSON files in `Resources/Letters/{letter}/strokes.json` with normalized coordinates
- **Audio**: Proximity-triggered playback via AudioEngine + StrokeTracker

## Key Files
- `TracingViewModel.swift` — main VM, coordinates phases, strokes, audio, animation
- `TracingCanvasView.swift` — Canvas rendering (ghost lines, start dots, ink, KP overlay)
- `MainAppView.swift` — root host with WorldSwitcherRail + worlds
- `SchuleWorldView.swift` — World 1: guided four-phase tracing
- `WerkstattWorldView.swift` — World 2: freeform writing
- `FortschritteWorldView.swift` — World 3: child-facing star/streak/letter gallery
- `StrokeTracker.swift` — checkpoint proximity detection
- `AudioEngine.swift` — ⚠️ STABLE AND FRAGILE — do NOT modify
- `SpeechSynthesizer.swift` — German TTS for child-facing verbal feedback
- `LetterRepository.swift` — loads letters from bundle
- `PrimaeLetterRenderer.swift` — renders letter glyphs using Primae font
- `ProgressStore.swift` — persists learning progress
- `OverlayQueueManager.swift` — serialised post-freeWrite overlay scheduler
- `StrokeCalibrationOverlay.swift` — debug stroke editing UI

For the full developer-grade reference + thesis foundation see
`docs/APP_DOCUMENTATION.md` (single comprehensive doc; includes
architecture quick reference, research export schema, and phoneme
audio guide as Appendices A/B/C).
Outstanding work, deferred items, post-thesis ideas, and the pilot-study
freeze items (H1–H6) + known issues live in `docs/ROADMAP.md`.
Pilot design decisions (D-series), their evidence, and the governing
constraints live in `docs/DECISIONS.md`; the sound-asset production
procedure is `docs/SOUND_PRODUCTION_SPEC.md`. (These three absorbed the
former `PILOT_READINESS.md`, removed in the 2026-06-20 doc reorg.)
Read `docs/LESSONS.md` before touching `AudioEngine.swift`,
`StrokeTracker.swift`, or the `load(letter:)` path.

## Build & Test
```bash
cd Primae
xcodebuild test -project Primae.xcodeproj -scheme Primae \
  -destination "platform=iOS Simulator,name=iPad (A16)" \
  -configuration Debug CODE_SIGNING_ALLOWED=NO
```

## Test Infrastructure

> **Note:** `xcodebuild` is NOT available on claudebox (Linux). Only Swift syntax
> checking works locally. Full build/test runs on hosted macos-26 GitHub Actions
> runners. Always verify CI passes after pushing.
> Physical-iPad testing is a deliberate LOCAL act on the Mac: it requires
> `-allowProvisioningUpdates` and an unlocked, connected iPad. It is NOT automated
> and never was.

> **Correction (2026-09-03, measured from a sandboxed Claude Code seat on this
> Mac — a different environment than claudebox above).** Neither `swift build`
> nor `xcodebuild` works from here; there is no local fallback because only
> `test` is blocked — **build is blocked too.** A claim otherwise, relayed
> from another seat or a prior session, did not reproduce; re-measure before
> trusting it again:
> - `swift build` fails at manifest compilation: `couldn't create cache file
>   '.../xcrun_db-*' (errno=Operation not permitted)`, and
>   `~/Library/org.swift.swiftpm/*` reports not accessible/writable.
> - `xcodebuild build` and even a bare `xcodebuild -resolvePackageDependencies`
>   (default derived-data path, no override) fail identically: `CoreSimulatorService
>   connection became invalid` (the XPC connection itself is refused) followed by
>   `error: permissionDenied` on package resolution. Not a `-derivedDataPath`
>   artifact — reproduces with Xcode's own default path.
> - Only CI (hosted macos-26 runner) can build or test this project from a
>   sandboxed seat. Prepare the change, then hand off to a build-capable seat
>   or David's terminal — don't spend a round trip re-discovering this.
> - `gh run list` (and `gh api .../actions/runs`) also fails locally with a
>   Go-TLS certificate error specific to that endpoint; `curl` with the token
>   from `gh auth token` against the same URL works. Use curl for reading CI
>   results from a sandboxed seat.

> **Commit signing runs IN a Claude Code session — it is not a handover.**
> `ls`/`cat` on `~/.ssh` return `Operation not permitted` from a sandboxed
> Bash tool call, which looks like a hard block on reading the signing key —
> it isn't one for `git commit` itself. Measured directly (2026-09-03,
> commit `b2d5397`): a plain `git commit` (no special flags, this repo's
> `commit.gpgsign=true` / `gpg.format=ssh` fires automatically) completed
> synchronously, no hang, no visible prompt delay, and `git log --show-signature`
> confirmed a genuine `Good "git" signature ... ED25519-SK key`. So: run the
> commit directly from the session. Only the physical key touch is David's;
> the commit itself is not. (Whether every future attempt is this fast — e.g.
> a FIDO2 recent-verification window — is unmeasured; if a commit ever
> genuinely hangs, that's new information to record, not a reason to assume
> the old "structurally blocked" claim was right after all.)

1. **Swift compilation check** (claudebox Linux — basic syntax check only, SwiftUI/QuartzCore won't link):
   ```bash
   swift build 2>&1 | head -20
   ```

2. **Full build** (CI runner or local Mac):
   ```bash
   xcodebuild build -project Primae/Primae.xcodeproj -scheme Primae \
     -destination "platform=iOS Simulator,name=iPad (A16)" \
     -configuration Debug CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO \
     -derivedDataPath /tmp/DerivedData-Primae 2>&1 | tail -20
   ```

3. **Full test suite** (CI runner or local Mac):
   ```bash
   xcodebuild test -project Primae/Primae.xcodeproj -scheme Primae \
     -destination "platform=iOS Simulator,name=iPad (A16)" \
     -configuration Debug CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO \
     -derivedDataPath /tmp/DerivedData-Primae 2>&1 | tail -30
   ```

4. **strokes.json validation** (works anywhere with python3):
   ```bash
   python3 -c "import json, pathlib; [json.loads(f.read_text()) for f in pathlib.Path('PrimaeNative/Resources/Letters').rglob('strokes.json')]; print('All strokes.json valid')"
   ```

5. **CI status**:
   ```bash
   gh run list --repo TheDave94/Primae --limit 3
   ```

## Study builds

A **study build** compiles the non-study surfaces out and defaults `studyMode`
ON (B2). `STUDY_BUILD` arrives as an xcodebuild command-line override, because a
project-level `SWIFT_ACTIVE_COMPILATION_CONDITIONS` reaches the app target but
NOT the `PrimaeNative` SwiftPM package target (measured — spike `ed055db`).
`scripts/build_study.sh` is the only blessed way to produce one.

**Two configurations, and they are not interchangeable:**

| | `Debug-Study` | `Release-Study` |
|---|---|---|
| Purpose | simulator + CI | **the pilot artefact** |
| Optimisation | `-Onone` | `-O` |
| `#if DEBUG` surfaces | compiled IN | compiled out |
| `ENABLE_TESTABILITY` | YES | NO |

`Debug-Study` is a DEBUG build. Do **not** put it on a child's iPad: `DEBUG` is
defined, so every `#if DEBUG` surface ships. (One of those was a live numeric
accuracy readout on the child-facing tracing canvas — now additionally gated on
`!STUDY_BUILD`, but the general hazard stands.)

**Producing the pilot artefact on a physical iPad** — a deliberate LOCAL act,
never automated. Requires an unlocked, connected iPad:

```bash
PRIMAE_CONFIGURATION=Release-Study \
PRIMAE_CODE_SIGNING=YES \
PRIMAE_DESTINATION='platform=iOS,name=<iPad name>' \
PRIMAE_DERIVED_DATA=/tmp/dd-pilot \
  scripts/build_study.sh build -allowProvisioningUpdates
```

Then verify the artefact rather than trusting the label — the identity is a
link-enforced symbol, so this is a fact the linker had to agree with:

```bash
nm -jU /tmp/dd-pilot/Build/Products/Release-Study-iphoneos/Primae.app/Primae \
  | grep primae_build_identity
# must print _primae_build_identity_study, and nothing else
```

Pressing ⌘R on the `Primae-Study` scheme does NOT produce a study build. It
fails at link time instead: every configuration names its own
`_primae_build_identity_{study,normal}` via `-u`, and the symbol exists only
when the package itself was compiled with the matching flag. Fail-closed in both
directions; CI proves both (CONTROL A and CONTROL B in `ios-build.yml`).

### ⚠️ The pilot artefact is built by a toolchain CI does not exercise

This workstation runs **Xcode 27 beta**; `ios-build.yml` pins **Xcode 26.4** on
`macos-26`. A device build made here is therefore compiled by a compiler no CI
job has ever run. That gap matters more than usual for `Release-Study`, because
it is the only `-O` build in the project and `-O` + `-default-isolation MainActor`
is the exact configuration of the known inliner crash swiftlang/swift#88173
(ROADMAP F11).

Until a toolchain pin lands (see ROADMAP F11), **record the toolchain with the
artefact** — `build_study.sh` prints `xcodebuild -version` on every run, so
capture that output alongside the build. A pilot binary whose compiler version
is unknown is not a reproducible artefact, and the thesis will be asked which
one built it.

## Credentials and the ELEVENLABS_API_KEY pattern

*Based on `/opt/autocoder/CREDENTIAL_CONVENTIONS_TEMPLATE.md` (canonical), adapted for this repo.*

This repo has exactly one credential surface: the `ELEVENLABS_API_KEY` used by `scripts/generate_letter_audio.py` and `scripts/generate_prompts.py`. **No `.env.local`** — the key is entered manually each session, not persisted. The rationale is workflow-shaped: audio generation is a deliberate, paid, low-frequency act ("I am consciously about to spend money") and removing the manual gate would dull that signal.

**Preferred entry pattern** (avoids bash-history leak):

```bash
read -s -p "ELEVENLABS_API_KEY: " ELEVENLABS_API_KEY && export ELEVENLABS_API_KEY
python3 scripts/generate_letter_audio.py …
```

`read -s` suppresses terminal echo; the value enters the shell as an env var without ever landing in `~/.bash_history`. Do **not** use the older `export ELEVENLABS_API_KEY=…<value>…` pattern — that writes the literal value into history, where it persists until rotation.

**Rotation.** `/opt/autocoder/ROTATION_RUNBOOK.md` covers the ElevenLabs key under "manual, not on disk." If a session inadvertently used the `export FOO=…` antipattern, rotate the key.

**`.gitignore`** already covers `.env` and `.env.*` (excluding `.env.example`) — no change needed here.

## DO NOT
- Do NOT modify `AudioEngine.swift` — it is stable and fragile
- Do NOT introduce new dependencies or frameworks
- Do NOT change `.swiftLanguageMode(.v5)` in the test target
- Do NOT change `.defaultIsolation(MainActor.self)` in the main target
- Do NOT modify the strokes.json coordinate format
- Do NOT modify `StrokeTracker.swift` unless the task explicitly targets it
- Do NOT use `UIColor(dynamicProvider:)` for design tokens — under Swift 6 default isolation the closure inherits MainActor and traps when SwiftUI samples it from `com.apple.SwiftUI.AsyncRenderer`. Design tokens go through Asset-Catalog colorsets (see `Primae/Primae/Assets.xcassets/Colors/` + `scripts/gen_colorsets.py`), which iOS resolves per trait collection without invoking any Swift code.
- Do NOT register an Xcode MCP bridge while the study configuration is frozen — see ROADMAP F12 for the reasoning and the conditions for revisiting it post-pilot.

## Conventions
- All new views go in `Features/Tracing/` unless they're core infrastructure
- Use existing protocols (AudioControlling, ProgressStoring) — don't create parallel interfaces
- Animations use SwiftUI `.transition()` and `withAnimation {}`
- Debug features gated on `vm.showDebug`
- German UI text (the app is for German-speaking children)
- Child-facing screens (Schule / Werkstatt / Fortschritte / Onboarding / overlays during practice) must work via icons + animation + TTS, not text — the target audience is 5–6 yr-old Volksschule 1. Klasse children who can't or barely read. Text is fine for parent-area screens (Settings, ParentDashboard, ResearchDashboard, Datenexport).
- Design tokens: read from `PrimaeNative/Theme/{Colors, Radii, Fonts}.swift`. Color values are auto-flipping light/dark via `Color("name")` (Asset-Catalog colorsets); fonts via `Font.display(_:weight:)` / `Font.body(_:weight:)` / `Font.cursive(_:)`. The picker for the appearance override lives in the parent area as "Erscheinungsbild" (System / Hell / Dunkel).
- Run `git config core.quotePath false` in every fresh clone. 35 of the ~500 tracked paths carry umlauts (`PrimaeNative/Resources/Letters/F/Föhn.mp3`, `.../Regular/Ä/strokes.json`, …); under git's default `quotePath=true` those come back octal-escaped and double-quoted (`"…/F\303\266hn.mp3"`), so any instrument that greps or diffs tracked paths silently drops exactly the letter assets that matter. This setting lives in `.git/config`, which is untracked — a fresh clone does NOT inherit it, which is why it is written down here.

## Visual sweep workflow

For any geometric or visual question with finite candidate options or a single tunable parameter, default to **render-and-compare BEFORE proposing or committing a specific construction**.

Workflow:
1. Identify candidate constructions or parameter values (4-6 typically; include current `main` as the baseline column).
2. Implement each, bake the target letters.
3. Compute sweep-renderer gauges (overshoot, reversal, max-turn — see `docs/BAKE_INVARIANTS.md` §3) per candidate. Gauges are diagnostic, not ship gates; the bake itself writes output regardless. A candidate that fails a gauge gets a labelled `SKIPPED` cell in the sweep grid for visual comparison; it does NOT auto-reject from being shippable.
4. Render PNGs of all candidates through the bake pipeline at iPad-equivalent style (dark ink ~#2D3748, red polyline ~#E53E3E).
5. Build a contact-sheet grid (rows = letters, columns = candidates) at `/tmp/sweep/grid.png`.
6. Present to David. Wait for selection.
7. Set chosen value, bake, commit, push as a **single** commit.

Numeric gates filter; visual judgment decides. Don't write prose arguments about which candidate is "correct" — let the grid speak.

This applies to: joint construction parameters, arm strategy choice, anchor placement values, curve-fit primitive selection, and any other geometric question where multiple constructions are plausible.

Primitives are registered in `scripts/generate_strokes_auto.py`:
- `ARM_STRATEGIES`: `chord`, `bfs_raw`, `lsq_line`, `smoothed_medial_axis`
- `JOINT_STRATEGIES`: `sharp`, `family_a_fillet`, `quadratic_bezier_at_V`, `cubic_bezier_clamped`
- `DEFAULT_ARM_STRATEGY` / `DEFAULT_JOINT_STRATEGY` control the line-kind default; sweep via per-spec `"arms"` / `"joints"` overrides, not by mutating the defaults.
