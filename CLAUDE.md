# CLAUDE.md — Primae (Letter Learning App)

> Brand: **Primae** (formerly "Buchstaben-Lernen-App"). Everything carries the new name: the GitHub repo (`TheDave94/Primae`), Xcode project, scheme, host app, host folder (`Primae/`), Swift Package target (`PrimaeNative`), test target (`PrimaeNativeTests`), bundle identifier (`de.flamingistan.primae`), and the SPM relative path (`../../Primae`). Pre-rebrand UserDefaults keys (`de.flamingistan.buchstaben.*`) moved to `de.flamingistan.primae.*` — the app is in alpha so existing test-device state is intentionally reset. The local working-tree directory is still `Buchstaben-Lernen-App` on this machine (the SPM ref expects `Primae`, so a fresh `git clone https://github.com/TheDave94/Primae.git` is the cleanest way to land in the right path).

## Project Overview
iPad app for teaching German children (ages 5-6) to trace letters. Built with SwiftUI, Swift 6.3, targeting iOS 18+. Academic thesis project.

## Architecture
- **Main target**: Uses `.defaultIsolation(MainActor.self)` — all types are implicitly @MainActor
- **Test target**: Uses `.swiftLanguageMode(.v5)` — do NOT change this
- **CI**: GitHub Actions on macos-26 runner with Xcode 26.4, self-hosted MacBook
- **Learning phases**: observe → guided → freeWrite (managed by PhaseController)
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
Outstanding work, deferred items, and post-thesis ideas live in
`/ROADMAP.md`.
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
> checking works locally. Full build/test runs on the self-hosted MacBook CI runner
> via GitHub Actions. Always verify CI passes after pushing.

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

## DO NOT
- Do NOT modify `AudioEngine.swift` — it is stable and fragile
- Do NOT introduce new dependencies or frameworks
- Do NOT change `.swiftLanguageMode(.v5)` in the test target
- Do NOT change `.defaultIsolation(MainActor.self)` in the main target
- Do NOT modify the strokes.json coordinate format
- Do NOT modify `StrokeTracker.swift` unless the task explicitly targets it
- Do NOT use `UIColor(dynamicProvider:)` for design tokens — under Swift 6 default isolation the closure inherits MainActor and traps when SwiftUI samples it from `com.apple.SwiftUI.AsyncRenderer`. Design tokens go through Asset-Catalog colorsets (see `Primae/Primae/Assets.xcassets/Colors/` + `scripts/gen_colorsets.py`), which iOS resolves per trait collection without invoking any Swift code.

## Conventions
- All new views go in `Features/Tracing/` unless they're core infrastructure
- Use existing protocols (AudioControlling, ProgressStoring) — don't create parallel interfaces
- Animations use SwiftUI `.transition()` and `withAnimation {}`
- Debug features gated on `vm.showDebug`
- German UI text (the app is for German-speaking children)
- Child-facing screens (Schule / Werkstatt / Fortschritte / Onboarding / overlays during practice) must work via icons + animation + TTS, not text — the target audience is 5–6 yr-old Volksschule 1. Klasse children who can't or barely read. Text is fine for parent-area screens (Settings, ParentDashboard, ResearchDashboard, Datenexport).
- Design tokens: read from `PrimaeNative/Theme/{Colors, Spacing, Radii, Fonts}.swift`. Color values are auto-flipping light/dark via `Color("name")` (Asset-Catalog colorsets); fonts via `Font.display(_:weight:)` / `Font.body(_:weight:)` / `Font.cursive(_:)`. The picker for the appearance override lives in the parent area as "Erscheinungsbild" (System / Hell / Dunkel).

## Visual sweep workflow

For any geometric or visual question with finite candidate options or a single tunable parameter, default to **render-and-compare BEFORE proposing or committing a specific construction**.

Workflow:
1. Identify candidate constructions or parameter values (4-6 typically; include current `main` as the baseline column).
2. Implement each, bake the target letters.
3. Run numeric gates (1 overshoot, 2 monotonicity, 3 tangent continuity, determinism, b firewall) as a filter; gate-failing candidates get a labelled `SKIPPED` cell in the grid.
4. Render PNGs of passing candidates through the bake pipeline at iPad-equivalent style (dark ink ~#2D3748, red polyline ~#E53E3E).
5. Build a contact-sheet grid (rows = letters, columns = candidates) at `/tmp/sweep/grid.png`.
6. Present to David. Wait for selection.
7. Set chosen value, bake, commit, push as a **single** commit.

Numeric gates filter; visual judgment decides. Don't write prose arguments about which candidate is "correct" — let the grid speak.

This applies to: joint construction parameters, arm strategy choice, anchor placement values, curve-fit primitive selection, and any other geometric question where multiple constructions are plausible.

Primitives are registered in `scripts/generate_strokes_auto.py`:
- `ARM_STRATEGIES`: `chord`, `bfs_raw`, `lsq_line`, `smoothed_medial_axis`
- `JOINT_STRATEGIES`: `sharp`, `family_a_fillet`, `quadratic_bezier_at_V`, `cubic_bezier_clamped`
- `DEFAULT_ARM_STRATEGY` / `DEFAULT_JOINT_STRATEGY` control the line-kind default; sweep via per-spec `"arms"` / `"joints"` overrides, not by mutating the defaults.
