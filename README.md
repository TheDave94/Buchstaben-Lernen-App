# Primae

> An iPad app that teaches **Austrian Volksschule 1. Klasse** children to write the alphabet by hand — through a research-backed four-phase pedagogical flow, on-device CoreML handwriting recognition, and a multidimensional *Schreibmotorik* motor-skill assessment.

[![iOS Build & Test](https://github.com/TheDave94/Primae/actions/workflows/ios-build.yml/badge.svg)](https://github.com/TheDave94/Primae/actions/workflows/ios-build.yml)
![Platform](https://img.shields.io/badge/platform-iPadOS%2018%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6.3-orange)
![Xcode](https://img.shields.io/badge/Xcode-26.4-blue)
![License](https://img.shields.io/badge/license-Master's%20thesis-lightgrey)

## About

***Primae*** (Latin: *the first ones*) — the child's first letters, the first strokes of school cursive, the first taste of literacy. The brand also shares its name with the bundled display typeface, the same Druckschrift the app renders on every glyph the child traces.

The app teaches the Latin alphabet to 5–6 year-olds, using a four-step pedagogical arc with adaptive scaffolding withdrawal, real-time audio + haptic feedback, on-device CoreML letter recognition, and a four-dimension *Schreibmotorik* motor-skill assessment (Marquardt & Söhl, 2016). Built as the practical artefact for a master's thesis comparing adaptive vs. non-adaptive handwriting instruction.

The child sees **only verbal evaluations and stars** — every numeric metric (Klarheit, Form, Tempo, Druck, Rhythmus, recognition confidence) lives behind a parental-gate research dashboard. Children at this age can't read fluently, so the app speaks every prompt aloud in German via `AVSpeechSynthesizer`.

The visual identity — paper not glass, blue ghost / green child ink / amber guide dot, sticker-pill buttons, dark-mode-aware throughout — is documented in the bundled [`design-system/`](design-system/) (tokens, type ramp, components).

## Features

### For the child
- **Four-phase pipeline per letter** — *observe* → *direct* → *guided* → *freeWrite*
- **Three child-facing worlds** — Schule (guided tracing), Werkstatt (freeform writing), Fortschritte (stars + streak)
- **Verbal-only feedback** — German TTS speaks every prompt; no percentages or technical scores ever shown
- **Real-time time-stretched audio** — letter pronunciation matches tracing speed (`AVAudioUnitTimePitch`)
- **Haptic feedback** — per-checkpoint ticks, escalating pattern at stroke / letter completion
- **Adaptive difficulty** — checkpoint radius widens or tightens based on rolling accuracy
- **Spaced-repetition scheduler** — Ebbinghaus-style recency decay + accuracy + novelty
- **Multiple scripts** — Druckschrift (Primae) and Schreibschrift (Playwrite AT)
- **Letter variants** — alternate stroke orderings for F, H, r
- **Freeform writing mode** — blank-canvas writing for single letters or words, with on-device CoreML recognition
- **Paper-transfer self-assessment** (research-only) — child writes on paper after the digital trial

### For the parent / researcher
- **Parent dashboard** — per-letter accuracy, phase completion rates, streak, 30-day practice trend, paper-transfer scores
- **Research dashboard** (parent-gated) — Schreibmotorik dimensions, KI predictions vs. expected, condition-arm distribution, scheduler-effectiveness Pearson r, last-20 raw phase records, per-letter aggregates
- **Data export** — CSV / TSV / JSON via the iOS share sheet, 13 columns per phase session including all four motor dimensions, the recognition prediction (predicted letter + confidence + isCorrect), and the active thesis condition
- **Built-in A/B testing** — three thesis conditions (`threePhase`, `guidedOnly`, `control`) with stable UUID-derived assignment, opt-in via Settings

### Privacy
- **No network calls.** All inference runs on-device through CoreML.
- **No accounts, no analytics, no third-party SDKs.** Zero external dependencies in the package manifest.
- **Data is sandboxed.** Progress, calibration, and dashboard data live in the iOS Application Support directory.
- **Pseudonymous participant UUID** is generated locally and used only to label exported data.
- **Export is parent-initiated** through the iOS share sheet — nothing leaves the device automatically.

## Pedagogical model

| Phase | German | What the child does | How it's scored |
|------|------|------------------|----------------|
| **Observe** | *Anschauen* | Watches an animated guide dot trace each stroke | Pass / fail (auto-advance after 2 cycles) |
| **Direct** | *Richtung lernen* | Taps numbered start dots in correct order | Pass / fail (per-stroke directionality) |
| **Guided** | *Nachspuren* | Traces over the letter with checkpoint rails | Checkpoint progress 0–1 |
| **FreeWrite** | *Selbst schreiben* | Writes from memory on a blank glyph | Schreibmotorik 4-dimension assessment |

The four phases implement **Gradual Release of Responsibility** (Pearson & Gallagher, 1983; Fisher & Frey, 2013), with **fading feedback** scheduled by Schmidt & Lee's (2005) *guidance hypothesis*. Form accuracy is computed via **discrete Fréchet distance** (Eiter & Mannila, 1994) against the canonical glyph centerline. The full set of citations and per-method implementation pointers lives in [`docs/APP_DOCUMENTATION.md`](docs/APP_DOCUMENTATION.md).

## Tech stack

- **Swift 6.3** with strict concurrency and `@MainActor` default isolation
- **SwiftUI** + UIKit overlays for pencil / finger touch handling
- **AVAudioEngine** + `AVAudioUnitTimePitch` — velocity-driven time-stretching
- **AVSpeechSynthesizer** — German verbal feedback (`de-DE`, enhanced voice when available)
- **CoreML** + Vision — on-device 40 × 40 grayscale CNN, 53 classes (A–Z, a–z, ß)
- **CoreHaptics** — phase-aware haptic patterns
- **Swift Testing** + a small core of XCTest — ~94 `@Test` declarations
- **Zero third-party dependencies**

## Gestures

| Gesture | Action |
|---|---|
| 1 finger — trace | Audio plays; speed adapts to writing velocity |
| 2 fingers — swipe up / down | Cycle through letter-sound variants |
| Apple Pencil | Pressure + azimuth feed the *Druck* dimension |
| Long-press gear (2 s) | Open the parental gate (Settings, Research, Export) |

## Building

### Requirements
- macOS with **Xcode 26+** (project targets iOS 26 SDK)
- iPad Simulator or physical iPad

### Open in Xcode
```bash
open Primae/Primae.xcodeproj
```
Set your development team in project settings, then build & run to a simulator or device.

### Run the test suite
```bash
cd Primae
xcodebuild test -project Primae.xcodeproj -scheme Primae \
  -destination "platform=iOS Simulator,name=iPad (A16)" \
  -configuration Debug CODE_SIGNING_ALLOWED=NO
```

### Pre-commit hook
A pre-commit hook gates commits on `swift build --build-tests` + `swift test --parallel`.
After cloning, install once:
```bash
./scripts/install-hooks.sh
```

### CI
Every push to `main` runs:
1. **iPad Simulator** build & test on `macos-26` / Xcode 26 (GitHub-hosted)
2. **Physical iPad** build & test on a self-hosted MacBook runner

See [`.github/workflows/`](.github/workflows/).

## Project structure

```
PrimaeNative/          Swift Package (library)
├── App/                   App entry point
├── Core/                  Audio, progress, strokes, haptics, difficulty,
│                          recognition, scoring, speech synthesis
└── Features/
    ├── Library/           Letter loading + caching
    ├── Navigation/        World-switcher rail + main app shell
    ├── Onboarding/        First-run flow (one demo per phase)
    ├── Parent/            Parental gate + research dashboard
    ├── Worlds/            Schule / Werkstatt / Fortschritte
    ├── Dashboard/         Settings + parent dashboard
    └── Tracing/           Canvas, ViewModel, freeform / freeWrite recorders

Primae/             Xcode host app (imports PrimaeNative)
PrimaeNativeTests/     Swift Testing + XCTest suite
docs/                      Architecture, thesis foundation, code invariants
scripts/                   Stroke, audio, app-icon, colorset generators + git hooks
```

## Documentation

The repo intentionally keeps documentation small and role-separated:

| File | Purpose |
|------|---------|
| [`docs/APP_DOCUMENTATION.md`](docs/APP_DOCUMENTATION.md) (+ [`.pdf`](docs/APP_DOCUMENTATION.pdf)) | **The single technical doc.** Architecture, scientific methods with citations, learning pipeline, data schemas, claim verification, bibliography. Includes appendices A (architecture quick reference), B (research export schema), C (phoneme audio authoring guide). |
| [`ROADMAP.md`](ROADMAP.md) | **The single outstanding-work file.** Forward-looking only — items shipped are removed (commit history is the archive). Each item has effort estimate, file list, citations, failure modes. |
| [`design-system/`](design-system/) | **Primae visual identity.** Color tokens (light + dark), type ramp, spacing scale, font files, sticker-button spec, preview HTML, and the iPad UI kit (`ui_kits/ipad-app/`). Source of truth for the SwiftUI tokens in `PrimaeNative/Theme/`. |
| [`docs/LESSONS.md`](docs/LESSONS.md) | **Code-level invariants** — guardrails to read before touching `AudioEngine.swift`, `StrokeTracker.swift`, or the `load(letter:)` path. Kept separate so the next contributor reads it in full instead of skimming an appendix. |
| [`docs/TESTING_CHECKLIST.md`](docs/TESTING_CHECKLIST.md) (+ [`testing_checklist.html`](docs/testing_checklist.html)) | **Manual test checklist.** The `.md` is the canonical source — read it on GitHub. The companion `.html` (regenerated via `python3 scripts/render_checklist.py`) is a self-contained page with **real, interactive checkboxes** that persist to `localStorage`, a sticky progress counter, and a "Copy unchecked" button that drops your failure list onto the clipboard ready to paste back. Open `docs/testing_checklist.html` directly from Finder (`file://…`) — no server needed. |
| [`CLAUDE.md`](CLAUDE.md) | Auto-loaded context for Claude Code agents. |

## Acknowledgments

Pedagogical model and scoring metrics are grounded in:

- Pearson, P. D., & Gallagher, M. C. (1983). *The instruction of reading comprehension* — Gradual Release of Responsibility
- Fisher, D., & Frey, N. (2013). *Better learning through structured teaching*
- Schmidt, R. A., & Lee, T. D. (2005). *Motor control and learning* — guidance hypothesis
- Marquardt, C., & Söhl, K. (2016). *Schreibmotorik: Schreiben lernen leicht gemacht* — four-dimension motor model
- Thibon, L. S., Gerber, S., & Kandel, S. (2018). The elaboration of motor programs for the automation of letter production
- Berninger, V. W., et al. (2006). *Early development of language by hand* — motor-similarity letter ordering
- Eiter, T., & Mannila, H. (1994). *Computing discrete Fréchet distance*
- Ebbinghaus, H. (1885); Cepeda, N. J., et al. (2006) — spaced practice meta-analysis
- Danna, J., & Velay, J.-L. (2015). Basic and supplementary sensory feedback in handwriting
- Alamargot, D., & Morin, M.-F. (2015). Does handwriting on a tablet screen affect students' graphomotor execution?

Full bibliography in [`docs/APP_DOCUMENTATION.md`](docs/APP_DOCUMENTATION.md) § 12.

Schreibschrift rendering uses **Playwrite Österreich** by TypeTogether, SIL Open Font License 1.1 — see [`PrimaeNative/Resources/Fonts/PlaywriteAT-OFL.txt`](PrimaeNative/Resources/Fonts/PlaywriteAT-OFL.txt).

## License

This is a private master's thesis project. Not licensed for redistribution. The bundled Playwrite AT font is © TypeTogether under SIL OFL 1.1; redistribution of the font itself follows that license, not the project's.
