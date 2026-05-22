# Primae — Manual Test Checklist

A manual end-to-end checklist for verifying the iPad app works as
expected after a fresh build.

> **For the interactive (clickable + auto-saving) version, open
> [`testing_checklist.html`](testing_checklist.html)** directly from
> Finder. GitHub-Markdown checkboxes are only clickable inside
> Issues / PRs / Discussions, NOT inside repo `.md` files — the
> HTML page has real `<input type="checkbox">`es backed by
> `localStorage`, a sticky progress counter, and a "Copy unchecked"
> button that drops the unticked items onto your clipboard ready to
> paste back. Regenerate it after editing this file with
> `python3 scripts/render_checklist.py`.

If a box doesn't tick (i.e. a behaviour is broken), copy the
**failure pointer** under that item back to me and I'll cut the
precise fix. The pointers name the file and the rough symbol, not
line numbers — line numbers drift, names don't.

> **Audience:** the person doing the testing. Test on a real iPad
> (or the iPad-A16 simulator from CI). Most child-facing
> behaviours work the same on both; pencil pressure + haptics are
> physical-iPad-only.

---

## 0 · Build, install, launch

- [ ] **Repo clones cleanly.**
  - Steps: `git clone https://github.com/TheDave94/Primae.git ~/repos/Primae && cd ~/repos/Primae && open Primae/Primae.xcodeproj`.
  - Expected: Xcode opens the project; the SPM ref `../../Primae` resolves automatically; no red files.
  - If broken: SPM relative path mismatch — check `Primae/Primae.xcodeproj/project.pbxproj` `XCLocalSwiftPackageReference`.
- [ ] **CI is green** for the commit you're testing.
  - `gh run list --repo TheDave94/Primae --limit 3` should show `success` for the SHA.
- [ ] **App builds** to the iPad-A16 simulator with `xcodebuild build -project Primae/Primae.xcodeproj -scheme Primae -destination "platform=iOS Simulator,name=iPad (A16)" -configuration Debug CODE_SIGNING_ALLOWED=NO`.
- [ ] **App launches** — a paper-cream screen appears with the world rail on the left.
  - If broken: check `Primae/Primae/PrimaeApp.swift:MainEntryPoint` (the @main entry).

---

## 1 · App icon & display name

- [ ] **Home-screen icon** shows the Primae glyph (rounded blue square, white "Aa" wordmark, amber dot top-right).
  - If broken: `Primae/Primae/Assets.xcassets/AppIcon.appiconset/` — re-run `python3 scripts/gen_appicon.py`.
- [ ] **App display name** under the icon reads **"Primae"** (not "BuchstabenApp" or any prior brand).
  - If broken: `INFOPLIST_KEY_CFBundleDisplayName` build setting in `Primae/Primae.xcodeproj/project.pbxproj`.

---

## 2 · First-run onboarding

> Skip this section if you've already completed onboarding once and
> just want to re-verify other features. To force onboarding again,
> delete the app from the simulator (long-press → ✕) and reinstall.
> The 7-step (or 3-step short) flow runs once per install.

- [ ] **Welcome step** shows ✏️ + "Willkommen!" + "Lerne, Buchstaben zu schreiben!" + a "Los geht's!" sticker button.
- [ ] **Tapping "Los geht's!"** advances to the **Anschauen** step (eye 👁️ + "Schau, wie der Buchstabe geschrieben wird!" + an animated A glyph cycling through three strokes).
- [ ] **"Weiter"** advances to **Richtung lernen** (☝️ + "Tippe die Punkte der Reihe nach an!" + numbered start-dot demo).
- [ ] Advances to **Nachspuren** (✏️ + "Fahre mit dem Finger über die Linie!" + an animated 👆 dragging along an A).
- [ ] Advances to **Selbst schreiben** (🖊️ + "Zum Schluss schreibst du den Buchstaben alleine!" + a static A reference).
- [ ] Advances to **Sammle Sterne!** (⭐ + "Für jeden Buchstaben bekommst du bis zu 4 Sterne!" + the four phase icons).
- [ ] **"Fertig!"** closes onboarding and lands you in the **Schule** world with the demo letter A.
  - If broken: `OnboardingView.swift:OnboardingCoordinator` — phase ordering enum.
- [ ] **"Für Eltern: gedrückt halten zum Überspringen"** (long-press in the corner) skips onboarding entirely.

---

## 3 · World rail (left side)

- [ ] **Three world icons** stacked vertically: Schule (book), Werkstatt (pencil tip), Fortschritte (star).
- [ ] **Active world** is highlighted with its tint colour (Schule = blue, Werkstatt = amber, Fortschritte = pink); inactive worlds are tinted-faded.
- [ ] **Tapping a world icon** swaps the right-hand content with a soft slide-in animation (or instant if Reduce Motion is on).
  - **No crash** on any tab switch (Schule ↔ Werkstatt ↔ Fortschritte, every direction).
  - If broken: `MainAppView.swift:body` worldContent transition or `WorldSwitcherRail.swift:worldButton`.
- [ ] **Star badge** sits on the Fortschritte tile (top-right corner) showing the total stars earned across all letters; "99+" when over 99.
  - Hidden when `starTotal == 0`.
  - If broken: `WorldSwitcherRail.swift:starBadge`.
- [ ] **Gear icon** at the bottom of the rail. **Single-tap does nothing**; **long-press for ~2 seconds** opens the Eltern-Bereich (parent area) full-screen cover. A blue progress ring fills around the gear during the press.
  - If broken: `WorldSwitcherRail.swift:gearButton` — `.onLongPressGesture` minimumDuration.

---

## 4 · Schule world — four-phase tracing

> The big paper-canvas takes most of the screen. Top-left has a
> letter pill (current letter + chevron-down), bottom row has
> phase-progress dots + prev/next arrows.

- [ ] **Letter pill** in the top-left shows the current uppercase letter (large) + a small chevron. Tap it: a wheel-style **letter picker** modal appears with all available letters and their star counts.
  - If broken: `SchuleWorldView.swift:letterPill` + `LetterWheelPicker.swift`.
- [ ] **Letter picker** lets you pick any letter; tapping one closes the picker and loads that letter into the canvas.
- [ ] **Prev / Next arrows** (chevron.left / chevron.right at the bottom) cycle through the demo set in the order configured in Settings → Buchstabenreihenfolge.

### 4.1 · Observe phase (Anschauen)

- [ ] Phase enters with the **brand-blue pill** in the lower portion of the canvas showing only **👁️ 👆** (no text — children can't read).
- [ ] **Voiceover** speaks "Pass jetzt gut auf!" (recorded ElevenLabs MP3 if `Resources/Prompts/phase_observe.mp3` is bundled, otherwise system TTS fallback).
  - If broken: `SpeechSynthesizer.swift:ChildSpeechLibrary.phaseEntry(.observe)` or `PromptPlayer.swift`.
- [ ] **Animated guide dot** (amber) traces along the letter's strokes inside the canvas. Loops.
- [ ] **Tapping anywhere** on the canvas advances to the next phase.

### 4.2 · Direct phase (Richtung lernen)

- [ ] **Numbered start-dots** appear over each stroke's start point (1, 2, 3, …). The next-expected dot pulses gently.
- [ ] **Voiceover** speaks "Tipp die Punkte der Reihe nach an."
- [ ] **Tapping the next-expected dot** plays a confirmation tap (haptic + audio) and shows a **directional arrow** along the stroke for ~1.2 s.
- [ ] **Tapping a wrong dot** fires a gentle off-path haptic and pulses the correct one. No advance.
- [ ] **All dots tapped in order** → phase auto-advances.

### 4.3 · Guided phase (Nachspuren)

- [ ] **Ghost letter** (faint blue stroke) is drawn on the canvas as a tracing target.
- [ ] **Voiceover** speaks "Fahr die Linie nach."
- [ ] **Dragging your finger / pencil** along the stroke leaves a **green ink trail** that follows the touch with sub-pixel hysteresis.
- [ ] **Audio time-stretches** with writing speed: slower drag = slower letter sound; faster drag = faster. (Real-device test only — simulator audio works but pencil pressure differs.)
- [ ] **Per-checkpoint haptic ticks** fire as you cross each invisible checkpoint.
- [ ] **Stroke completion haptic** fires at end of each stroke.
- [ ] **All strokes complete** → auto-advances.

### 4.4 · FreeWrite phase (Selbst schreiben)

- [ ] Canvas shows a blank glyph (no ghost letter — the child writes from memory).
- [ ] **Voiceover** speaks "Und jetzt du alleine."
- [ ] **Drawing on the canvas** leaves green ink with no rails.
- [ ] **After lifting** (no input for ~1.5 s), the **CoreML recognizer** runs and shows a coloured **recognition badge** above the canvas:
  - Green + "Du hast ein A geschrieben! 🎉" when correct + confident.
  - Yellow + "Das sieht aus wie ein A — gut gemacht!" when correct + uncertain.
  - Orange + "Das sieht eher nach O aus — schreib nochmal ein A!" when wrong + confident.
  - No badge when confidence is below 0.4.
- [ ] **KP overlay** (knowledge-of-performance) appears: dark scrim with the canonical reference stroke (blue) overlaid on the child's path (green). Auto-dismisses after ~3 s.

### 4.5 · Letter completion celebration

- [ ] **System success chime** plays the moment the final phase completes.
  - If broken: `PromptPlayer.swift:playSuccessChime` (`AudioServicesPlaySystemSound(1322)`).
- [ ] **Voiceover** speaks "Super gemacht!" (regardless of star count).
- [ ] **Celebration overlay** appears: brand-blue panel with 🎉 + "Geschafft!" + a star row showing N-of-4 filled stars + a paper-coloured **Weiter** sticker button.
- [ ] **Tapping Weiter** loads the next recommended letter and lands you on its observe phase.

---

## 5 · Werkstatt world — freeform writing

> Two-column layout: left mode panel (140 pt) with two cards
> (Buchstabe, Wort), right canvas filling the rest.

- [ ] **Mode panel on the left** shows two vertical cards:
  - **Buchstabe** card (character icon).
  - **Wort** card (cursor icon).
  - Active card = filled with `Color.werkstatt` (amber); inactive = paper card with the amber icon.
- [ ] **Tapping Buchstabe** sets letter mode + clears canvas.
- [ ] **Tapping Wort** sets word mode + auto-selects the first word in `FreeformWordList.all` (OMA by default).
- [ ] **No horizontal mode picker at the top of the canvas** — was removed in commit `b41c916` so there's only one path to switch modes.
  - If you see a segmented Buchstabe/Wort picker at the top: `FreeformWritingView.swift:header` — the Picker should be gone.
- [ ] **Header row** at the top of the canvas has only **Zurück** (left) and **Nochmal** (right). The prompt row underneath shows "Schreibe einen Buchstaben mit dem Finger oder dem Stift." in letter mode, or "Schreibe: <WORD>" in word mode.
- [ ] **Tapping Nochmal** clears the canvas.
- [ ] **Tapping Zurück** exits freeform and returns to Schule.
- [ ] **Letter mode**: writing on the canvas + lifting after ~1.5 s triggers recognition; a result popup appears centred (recognised letter + confidence chip).
- [ ] **Word mode**: a word picker strip appears below the header; tapping a word sets it as the target. Writing it letter-by-letter shows per-cell recognition chips (green = correct, grey placeholder = missing).

---

## 6 · Fortschritte world — progress

- [ ] **Top row** has three cards:
  - **Daily-goal pill** ("X / Y today" with 🎯 or 📅 — green when goal met).
  - **Stars-earned card** (⭐ + total stars + "gesammelt").
  - **Streak card** (🔥 + day count + "Tage in Folge" or similar).
- [ ] **Auszeichnungen** (achievements) row scrolls horizontally with reward badges (only earned ones are coloured).
- [ ] **Deine Buchstaben** gallery: a grid of letter tiles, each showing the letter glyph + a 0-of-4 star row.
  - **Tap a letter tile** → loads that letter into Schule and switches the world.
- [ ] **Schreibflüssigkeit** card at the bottom shows a fluency trend (improving / stable / declining + colour).

---

## 7 · Parent area (Eltern-Bereich)

> Reached only via the 2-second gear long-press on the rail.
> Plain iOS `NavigationSplitView` chrome — child should never
> end up here by accident.

### 7.1 · Übersicht (parent dashboard)

- [ ] **Per-letter accuracy chart** visible.
- [ ] **Phase completion rates** card shows per-phase success counts.
- [ ] **30-day practice trend** graph renders.
- [ ] **Paper-transfer scores** section visible (only populated when the toggle is on and the child has completed paper-transfer trials).

### 7.2 · Forschungs-Daten (research dashboard)

- [ ] **Schreibmotorik dimensions** sparkline cards (Form, Tempo, Druck, Rhythmus).
- [ ] **KI predictions** vs. expected count.
- [ ] **Condition-arm distribution** pie/bar chart.
- [ ] **Scheduler-effectiveness Pearson r** stat with explanatory caption.
- [ ] **Last-20 raw phase records** table.
- [ ] **Per-letter aggregates** table.

### 7.3 · Einstellungen

- [ ] **Schriftart** picker: Druckschrift / Schreibschrift. Switching reloads the active glyph in Schule.
- [ ] **Buchstabenreihenfolge** picker: Motorisch ähnlich / Wortbildend / Alphabetisch. Switching re-orders the demo set.
- [ ] **Freies Schreiben erlauben** toggle.
- [ ] **Letzten Strich zuerst** toggle (P5 backward chaining — direct phase only).
- [ ] **Erinnerungstest aktivieren** toggle (P1 spaced retrieval).
- [ ] **Lautwert wiedergeben** toggle (P6 phoneme audio).
- [ ] **Sprechgeschwindigkeit** picker: Langsam / Normal / Schnell. Verify TTS rate changes immediately.
- [ ] **Geisterbuchstabe anzeigen** toggle.
- [ ] **Erscheinungsbild** picker: System / Hell / Dunkel.
  - **Hell** → app stays in light mode regardless of iOS Settings.
  - **Dunkel** → paper turns slate-950, ink turns near-white, canvas semantics flip (blue-400 ghost, emerald-400 ink, amber-400 guide dot). Star count, world tints, brand all flip too.
  - **System** → follows iOS Settings → Display & Brightness.
  - If broken: `PrimaeAppearance.swift:resolve` + `Primae/Primae/Assets.xcassets/Colors/<token>.colorset/Contents.json` for any non-flipping token.
- [ ] **Schreiben auf Papier** toggle (paper-transfer self-assessment).
- [ ] **Studienteilnahme (A/B-Arm)** toggle. When on, **Studienarm überschreiben** picker appears with Automatisch / threePhase / guidedOnly / control.
- [ ] **Kurze Einführung** toggle.
- [ ] **Einführung wiederholen** button.

### 7.4 · Datenexport

- [ ] **CSV exportieren / TSV exportieren / JSON exportieren** buttons each open the iOS share sheet with a file named `primae_progress_<YYYY-MM-DD>.<ext>`.
  - If the filename starts with `buchstaben_` instead: `ParentDashboardExporter.swift` — old prefix not migrated.
- [ ] Sharing the file (e.g. Save to Files) writes a non-empty file with at least one phase-session row.

---

## 8 · Voiceover (TTS / ElevenLabs prompts)

> Two pipelines: pre-recorded ElevenLabs MP3s (preferred) +
> AVSpeechSynthesizer fallback when an MP3 is missing. Until you
> run `scripts/generate_prompts.py`, every prompt comes from the
> system TTS — that's expected.

- [ ] **Phase entry prompts** speak the four phrases above (4.1–4.4) in a German voice. Accent should be German, not English-reading-German.
- [ ] **Letter-completion celebration** speaks "Super gemacht!" once.
- [ ] **Paper-transfer flow** (when the toggle is on, after a freeWrite) speaks three lines in sequence: "Schau dir den Buchstaben gut an." → "Jetzt schreibst du den Buchstaben auf Papier." → "Wie ist dein Buchstabe geworden?"
- [ ] **Retrieval prompt** modal (when the toggle is on, every Nth letter) speaks "Welchen Buchstaben hörst du?" on appear.
- [ ] **Recognition feedback** speaks the badge text (correct / wrong + letter) when the recognizer fires.
- [ ] **Switching Sprechgeschwindigkeit** in Settings to **Langsam** noticeably slows the system-TTS lines (the recorded MP3s play at their fixed recorded rate).
  - If broken: `SpeechSynthesizer.swift:setRate`.

---

## 9 · Audio + haptics during writing

- [ ] **Letter sound** (the recorded phoneme/name MP3 from `Letters/<X>/<X>1.mp3`) plays when you start dragging on the canvas during the guided or freeWrite phase.
- [ ] **Pitch / speed** of the letter sound stretches with stroke velocity — slower drag = lower / longer; faster = higher / shorter.
- [ ] **Per-checkpoint haptic** ticks each time you cross an invisible checkpoint.
- [ ] **Stroke-completion haptic** fires on each stroke end.
- [ ] **Letter-completion haptic** fires (stronger pattern) when the whole letter is done.
- [ ] **Two-finger swipe up / down** cycles through letter-sound variants (A1.mp3 → A2.mp3 → A3.mp3 in letter mode). Currently only the demo letters (A F I K L M O) ship audio variants — others may be silent.

---

## 10 · Adaptive difficulty + scheduler

- [ ] After **two perfect freeWrite trials in a row**, the **checkpoint radius tightens** on the next attempt (you have to hit closer to the centerline). Visible only on real iPad — easier to feel than see in the simulator.
- [ ] After **two poor trials**, the radius widens.
- [ ] **Loading the recommended next letter** (via Weiter on the celebration overlay) prefers letters with low recent accuracy / long since last seen.
- [ ] **Studienteilnahme = on** + Studienarm = `guidedOnly` skips observe / direct / freeWrite — the child only sees guided.
- [ ] **Studienteilnahme = on** + Studienarm = `control` runs all four phases at fixed difficulty (no adaptation).

---

## 11 · Lifecycle

- [ ] **Backgrounding the app** (swipe up to home) mid-trace stops the audio + haptics; ink is preserved.
- [ ] **Resuming** keeps the same letter loaded at the same phase; no lost progress.
- [ ] **Killing the app** and relaunching restores the active world (`primaeAppearance` / `de.flamingistan.primae.activeWorld` AppStorage) and the last letter.

---

## 12 · Edge cases

- [ ] **Picking a letter without audio** (any letter outside the demo set `A F I K L M O`) still runs all four phases, but prompts that would normally play a recording fall back to TTS. (All 59 letters now ship real baked `strokes.json` — the empty-strokes auto-skip branch is no longer reachable in normal use; if you do encounter it, that's a regression.)
- [ ] **No internet connection** — every screen still works; no spinners stuck. (The CoreML recognizer is on-device.)
- [ ] **VoiceOver accessibility** (Settings → Accessibility → VoiceOver) reads the world rail buttons + every Settings toggle correctly. Letter glyphs read as "Aktueller Buchstabe A".
- [ ] **Dynamic Type** (Settings → Accessibility → Larger Text) — Settings + dashboards scale up; canvas chrome stays at fixed sizes (intentional — the canvas is laid out on a fixed grid).
- [ ] **Reduce Motion** (Settings → Accessibility) — world transitions become instant, animations on praise / celebration become opacity-only.
- [ ] **Pencil 2 squeeze** (Pencil 2 only): squeezing replays the active letter audio. Pencil tap is independent of finger tap (no double-fire).

---

## 13 · Visual identity smoke

- [ ] **Paper not glass**: every card surface is opaque (Color.paper), not blurred / translucent.
- [ ] **Sticker buttons** (CTAs): pill capsule, white label on tinted fill, slight shadow, 1-pt offset on press.
- [ ] **Canvas semantics** match the spec:
  - Ghost stroke = blue.
  - Child ink = green.
  - Animation guide dot = amber.
  - Numbered start dot = ink-dark.
  - In dark mode all four flip to their lighter variants (blue-400 / emerald-400 / amber-400 / near-white).
- [ ] **No emoji decoration** in chrome. Only emoji are: 👁️ 👆 (observe overlay), 🎉 (celebration), 🔥 (streak), ⭐ (stars), 😟 😐 😊 (paper-transfer).
- [ ] **Font**: every numeric / heading text uses the bundled **Primae** family (rounded humanist), not SF system. Body copy uses **PrimaeText**. Schreibschrift (when selected) uses **Playwrite AT**.
  - If a label looks like SF instead of Primae: `PrimaeFonts.registerAll()` may have failed — check the logger output for "PrimaeFonts: register failed" lines.

---

## 14 · Stroke calibrator — single-checkpoint dots ("+ Punkt")

> DEBUG-only flow. Reach the calibrator via parent-area → Werkzeuge (or
> the dev menu — the path varies). Verify the new `+ Punkt` workflow
> for authoring single-checkpoint dot strokes (umlaut diaeresis,
> tittles).

- [ ] **`+ Punkt` button visible** in the calibrator's bottom action
  row, next to `+ Strich`. Same green tint and visual weight. Icon
  is a filled small-circle inside a circle.
- [ ] **Tap `+ Punkt` with no letter loaded**: silent no-op (button is
  inert until a letter is active).
- [ ] **Tap `+ Punkt` on a loaded letter**: a new empty stroke
  appears in the chip row; calibrator switches to ANKER mode; status
  hint reads "Punkt setzen — Strich N: tippen, um Punkt zu platzieren".
- [ ] **Tap once in canvas**: a single-point dot stroke is created
  at the tap location; status hint updates to "Punkt setzen —
  Strich N: Punkt platziert, erneut tippen zum Verschieben".
- [ ] **Tap a different canvas location while still in `+ Punkt`
  mode**: the dot moves to the new location (the stroke remains a
  single checkpoint; no new stroke added).
- [ ] **Speichern**: the dot persists. After save, reopening the
  letter shows the dot at the same position.
- [ ] **`+ Punkt` without placement + Speichern**: no-op. No empty
  stroke gets persisted; the chip row drops back to the prior
  stroke count after save.
- [ ] **`+ Punkt` + switch to SKELETT mode without placement**:
  the empty stroke is pruned (chip count returns to prior).
- [ ] **Tap `+ Punkt` outside the bbox** (above the cap-height
  margin): silent ignore — no stroke created at out-of-bbox
  coordinates.
- [ ] **Round-trip test on Ä**: tap `+ Punkt` → tap at (~0.34, 0.05)
  → tap `+ Punkt` again → tap at (~0.66, 0.05) → Speichern. Reopen
  Ä: two single-checkpoint dot strokes visible at the placed
  positions (matches the Ü dot template).
- [ ] **Session log captures the dot add**: open Files app → Primae
  → `PrimaeNative/CalibrationSessions/Ä/<timestamp>.json` →
  inspect: `post_polyline` should include the new single-point
  stroke as a 1-element array. `tool` field reads `"ANKER"` (dot
  placement is an ANKER-mode action). `edit_count_in_session`
  > 0.

If broken: `StrokeCalibrationOverlay.swift::addPunkt` /
`placePunkt`. AnkerTool's `.punkt` case is filtered out of the
toolbar (only the `+ Punkt` button can activate it) — if it
appears in the toolbar pill row, check the `inToolbar` filter at
the ANKER `ForEach`.

---

## How to report a failure back

For each unticked box, paste back:
1. The **section number + line** (e.g. "4.4 last bullet — recognition badge stays grey").
2. Any **simulator console output** (Xcode → Debug Area → cmd-` to focus, copy red lines).
3. A **single-line description** of what you saw vs. what was expected.

I'll cut the fix against the file pointer in the bullet, push, and reply when CI is green so you can re-tick.
