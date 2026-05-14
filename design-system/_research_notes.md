# Research Notes — Primae

Source: https://github.com/TheDave94/Primae/blob/main/docs/APP_DOCUMENTATION.md

## Product summary
- iPadOS app for German-speaking 5–6 year-old Austrian Volksschule first-graders to learn handwriting
- iPad-only, landscape, iOS 18+, Swift 6.3 / Xcode 26.4 (newer SwiftUI version per docs)
- Public README in repo describes older C/C++ SDL3 "Timestretch" version with PBM masks + MP3 audio, ~7 letters (A F I K L M O)
- UI 100% German. Apple Pencil + finger input. CoreML on-device letter recognition. Haptics. Audio time-stretching tied to writing velocity.
- Master's thesis project with built-in A/B test infrastructure

## Three "worlds" (top-level navigation)
- **Schule** ("School") — book.fill icon — 4-phase guided tracing flow
- **Werkstatt** ("Workshop") — pencil.tip icon — freeform writing
- **Fortschritte** ("Progress / Stars") — star.fill icon — star + streak + letter gallery
- 64pt left rail (`WorldSwitcherRail`); 2-second long-press on gear icon → parent area (gated)

## 4-phase pedagogical flow per letter (Gradual Release of Responsibility)
1. **Anschauen** (observe) — animated guide dot traces strokes; orange dot; "Schau mal genau hin." spoken
2. **Richtung lernen** (direct) — pulsing numbered start dot per stroke, child taps in order; arrow flashes 1.2s; "Tippe die Punkte der Reihe nach."
3. **Nachspuren** (guided) — faint blue ghost lines (line width 8, opacity 0.4); real-time green ink (line width 4 at first, 8 actual); haptic+audio feedback; "Jetzt fährst du die Linien nach."
4. **Selbst schreiben** (freeWrite) — blank canvas, no scaffolding, no audio/haptics; "Jetzt schreibst du den Buchstaben ganz alleine."

## Key visual color cues (extracted from doc)
- **Reference / ghost strokes**: BLUE, line width 8, opacity 0.4
- **Child's path / live ink**: GREEN, line width 4 (KP overlay) / 8 (active stroke)
- **Animation guide dot (observe)**: ORANGE
- **KP overlay background**: darkened
- **Direct phase**: pulsing numbered dot
- Recognition rows: GREEN tint = correct, ORANGE tint = incorrect
- 3 emoji self-assessment: 😟 / 😐 / 😊 (scores 0.0/0.5/1.0)

## Typography
- **Primae** font family — custom display, 22 OTF weights bundled (Regular, Light, Semilight, Semibold, Bold + cursives + PrimaeText)
  - Used for Druckschrift (print) — clean sans-serif with unambiguous lowercase forms
- **Playwrite AT** (Playwrite Österreich) — Austrian school cursive, SIL OFL 1.1, variable TTF
  - Used for Schreibschrift (cursive)
- 5 SchriftArt enum cases, only 2 bundled (Druckschrift, Schreibschrift). Other 3: Grundschrift, Vereinfachte Ausgangsschrift, Schulausgangsschrift (scaffolded only)
- UI labels deliberately generic ("Schreibschrift") rather than "Schulschrift 1995" because not bundled

## German copy strings (in-doc / from ChildSpeechLibrary)
- "Schau mal genau hin." — observe phase prompt
- "Tippe die Punkte der Reihe nach." — direct phase prompt
- "Jetzt fährst du die Linien nach." — guided phase prompt
- "Jetzt schreibst du den Buchstaben ganz alleine." — freeWrite prompt
- Phase names (German): Anschauen / Richtung lernen / Nachspuren / Selbst schreiben
- World names: Schule / Werkstatt / Fortschritte
- Settings sections: Schriftart, Buchstabenreihenfolge, Freies Schreiben, Forschung, Hilfe
- Settings rows: Druckschrift / Schreibschrift, Studienteilnahme (A/B-Arm), Schreiben auf Papier, Einführung wiederholen
- Buttons: "Los geht's!", "Weiter", "Fertig!"
- Verbal trend: "aufwärts / stabil / abwärts" (no numbers shown to child)
- "Für Eltern: gedrückt halten zum Überspringen"
- "KI-Modell nicht verfügbar" (when CoreML model missing)
- "Nachspuren fertig"
- Onboarding 7 steps: welcome → traceDemo (A) → directDemo → guidedDemo → freeWriteDemo (green A) → rewardIntro → complete

## Onboarding step titles
Welcome / Anschauen / Richtung lernen / Nachspuren / Selbst schreiben / Sterne sammeln

## Letters shipped (full audio + checkpoints)
A, F, I, K, L, M, O (the demo set)

## Star system
0–4 stars per letter (one per phase completed). `LetterStars` struct.

## Parent-only screens
- ParentAreaView (NavigationSplitView): Übersicht, Forschungs-Daten, Einstellungen, Datenexport
- Schreibmotorik 4-tile dashboard: Form (×0.40), Tempo (×0.25), Druck (×0.15), Rhythmus (×0.20)
- 30-day practice trend chart, top-5 strongest letters, "Übung nötig" letters, paper-transfer scores, recognition accuracy

## Iconography clue
Uses **SF Symbols** style names (book.fill, pencil.tip, star.fill, gearshape, etc.). No custom icon set described. iPadOS native conventions.

## Schriftart switching key
UserDefaults: `de.flamingistan.buchstaben.selectedSchriftArt`
Suggests bundle ID base: `de.flamingistan.buchstaben.*`

## Audio
- AVAudioEngine + AVAudioUnitTimePitch (pitch-preserving time-stretch)
- Audio speed maps to writing velocity (0.5x = slow, 1.0x normal, 2.0x fast)
- Stereo panning via canvas-x → hBias

## Tone / vibe (inferred)
- Direct, warm, child-second-person ("du fährst, du schreibst")
- No emoji in copy except the 3 self-assessment faces (😟😐😊)
- Encouraging, not corrective — "verbal-only result popups, no metrics shown to children"
- Adult-language is more clinical (Schreibmotorik, Studienteilnahme)
- All adult/child speech in German

## Caveats / unknowns I had to infer
- No screenshots in the doc — actual hex colors, exact layouts, spacing not explicit
- Logo / app icon: not described in doc
- Background colors / surfaces: not specified — I'll choose warm paper-like neutrals appropriate for a child education app, with distinct world tints
- Public repo doesn't have the SwiftUI source; I'm working from the spec doc only
