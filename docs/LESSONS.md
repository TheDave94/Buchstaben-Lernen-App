# LESSONS.md

Two layers of lessons. The first (Part A) is architectural — read
before designing the next font/weight pipeline or any similar
algorithm-vs-tool decision. The second (Part B) is code-level —
read before touching `AudioEngine.swift`, `StrokeTracker.swift`,
or the `load(letter:)` path.

---

# Part A — Lessons from Druckschrift Regular

Audience: future maintainers facing similar architectural questions
("should this be fully automated or tool-assisted?", "should I
train an ML model or hand-author the data?", "the algorithm
produces something different from what I'd draw — why?").

## 1. Tool-assisted authorship beats fully automated bake for handwriting pedagogy

We spent a long time trying to build a bake pipeline that produced
ship-quality polylines from glyph rasters. For simple letters
(straight lines, single curves) it worked. For visually complex
letters (closed bowls, asymmetric curves, multi-stroke junctions)
every algorithmic approach we tried either failed or required so
much tuning that hand-authorship via the calibrator was faster.

The right architecture turned out to be:

- bake produces drafts (good for simple geometry)
- calibrator (with skeleton-edit mode) produces ship-quality
  polylines for everything else
- the runtime ships the calibrator output for all 59 letters

The lesson to internalize: for creative or pedagogical artifacts
where human judgment is the quality criterion, "build the
algorithm" and "build the editor" are different investments. The
editor compounds across all letters; the algorithm has diminishing
returns past a certain point.

## 2. Medial-axis math ≠ pedagogical centerline

The mathematical medial axis (locus of points equidistant from
the ink boundary) is well-defined and computable. For simple
shapes it coincides with what a human reads as "the line through
the middle of the stroke." For asymmetric or junction-heavy
shapes it branches, takes detours, or sits visibly off-center.

We spent significant time building post-processing (snap-to-middle,
Y-junction reconciliation, per-stroke mask isolation, slanted-stem
LSQ) to bridge this gap. Each layer either failed or introduced
new artifacts. The fundamental problem is representational: medial
axis is a property of ink geometry; centerline (as humans read it)
is a property of intended stroke trajectory. The algorithm and
the goal aren't measuring the same thing.

When the algorithmic output of a geometric primitive doesn't match
what looks right, the answer is often not "tune the primitive
more" — it's "this primitive isn't measuring what you want."

## 3. Training data IS the deliverable (for small fixed corpora)

We considered training an ML model to produce polylines from
glyph masks. The external evaluator's framing:

> For a 59-letter font, the training set and the deliverable are
> the same set. A model trained on 30 to predict the 15 only
> matters if the model output is acceptable without correction —
> and if it were, we wouldn't have needed the calibrator. A model
> trained on all 59 has nothing left to predict.

ML pays off when:

- the corpus is open-ended (new examples will keep arriving)
- hand-correction of model output is meaningfully faster than
  hand-authoring from scratch
- you have enough training data to span the topological space

For 59 letters with high topological diversity, none of those
held. We deferred ML and shipped via hand-tuning.

## 4. The BFS-trim regression cycle (worked example)

A specific bug pattern worth documenting because it'll recur in
any pipeline that runs SVD on pixel-discretized skeleton paths.

**Problem:** A's crossbar polyline sat 7.5 px above the ink's
center because the SVD fit over the L-shaped BFS path (diagonal
leg + on-axis crossbar + diagonal leg) was pulled off-center by
the perpendicular legs.

**Fix:** trim BFS path to the longest contiguous run of segments
whose tangent matches the chord direction within ±30°.

**Regression:** the same trim broke A's diagonals. Pixel-staircase
zigzag on the diagonal skeleton produced per-segment tangent
noise (some segments at 0°, some at 45°). The longest contiguous
on-axis run was 12 segments out of 444. SVD over 12 segments
produced a degenerate fit.

**Re-fix:** raise threshold to ±45° (enough to absorb staircase
noise on diagonals; still tight enough to drop crossbar-
perpendicular legs at 90°).

**Generalizable lesson:** any time you set an angle threshold
against pixel-discretized data, sanity-check it against ALL the
shapes that data could plausibly produce. Pixel staircases are
noisier than continuous geometry suggests. A smoothing pass
before the angle check (the eventual cleaner solution if this
recurs) sidesteps the issue.

## 5. NFC vs NFD gotcha for letter-named filesystem paths

When importing data with non-ASCII letter names (Ä Ö Ü ß ä ö ü on
Linux/macOS), normalize to NFC before constructing paths.

The iPad calibrator exported `Ä` in NFD (A + combining diaeresis).
Linux filesystems treated this as a different path from the
existing NFC `Ä` directory. The import created NFD-named
directories alongside the NFC ones, silently splitting the letter
data.

Fix: `unicodedata.normalize("NFC", letter)` before any path
construction. Always. Even when you think the input is "obviously"
NFC. See `scripts/calibration_to_override.py` for the canonical
helper.

## 6. Polyline diff isn't always shape diff

When comparing two polylines (e.g. bake output vs reference), a
high per-checkpoint distance can mean either (a) the shapes are
different, or (b) the same shape is sampled at different
parameterizations.

Example: t's bake and calibrator polylines had a 179‰-of-bbox
max checkpoint distance at t=0.75 along the parameter. Both
polylines traced the same geometric path; the calibrator
distributed more checkpoints along the curl, the bake distributed
more along the stem.

When diff metrics flag something, check parameterization before
chasing a shape bug. Cheap check: compare endpoints first, then
sample at fixed arc-length percentages, not at fixed checkpoint
indices.

## 7. The iPad calibrator's design evolution

The calibrator started as anchor-placement (ANKER mode). Anchors
are pedagogical waypoints; placing them on top of an
algorithmically-baked polyline gave the runtime the start / stop /
check points it needed.

That worked until the polyline itself was wrong. Anchors snap to
polylines, so a wrong polyline produced wrong anchor positions
with no escape.

The fix: SKELETT mode for direct polyline editing. Sparse RDP-
derived handles, Catmull-Rom interpolation between them, save
resamples back to the original checkpoint count. The two modes
(SKELETT and ANKER) stay strictly separate; editing one never
affects the other.

**Generalizable lesson:** if your tool's edit affordances only
operate on the wrong layer of abstraction, that's not a bug —
that's a missing tool. Building the second tool is often less
work than fighting around its absence.

---

# Part B — Code-level invariants

Hard-won invariants that catch regressions a typecheck won't. Read
this before touching `AudioEngine.swift`, `StrokeTracker.swift`,
or the `load(letter:)` path. (Earlier revisions of this file
logged a council-style automation pipeline's post-mortems; that
pipeline is gone, so only the invariants survived the trim.)

_Last audited 2026-04-29 against `main` after the Primae rebrand
+ design-system rollout + U11 dark-mode parity (Asset-Catalog
colorsets) — added the `UIColor(dynamicProvider:)` invariant under
Concurrency._

## Audio + tracking

### `AudioEngine.swift` is stable and fragile
- AVAudioSession + AVAudioEngine setup is intricate and full of
  syntactically-similar lines (catch blocks, optional casts, observer
  registrations). Many "fixes" that look right turn out to be no-ops
  that break compilation or runtime in subtle ways.
- Changes must be minimal and surgical. Never restructure init / deinit
  or rewrite catch blocks.
- The `deinit` uses `nonisolated deinit { Self.removeObservers(for: self) }`
  with a static observer dict keyed by `ObjectIdentifier` — this is the
  only Swift 6 pattern that keeps `@MainActor` isolation off the deinit
  path. Do not refactor it.
- If CI fails on AudioEngine syntax errors, **revert** rather than
  attempt further fixes; the file is bigger than it looks.

### Never replace `hypot()` with `distSq` in `StrokeTracker.update()`
```swift
let dist = hypot(dx, dy)   // KEEP THIS
```
Although squared distance is mathematically equivalent for the
threshold comparison, the change reliably breaks
`fastVelocity_triggersPlayAfterDebounce` and `fastTouch_triggersPlay`:
the fast-drag test path doesn't hit checkpoints under the squared
comparison because of the smoothing windows. This optimisation has
been tried and reverted twice — do not attempt again.

### `load(letter:)` must call audio synchronously
```swift
private func load(letter: LetterAsset) {
    // …
    audio.loadAudioFile(named: firstAudio, autoplay: false)   // SYNC
    playback.request(.idle, immediate: true)                  // SYNC
}
```
The function is already `@MainActor`. **Never** wrap these calls in
`Task { … }` or `Task { @MainActor in … }`. Doing so puts the audio
load behind the `updateTouch` debounce window, which resets playback
state and produces `playCount == 0` failures in
`TracingViewModelTests`.

### `showGhost` must reset on letter change
Every `nextLetter()` / `previousLetter()` / `randomLetter()` /
`loadLetter(name:)` / `loadRecommendedLetter()` path must reset
`showGhost = false`. The reset lives in `load(letter:)`; any new entry
point that bypasses `load(…)` needs its own reset.

## Concurrency (Swift 6)

### `@MainActor` on classes with `@Published`
The package uses `.defaultIsolation(MainActor.self)`, so most classes
are MainActor-implicitly. New classes that hold `@Published` properties
must remain MainActor — explicitly mark them or rely on the implicit
isolation. Forgetting causes Swift 6 strict-concurrency build failures.

### Bare `Task { }` is non-isolated
For `@MainActor`-isolated classes, a direct call from another
`@MainActor` context is already safe — do not wrap in `Task { @MainActor in }`.
Adding a Task wrapper causes ordering issues with debounce timers.
Reserve `Task { @MainActor in }` for callbacks delivered from
genuinely non-isolated contexts (delegate callbacks, completion
handlers from background frameworks).

### `UIColor(dynamicProvider:)` traps on AsyncRenderer
The Primae design tokens originally lived in `Color.dynamic(light:dark:)`
which wrapped each value with `UIColor(dynamicProvider:)`. Under
Swift 6 with `.defaultIsolation(MainActor.self)`, that closure
inherits MainActor isolation. SwiftUI samples dynamic colors from
`com.apple.SwiftUI.AsyncRenderer` (a non-main thread) during async
view-body evaluation, and the strict-concurrency runtime traps the
isolation mismatch as `EXC_BREAKPOINT`. The app crashes the moment
any view body re-evaluates that token — i.e. every tab switch,
picker toggle, animation tick.

**Use Asset-Catalog colorsets instead.** Each colorset has explicit
light + dark `appearance` variants and is compiled into the
host's `.car`; iOS resolves the active variant from the trait
collection without invoking any Swift code.

```
Primae/Primae/Assets.xcassets/Colors/<token>.colorset/Contents.json
PrimaeNative/Theme/Colors.swift  → static let token = Color("<token>")
scripts/gen_colorsets.py         → regenerate the JSON from the
                                    light/dark hex table
```

If you ever need a quick one-off colour that doesn't ship in the
catalog, use `Color(hex: 0xRRGGBB)` (defined in `Colors.swift`) —
it's a pure-arithmetic init with no closure, safe on any thread.

### `OSLog.Logger` has no `.shared` singleton
```swift
// WRONG — does not compile
Logger.shared.warning("…")

// RIGHT
private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "PrimaeNative",
    category: "Recogniser"
)
```
Plain `print()` is also acceptable for short-lived debug output. Do
not invent a `.shared` accessor.

## Testing conventions

### Do not mix `@Test` and `XCTestCase` in the same file
Existing test files written in **XCTest** stay XCTest. **Swift
Testing** (`@Test`, `@Suite`, `#expect`) is for new test files only.
Do not migrate existing XCTest suites. Mixing the two frameworks in
one file produces confusing test discovery behaviour in Xcode.

**Why the existing XCTest files can't be migrated** (verified
2026-04-29 in `docs/ROADMAP_V5_DEFERRED_NOTES.md` D7 section):

- `AudioEngineTests.swift` uses `throw XCTSkip(…)` in instance
  `setUp` to mark the suite as skipped (not failed) when AVAudioSession
  isn't routed on the simulator. Swift Testing's `.disabled(if:)`
  evaluates at attribute time, not at runtime — there's no clean
  equivalent for a runtime hardware-availability gate. Also uses
  `XCTestExpectation` + `wait(for:timeout:)` for NotificationCenter
  callback synchronisation; Swift Testing's `confirmation { }` has
  different semantics.
- `StrokeTrackerRegressionGateTests.swift` and
  `PerformanceBenchmarkTests.swift` use
  `measure(metrics: [XCTClockMetric, XCTCPUMetric, XCTMemoryMetric])`
  to set CI performance regression baselines. **Swift Testing has no
  `XCTMetric` equivalent as of Swift 6.x.** Re-implementing would
  drop the regression gate or require a hand-rolled benchmark harness.

The `.swiftLanguageMode(.v5)` carve-out on the test target
(`Package.swift:32`) exists because `XCTestCase`'s inherited
nonisolated init conflicts with the package's
`.defaultIsolation(MainActor.self)` under Swift 6 strict checking.
The carve-out is load-bearing as long as any XCTest file remains.

If a future Swift Testing release ships an `XCTMetric` equivalent,
revisit the perf files first, then `AudioEngineTests`. Until then
the policy holds.

### Tests must match actual implementation behaviour
When adding tests, first read the implementation to understand what it
actually does. Do not write tests that describe desired future
behaviour and assert against the current code — they will fail. Test
coverage tasks add tests that **pass** against current code; behaviour
changes need a separate commit.

## SwiftUI / Observation

### Use `@Observable`, not `ObservableObject` / `@Published`
The migration is complete: `grep -r "ObservableObject\|@Published"
PrimaeNative/` returns zero matches (verified 2026-04-29).
**Do not regress** any new type back to the `ObservableObject` /
`@Published` shape — it would re-introduce isolation traps under
Swift 6 strict-concurrency checking. Every new observable type uses
`@MainActor @Observable final class`.

## Repo hygiene

### `.github/workflows/` modifications need explicit user approval
CI workflow files are infrastructure, not application code. Invalid
GitHub Actions syntax breaks every future run, so changes are
high-risk. **Modify only when the user has explicitly approved the
specific change.** Dependabot handles deprecation warnings.

Approved-and-applied changes for the record:
- `a6a8bc4` (D9 ROADMAP_V5): added `timeout-minutes: 20` /
  `25` caps on the simulator + device-test jobs so a hung
  `xcodebuild` can't sit at "in_progress" until GitHub's 6-hour
  default kills it.
- `1ac48be` (ROADMAP_V5 branch CI): added `roadmap-*` to the
  `branches:` filter on push + pull_request triggers so
  feature-roadmap branches get the same build + test treatment as
  main without manual `workflow_dispatch`.

Both were minimal, targeted, and validated by the next CI run. Future
modifications should follow the same shape: small, reviewable, and
the next CI run is the verification.

### `git revert` can truncate Swift files
`git revert --no-commit` of multiple commits that touched the same
file (notably `StrokeTracker.swift`) once left the file missing its
closing `}` class brace. Swift's quick-syntax check accepted it but
the build failed.
- After **any** revert, verify the affected file ends with `}` before
  pushing.
- Never chain multiple reverts on the same file in one
  `git revert --no-commit` call — split them.

## Calibrator

### SKELETT bootstrap is read-only against `editableStrokes`
Opening a letter in SKELETT mode and saving without making any
handle edit produces a byte-identical `strokes.json` (modulo the
3-decimal rounding in `CalibrationStore.persist`).
`bootstrapHandles` derives the `handles` array from
`editableStrokes` but never writes back. `editableStrokes` is
only mutated by user gesture handlers (drag, insert, delete,
anchor edits) and by the load/reset paths.

Verified by code audit of all 12 `editableStrokes` write sites in
`StrokeCalibrationOverlay.swift` and by a Python simulator of the
bootstrap → handles → no-edit-save path against all 59 letters
(all show 0.00 px drift on the no-edit path).

The 40 px post-edit drift on D's bowl is a separate concern —
the SKELETT post-edit edit-locality issue. If you touch the
bootstrap or save paths, re-run the simulator before pushing.
